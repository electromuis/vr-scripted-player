# Video decoding: `gde_gozen` (FFmpeg wrapper)

The player uses **[gde_gozen](https://codeberg.org/gozen/gde_gozen)** — an actively-maintained Godot GDExtension wrapping FFmpeg. It's the video engine behind the GoZen video editor, so **frame-accurate seek is a first-class feature**. This replaces the earlier `godot_mpv` alpha (which had no seek API).

## What ships

Under `addons/gde_gozen/`:
- `gozen.gdextension` — extension config (patched locally: release path points at the debug binary since only debug ships in the alpha).
- `bin/libgozen.windows.template_debug.x86_64.dll` — the wrapper + bundled FFmpeg.
- `video_playback.gd` — a `Control` node wrapping the underlying `GoZenVideo` GDExtension class.
- `yuv_to_rgb_forward.gdshader` + `yuv_to_rgb_compatibility.gdshader` — YUV → RGB shaders.

## Godot version requirement

**The shipped alpha binary is built for Godot 4.4.1+.** If you're on Godot 4.4.0 (`4.4-stable` at first release), the extension fails to load with:

```
Cannot load a GDExtension built for Godot 4.4.1 using an older version of Godot (4.4.0).
```

Fix: upgrade Godot to 4.4.1 or newer. Download from https://godotengine.org/download/archive/. Replace the binary at `C:\ProgramData\chocolatey\lib\godot\tools\` or install fresh.

## Public API surface (VideoPlayback)

Class: `VideoPlayback` (extends `Control`). Declared via `class_name` — usable via `preload/load`.

```
# Setup
set_video_path(path: String)          # async load; emits video_loaded when ready
enable_audio: bool                    # default true
enable_auto_play: bool                # default false
loop: bool

# Playback
play()
pause()
close()
is_playing: bool
playback_speed: float                 # 0.25 .. 4
current_frame: int

# Seek + query
seek_frame(nr: int)                   # frame-accurate seek
get_video_frame_count() -> int
get_video_framerate() -> float
get_video_length_float() -> float     # duration in seconds
get_current_playback_position_float() -> float
get_video_rotation() -> int
is_video_alpha() -> bool
is_open() -> bool

# Signals
video_loaded, video_ended
playback_started, playback_paused, playback_ready
frame_changed(frame_nr), next_frame_called(frame_nr)
```

The visible output lives on an internal `TextureRect` whose material is a `ShaderMaterial` with the YUV→RGB shader. Plane textures (y/u/v/a) are `ImageTexture`s updated via `RenderingServer.texture_2d_update` each frame.

## How it's wired

`player/video_bridge.gd` (class `VideoBridge`) owns a hidden `VideoPlayback` and hijacks its `_shader_material` onto the 3D `VideoQuad`'s `material_override`. This skips the extra SubViewport render pass that a naïve setup would incur — a real win at 4K.

`player/main.gd`:
1. Instantiates `VideoBridge`, hands it the `VideoQuad`.
2. On `ScriptRunner.script_loaded`, resolves `media.video`'s relative path, `globalize_path()`s it, and calls `bridge.load_video(os_path)`.
3. On `ScriptRunner.seeked(t)` — fired by the scrub bar — forwards to `bridge.seek_seconds(t)` which maps seconds to frame via the video's own fps.
4. On `ScriptRunner.play_state_changed(is_playing)` — forwards to `bridge.play()` / `bridge.pause()`.

If the addon fails to load (e.g. Godot version mismatch), `VideoBridge` degrades gracefully — no video, but the rest of the app still runs.

## Hardware acceleration

Not called out explicitly in gozen's README. If 4K/60 drops frames on your GPU, that's the likely cause. FFmpeg supports `-hwaccel d3d11va` etc.; whether the shipped alpha exposes it is a benchmark question — profile with a 4K clip in `examples/minimal/` and check `Task Manager → GPU → Video Decode` vs. CPU.

If HW decode isn't on: options are (a) upstream a PR to enable, (b) rebuild from source (the source tree is in `gde_gozen/` at project root — SConstruct + build.py), or (c) stay software-only for now.

## Fallback

Godot's built-in `VideoStreamPlayer` still handles Theora `.ogv` — swap in for a smoke test if gozen is broken. Not viable for 4K/60.
