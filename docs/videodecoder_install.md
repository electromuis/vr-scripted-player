# Video decoding: `godot_mpv` (libmpv wrapper)

The player uses **[godot_mpv](https://github.com/) — a libmpv GDExtension** for video decoding. mpv gives us hardware-accelerated decode (D3D11VA on Windows), universal codec support (H.264, H.265, AV1, VP9, ProRes, ...), frame-accurate seeking, and 4K/60 headroom on any GPU built in the last ~5 years.

Status: **alpha wrapper.** Enough for Phase 0/1 smoke testing; may hit edges around threading, seek precision, or texture lifetimes as the project matures.

## What ships

Under `bin/`:

- `godot_mpv.gdextension` — extension config
- `libgodot_mpv.windows.template_release.x86_64.dll` — the wrapper
- `libmpv-2.dll` — libmpv itself
- `libEGL.dll`, `libGLESv2.dll` — ANGLE (mpv renders through OpenGL ES on Windows)
- `zlib1.dll` — dependency

## Public API (as of alpha)

Class: `MPVPlayer` (extends `Node`)

```
initialize() -> bool
load_file(path: String) -> void        # OS filesystem path, not res://
play() -> void
pause() -> void
stop() -> void
get_texture() -> Texture               # the live video texture
get_width() -> int
get_height() -> int
apply_to_mesh_3d(mesh: MeshInstance3D) -> void   # binds the video texture as albedo
apply_to_viewport(viewport: Viewport) -> void    # for 2D use
create_video_mesh_2d() -> Object
create_video_mesh_3d() -> Object
signal texture_updated
```

## How it's wired

In `player/main.gd`:

1. `_init_mpv()` instantiates `MPVPlayer` via `ClassDB.instantiate("MPVPlayer")`, calls `initialize()`, and binds it to `$Stage/VideoQuad` via `apply_to_mesh_3d()`.
2. When `ScriptRunner` fires `script_loaded`, `_play_video_for(data)` resolves the script's `media.video` relative path, converts `res://` → OS path with `ProjectSettings.globalize_path()`, and calls `load_file()` + `play()`.

## Fallback: Theora `.ogv` via built-in `VideoStreamPlayer`

If the mpv wrapper breaks or you need to work without it, transcode source to Theora:

```
ffmpeg -i input.mp4 -c:v libtheora -q:v 7 -c:a libvorbis video.ogv
```

Then swap in a stock `VideoStreamPlayer` node (built into Godot 4). Limited to ~1080p/30 practically — not viable for 4K/60.

## Known alpha caveats to watch for

- `godot_mpv.gdextension` originally referenced a `template_debug` DLL that isn't shipped; the file is patched to point both debug and release at the release binary. Revisit if a debug build lands upstream.
- Only Windows x86_64 release binary is present. Linux/Mac builds need to be added if we target those.
- **No public seek API.** The introspected surface exposes `load_file / play / pause / stop` and nothing for `seek` / `time-pos`. Timeline scrubbing works for the *script stage* (transforms, spawned objects, shader params — reprojected deterministically by `ScriptRunner.seek()`), but the video plays linearly and does **not** jump to the scrubbed time. Workarounds for later: (a) upstream a seek method; (b) `stop() → load_file(path)` on scrub as a coarse resync (drops frames, may glitch audio); (c) send a raw mpv command via a wrapper extension.
- Texture-format edge cases and thread-safety around `apply_to_mesh_3d` in VR are unverified — smoke-test each before relying on them.
