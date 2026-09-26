class_name VisualizerShaders
extends RefCounted

## Shaders for the shader layers. A key is a file path ("" = none):
##   *.glsl / *.frag / *.txt — Shadertoy code pasted as-is (its mainImage);
##                             wrapped with the compatibility includes on load
##   *.gdshader              — a Godot canvas_item shader, used as-is (it can
##                             include the same two files itself, as the
##                             built-ins do)
## A .gdshader that uses `input_tex` (usually by including EFFECT_PRELUDE)
## is an effect instead: it runs on a layer's or the screen's output, after
## the layer's shader, and gets none of the Shadertoy inputs.
##
## Hints, read from the source:
##   // @resolution 1024x1024  — pixel size a layer shader renders at (and
##                               its screen's shape); default DEFAULT_RESOLUTION,
##                               or that height at the video's shape when the
##                               shader reads the video. `@resolution 270`
##                               gives just the height (x = 0), the width
##                               following that same shape
##   // @iChannel1 video       — what a layer's iChannelN samples (one of
##                               CHANNEL_SOURCES); iChannel0 is "audio" unless
##                               tagged otherwise
##   uniform float x : hint_range(0.0, 1.0, 0.01) = 0.5;
##                             — a slider in the Camera tab (int too); a
##                               plain `uniform bool` gets a checkbox
##
## Built-ins ship with the player; user shaders are discovered in
## `user://shaders/` and a `shaders/` folder next to the executable, like
## skyboxes.

const PRELUDE := "res://player/visualizer/shadertoy_prelude.gdshaderinc"
const MAIN := "res://player/visualizer/shadertoy_main.gdshaderinc"
const EFFECT_PRELUDE := "res://player/visualizer/effect_prelude.gdshaderinc"
const SHADERTOY_EXTENSIONS := ["glsl", "frag", "txt"]
const GODOT_EXTENSIONS := ["gdshader"]
const DEFAULT_RESOLUTION := Vector2i(960, 540)
## @iChannelN sources: the live audio texture, or the playing video's whole
## frame (both eyes of a stereo video; see Visualizer).
const CHANNEL_SOURCES := ["audio", "video"]

const KEY_BLACK := "res://player/visualizer/effects/key_black.gdshader"
const OVAL_MASK := "res://player/visualizer/effects/oval_mask.gdshader"
const EDGE_BLUR := "res://player/visualizer/effects/edge_blur.gdshader"
## Effect uniforms the chain sets itself (see effect_prelude.gdshaderinc),
## never controls.
const CHAIN_INPUTS := ["prepass"]
## Not an ordinary effect: Screen grows the passes after it (see padding.gdshader).
const PADDING := "res://player/visualizer/effects/padding.gdshader"
const GLOW := "res://player/visualizer/effects/glow.gdshader"
const CROP := "res://player/visualizer/effects/crop.gdshader"
const ROUNDED_CORNERS := "res://player/visualizer/effects/rounded_corners.gdshader"
const KEEP_CENTER := "res://player/visualizer/effects/keep_center.gdshader"

const BUILTINS := [
	{"key": "res://player/visualizer/shaders/light_ring.gdshader", "label": "Light ring"},
	{"key": "res://player/visualizer/shaders/spectrum_bars.gdshader", "label": "Spectrum bars"},
	{"key": "res://player/visualizer/shaders/video_blur.gdshader", "label": "Video blur"},
]
const BUILTIN_EFFECTS := [
	{"key": KEY_BLACK, "label": "Key black"},
	{"key": OVAL_MASK, "label": "Oval mask"},
	{"key": EDGE_BLUR, "label": "Edge blur"},
	{"key": PADDING, "label": "Padding"},
	{"key": GLOW, "label": "Glow"},
	{"key": CROP, "label": "Crop"},
	{"key": ROUNDED_CORNERS, "label": "Rounded corners"},
	{"key": KEEP_CENTER, "label": "Keep center"},
]

## key -> parse_hints() result; cleared by list_options so edits show up.
static var _hints_cache := {}


## Folders scanned for user shaders. Missing folders are skipped.
static func search_dirs() -> Array[String]:
	var out: Array[String] = [ProjectSettings.globalize_path("user://shaders")]
	out.append(OS.get_executable_path().get_base_dir().path_join("shaders"))
	return out


## [{key, label}] for a dropdown: built-ins first, then discovered files —
## layer shaders, or effects when `effects`. Doesn't include a "none" entry.
static func list_options(dirs: Array[String] = search_dirs(), effects: bool = false) -> Array[Dictionary]:
	_hints_cache.clear()
	var out: Array[Dictionary] = []
	for b in (BUILTIN_EFFECTS if effects else BUILTINS):
		out.append(b.duplicate())
	for dir in dirs:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		var files := Array(d.get_files())
		files.sort()
		for f in files:
			var ext := String(f).get_extension().to_lower()
			var path := dir.path_join(f)
			var is_effect := false
			if ext in GODOT_EXTENSIONS:
				is_effect = is_effect_code(FileAccess.get_file_as_string(path))
			elif not ext in SHADERTOY_EXTENSIONS:
				continue
			elif CameraFxShaders.is_camera_code(FileAccess.get_file_as_string(path)):
				continue  # a camera effect (CameraFxShaders), not a layer
			if is_effect == effects:
				out.append({"key": path, "label": String(f).get_basename()})
	return out


## The shader for `key`, or null if it can't be read. User files are read
## fresh each time, so re-selecting one picks up edits.
static func load_shader(key: String) -> Shader:
	if key == "":
		return null
	var ext := key.get_extension().to_lower()
	if ext in GODOT_EXTENSIONS:
		if key.begins_with("res://"):
			return load(key) as Shader
		return ResourceLoader.load(key, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if ext in SHADERTOY_EXTENSIONS:
		if not FileAccess.file_exists(key):
			return null
		var shader := Shader.new()
		shader.code = wrap_shadertoy(FileAccess.get_file_as_string(key))
		return shader
	return null


## Godot shader source around pasted Shadertoy code.
static func wrap_shadertoy(source: String) -> String:
	return "shader_type canvas_item;\n#include \"%s\"\n\n%s\n\n#include \"%s\"\n" % [PRELUDE, source, MAIN]


static func is_effect_code(code: String) -> bool:
	return code.contains("input_tex") or code.contains(EFFECT_PRELUDE)


## Whether an effect wants a prepass (it declares `prepass_tex`; see
## effect_prelude.gdshaderinc and Screen).
static func has_prepass(shader: Shader) -> bool:
	return shader != null and shader.code.contains("prepass_tex")


## parse_hints() for the shader at `key` (cached); {} hints if unreadable.
static func hints_for(key: String) -> Dictionary:
	if not _hints_cache.has(key):
		var shader := load_shader(key)
		_hints_cache[key] = parse_hints(shader.code if shader != null else "")
	return _hints_cache[key]


## {resolution: Vector2i (ZERO = none given, x 0 = height only), channels: {index: source}
## (always has 0), params: [{name, type ("float" / "int" / "bool"), min,
## max, step, default}]} from shader source. Only uniforms with a
## hint_range, and bools, become params; unknown channel sources are skipped.
static func parse_hints(code: String) -> Dictionary:
	var out := {"resolution": Vector2i.ZERO, "channels": {0: "audio"}, "params": []}
	var res_re := RegEx.create_from_string("@resolution\\s+(\\d+)(?:\\s*[xX×]\\s*(\\d+))?")
	var m := res_re.search(code)
	if m != null:
		if m.get_string(2) == "":
			out.resolution = Vector2i(0, int(m.get_string(1)))
		else:
			out.resolution = Vector2i(int(m.get_string(1)), int(m.get_string(2)))
	var ch_re := RegEx.create_from_string("@iChannel([0-3])\\s+(\\w+)")
	for c in ch_re.search_all(code):
		var source := c.get_string(2).to_lower()
		if source in CHANNEL_SOURCES:
			out.channels[int(c.get_string(1))] = source
	var uni_re := RegEx.create_from_string(
			"(?m)^\\s*uniform\\s+(float|int|bool)\\s+(\\w+)\\s*(?::\\s*([^=;]*))?(?:=\\s*([^;]+))?;")
	var range_re := RegEx.create_from_string("hint_range\\s*\\(([^)]*)\\)")
	for u in uni_re.search_all(code):
		var type := u.get_string(1)
		if u.get_string(2) in CHAIN_INPUTS:
			continue
		var p := {"name": u.get_string(2), "type": type}
		var default_src := u.get_string(4).strip_edges()
		if type == "bool":
			p.default = default_src == "true"
		else:
			var r := range_re.search(u.get_string(3))
			if r == null:
				continue
			var nums := r.get_string(1).split(",")
			p.min = _eval(nums[0], 0.0)
			p.max = _eval(nums[1], 1.0) if nums.size() > 1 else 1.0
			p.step = _eval(nums[2], 0.0) if nums.size() > 2 else (1.0 if type == "int" else 0.01)
			p.default = _eval(default_src, p.min) if default_src != "" else p.min
		out.params.append(p)
	return out


## A number from shader source ("0.5", "1.0 / 3.0", "-2"), or `fallback`.
static func _eval(src: String, fallback: float) -> float:
	var e := Expression.new()
	if e.parse(src.strip_edges()) != OK:
		return fallback
	var v = e.execute()
	if e.has_execute_failed() or not (typeof(v) in [TYPE_FLOAT, TYPE_INT]):
		return fallback
	return float(v)
