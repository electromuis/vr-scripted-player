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
3. **Desktop mode is a first-class runtime, not a fallback.** Whirligig and VRChat both start on desktop and let the user opt into VR. This player does the same. `openxr/enabled=false` in `project.godot` — OpenXR is initialized *at runtime* only when the user chooses "Enter VR" (button in the top bar, `F12` keybind, or `--vr` CLI flag). Consequences: (a) no headset required to launch, browse scripts, or preview; (b) full feature parity between desktop and VR playback — script authoring/preview must be possible entirely desktop; (c) a parallel 2D overlay UI mirrors the world-space HUD's controls for desktop; (d) desktop camera has WASD + right-click mouse-look, matching the affordances people expect from Whirligig/VRChat.

## Architecture

Three pieces, one shared format:

1. **Script format** — JSON describing a timeline of keyframed continuous tracks (transforms, shader params) and discrete events (spawn, despawn, transitions). Fully declarative — no embedded code. Assets referenced by relative path. Full schema in "Script Format" section below.
2. **Standalone player** — exported Godot 4.4 project (VR via OpenXR) that loads a script folder, plays the video on 3D surface(s), and evaluates the timeline each frame. Hot-reloads script + referenced assets. This is the only piece end viewers need.
3. **Editor plugin** — a Godot `EditorPlugin` that adds a custom bottom dock: timeline UI, per-track editors, schematic 2D preview, and live-sync to a running player instance for true WYSIWYG without in-editor 3D rendering.

The script format is the contract between the three pieces. Any one of them can be built or replaced without touching the others.

## Tech Stack

- **Engine**: Godot 4.4 stable (installed at `C:\ProgramData\chocolatey\lib\godot\tools\Godot_v4.4-stable_win64.exe`).
- **Language**: GDScript 2.0 for everything. C# is not needed and would complicate the plugin.
- **Video decoding**: `godot-videodecoder` (GStreamer-based FFmpeg wrapper) — Godot's built-in `VideoStreamPlayer` only handles Theora, which is a non-starter for real MP4/H.264/H.265 source material. **Verify this addon works on Windows in Phase 0 before committing.** Fallback: transcode inputs to Theora `.ogv` and use the built-in player, accepting the quality hit.
- **VR runtime**: OpenXR (Godot built-in). Hardware-agnostic — Index, Vive, Quest via Link/Virtual Desktop, etc.
- **VR helpers**: [Godot XR Tools](https://github.com/GodotVR/godot-xr-tools) for controller raycast + UI interaction.
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
  "format_version": 1,
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

- **Continuous tracks** — `transform`, `shader_param`. Interpolated every frame between keyframes.
- **Discrete events** — `spawn`, `despawn`, `vr_cut`, `vr_teleport`. Fired at their exact time.

Special references:

- `$video` — the video texture (a `ViewportTexture` from the video's `SubViewport`).
- `<object_id>.<material_slot>` — targets a named material on a spawned object (used by `shader_param` tracks).

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
- **UI**: 2D overlay (`CanvasLayer`) with a top bar showing mode ("Desktop"/"VR"), a play/pause/scrub bar (Phase 5), and an "Enter VR" button on the right. A settings panel toggled with `Tab` mirrors the VR floating panel's settings (virtual screen size/distance/curvature, script reload, file browser).
- **File browser**: standard `FileDialog` for picking script folders on disk.
- **Feature parity**: script authors and viewers can do everything except experience the piece in VR — authoring, previewing, scrubbing, and hot-reload all work desktop-only.

## VR Mode (opt-in)

- **Entry**: user clicks "Enter VR" in the top bar, presses `F12`, or launches with `--vr` on the command line. If OpenXR init fails, the player stays in desktop mode and shows a status message — never a fatal alert dialog.
- **Runtime**: Godot's built-in OpenXR, initialized programmatically at runtime. Hardware-agnostic (Index, Vive, Quest via Link/Virtual Desktop, etc. all route through SteamVR or a native OpenXR runtime).
- **Rig**: `XROrigin3D` with `XRCamera3D` and two `XRController3D` children. `vr_cut` / `vr_teleport` events move the XROrigin, not the camera.
- **World-space HUD**:
  - **Wrist-attached panel** (left controller): play/pause, volume, current time. Always visible when the wrist is up.
  - **Floating panel** (toggle on right controller menu button): file browser, virtual-screen settings, script reload button. Same *controls* as the desktop settings panel — different presentation.
- **Interaction**: right controller raycast + trigger. Use Godot XR Tools' `XRToolsPointer` scene rather than writing this from scratch.
- **"FOV" is virtual screen size**: don't touch camera FOV (motion sickness). The user-facing control is the virtual screen's size, curvature, and distance — sliders in the floating panel, persisted per-user in `user://settings.cfg`.

## Editor Plugin

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

### Phase 2 — Runtime interpreter (5–7 days)

- `script_runner.gd` — advances playhead, evaluates continuous tracks, fires discrete events. No VR yet.
- `object_registry.gd` — spawn/despawn with a simple fade transition.
- `prefab_library.gd` — cache.
- Interpolation utilities (linear, cubic bezier keyframes).
- `video_surface` prefab: a `MeshInstance3D` with a shader material sampling the video's `ViewportTexture`, exposing UV offset/scale as shader params.
- Deliverable: `examples/minimal/` plays end-to-end in flat mode. Keyframed transforms move the screen; spawn/despawn works.

### Phase 3 — Live reload (2–3 days)

- `file_watcher.gd` — mtime polling on a `Timer`.
- Reconciliation logic in `script_runner.gd`: re-parse, diff stage, apply, preserve playhead.
- Shader-only fast path.
- Deliverable: editing `script.json` in an external editor changes the running player without a restart, playhead preserved.

### Phase 4 — Desktop UI + VR + HUD (7–9 days)

Split into two sub-phases because desktop mode and VR mode share a settings model but not a presentation.

**4a — Desktop UI (2–3 days)**

- Top bar overlay: mode label, current time, "Enter VR" button (already scaffolded in Phase 0).
- Settings panel toggled with `Tab`: virtual-screen size/distance/curvature sliders, script reload, file picker via `FileDialog`, persisted to `user://settings.cfg`.
- Play/pause/scrub bar bound to `ScriptRunner`.
- `vr_cut` / `vr_teleport` / `fade_to_black` event handlers that also work in desktop mode (fade is a 2D overlay; cut/teleport moves the desktop camera).

**4b — VR runtime + HUD (5–6 days)**

- Programmatic OpenXR init via `XRMode.try_enter_vr()` (already scaffolded in Phase 0).
- `xr_rig.tscn`: `XROrigin3D` + `XRCamera3D` + two `XRController3D`.
- Wrist HUD: `SubViewport` → material on a `Node3D` panel attached to left controller. Play/pause/volume/time.
- Floating HUD toggle on right controller menu button.
- Right-controller raycast + trigger click using Godot XR Tools.
- Deliverable: player runs on any machine (desktop mode). On a machine with a headset + OpenXR, clicking "Enter VR" switches to headset rendering with functional wrist controls; clicking "Exit VR" or unplugging the headset returns to desktop mode without crashing.

### Phase 5 — Player polish + export (2–3 days)

- CLI args: `--script <path>`, `--live-sync <port>`, `--windowed`.
- Loading spinner / error dialog for bad scripts.
- Windows export preset with OpenXR enabled.
- Deliverable: `.exe` viewers can double-click to run; drag a script folder onto it (or use file browser) to play.

### Phase 6 — Editor plugin skeleton (3–4 days)

- `plugin.cfg`, `plugin.gd`, dock registration.
- Load/save `script.json` UI.
- Video-frame thumbnail using `godot-videodecoder`.
- Scrub bar with playhead time display.
- Simple flat track list showing what exists in the file (no editing yet).
- Deliverable: open a `script.json` in Godot editor, see its tracks, scrub the thumbnail.

### Phase 7 — Track editors (5–7 days)

- Registration system for track-editor types.
- `transform_track.gd`: keyframe lane, drag-to-move, keyframe inspector with a curve-easing dropdown.
- `shader_param_track.gd`: same UX, but the "target" picker walks the objects list and their material slots.
- `event_track.gd`: discrete event markers, action-type dropdown, per-action property forms.
- Schematic 2D preview canvas.
- Deliverable: author the `examples/minimal/` script entirely inside the plugin.

### Phase 8 — Live sync (2–3 days)

- `ws_server.gd` in plugin, `ws_client.gd` in player.
- "Launch Player ▶" button spawns a player process with `--live-sync <port>`.
- Bidirectional `seek` / `play` / `pause` / `reload` / `report_position`.
- Deliverable: scrub in Godot → running player seeks; save in Godot → running player hot-reloads.

### Phase 9 — Worked example: forest → tunnel (5–7 days)

- Build the prefabs: forest scene (terrain + trees), tunnel (tube + scrolling emissive shader), screen (with UV sub-rect shader).
- Compose `examples/forest_to_tunnel/script.json`.
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
- The `examples/forest_to_tunnel/` demo runs end-to-end and demonstrates every schema feature.
- The three docs (`script_format.md`, `authoring_guide.md`, `player_usage.md`) are complete enough for a stranger to author and ship a piece without asking.
- `tests/` has coverage of the script parser and reconciliation logic, and passes.

## Next Concrete Step

Phase 0 spike: scaffold the Godot project and validate video decoding on Windows. That's the single largest technical risk and blocks everything else. If it fails, the rest of the plan needs a Theora-based rewrite of Phase 2's video surface. Everything else in this plan is de-risked if Phase 0 works.
