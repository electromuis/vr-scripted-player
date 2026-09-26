# VJ Editor (addon)

Author VJ scripts natively in Godot: place prefab instances in a scene, drive
them with an `AnimationPlayer`, and export the whole thing to the JSON format
the player runtime consumes.

The script JSON is the master copy of a piece. A scene is a way to edit it:
**Tools > VJ: Import script.json…** builds one from a JSON in an empty
project, and its export writes back to that JSON (see *Import* below).

## Layout

- `plugin.gd` / `plugin.cfg` — `EditorPlugin`: **Tools > VJ: Export…**,
  **Tools > VJ: Import script.json…**, **Tools > VJ: Preview in player**, and a **▶ Preview in player** button in
  the 3D editor toolbar
- `preview/desktop_preview.gd` — runtime-only desktop preview (fly camera, media bar, video)
- `builtin_prefabs/` — self-contained prefabs the artist drops into a scene
  - `vj_scene.gd` — `@tool` script for the scene root; holds meta/media/output-path
    and an optional `preview_image`
  - `vj_viewer.gd` — `VJViewer` camera marking the viewer; its keys become `vr_cut`s
  - `screen.tscn` + `screen.gd` — video screen with an optional artist shader in a
    SubViewport, then its effects (`VJEffect` children). A glowing screen is
    Padding → Glow effects; a split-screen piece is a Crop effect first. In the
    editor it shows `preview_image` or a three-column test card (no video decoder)
  - `layer.tscn` + `layer.gd` — shader layer (`VJLayer`): a Shadertoy-style shader
    on its own quad, with effects, like the player's Camera tab layers
  - `effect.gd` — `VJEffect`, one effect pass as a child node of a screen or layer
  - `effect_tools.gd` — **Add VJ effect** (Scene dock right-click) and
    **Tools > VJ: Convert effect slots to nodes**
  - `effect_chain.gd` — the editor preview's effect passes (screens and layers)
  - `screen_preview_display.gdshader` — editor-only display pass (curvature bends, opacity)
  - `cube.tscn` — placeholder solid object
- `modifiers/` — `vj_object.gd` (`VJObject`: the modifier and reactive fields,
  attached to any object; screens and layers extend it), `make_vj_object.gd`
  (the **Make VJ object** action) and `modifiers.gd`, the logic shared with
  the player (an identical copy of `project_engine/player/runtime/modifiers.gd`;
  a test checks)
- `visualizer/` — copies of the player's layer shaders (`shaders/`), effect
  shaders (`effects/`) and their includes, so they preview in the editor. The
  exporter maps them to the player's own. Keep them identical apart from the
  include paths; `project_engine/tests/test_addon_shader_copies.gd` checks
- `exporter/scene_exporter.gd` — walks a scene + its `AnimationPlayer`, produces
  the JSON dict, writes it to the configured output path
- `importer/script_importer.gd` — the reverse: builds the scene from a JSON;
  `importer/run_import.gd` runs it headless
- `tests/run_roundtrip.gd` — imports and re-exports every script (the repo's
  `scripts/` and `tests/fixtures/`) and checks they play the same

## Scene convention (what the exporter expects)

- Scene root: a `Node3D` with `vj_scene.gd` attached. Its exported properties
  drive the JSON `meta` and `media` blocks and the output file path.
- Children of the root are the addressable VJ objects. Each node's `name`
  becomes the JSON object `id`, so names must be unique across the whole
  scene. Builtins carry a `vj_prefab` metadata entry (`"screen"` / `"layer"` /
  `"cube"`, mapped to the player's own copies). Any other instanced `.tscn` is
  a custom prefab: the exporter copies it to `<json dir>/prefabs/<name>.tscn`
  with its external resources (shaders, scripts, materials) embedded, so the
  script folder is self-contained.
- Groups: a plain `Node3D` (no script) is a group. Anything you put under a
  group, screen or layer in this scene exports with `parent`, so it moves,
  rotates and scales with it and disappears with it. Hiding a parent
  (`visible` key) removes its children in the player too; showing it again
  brings back the ones that are visible.
- Screens: each instance needs its own `shader_material` (the prefab's is
  local-to-scene). `render_scale`, `curvature`, `vertical_curvature` and
  `opacity` export into `config`. A non-builtin shader is copied to
  `<json dir>/shaders/`.
- Effects (screens and layers): `VJEffect` child nodes (`builtin_prefabs/effect.gd`),
  run in child order, so drag them to reorder. Right-click a screen or layer →
  **Add VJ effect ▸** picks one of `visualizer/effects/` (Key black, Oval mask,
  Edge blur, Padding, Glow, Crop, Rounded corners, Keep center); **Empty** takes your own effect shader (include
  `visualizer/effect_prelude.gdshaderinc`) in its `material`. They export as
  `config.effects`; switched-off ones (`enabled` off) go along with
  `"enabled": false`, which the player skips. Scenes from before effects were nodes have
  `effect_1..4` slots, which no longer preview or export: run **Tools > VJ:
  Convert effect slots to nodes** once (undoable). It moves them into nodes
  named after their shaders and rewrites the tracks.
- Layers (`layer.tscn`): `shader_material` holds a layer shader, one of
  `visualizer/shaders/` (Light ring, Spectrum bars, Video blur) or your own
  canvas_item shader written the same way. `render_scale` exports as the
  layer's `resolution`. The editor has no audio, so sound-reactive layers
  only come alive in the player.
- VJ objects: right-click an object in the Scene dock → **Make VJ object** (or
  **Tools > VJ: Make VJ object**, or Attach Script → `modifiers/vj_object.gd`).
  Its **Modifiers** and **Reactive** fields then sit on the object itself, keyed
  like any property (`forest:opacity` next to `forest:position`). The prefab
  itself isn't changed: the script is attached to the instance in your scene.
  Screens and layers have the fields already. A prefab whose root has its own
  script can't take a second one; make that script extend `vj_object.gd`.
  A plain `Node3D` with it is a group whose modifiers reach its children.
- Modifiers reach everything under the object, and a group's multiply into its
  children's. They preview while you scrub, and the scene is always saved
  with the prefab's own values. All of them are Godot-native properties:
  - `opacity` (0–1): every mesh's `transparency`. On screens and layers it's
    their own display fade, as before
  - `tint` (colour): multiplies the colour (a multiply-blend `material_overlay`)
  - `flash` (colour, alpha = strength): adds light (an additive overlay pass)
  - `speed`: `speed_scale` of its particles and AnimationPlayers
  - `sort_offset` (m): `sorting_offset`, for while it's see-through. Faded
    things draw back to front by their centre, so a big environment around
    the viewer can land in front of a screen inside it; negative sorts it back
  `tint` and `flash` draw the object once more while they're not neutral;
  keep them short on big objects.
- Reactive fields are computed motion on top of the object's animated
  transform: `spin` (degrees per second per axis) and
  `pulse` (0–1, scale grows with the music's bass). The editor viewport
  doesn't move (your saved transform stays yours); spin shows in the F5
  preview and the player, pulse in the player only.
- Optional `VJViewer` child: the viewer's pose. Every key after t=0 on its
  position/rotation exports as a `vr_cut`; with `transition = fade_to_black`
  the event starts `fade_duration / 2` early so the cut lands at peak black
  on the key's time. The player starts every script at its home pose
  (0, 2, 8) looking down −Z; a start pose (rest pose, or a key at t=0)
  anywhere else exports as a hard `vr_cut` at t=0.
- A single `AnimationPlayer` child of the root holds one Animation named
  `"main"`. Tracks (`<node>` is the path from the root, e.g. `screens/screen_left`;
  the target is that node's name):
  - `<node>:position` → transform track, channel `position`
  - `<node>:rotation` → transform track, channel `rotation_deg` (radians → degrees)
  - `<node>:scale` → transform track, channel `scale`
  - `<node>:visible` → spawn / despawn events at the boolean transitions
  - `<node>:<resource>:shader_parameter/<p>` (e.g. `shader_material:…`,
    `material_override:…`) → `shader_param` track, target `<node>.surface`
    (`<node>.layer` on layers)
  - `<node>/<effect>:material:shader_parameter/<p>` → target `<node>.effect<N>`,
    N being the effect's place among the node's enabled effects (from 0)
  - `<node>:tint` / `:flash` / `:speed` / `:sort_offset`, and `:opacity` on
    other VJ objects than screens and layers → target `<node>.modifiers`
  - `<node>:spin` / `:pulse` → target `<node>.reactive`
  - `<screen or layer>:curvature` / `:vertical_curvature` / `:opacity` →
    `shader_param` track, target `<node>.display`
  - Discrete tracks export with `"interp": "step"`
  - Cubic tracks export as `"interp": "cubic"`, which the player runs through
    the keys the way Godot does
  - Bezier tracks work too (one per component, e.g. `<node>:position:x`); they
    export as `"interp": "bezier"` keys with their handles, so the player draws
    the same curves. Where a vector's components have keys at different times,
    each curve is split there exactly (it stays the same curve). Segments with
    flat handles export as plain linear. **Tools > VJ: Convert value tracks to Bezier**
    converts a scene's numeric value tracks (undoable) so the Animation panel's
    curve editor can edit them; `visible`, nearest / discrete and viewer tracks
    stay value tracks.

## Desktop preview (running the scene)

Running a `VJScene` (F5) adds `preview/desktop_preview.gd`. It gives you a fly camera on the `VJViewer` (or the first `Camera3D`): WASD, Q/E, Shift, right-drag look, R to reset. It also adds a media bar: play/pause, scrub, Space/K, ←/→ ±10 s. If the project has `addons/gde_gozen`, the video plays on every screen and the animation follows the video's clock. Without it, screens keep the preview still. Turn it off with `VJScene.desktop_preview`.

## Preview in player

Exports, then launches the player on the JSON with `--start <animation time>`.
By default it runs `project_engine` (Project Settings >
`vj_editor/player/engine_project`, default `res://../project_engine`) with the
editor's own Godot binary. Set `vj_editor/player/executable` to use an
exported player `.exe` instead. The player starts on desktop even with a
headset connected; press **Enter VR** (F1) in it to check in the headset, and
again to come back. Set `vj_editor/player/start_in_vr` to start in VR instead.

## Live sync

The launched player connects back to the editor over a local WebSocket
(`live_sync/live_sync.gd`, port `vj_editor/live_sync/port`, default 47810; the
next free one if taken). A green **● live** next to the Preview button shows
it's connected. While the previewed scene is open:

- scrubbing the `main` animation seeks the player,
- playing / pausing the animation plays / pauses the player,
- pausing the player (or scrubbing it while paused) moves the Animation
  panel's playhead there, so you can watch in the player or headset, stop at a
  moment, and keyframe it,
- **Preview** or saving the scene (Ctrl+S) re-exports and hot-reloads the
  player at the animation time, keeping its play state.

If you open something else in the player, it stops following until the next
Preview. Switching the player between desktop and VR doesn't affect sync. To
turn sync off, use the player's **F2 → Config → Editor sync** toggle. The protocol is documented in the player's
`player/live_sync/ws_client.gd`.

Scrubbing the `main` animation in the editor is the rough in-editor preview;
the player is the accurate one.

## Import

**Tools > VJ: Import script.json…** picks a script and builds `res://main.tscn`
(made the main scene), with custom prefabs copied to `prefabs/` and custom
shaders to `shaders/`. It only runs in an empty project (no scenes outside
`addons/`): the JSON is the master and the scene a view of it, so there's
nothing to merge. The scene's `output_path` is the JSON you imported, so
**Export** / **Preview** write back to it. Headless:

```
godot --headless --path <empty project> --script res://addons/vj_editor/importer/run_import.gd -- <script.json>
```

Everything the exporter writes imports exactly, so exporting an imported
script gives the same script. Hand-written scripts can say a few things a
scene can't; the importer converts them and lists each in the Output panel:

- a track mixing interpolations, or using `ease`, becomes Bezier tracks with
  the handles that draw the same curve (a `step` among other interpolations
  holds until 1 ms before its next key)
- an object spawned again with a different prefab, transform, parent or
  config keeps its first spawn's
- the scene's viewer has one transition, so cuts with different ones all
  get the first cut's
- `vr_teleport`, top-level `objects` (the player ignores them too) and
  `media.audio` are dropped

To check the round trip, from an authoring project with the addon linked in:

```
godot --headless --path project_script_example --script res://addons/vj_editor/tests/run_roundtrip.gd
```

It imports and exports each script twice and fails if the export plays
differently from the original (every track sampled through the player's
own interpolation) or changes on the second pass.

## Sharing between projects

The canonical copy of this addon lives at `<repo-root>/addon_vj/`. Each Godot
project that uses it (`project_engine`, `project_script_example`) contains a
Windows junction at `addons/vj_editor/` pointing there. Create the junction
with:

```powershell
New-Item -ItemType Junction -Path "<project>/addons/vj_editor" -Target "<repo>/addon_vj"
```

## Not-yet-implemented

- Fade `transition` on despawn — the exporter emits a plain despawn event
- `vr_teleport` (the Viewer only produces `vr_cut`s)
- Multiple animations / clip chaining
