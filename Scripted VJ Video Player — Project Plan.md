# Scripted VJ Video Player — Project Plan

2026-09-22 · @Someone

## Overview

A scripted, VJ-style video player: a music video plays while a script drives keyframed events on top of it — screen/projection transforms, spawning and moving objects, and shaders applied to cameras and objects. Two audiences:

- **Viewers** run a small standalone player (exported from Godot, VR-capable via OpenXR) that just plays a video + script.
- **Script authors** use an editor plugin inside Godot to build sequences visually, without hand-writing files.

The project has three deliverables: a **script format**, a **standalone player**, and an **editor plugin**. They share a common script format so any of the three can be used independently — someone could hand-write a script in a text editor without ever opening Godot.

## Locked Decisions (previously "open")

Three decisions the earlier draft deferred, resolved here so the build can proceed:

1. **Script format: custom JSON, not Godot's native `Animation` resource.** The tempting shortcut of using `Animation` gives a free editor UI but couples every script to a specific Godot scene tree (node paths, method names on real classes) and to Godot's binary/`.tres` serialization. That kills the "hand-edit outside Godot" and "share as a zip" properties, which are core to the goal. JSON with a `format_version` field wins on portability, diff-ability, and third-party tooling. We lose the free Animation panel — Phase 6/7 rebuilds a purpose-built timeline dock, which is worth it because our tracks (spawn/despawn, UV sub-rects, VR transitions) don't map cleanly onto Animation's model anyway.
2. **Plugin ↔ player live sync: WebSocket, from day one of the plugin.** The intermediate "file-watch only" step was going to be thrown away as soon as scrub-sync was wanted. Skip it. The player already needs a file watcher for `.json`/shader hot-reload; adding a WebSocket client alongside is small. The plugin runs a `WebSocketServer`; the player connects when it loads a script. Bidirectional messages: `seek`, `reload`, `play/pause`, `report_position`.
3. **Desktop mode is a first-class runtime, not a fallback.** Whirligig and VRChat both start on desktop and let the user opt into VR. This player does the same. Godot 4 requires `xr/openxr/enabled=true` in `project.godot` for the OpenXR loader config (action map, form factor) to be registered — without it, runtime `initialize()` returns false and the whole opt-in flow fails. We set `enabled=true` and `startup_alert=false`, so the OpenXR runtime is *touched* at boot (near-free if SteamVR is already running; a suppressed stderr warning if not), but the app never renders to XR until we set `viewport.use_xr = true` from `XRMode.try_enter_vr()`. Trigger paths: "Enter VR" button in the top bar, `F1` keybind, or `--vr` CLI flag. Consequences: (a) no headset required to launch, browse scripts, or preview; (b) full feature parity between desktop and VR playback — script authoring/preview must be possible entirely desktop; (c) a parallel 2D overlay UI mirrors the world-space HUD's controls for desktop; (d) desktop camera has WASD + right-click mouse-look, matching the affordances people expect from Whirligig/VRChat.

## Current Status (2026-09-23)

The phase write-ups further down record how each piece was built; some of their details have since changed. This section is the up-to-date picture. 74 tests pass (`--headless --script res://tests/run.gd` in `project_engine/`).

### What works today

- **Player (`project_engine/`)** — plays a timeline script, or a bare video file on the default screen (a same-name `.json` next to a video is used as its script). Hot-reloads scripts, prefabs and shaders. A Windows export preset writes `build/VRmviewer.exe`.
  - **Video**: `gde_gozen` (FFmpeg), frame-accurate seek; local files and http(s) URLs.
  - **Projections**: flat, flat SBS/TB, 180° SBS/TB/mono, 360° mono/TB/SBS; auto-detected from the file name, overridable per video in the Camera tab.
  - **Desktop controls**: WASD + right-click look; ←/→ seek, ↑/↓ volume, Space/K play-pause, R/Home reset view; F2 menu, F1 enter/exit VR. Bottom media bar with play/pause, scrub and time.
  - **Menu (F2, or right controller menu button)**, a world-space panel used by both mouse and VR pointer:
    - *Camera*: presets (Save/New, stored as `user://presets/preset_N.json`), projection, reset view, and six sliders: size (scales about the screen's centre), distance (inverted: right = nearer), height, tilt, curvature, opacity. Opacity fades the flat quad in the display pass; the 180°/360° sphere stays opaque. Curvature bends the main screen through the display shader's vertex pass; a flat preset doesn't override a script's own curvature. An *Adjust* dropdown switches the sliders between the screen and the shader plane (below); in Shader mode the projection dropdown becomes the shader picker, and a *Lock to screen* box centres the plane on `main_screen` every frame, at its own size, following sliders and script animation. While it's locked, distance, height and tilt are greyed out. Presets store both (`screen` and `visualizer` blocks).
    - *Shader plane (visualizer)*: `player/visualizer/`. A second Screen prefab on its own mount, 1 cm in front of the main screen's default position, drawing a sound-reactive shader in its artist viewport at half of full HD. Its display pass has `luma_key` on: alpha is the brightest channel, so black is transparent and it composites like a screen blend. `AudioAnalyzer` adds a spectrum analyzer and a capture effect to gozen's audio bus (ahead of its pitch shift) and fills a Shadertoy-layout 512×2 texture every frame. Row 0 is 0–11 kHz, with the dB window shifted from Web Audio's by the measured 7.5 dB window-gain difference, and smoothing matches AnalyserNode. Row 1 is the waveform. It also computes band levels. The analysis divides the volume back out so visuals don't follow the volume slider, and it only runs while a shader is selected. `VisualizerShaders` lists built-ins plus `user://shaders/` and `<exe>/shaders/`. It wraps `.glsl`/`.frag`/`.txt` Shadertoy code between `shadertoy_prelude.gdshaderinc` (iChannel0–3, iResolution, iTime→TIME, …) and `shadertoy_main.gdshaderinc` (a `fragment()` that calls `mainImage` with a flipped Y), and loads `.gdshader` files as-is. Live analysis only: while paused or scrubbing, the shader sees silence. Not supported: multipass buffers, iMouse, texture channels.
    - *Files*: inline browser for folders, scripts and videos, with OS thumbnails, list or tiles view. Picking a file opens it and closes the menu.
    - *Network*: DLNA media-server browser (SSDP discovery, server-provided thumbnails). Picking a video plays it and closes the menu.
    - *Config*: locomotion (locked, where the sticks seek and change volume / free, walk and snap-turn), skybox, floor on/off, volume.
    - *Presets*: manage screen presets: click to apply, rename, overwrite with current values, new from current, delete (second press confirms; preset 1 can't be deleted), and choose which preset loads at startup (`user://presets/startup.cfg`). The Camera tab dropdown follows the same active preset. Preset 0, **Script (defaults)**, is built in and locked (no file, can't be saved over, renamed or deleted): software defaults, no effects, no layers. Loading a script switches to it so pieces look as authored, and the look from before (preset, unsaved tweaks, layers) comes back when a plain video loads. Sliders and other presets still work during a script, until the next load.
  - **VR**: auto-entered at startup when a headset is detected, XR Tools rig with a laser pointer on the right controller, wrist HUD (play/pause, time, menu button, volume), in-headset fade, recenter, and the runtime's own recenter mapped to reset view. Right stick click = play/pause while aiming at the screen, reset view otherwise; holding the right grip drags the floating menu. The menu has a close (X) and a Quit button (press twice). The "VR working" commit (2026-09-22) shows the basics run on a headset; the individual Phase 4b checks aren't recorded as confirmed.
  - **Whirligig-compatible timecode server** on `127.0.0.1:2000` so MultiFunPlayer / ScriptPlayer can sync (`--whirligig-port N`, `0` = off; `--whirligig-lan`).
  - **CLI**: `--script <path>`, `--vr`, `--desktop` (skip auto-VR), `--start <seconds>`, `--paused` (open the script without playing), `--live-sync <port>`, `--whirligig-port`, `--whirligig-lan`, or a video/script path passed as a plain argument ("Open with").
- **The script JSON is the master format.** A Godot scene is one way to edit it: the addon's importer builds a scene from a JSON in an empty project, and the scene's export writes back to it. The VR editor will edit the JSON directly, on the player's own renderer. The addon's round-trip test (`addon_vj/tests/run_roundtrip.gd`) checks that import then export plays the same as the original.
- **Authoring (`addon_vj/`, copied into the authoring projects as `addons/vj_editor/`)** — the plan's custom timeline dock (Phases 6–7) was **replaced** by authoring in a normal Godot scene: prefabs and screens are nodes, animation lives in an `AnimationPlayer`, and the scene exporter writes the script JSON (transform, `shader_param` and curvature tracks; `VJViewer` camera keys become `vr_cut` events; custom prefabs are bundled next to the JSON). **▶ Preview in player** exports and launches the player at the current scrub time, with live sync: scrubbing / playing the animation drives the player, pausing the player moves the Animation panel's playhead, and Preview or Ctrl+S re-exports and hot-reloads the connected player.
- **Example pieces (`scripts/`)**: `minimal`, `moving_screen`, `forest_tunnel` (the worked example, authored in `project_script_forest_tunnel/`).

### Open points

**VR verification**
- Walk through the Phase 4b checklist on a headset and record the results: wrist HUD buttons, menu button, pointer clicks in every menu tab, `vr_cut` + `fade_to_black`.
- Comfort pass on `forest_tunnel`: the fades, and whether the columns' fly-by at 68–76 s is too close.
- Pressing "Exit VR" during a fade or a cut isn't handled.
- The controllers are invisible apart from the laser. Add hand models or simple markers.

**Player**
- Desktop hint text in `main.gd` says "F12 VR"; the key is F1.
- With the menu open, releasing right-click may not end mouse-look, because the menu catches the release. Not re-checked since it was first noted.
- Script load errors only show in the status line; there's no error dialog or loading spinner.
- `--windowed` isn't implemented.
- Cuts can only return the viewer to the home pose. A cut to somewhere else needs `ScreenMount` to follow the viewer.
- The curvature slider affects only `main_screen`, not screens a script splits off.

**Live sync**
- Moving the Animation panel's playhead from the player relies on an unexposed editor control (the panel's time SpinBox, found by class); if a Godot update moves it, the scene still follows but the panel's cursor doesn't.
- A seek that arrives while the player's video is still opening reports t=0 until the video has loaded, so the editor's playhead can blip to 0.
- With two authoring editors open, the second listens on the next port; a player only follows the editor that launched it.

**Authoring**
- Confirm that scene + AnimationPlayer authoring replaces the custom timeline dock for good, then drop or rewrite Phases 6–7 and the "Editor Plugin" section.
- Undecided from the worked example: an `env_swap` event that spawns/despawns a set at once, and documenting the 3-way screen split as a prefab convention.

**Docs + release (Phase 10)**
- No `docs/` folder yet: `script_format.md`, `authoring_guide.md`, `player_usage.md`. (`docs/videodecoder_install.md`, cited under Tech Stack, doesn't exist either.)
- Package the addon as a zip and the player as a release build. Only a debug build of the `gde_gozen` library is in `build/` so far.
- The Definition of Done names `examples/forest_to_tunnel/`; the example lives at `scripts/forest_tunnel/`.

## Architecture

Three pieces, one shared format:

1. **Script format** — JSON describing a timeline of keyframed continuous tracks (transforms, shader params) and discrete events (spawn, despawn, transitions). Fully declarative — no embedded code. Assets referenced by relative path. Full schema in "Script Format" section below.
2. **Standalone player** — exported Godot 4.4 project (VR via OpenXR) that loads a script folder, plays the video on 3D surface(s), and evaluates the timeline each frame. Hot-reloads script + referenced assets. This is the only piece end viewers need.
3. **Editor plugin** — a Godot `EditorPlugin` that adds a custom bottom dock: timeline UI, per-track editors, schematic 2D preview, and live-sync to a running player instance for true WYSIWYG without in-editor 3D rendering.

The script format is the contract between the three pieces. Any one of them can be built or replaced without touching the others.

## Tech Stack

- **Engine**: Godot 4.7.2 stable (installed at `C:\ProgramData\chocolatey\lib\godot\tools\Godot_v4.7.2-stable_win64.exe`). The 4.4 binary is retained as a `.4.4.0` sidecar for reference — `gde_gozen`'s shipped alpha needs 4.4.1+, and 4.7.2 satisfies that with room to spare.
- **Language**: GDScript 2.0 for everything. C# is not needed and would complicate the plugin.
- **Video decoding**: [`gde_gozen`](https://codeberg.org/gozen/gde_gozen) — actively-maintained FFmpeg-based GDExtension. Exposes frame-accurate `seek_frame()` (critical for scrub), universal codec coverage via FFmpeg, and powers the GoZen video editor so it's real-world tested. Requires Godot 4.4.1+ (the shipped alpha binary is version-gated). Fallback for smoke tests: Godot's built-in `VideoStreamPlayer` with Theora `.ogv`. Superseded the earlier `godot_mpv` alpha which lacked seek entirely — see `docs/videodecoder_install.md` for the full swap notes and hwaccel status.
- **VR runtime**: OpenXR (Godot built-in). Hardware-agnostic — Index, Vive, Quest via Link/Virtual Desktop, etc.
- **VR helpers**: [Godot XR Tools](https://github.com/GodotVR/godot-xr-tools) v4.5.1 for controller raycast + UI interaction. Vendored at `addons/godot-xr-tools/` (whole addon; runtime doesn't require enabling the editor plugin). Currently we lean on `XRToolsViewport2DIn3D` for the floating panel; `XRToolsFunctionPointer` gets wired under the right controller in Phase 4b.
- **Testing**: [GUT (Godot Unit Test)](https://github.com/bitwes/Gut) once the script parser + evaluator core exists.
- **Live sync transport**: `WebSocketServer` / `WebSocketPeer` (Godot built-in, no dependency).
- **File watching**: mtime polling on a `Timer` (~0.5s). Godot has no native inotify equivalent.

## Script Format

A script ships as a self-contained folder:

```
my-video-script/
  script.json          # the timeline
  video.mp4
  audio.wav            # optional, if separate from video
  shaders/
    glow.gdshader
    distort.gdshader
  prefabs/
    forest.tscn
    tunnel.tscn
    screen.tscn
  textures/
    ...
```

- All paths in `script.json` are **relative to `script.json` itself**, not Godot's `res://`. The loader resolves them at load time.
- Prefabs are `.tscn` files — Godot scenes packaged in the script folder. The player loads them via `ResourceLoader.load()` from the resolved absolute path. Authors can build prefabs in a scratch Godot project and copy them in.
- Shaders are `.gdshader` text files, likewise loaded from absolute paths.
- Hot-reload watches mtimes of `script.json` and every referenced asset.

### JSON schema (v1)

```json
{
  "format_version": 2,
  "meta": {
    "title": "Forest to Tunnel",
    "author": "Someone",
    "created": "2026-09-22"
  },
  "media": {
    "video": "video.mp4",
    "audio": null,
    "duration": 240.0
  },
  "prefabs": {
    "screen":  "prefabs/screen.tscn",
    "forest":  "prefabs/forest.tscn",
    "tunnel":  "prefabs/tunnel.tscn"
  },
  "shaders": {
    "video_surface": "shaders/video_surface.gdshader",
    "glow":          "shaders/glow.gdshader"
  },
  "objects": [
    {
      "id": "main_screen",
      "prefab": "screen",
      "spawn_at": 0.0,
      "despawn_at": null,
      "transform": { "position": [0, 1.6, -5], "rotation_deg": [0,0,0], "scale": [16, 9, 1] },
      "materials": {
        "surface": {
          "shader": "video_surface",
          "params": { "video_texture": "$video", "uv_offset": [0,0], "uv_scale": [1,1] }
        }
      }
    }
  ],
  "tracks": [
    {
      "type": "transform",
      "target": "main_screen",
      "channel": "position",
      "keyframes": [
        { "t": 0.0,  "value": [0, 1.6, -5], "interp": "linear" },
        { "t": 30.0, "value": [0, 2.0, -3], "interp": "cubic" }
      ]
    },
    {
      "type": "shader_param",
      "target": "main_screen.surface",
      "param": "glow_intensity",
      "keyframes": [
        { "t": 0.0, "value": 0.0 },
        { "t": 10.0, "value": 1.0 }
      ]
    },
    {
      "type": "event",
      "t": 120.0,
      "action": "spawn",
      "id": "tunnel_1",
      "prefab": "tunnel",
      "transform": { "position": [0,0,0], "rotation_deg": [0,0,0], "scale": [1,1,1] }
    },
    {
      "type": "event",
      "t": 120.0,
      "action": "despawn",
      "target": "main_screen",
      "transition": { "type": "fade", "duration": 2.0 }
    },
    {
      "type": "event",
      "t": 120.0,
      "action": "vr_cut",
      "to": { "position": [0, 1.6, 10], "rotation_deg": [0, 180, 0] },
      "transition": { "type": "fade_to_black", "duration": 0.5 }
    }
  ]
}
```

Two track kinds:

- **Continuous tracks** — `transform`, `shader_param`. Interpolated every frame between keyframes. A key's `interp` shapes the segment after it: `linear` (default), `step` (hold), `ease` (smoothstep, easing out of and into each key), `cubic` (a spline through the keys, Godot's cubic value-track interpolation) or `bezier` (Godot's bezier curve, from the key's `out` handle and the next key's `in` handle, each `[dt, dv]` relative to its key, or one per element for array values). Format version 2 added `ease` and `bezier` and changed `cubic`: version 1's `cubic` was the smoothstep, so version 1 scripts load with it read as `ease`.
- A screen's or layer's `config.effects` entry with `"enabled": false` is kept in the file (for editors) but skipped by the player, and doesn't count towards `effect<N>`.
- **Discrete events** — `spawn`, `despawn`, `vr_cut`, `vr_teleport`. Fired at their exact time. Seeking or a live reload rebuilds what exists at the playhead; an object whose spawn event changed (config, transform, parent) is respawned.

Special references:

- `$video` — the video texture (a `ViewportTexture` from the video's `SubViewport`).
- `<object_id>.<material_slot>` — targets a named material on a spawned object (used by `shader_param` tracks). Prefabs with more than one material route by slot via `set_material_param(slot, param, value)`: the Screen prefab uses `surface` (or any other name) for the artist shader, `display` for its display pass (`curvature`, `vertical_curvature`, `opacity`) and `effect<N>` for its Nth effect (from 0); a layer uses `layer` for its shader and the same `display` / `effect<N>` slots. Otherwise the slot name is ignored and the prefab's shader material is used.
- Shader param values that are numeric arrays of length 2/3/4 are passed to shaders as `Vector2/3/4` (a raw JSON array would read as zero in a `vecN` uniform).

### Groups, effects and shader layers

- **`parent`** (optional, on `spawn`): the id of an object that already exists. The new object is placed inside it, with `transform` in the parent's space, so moving, rotating or scaling the parent moves it too. Despawning (or respawning) the parent removes its children. At the same `t`, events run in file order, so list a parent's spawn before its children's. Ids stay unique across the whole script.
- **Built-in prefabs** the player ships (map them in `prefabs` like `screen`): `res://player/prefabs/group.tscn` (an empty node for grouping) and `res://player/prefabs/layer.tscn` (a shader layer). Top-level screens, groups and layers live in the player's ScreenMount, so the viewer's screen size/distance preferences move them together.
- **Effects** (screen and layer `config.effects`): `[{"shader": <shaders key>, "params": {...}}]`, run in order over the picture, the same effect shaders the Camera tab uses. The player's built-ins are `res://player/visualizer/effects/{key_black,oval_mask,edge_blur,padding}.gdshader`. An entry with `"shader": ""` is an empty slot (kept so `effect<N>` targets line up).
- **Screen config** also takes `opacity` and `vertical_curvature`. Values a script sets win over the viewer's Camera tab settings for that screen (resolution is always the viewer's).
- **Layer config**: `shader` (a `shaders` key naming a layer shader, e.g. `res://player/visualizer/shaders/{light_ring,spectrum_bars,video_blur}.gdshader` or a Shadertoy `.glsl`), `params` (its hinted uniforms), `effects`, `opacity`, `curvature`, `vertical_curvature`, `resolution` (multiplier on the shader's `@resolution`). The layer's quad sits at the object's transform, the same size as a screen's at the same scale, and it gets the live audio and, for `@iChannelN video` channels, the video.

- **Modifiers** (any object, `config.modifiers`, tracks on `<id>.modifiers`): Godot-native properties set on everything under the object, combined down through groups: `opacity` (0–1, meshes' `transparency`), `tint` (`[r, g, b, a]`, multiply overlay), `flash` (`[r, g, b, a]`, alpha = strength, additive overlay), `speed` (`speed_scale` of particles and AnimationPlayers), `sort_offset` (`sorting_offset`, metres). The prefab needs nothing for them. Despawn fades (`"transition": {"type": "fade"}`) also use `transparency` now, so they work on any mesh, MultiMeshes included.
- **Reactive motion** (any object, `config.reactive`, tracks on `<id>.reactive`): computed on top of the object's animated transform, never fed back into it. `spin` (`[x, y, z]` degrees per second, integrated over the timeline so seeking lands on the same angle) and `pulse` (0–1: scale 1 + pulse × the music's bass; the player runs its audio analyser while anything pulses).

```json
{ "type": "event", "t": 0, "action": "spawn", "id": "backdrop", "prefab": "layer", "parent": "main_screen",
  "transform": { "position": [0, 0, -12], "scale": [3, 3, 3] },
  "config": { "shader": "video_blur", "params": { "radius": 0.065 },
              "effects": [ { "shader": "padding" }, { "shader": "oval_mask", "params": { "size": 0.44, "ratio": 1.7 } } ] } }
```

VR comfort primitives (`vr_cut`, `vr_teleport`, `fade_to_black`) are first-class events, not something authors have to hand-roll — this is deliberate given the motion-sickness risk in the worked example.

## Runtime Player

### Scene tree

```
Main (Node3D)
├── XRRig (XROrigin3D)
│   ├── XRCamera3D
│   ├── LeftController (XRController3D)
│   │   └── WristHUD (SubViewport panel)
│   └── RightController (XRController3D)
│       └── Raycast + interaction
├── VideoDecoder (SubViewport with videodecoder node)  # produces the video texture
├── Stage (Node3D)                                     # spawned objects live here
├── FloatingHUD (Node3D, hidden by default)
└── ScriptRunner (Node)                                # loads + evaluates timeline
    ├── FileWatcher
    └── WSClient
```

### Core scripts

- **`script_format.gd`** — parser: JSON → typed `TimelineData` resource. Validates schema, resolves relative paths, catches errors.
- **`timeline_data.gd`** — in-memory representation. Immutable-ish; live-reload swaps the whole object.
- **`script_runner.gd`** — owns the current `TimelineData`, the current playhead time, and the stage state. Each `_process(delta)`:
  1. Advance playhead.
  2. Fire any discrete events crossed since last frame.
  3. For each continuous track, interpolate and apply.
- **`object_registry.gd`** — map of `id -> Node3D` for all spawned objects. Handles spawn/despawn with transitions.
- **`prefab_library.gd`** — cache of loaded `PackedScene` resources.
- **`file_watcher.gd`** — polls mtimes on a `Timer`. On change, emits `script_changed` or `asset_changed(path)`.
- **`ws_client.gd`** — connects to editor plugin if `--live-sync <port>` argument passed; handles `seek`/`reload`/`play`/`pause` messages; sends `report_position` at ~10Hz.

### Live reload (reconciliation model)

The subtle part. When `script.json` changes:

1. Re-parse into a new `TimelineData`. If parse fails, log and keep the old one (retry next mtime bump).
2. Diff current stage against what the new timeline says should exist at current playhead time T:
   - Objects present in new timeline at T but not in stage → spawn.
   - Objects in stage but not in new timeline at T → despawn.
   - Objects in both → keep, next frame's continuous-track evaluation will move them.
3. Swap `TimelineData`, keep playhead position, keep video playback state.

This is what makes editing feel live rather than restart-y. The author changes a keyframe on frame 3000, saves, and the change appears at frame 3000 without losing their scrub position.

Shader-only reloads (`.gdshader` mtime changed) can skip the whole diff — just reload the shader resource and let the material pick it up.

## Desktop Mode (default)

Runs on any Windows machine, no headset required.

- **Camera**: free-flying `Camera3D` with WASD movement, right-click-held mouse-look, shift-to-boost. Space/Ctrl for up/down. Matches the affordances people expect from Whirligig and VRChat's desktop mode.
- **UI**: 2D overlay (`CanvasLayer`) with a top bar showing mode ("Desktop"/"VR") and an "Enter VR" button, plus a bottom play/pause/scrub bar. Settings and file browsing use the same world-space floating panel as VR (F2), driven by the mouse — there is no separate 2D settings panel.
- **File browser**: inline `ItemList` browser in the panel's Files tab (an embedded `FileDialog` froze input; see Phase 4a).
- **Feature parity**: script authors and viewers can do everything except experience the piece in VR — authoring, previewing, scrubbing, and hot-reload all work desktop-only.

## VR Mode (opt-in)

- **Entry**: automatic at startup when a headset is detected (OpenXR initialized at boot; `--desktop` opts out), or the user clicks "Enter VR" in the top bar, presses `F1`, or launches with `--vr` on the command line. If OpenXR init fails, the player stays in desktop mode and shows a status message — never a fatal alert dialog.
- **Runtime**: Godot's built-in OpenXR, initialized programmatically at runtime. Hardware-agnostic (Index, Vive, Quest via Link/Virtual Desktop, etc. all route through SteamVR or a native OpenXR runtime).
- **Rig**: `XROrigin3D` with `XRCamera3D` and two `XRController3D` children. `vr_cut` / `vr_teleport` events move the XROrigin, not the camera.
- **World-space HUD**:
  - **Wrist-attached panel** (left controller): play/pause, volume, current time. Always visible when the wrist is up.
  - **Floating panel** (toggle on right controller menu button): the same panel desktop uses — Camera, Files, Network, Config tabs.
- **Interaction**: right controller raycast + trigger. Use Godot XR Tools' `XRToolsPointer` scene rather than writing this from scratch.
- **"FOV" is virtual screen size**: don't touch camera FOV (motion sickness). The user-facing control is the virtual screen's size, curvature, and distance — sliders in the floating panel's Camera tab, persisted as presets in `user://presets/`.

## Editor Plugin

> **Superseded.** Authoring moved to scene + `AnimationPlayer` export (see Current Status). The dock design below was never built.

Lives in `addons/vj_editor/`. Registered via `plugin.cfg` + `plugin.gd`.

### Dock layout

Bottom dock, single custom `Control`:

```
+---------------------------------------------------------------+
| [Load] [Save] [Launch Player ▶] [Reload] [WS: connected]      |
+---------------------------------+-----------------------------+
|                                 |                             |
|  Video preview (thumbnail)      |  Schematic 2D preview        |
|  + scrub bar                    |  (objects, camera, screen)   |
|                                 |                             |
+---------------------------------+-----------------------------+
|  Timeline (tracks stacked)                                    |
|    ▸ transform: main_screen.position   [keys...]              |
|    ▸ shader_param: main_screen.glow    [keys...]              |
|    ▸ events                            [spawn][despawn]...    |
+---------------------------------------------------------------+
| Selected keyframe / event inspector                           |
+---------------------------------------------------------------+
```

### Track-editor plugin system

Each track type is a registered subclass. Adding a new track type = one file in `addons/vj_editor/track_editors/`. Each registers:

- Type name (matches `"type"` field in JSON).
- Icon.
- Draw function for the timeline lane.
- Inspector UI for a selected keyframe.
- Serialize/deserialize hooks (usually just JSON pass-through).

Ship in v1: `transform`, `shader_param`, `event` (with `spawn`/`despawn`/`vr_cut`/`vr_teleport` sub-actions).

### Schematic 2D preview

Top-down `Control._draw()` canvas:

- Camera icon (position + facing arrow), extracted from current XR rig transform at playhead T.
- Screen rectangles at their world XZ positions.
- Object icons color-coded by prefab.
- No 3D rendering — that's the running player's job via live sync.

### Launch + live sync flow

1. Author clicks "Launch Player ▶" in the dock.
2. Plugin starts `WebSocketServer` on a free port, then `OS.execute()`s the exported player (or `Godot --path <player scene>` during dev) with `--script <path> --live-sync <port>`.
3. Player connects, dock shows "WS: connected".
4. Dragging the scrub bar in the dock sends `seek`. Player seeks video + evaluates timeline at new T.
5. Ctrl+S in Godot triggers plugin's save → writes `script.json` → sends `reload` → player re-reads and reconciles.

## Directory Layout

> **Planned layout — the repo differs.** Actual top level: `project_engine/` (the player Godot project: `player/`, `tests/`, `addons/gde_gozen`, `addons/godot-xr-tools`), `addon_vj/` (authoring addon, copied into authoring projects as `addons/vj_editor/`), `project_script_example/` and `project_script_forest_tunnel/` (authoring projects), `scripts/` (exported pieces), `build/` (exported player). No `docs/` or `examples/` yet.

```
c:\dev\VRmviewer\
├── project.godot
├── .gitignore
├── README.md
├── Scripted VJ Video Player — Project Plan.md      # this file
│
├── addons/
│   ├── vj_editor/                        # editor plugin
│   │   ├── plugin.cfg
│   │   ├── plugin.gd
│   │   ├── docks/timeline_dock.tscn / .gd
│   │   ├── track_editors/
│   │   │   ├── transform_track.gd
│   │   │   ├── shader_param_track.gd
│   │   │   └── event_track.gd
│   │   ├── preview/schematic_canvas.gd
│   │   └── live_sync/ws_server.gd
│   ├── godot-xr-tools/                   # vendored
│   ├── godot-videodecoder/               # vendored (or fallback: none)
│   └── gut/                              # vendored for tests
│
├── player/                               # standalone player runtime
│   ├── main.tscn / main.gd
│   ├── script_format/
│   │   ├── script_format.gd              # parser
│   │   └── timeline_data.gd
│   ├── runtime/
│   │   ├── script_runner.gd
│   │   ├── object_registry.gd
│   │   ├── prefab_library.gd
│   │   ├── file_watcher.gd
│   │   └── video_surface.tscn
│   ├── vr/
│   │   ├── xr_rig.tscn
│   │   ├── wrist_hud.tscn / .gd
│   │   ├── floating_hud.tscn / .gd
│   │   └── file_browser.tscn / .gd
│   └── live_sync/ws_client.gd
│
├── tests/                                # GUT
│   ├── test_script_format.gd
│   ├── test_script_runner_reconcile.gd
│   └── fixtures/
│
├── examples/
│   ├── minimal/                          # smoke-test script
│   └── forest_to_tunnel/                 # the worked example
│
└── docs/
    ├── script_format.md
    ├── authoring_guide.md
    └── player_usage.md
```

## Build Phases

Each phase produces something runnable. Order matters: script format before runtime; runtime before editor plugin; both before VR polish; worked example last as a stress test.

### Phase 0 — Foundation & risk-buydown (2–3 days)

- Godot 4.4 project at `c:\dev\VRmviewer\` with the directory skeleton above.
- `.gitignore` for Godot (`.godot/`, `*.import`, `export_presets.cfg`, etc.), `git init`.
- Play a test MP4 with `godot-videodecoder` on a flat `MeshInstance3D` quad. **Fail fast here** if the addon doesn't work on Windows — decide Theora fallback vs. FFmpeg-CLI-transcode-at-load-time before proceeding.
- Verify OpenXR: bring up SteamVR, launch a stub XR scene, see the headset.
- Deliverable: `player/main.tscn` shows a video on a quad in flat mode; XR stub scene shows headset tracking.

### Phase 1 — Script format ✅ DONE

- `script_format.gd` — JSON parser with per-field schema validation and multi-error reporting (fixed error path locations like `tracks[3].keyframes[1].t`). Also validates event action-specific requirements (spawn needs id+prefab, despawn needs target, vr_cut/vr_teleport need a `to` object).
- `timeline_data.gd` — typed helpers: `title()`, `duration()`, `continuous_tracks()`, `events_sorted()`, `resolve()`, `resolve_prefab()`, `resolve_shader()`.
- Vanilla test harness (`tests/run.gd` + `tests/test_case.gd`) — deliberate subset of GUT's API so we can migrate cleanly if we outgrow it. Discovers `tests/test_*.gd`, invokes every `static func test_*`.
- **16 tests passing** covering: valid parsing, missing/wrong `format_version`, missing media/video, bad JSON, unknown track types, transform track validation (channel + vector length), keyframe ordering, event action requirements, duplicate object ids, timeline helpers, path resolution, and the real `examples/minimal/script.json`.
- Deliverable: `Godot --headless --script res://tests/run.gd` runs the suite; can load `examples/minimal/script.json` into `TimelineData`.

### Phase 2 — Runtime interpreter ✅ DONE

- `interpolation.gd` — evaluates a keyframe array at time `t`. Modes: linear (default), cubic (smoothstep), step. Scalars and equal-length numeric arrays (used for Vector3 as `[x,y,z]`). Clamps to endpoint values before first / after last keyframe. `to_vec3()` helper.
- `object_registry.gd` — spawn/despawn with alpha-fade transitions. `spawn()` instantiates a `PackedScene` under the stage, registers by id, applies initial transform. `despawn(id, fade_duration)` either instantly frees or animates alpha to 0 over the duration before freeing. `tick_fades(delta)` from the runner drives the interpolation.
- `prefab_library.gd` — caches `ResourceLoader.load(abs_path)` results.
- `script_runner.gd` — owns TimelineData + playhead. Each `tick(delta)`: advances playhead, fires all discrete events whose `t` was crossed since the last tick, evaluates every continuous track and applies to the registered node. Handles `transform` (position/rotation_deg/scale) and `shader_param` (via `ShaderMaterial.set_shader_parameter`). `seek(t)` re-anchors the event cursor for replay. Public `tick()` is decoupled from `_process` so tests can drive it deterministically.
- Main scene registers `VideoQuad` as the `"main_screen"` id in the registry on script load — so transform/shader_param tracks can target the video screen without spawning it.
- `examples/moving_screen/` demonstrates the pipeline end-to-end: a `cube.tscn` prefab is spawned at `t=3`, despawned with a 2s fade at `t=15`, and the video screen loops through a cubic-eased position path.
- **28 tests passing**: 7 interpolation, 16 format, 5 runner (transform, rotation, event firing, seek rewind, shader_param).
- Video-surface **prefab** with UV-sub-rect shader is deferred to Phase 9 (worked example) — for now the fixed `VideoQuad` in main.tscn handles the single-screen case, and the format is expressive enough to add spawnable video surfaces later without a schema change.
- Deliverable: `examples/moving_screen/script.json` plays end-to-end. Keyframed transforms move the screen; spawn/despawn works with fade.

### Phase 3 — Live reload ✅ DONE

- `file_watcher.gd` — polls mtimes on a 0.5s Timer; emits `file_changed(path)` per watched file.
- ScriptRunner watches the script file plus every referenced prefab and shader on each load / reload.
- On `script.json` change: full re-parse. If parse fails (e.g. editor is mid-write), the current timeline is kept and the next mtime bump retries — no clobber. On success: reconcile.
- Reconciliation model:
  - Project the expected owned-object set at the current playhead from the *new* timeline (walk sorted events, tracking spawn/despawn deltas).
  - Diff against currently-owned objects in the registry.
  - Despawn what's no longer expected; spawn what's newly expected.
  - Objects in both — untouched. Their continuous tracks (transform / shader_param) will apply on the next tick.
  - **External objects (main_screen)** — marked via `register(id, node, external=true)`. Never touched by reconciliation or `_apply_timeline`'s owned-clear pass. This is what keeps the fixed VideoQuad alive across script edits.
  - Playhead is preserved; event cursor is re-anchored.
- Prefab or shader file change: cache invalidation only. Running instances keep their current material; next spawn will pick up the new prefab. Full shader hot-swap on existing instances is deferred until it's actually needed (Phase 7+).
- **35 tests passing** (added 7 reconciliation tests: state-projection at various times, event-cursor index calc, reconcile despawns disappeared objects, reconcile + `_apply_timeline` both preserve externals).
- Deliverable: editing `script.json` in an external editor changes the running player without a restart, playhead preserved, main_screen intact. Mid-write parse failures are tolerated silently.

### Phase 4 — Desktop UI + VR + HUD (7–9 days)

Split into two sub-phases because desktop mode and VR mode share a settings model but not a presentation.

**4a — Desktop UI (2–3 days)**

- Top bar overlay: mode label, current time, "Enter VR" button (already scaffolded in Phase 0). ✅
- **Media controls bottom bar: play/pause + scrub + time readout.** ✅ Scrubbing is deterministic — `ScriptRunner.seek(t)` reprojects the owned-object set (same model as live reload), evaluates continuous tracks, emits a `seeked(t)` signal. `VideoBridge` (owns a hidden `gde_gozen` `VideoPlayback`) listens and calls `seek_frame(int(t * fps))` for frame-accurate video seek. Video and script stage stay in sync during scrub. `play_state_changed` signal likewise mirrors play/pause to the video.
- **`vr_cut` / `vr_teleport` / `fade_to_black` event handlers** that also work in desktop mode. ✅ Runner emits `event_fired`; `main.gd` dispatches vr_cut/vr_teleport to `DesktopCamera.set_view(pos, rot_deg)` (which resyncs yaw/pitch so mouse-look picks up from the new pose). Optional `transition: {type:"fade_to_black", duration}` runs a full-screen `FadeOverlay` (`player/ui/fade_overlay.gd`) that fades to black over duration/2, applies the cut at peak-black, and fades back. VR-rig cut is deferred to 4b (XROrigin isn't in the tree yet); `_snap_camera` no-ops while `xr_mode.is_in_vr()`.
- **Floating world-space panel infrastructure.** ✅ Vendored `addons/godot-xr-tools/` (v4.5.1) to leverage `XRToolsViewport2DIn3D` rather than hand-rolling a SubViewport-on-a-quad. `player/ui/floating_panel.tscn`+`.gd` wraps it: on `toggle_panel` (F2) the panel shows in front of the active camera at 1.2 m, facing the viewer; on toggle again it hides. Content is `player/ui/floating_panel_content.tscn` — a `TabContainer` with **Camera / Files / Config / Presets** tabs (currently placeholder labels; contents deferred). Desktop mouse input: `_process` raycasts from `DesktopCamera` through the mouse cursor, hits the panel's `StaticBody3D`, calls the XR Tools body's `global_to_viewport()` for UV coords, and pushes `InputEventMouseMotion` / `InputEventMouseButton` into the panel's `SubViewport` — so the `TabContainer` and any future widgets react to mouse hover + click as normal 2D controls. VR path: same panel accepts controller trigger clicks via `XRToolsFunctionPointer` once 4b lands, no changes to the Control tree needed.
- **Camera tab contents** ✅ — `player/ui/camera_tab.gd` + `player/ui/floating_panel_content.gd` fill the Camera tab with a preset dropdown, Save / New buttons, and sliders for size, distance, height, curvature (tilt was added later). Sliders write through a shared `ScreenSettings` (`player/settings/screen_settings.gd`) which drives a `Stage/ScreenMount` Node3D. `main.gd:_on_object_spawned` reparents the timeline-spawned `main_screen` into the mount with `keep_global_transform=false`, so the runner's transform tracks still write to the child's local space and the mount's size/position offsets layer on top with no drift. Curvature was later wired to the screen's display shader (vertex bend of the subdivided quad).
- **Preset persistence** ✅ — `player/settings/preset_store.gd` reads/writes JSON files at `user://presets/preset_N.json`. Preset 1 is the auto-created default; each file mirrors the timeline script format's `format_version` convention with a `kind: "camera_preset"` discriminator and a nested `screen` block. The Camera tab's Save overwrites the selected preset; New allocates the next free index. `user://settings.cfg` is *not* used for camera state — presets replace it.
- **Files tab: inline folder browser** ✅ — `player/ui/files_tab.gd` renders an `ItemList` filling the tab (`PathLabel` breadcrumb on top, `StatusLabel` on the bottom). First tried Godot's `FileDialog` with `gui_embed_subwindows = true` on the SubViewport, but `popup_centered()` on an embedded FileDialog freezes the root viewport (modal input grab misroutes when the popup lives inside a SubViewport with pushed input). Rewrote as a plain `ItemList` walker: row 0 is `..` for parent nav, then folders, then `*.json` scripts and video files, all alphabetized (later: OS thumbnails and a list/tiles toggle). A single click (`item_selected`) either navigates into the folder or hands the file path to `main.gd:open_file`, which also closes the panel. Other files are hidden — this is a media picker, not a general explorer. First-launch dir is the repo's `scripts/` folder (one level above `res://`). Load results surface via `script_loaded` / `script_load_failed` into the status label. `gui_embed_subwindows = true` is kept on the SubViewport for future non-modal popups (tooltips, confirm dialogs).
- Config tab later filled in (locomotion, skybox, floor, volume) and a Network (DLNA) tab added; the Presets tab later became a preset manager (rename, delete, startup preset).

**4b — VR runtime + HUD** ✅ SCAFFOLDED (needs headset verification)

- Programmatic OpenXR init via `XRMode.try_enter_vr()` (already scaffolded in Phase 0). ✅ `session_stopping` now routed through `XRMode` so runtime-side session teardown (headset unplug, SteamVR quit) fires `exited_vr` and hands control back to desktop without a second `uninitialize()` call.
- `xr_rig.tscn`: `XROrigin3D` + `XRCamera3D` + `LeftController` + `RightController`. ✅ Instantiated under `Main` and hidden until `entered_vr`. On enter: `desktop_camera.current = false`, rig visible, `xr_camera.current = true`; reverse on exit.
- Wrist HUD ✅ — `XRToolsViewport2DIn3D` mounted at `LeftController/WristHud` (tilted `~45°` toward the palm, `0.18 m × 0.12 m` @ `540×360`). Hosts `player/vr/wrist_hud_content.tscn`: play/pause button + time label + volume slider (volume now works through `VideoBridge.set_volume`). `main.gd:_bind_wrist_hud()` waits one frame (XRToolsViewport2DIn3D instantiates its scene during its own `_ready`), then calls `bind(runner)`.
- Floating HUD toggle on right controller menu button ✅ — `XRRig` connects to `RightController.button_pressed`; on `menu_button` it emits `menu_button_pressed`, which `main.gd` bridges to `floating_panel.toggle`. The same `FloatingPanel` from 4a is reused: mouse forwarding stays wired for the desktop mirror; VR trigger clicks arrive through the `XRToolsFunctionPointer` → `XRToolsViewport2DIn3D` pointer-event pipeline, which the panel's static body already supports (no changes to the Control tree needed).
- Right-controller raycast + trigger click ✅ — `addons/godot-xr-tools/functions/function_pointer.tscn` instanced under `RightController`. Its default collision mask (`21:pointable | 23:ui-objects`) matches `XRToolsViewport2DIn3D`'s `DEFAULT_LAYER`, so the pointer lights up on both the wrist HUD and the floating panel.
- `_snap_camera` unstubbed ✅ — in VR it calls `XRRig.set_view(pos, rot_deg)` which moves the `XROrigin3D` (yaw only; pitch/roll deliberately dropped to avoid nausea). Desktop path unchanged.
- In-headset fade primitive ✅ — `XRRig` owns a 4 m × 4 m unlit quad `0.4 m` in front of `XRCamera3D` with an alpha-blend `StandardMaterial3D` (material is duplicated per-rig so the alpha isn't shared between instances). `fade_through()` tweens alpha 0→1→0 and mirrors `FadeOverlay.fade_through`'s API. On `fade_to_black` transitions `main.gd` runs the rig fade in VR (with the desktop overlay fading in parallel so the mirror matches) and only the overlay in desktop mode.
- **Not yet done**: (a) a recorded headset pass over this checklist — basic VR runs ("VR working" commit, 2026-09-22) but the items above aren't individually confirmed; (b) the "Exit VR" button doesn't yet gracefully handle mid-fade or mid-cut states; (c) hand models — the pointer laser is visible but the controllers themselves are invisible. Add `XRToolsController` hand models or simple gizmos in a follow-up.
- Deliverable: player runs on any machine (desktop mode). On a machine with a headset + OpenXR, clicking "Enter VR" switches to headset rendering with functional wrist controls; clicking "Exit VR" or unplugging the headset returns to desktop mode without crashing.

### Phase 5 — Player polish + export (2–3 days) 🚧 PARTLY DONE

*Status: `--script` works (plus `--vr`, `--start`, plain "Open with" paths) and the Windows export preset builds `build/VRmviewer.exe`; drag-and-drop onto the window and the Files tab both open scripts. Still open: `--windowed`, a loading spinner / error dialog, a release build. `--live-sync` belongs to Phase 8.*

- CLI args: `--script <path>`, `--live-sync <port>`, `--windowed`.
- Loading spinner / error dialog for bad scripts.
- Windows export preset with OpenXR enabled.
- Deliverable: `.exe` viewers can double-click to run; drag a script folder onto it (or use file browser) to play.

### Phase 6 — Editor plugin skeleton (3–4 days) ↪ REPLACED

*Status: replaced by scene-based authoring (`addon_vj/`): a normal Godot scene + `AnimationPlayer`, exported to the JSON format, with ▶ Preview in player. See Current Status. The original plan is kept below for reference.*

- `plugin.cfg`, `plugin.gd`, dock registration.
- Load/save `script.json` UI.
- Video-frame thumbnail using `godot-videodecoder`.
- Scrub bar with playhead time display.
- Simple flat track list showing what exists in the file (no editing yet).
- Deliverable: open a `script.json` in Godot editor, see its tracks, scrub the thumbnail.

### Phase 7 — Track editors (5–7 days) ↪ REPLACED

*Status: Godot's own animation editor does this job; the exporter maps its tracks to `transform` / `shader_param` / events. Original plan kept below for reference.*

- Registration system for track-editor types.
- `transform_track.gd`: keyframe lane, drag-to-move, keyframe inspector with a curve-easing dropdown.
- `shader_param_track.gd`: same UX, but the "target" picker walks the objects list and their material slots.
- `event_track.gd`: discrete event markers, action-type dropdown, per-action property forms.
- Schematic 2D preview canvas.
- Deliverable: author the `examples/minimal/` script entirely inside the plugin.

### Phase 8 — Live sync (2–3 days) ✅ DONE

*Status: `addon_vj/live_sync/live_sync.gd` (server, in the editor) and `player/live_sync/ws_client.gd` (`LiveSyncClient`) speak JSON over WebSocket on 127.0.0.1: `open` / `seek` / `play` / `pause` with a `seq`, answered by `state {script, t, playing, ack}`. The editor follows the player's playhead only from states that ack its latest command, so mid-scrub replies don't drag it back. Preview passes `--live-sync <port>`; with a player connected, Preview and scene save send `open` (reload in place via `ScriptRunner.reload()`) instead of relaunching. The player retries the connection every second; **F2 → Config → Editor sync** (`PlayerSettings.live_sync`) turns it off. Preview starts the player on desktop (`--desktop`) unless `vj_editor/player/start_in_vr` is set, since authoring is desktop-first with occasional F1 checks in the headset. Tests: `tests/test_live_sync.gd`.*

- `ws_server.gd` in plugin, `ws_client.gd` in player.
- "Launch Player ▶" button spawns a player process with `--live-sync <port>`.
- Bidirectional `seek` / `play` / `pause` / `reload` / `report_position`.
- Deliverable: scrub in Godot → running player seeks; save in Godot → running player hot-reloads.

### Phase 9 — Worked example: forest → tunnel (5–7 days) 🚧 FIRST PASS PLAYS END-TO-END

Done so far — authored in Godot in `project_script_forest_tunnel/` (a copy of the moving-screen authoring project), exported to `scripts/forest_tunnel/video.json`:

- **Prefabs**: `forest.tscn` (baked by `tools/build_forest.gd`: ground, ~420 firs and fireflies as MultiMeshes, no scripts) and `tunnel.tscn` (a 14 m open tube; rings and streaks in `tunnel.gdshader`, driven by a keyframed `scroll` param so scrubbing is deterministic). The screen's glow shader gained `uv_offset` / `uv_scale` (source sub-rect), and its halo alpha now scales with `glow_intensity`, so a screen at 0 has no dark rim and split pieces sit edge to edge without seams. The screen prefab gained `curvature` (vertex bend of a subdivided quad; `config.curvature` or a `<id>.display` track).
- **Timeline**: forest with a curved glowing screen → `vr_cut` fade at 45 s swaps to the tunnel at peak black → the screen flattens and dims, then splits at 55 s into three column screens (thirds of the video) that are choreographed independently → they merge at 160 s → cut back to the forest at 175 s. No format change was needed for any of it, which validates the v1 schema as the plan predicted.
- **Exporter** (addon): `shader_parameter` and `curvature` tracks → `shader_param`; a `VJViewer` camera's keys → `vr_cut` events (starting half the fade early so the cut lands at peak black); custom prefabs are bundled next to the JSON with their external dependencies embedded (dependency-free ones are copied verbatim, because re-saving under `--headless` loses MultiMesh buffers); `res://../` output paths.
- **Preview**: in the authoring project, scrubbing the AnimationPlayer is a rough preview (screens show a three-column test card or a `preview_image` still). **▶ Preview in player** (3D toolbar / Tools menu) exports and launches `project_engine` with `--script <json> --start <scrub time>`; pressing it again while that player is open only re-exports, and the player hot-reloads.
- **Player**: every spawned screen (not just `main_screen`) goes under `ScreenMount`, so split screens follow the user's size and distance settings; new `--start <seconds>` flag (applied once the video has loaded).
- 56 tests pass (new: example scripts parse, bundled prefabs load from disk, forest_tunnel object sets at key times, shader value coercion, slot routing).

Remaining:
- VR comfort pass on a headset (the fades, and whether the columns' fly-by at 68–76 s is too close).
- `env_swap` composite event: not needed so far. Two events at the same `t` read fine.
- Cuts only return to the home pose. A real "move somewhere else" cut would need `ScreenMount` to follow the viewer (see the forest_tunnel README).
- Add capabilities discovered during authoring — likely: a `env_swap` composite event that spawns/despawns a set atomically; a "3-way screen split" pattern documented as a prefab convention.
- Verify comfort: use `vr_cut` with `fade_to_black` for the environment transition.
- Deliverable: a shippable demo piece and a lessons-learned pass over the format.

### Phase 10 — Docs + release (2–3 days)

- `docs/script_format.md`: schema reference.
- `docs/authoring_guide.md`: walk through building a short piece in the plugin.
- `docs/player_usage.md`: how viewers install and run.
- Package plugin as a downloadable zip; package player as `.exe`.
- Deliverable: someone unfamiliar with the project can pick up the plugin and ship a piece.

**Total: ~8–12 weeks of focused work.**

## Risks & Mitigations

1. **Godot video decoding on Windows.** `VideoStreamPlayer` only handles Theora. `godot-videodecoder` exists but is community-maintained and its Windows/Godot 4.4 build state is not something I've verified. **Mitigation**: Phase 0 spike, before any other code. Fallbacks in order of preference: (a) godot-videodecoder works → done; (b) FFmpeg CLI transcodes MP4 → Theora on script load, cached alongside the script; (c) direct FFmpeg-libav integration via GDExtension (large scope increase — treat as last resort).
2. **XR framerate with multiple shaded surfaces at 90Hz × 2 eyes.** Fragment-shader-heavy scenes tank easily. **Mitigation**: profile in Phase 4 on the target hardware; keep shader math simple; render video to lower-res SubViewport where acceptable; document a "budget" (e.g. max 3 shaded surfaces concurrent) in the authoring guide.
3. **Live-reload race with mid-write files.** External editors write in stages; the watcher might catch a truncated file. **Mitigation**: parse errors don't clobber good state — keep last-good `TimelineData`, retry on next mtime bump. Debounce mtime changes (~150ms) before parsing.
4. **VR motion sickness in composed pieces.** Author writes a smooth 30-second forest-to-tunnel dolly and viewers get sick. **Mitigation**: `vr_cut` / `vr_teleport` / `fade_to_black` are first-class in the schema and the plugin surfaces them prominently as the default transition. Continuous XR-rig motion is possible but not the path of least resistance.
5. **Plugin ↔ player scene tree drift over time.** Two codebases share the schema — easy to diverge. **Mitigation**: schema lives in one place (`script_format/`) and is `class_name`'d so both plugin and player import the same parser. Version field lets the parser detect and reject mismatched scripts cleanly.
6. **Prefabs authored in one Godot version, played in another.** `.tscn` cross-version compatibility isn't guaranteed. **Mitigation**: pin Godot version in the schema's `format_version` compatibility matrix; ship a "prefab lint" step in the plugin that opens each referenced prefab and confirms it loads.

## Prior Art Worth Studying

- **[godot-event-sequencer](https://github.com/Amethyst-szs/godot-event-sequencer)** — visual scripting system for Godot 4 built around an Event Node + Event Editor. Closest public match to the "author a sequence of events in a custom editor panel" problem.
- **Dialogic 2** — most mature public example of a full custom timeline/event editor dock as a Godot addon, with its own file format (`.dtl`) and save/load integration. Reference for editor-dock lifecycle and custom-resource-format patterns.
- **Godot XR Tools** — controller/laser-pointer/UI-interaction helpers for the VR HUD.
- **GUT (Godot Unit Test)** — for the script-parsing/keyframe-evaluation core.
- **[godot-videodecoder](https://github.com/EIREXE/godot-videodecoder)** — GStreamer/FFmpeg-based video decoding addon; the Phase 0 risk-buydown.

## Worked Example: Forest → Light Tunnel, Splitting Screen

Scenario: video is a 3-column composition. Viewer starts in a forest with a big curved, glowing screen floating in the air; later transitions to a light tunnel, where the screen splits into 3 pieces that move independently — each showing one column of the source video.

This is expressible in the v1 schema with these mechanics:

- **Environment swap**: `spawn` and `despawn` events fire on the same `t=120.0`, with a `vr_cut` `fade_to_black` transition between them. The forest is one prefab (whole set of trees + terrain), the tunnel is another (tube + emissive shader). No new format machinery needed.
- **Screen splitting via UV sub-rects**: at the split moment, `despawn` the single `main_screen`, `spawn` three new screens (`screen_left`, `screen_center`, `screen_right`) at the same combined position. Each references the `video_surface` shader with a different `uv_offset` and `uv_scale` (thirds of the source). After the split, each is keyframed independently. The UV sub-rect is a shader param like any other, tracked by a `shader_param` track — no new track type needed. **This validates the format**: if this scenario works cleanly, most VJ compositions will.
- **Locomotion**: the viewer is moved from forest to tunnel via a `vr_cut` event with `fade_to_black`. No continuous XR-rig movement — no motion sickness. If a specific piece wants continuous locomotion, it can be added later as a `vr_dolly` event; not shipping in v1.

## Definition of Done (v1)

The project is v1-shippable when all of these are true:

- A viewer can double-click `player.exe`, use the wrist HUD to browse to a script folder on disk, put on a headset, and watch the piece play with correct video + timeline + VR comfort.
- An author can open Godot with the plugin enabled, create a new `script.json` from scratch, add keyframes and spawn events using the timeline dock, click "Launch Player ▶", and see their edits live-update in a running player instance.
- The `scripts/forest_tunnel/` demo runs end-to-end and demonstrates every schema feature.
- The three docs (`script_format.md`, `authoring_guide.md`, `player_usage.md`) are complete enough for a stranger to author and ship a piece without asking.
- `tests/` has coverage of the script parser and reconciliation logic, and passes.

## Next Concrete Step

See **Current Status → Open points** at the top; pick from there. The earlier note here (verify 4b on a headset, plus small nits) is folded into that list — the volume stub, `DEFAULT_SCRIPT` and curvature nits are fixed, the FileDialog check no longer applies, and the F1/F12 and right-click items are listed under Player.
