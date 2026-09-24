class_name OsThumbnails
extends Node

## Thumbnails the operating system already has for files and folders. The
## player never decodes media for these itself.
##
##   Windows — the shell's IShellItemImageFactory, i.e. exactly what Explorer
##             shows (thumbnail cache, installed thumbnail providers, or the
##             file type's icon). Queried through one long-lived PowerShell
##             helper (C# compiled by Add-Type) so no native module is
##             needed. One request is in flight at a time; a request that
##             hangs (a misbehaving shell extension) is abandoned and the
##             helper restarted.
##   Linux   — the freedesktop thumbnail cache (~/.cache/thumbnails), i.e.
##             whatever the file manager already made. Folders get none.
##   Other   — none; callers keep their placeholder icons.
##
## request() answers from the cache immediately when it can; otherwise the
## result arrives later via thumbnail_ready (only for paths that have one).

signal thumbnail_ready(path: String, texture: Texture2D)

const SIZE := 256
const CACHE_LIMIT := 1000
## Seconds to wait for one thumbnail; the first also covers helper start-up
## (PowerShell launch + C# compile, typically 1–3 s).
const REQUEST_TIMEOUT := 15.0
const STARTUP_TIMEOUT := 30.0
## Stop trying after this many helper crashes / timeouts in one session.
const MAX_HELPER_FAILURES := 3
const HELPER_SCRIPT := "user://os_thumbnails.ps1"
## The helper writes each thumbnail's pixels here (one request in flight, so
## one file suffices) — far faster than pushing them through the pipe, which
## Godot reads a byte per syscall.
const HELPER_PIXELS := "user://os_thumbnail.rgba"

## path → Texture2D, or null once known to have none.
var _cache: Dictionary = {}
var _queue: Array[String] = []

# Windows helper state.
var _proc: Dictionary = {}
var _reader: Thread
var _mutex := Mutex.new()
## Parsed replies from the reader thread: [path, Image-or-null], or ["", null] on helper exit.
var _replies: Array = []
var _in_flight: String = ""
var _in_flight_left: float = 0.0
var _helper_started: bool = false
## No reply yet from this helper instance (start-up still in progress).
var _helper_cold: bool = false
var _helper_failures: int = 0


func is_supported() -> bool:
	match OS.get_name():
		"Windows":
			return _helper_failures < MAX_HELPER_FAILURES
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			return true
	return false


## Cached texture for `path`, or null. When not yet known, queues a lookup
## whose result arrives via thumbnail_ready.
func request(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	if not is_supported():
		return null
	if OS.get_name() != "Windows":
		_store(path, _freedesktop_lookup(path))
		return _cache[path]
	if path != _in_flight and not _queue.has(path):
		_queue.append(path)
		_pump()
	return null


## Drop queued (not yet sent) lookups — e.g. after navigating elsewhere.
func cancel_pending() -> void:
	_queue.clear()


func _process(delta: float) -> void:
	if _in_flight == "":
		return
	_mutex.lock()
	var replies := _replies
	_replies = []
	_mutex.unlock()
	for r in replies:
		var path: String = r[0]
		if path == "":
			_on_helper_failed("helper exited")
			return
		if path != _in_flight:
			continue  # stale answer from before a restart
		_in_flight = ""
		_helper_cold = false
		var img: Image = r[1]
		var tex: Texture2D = ImageTexture.create_from_image(img) if img != null else null
		_store(path, tex)
		if tex != null:
			thumbnail_ready.emit(path, tex)
	if _in_flight != "":
		_in_flight_left -= delta
		if _in_flight_left <= 0.0:
			_store(_in_flight, null)
			_on_helper_failed("timed out on %s" % _in_flight)
			return
	_pump()


func _exit_tree() -> void:
	_stop_helper()


func _store(path: String, tex: Texture2D) -> void:
	if _cache.size() >= CACHE_LIMIT:
		_cache.clear()
	_cache[path] = tex


# --- Windows helper ---

func _pump() -> void:
	if _in_flight != "" or _queue.is_empty() or not is_supported():
		return
	if not _helper_started and not _start_helper():
		_on_helper_failed("could not start")
		return
	_in_flight = _queue.pop_front()
	_in_flight_left = STARTUP_TIMEOUT if _helper_cold else REQUEST_TIMEOUT
	var stdio: FileAccess = _proc["stdio"]
	stdio.store_line(_in_flight)
	stdio.flush()


func _start_helper() -> bool:
	var f := FileAccess.open(HELPER_SCRIPT, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(_HELPER_PS1)
	f.close()
	var exe := "powershell.exe"
	var sys_root := OS.get_environment("SystemRoot")
	if sys_root != "":
		var full := sys_root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
		if FileAccess.file_exists(full):
			exe = full
	_proc = OS.execute_with_pipe(exe, [
		"-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
		"-ExecutionPolicy", "Bypass",
		"-File", ProjectSettings.globalize_path(HELPER_SCRIPT),
		str(SIZE), ProjectSettings.globalize_path(HELPER_PIXELS),
	])
	if _proc.is_empty():
		return false
	_helper_started = true
	_helper_cold = true
	_reader = Thread.new()
	_reader.start(_read_loop.bind(_proc["stdio"]))
	return true


func _stop_helper() -> void:
	if not _helper_started:
		return
	_helper_started = false
	if OS.is_process_running(_proc["pid"]):
		OS.kill(_proc["pid"])
	if _reader != null:
		_reader.wait_to_finish()
		_reader = null
	_proc = {}
	_mutex.lock()
	_replies.clear()
	_mutex.unlock()
	DirAccess.remove_absolute(HELPER_PIXELS)


func _on_helper_failed(why: String) -> void:
	_helper_failures += 1
	push_warning("OsThumbnails: thumbnail helper %s (%d/%d)." % [why, _helper_failures, MAX_HELPER_FAILURES])
	_in_flight = ""
	_stop_helper()
	if not is_supported():
		_queue.clear()
	else:
		_pump()


## Reader thread: one reply line per request —
##   "THUMB\t<path>\t<width>\t<height>"  (RGBA8 pixels in HELPER_PIXELS)
##   "THUMB\t<path>\t"                    (the shell has nothing)
## Anything else (start-up chatter) is ignored.
func _read_loop(stdio: FileAccess) -> void:
	while true:
		var line := stdio.get_line()
		if line == "" and (stdio.eof_reached() or stdio.get_error() != OK):
			break
		if not line.begins_with("THUMB\t"):
			continue
		var parts := line.split("\t")
		if parts.size() < 3:
			continue
		var img: Image = null
		if parts.size() >= 4:
			var w := parts[2].to_int()
			var h := parts[3].to_int()
			var px := FileAccess.get_file_as_bytes(HELPER_PIXELS)
			if w > 0 and h > 0 and px.size() == w * h * 4:
				img = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)
		_mutex.lock()
		_replies.append([parts[1], img])
		_mutex.unlock()
	_mutex.lock()
	_replies.append(["", null])
	_mutex.unlock()


# --- freedesktop ---

func _freedesktop_lookup(path: String) -> Texture2D:
	var cache_home := OS.get_environment("XDG_CACHE_HOME")
	if cache_home == "":
		cache_home = OS.get_environment("HOME").path_join(".cache")
	var name := _file_uri(path).md5_text() + ".png"
	for size_dir in ["large", "x-large", "xx-large", "normal"]:
		var png := cache_home.path_join("thumbnails").path_join(size_dir).path_join(name)
		if FileAccess.file_exists(png):
			var img := Image.load_from_file(png)
			if img != null and not img.is_empty():
				return ImageTexture.create_from_image(img)
	return null


static func _file_uri(path: String) -> String:
	var segments := path.split("/")
	for i in segments.size():
		segments[i] = segments[i].uri_encode()
	return "file://" + "/".join(segments)


const _HELPER_PS1 := r"""# Written by the VJ player (OsThumbnails); regenerated on every start.
# Reads file paths on stdin, answers each with the shell's thumbnail as
# "THUMB<TAB>path<TAB>w<TAB>h" with the RGBA8 pixels written to $PixelFile
# (or "THUMB<TAB>path<TAB>" when there is no thumbnail).
param([int]$Size = 256, [string]$PixelFile)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

public static class VjOsThumbs {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SIZE { public int cx; public int cy; }

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAP {
        public int bmType; public int bmWidth; public int bmHeight; public int bmWidthBytes;
        public ushort bmPlanes; public ushort bmBitsPixel; public IntPtr bmBits;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER {
        public int biSize; public int biWidth; public int biHeight;
        public short biPlanes; public short biBitCount; public int biCompression; public int biSizeImage;
        public int biXPelsPerMeter; public int biYPelsPerMeter; public int biClrUsed; public int biClrImportant;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, ref BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint lines,
        byte[] bits, ref BITMAPINFOHEADER bmi, uint usage);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    public static void Run(int size, string pixelFile) {
        var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
        var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        output.AutoFlush = true;
        output.NewLine = "\n";
        string line;
        while ((line = input.ReadLine()) != null) {
            string path = line.TrimEnd('\r', '\n');
            if (path.Length == 0) continue;
            string reply = "";
            try { reply = Encode(path.Replace('/', '\\'), size, pixelFile); } catch (Exception) { reply = ""; }
            output.WriteLine("THUMB\t" + path + "\t" + reply);
        }
    }

    // Writes RGBA8 (straight alpha) to pixelFile and returns "w\th", or ""
    // when the shell has nothing.
    static string Encode(string path, int size, string pixelFile) {
        Guid iid = typeof(IShellItemImageFactory).GUID;
        IShellItemImageFactory factory;
        if (SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out factory) != 0 || factory == null) return "";
        IntPtr hbm = IntPtr.Zero;
        try {
            SIZE s; s.cx = size; s.cy = size;
            // Flags 0 = SIIGBF_RESIZETOFIT: thumbnail if there is one, else the icon.
            if (factory.GetImage(s, 0, out hbm) != 0 || hbm == IntPtr.Zero) return "";
            BITMAP bm = new BITMAP();
            if (GetObject(hbm, Marshal.SizeOf(typeof(BITMAP)), ref bm) == 0) return "";
            int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
            if (w <= 0 || h <= 0) return "";
            BITMAPINFOHEADER bmi = new BITMAPINFOHEADER();
            bmi.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bmi.biWidth = w; bmi.biHeight = -h; bmi.biPlanes = 1; bmi.biBitCount = 32;
            byte[] px = new byte[w * h * 4];
            IntPtr dc = GetDC(IntPtr.Zero);
            int got = GetDIBits(dc, hbm, 0, (uint)h, px, ref bmi, 0);
            ReleaseDC(IntPtr.Zero, dc);
            if (got == 0) return "";
            // BGRA premultiplied → RGBA straight. An all-zero alpha channel
            // means the bitmap carries no alpha at all: treat as opaque.
            bool hasAlpha = false;
            for (int i = 3; i < px.Length; i += 4) { if (px[i] != 0) { hasAlpha = true; break; } }
            for (int i = 0; i < px.Length; i += 4) {
                int b = px[i], g = px[i + 1], r = px[i + 2], a = hasAlpha ? px[i + 3] : 255;
                if (a > 0 && a < 255) {
                    r = Math.Min(255, r * 255 / a); g = Math.Min(255, g * 255 / a); b = Math.Min(255, b * 255 / a);
                }
                px[i] = (byte)r; px[i + 1] = (byte)g; px[i + 2] = (byte)b; px[i + 3] = (byte)a;
            }
            File.WriteAllBytes(pixelFile, px);
            return w + "\t" + h;
        } finally {
            if (hbm != IntPtr.Zero) DeleteObject(hbm);
            Marshal.ReleaseComObject(factory);
        }
    }
}
'@
[VjOsThumbs]::Run($Size, $PixelFile)
"""
