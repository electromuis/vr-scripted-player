# project_script_forest_tunnel — Forest → Light Tunnel, Splitting Screen

Godot authoring project for the plan's **worked example**. It started as a copy
of `project_script_example` (moving screen). Edit `main.tscn` in Godot, then
click **▶ Preview in player** in the 3D editor toolbar (or **Tools > VJ: Preview
in player**). That exports to `scripts/forest_tunnel/video.json` and plays it in
the real player, starting at the Animation panel's current time.

Scrubbing the `main` animation in the editor gives a rough preview. It shows a
three-column test card instead of the video, and the easing differs slightly
from the player's. The player is the accurate view.

## Desktop preview (F5)

Running the scene (F5, or **Run Current Scene**) opens a desktop preview. It has no VR.

- **WASD** to move, **Q/E** down/up, **Shift** faster, hold **right-click** to look around, **R** to reset the view.
- The media bar has play/pause and a scrub bar with the time. **Space**/**K** play/pause, **←/→** seek ±10 s.
- The real video plays on every screen, with audio, through gde_gozen. The AnimationPlayer's `main` animation follows the video's clock.
- The fly camera is the `Viewer` itself, so the viewer's cut keys (45 s, 175 s) snap you back to the home pose, as in the player. The player's fade to black isn't reproduced.

This comes from `addon_vj/preview/desktop_preview.gd`, which `VJScene` adds at runtime (turn it off with `desktop_preview` on the root). Other authoring projects get the same preview without video, unless they also link gde_gozen.

## The piece (video: `scripts/minimal/video.mp4`, 188.9 s)

| Time | What happens |
| --- | --- |
| 0–45 s | Night forest. A big curved (`curvature` 0.35), glowing screen floats and sways, cut to an oval with soft edges (Padding → Oval mask → Edge blur effects). Behind it, the `backdrop` layer (a blurred copy of the video in an oval) glows. The glow and backdrop fade in over the first 4 s. |
| 42–44.5 s | The forest fades out (`forest:opacity` 1 → 0; `sort_offset` −30 keeps the see-through trees behind the screen). |
| 45 s | Environment swap: `forest` despawns and `tunnel` spawns at the peak of a 1 s `vr_cut` fade to black (the cut event starts at 44.5 s). The tunnel then fades in over 45–53.5 s (`tunnel:opacity` 0 → 1). |
| 49–55 s | The screen flattens (display `curvature` → 0), the oval opens up (Oval mask `size` → 2), and the glow, inner glow and Edge blur fade to 0. Adjacent pieces can then sit edge to edge without seams. |
| 55 s | **Split**: `main_screen` despawns, taking its `backdrop` with it. `screen_left` / `screen_center` / `screen_right` spawn in the same spot inside the `screens` group, showing the video's thirds (`uv_offset` 0, ⅓, ⅔ and `uv_scale` (⅓, 1)). |
| 55–150 s | The columns move independently: they fly apart and their glow returns, then a diagonal, a side swap (the whole group swells, `screens:scale`), a vertical cross-over, and a wide spread with warm/cool tints (the group sways, `screens:rotation`) while the tunnel speeds up. From 60 s the `rings` layer (Light ring, curved, inner oval cut out) fades in behind them and pulses with the music. |
| 150–160 s | `rings` fades out, the columns line back up and dim. At 160 s they merge back into `main_screen`, and the backdrop comes back. |
| 175 s | Cut back to the forest, which fades back in over 3 s, and the screen curves back into its oval. |

The effects and the two layers come from the player's "Preset 2" camera preset: the screen's effect chain, the Video blur backdrop and the Light ring, now authored in the scene instead of set by the viewer.

## Layout

- `main.tscn`: the piece.
  - `Stage` (root, `VJScene`): meta, video path, `output_path = res://../scripts/forest_tunnel/video.json`, and an optional `preview_image` (a still to use instead of the test card).
  - `Viewer` (`VJViewer` camera): the viewer. Each key after t=0 on `Viewer:position` / `:rotation` exports as a `vr_cut` (`fade_to_black`, `fade_duration`). Toggle its camera preview in the 3D editor to see what the viewer sees.
  - `forest`, `tunnel`: custom prefabs, spawned and despawned by their `visible` tracks. Both are VJ objects (`vj_object.gd` attached, see the addon README), with `opacity` keyed for the fades.
  - `main_screen`, `screen_left|center|right`: `screen` prefab instances. Each one has its own `shader_material`. `main_screen` also has three effects (`effect_1..3`).
  - `main_screen/backdrop`: a `layer` prefab (Video blur + Padding + Oval mask) inside the screen, so it follows the screen's sway and goes when the screen does.
  - `screens`: a group (plain `Node3D` at (0, 3, −2)) holding the three columns, whose positions are relative to it, and the `rings` layer (Light ring + inner Oval mask).
  - `AnimationPlayer` → `main` (36 tracks).
- `prefabs/tunnel.tscn` + `tunnel.gdshader`: an open 14 m-radius tube with scrolling rings and streaks. Its motion is driven by the keyframed `scroll` param (not `TIME`), so scrubbing is deterministic.
- `prefabs/forest.tscn`: baked by `tools/build_forest.gd` (trees and fireflies are MultiMeshes; the file contains no scripts). Regenerate it with `godot --path project_script_forest_tunnel --script res://tools/build_forest.gd`. Don't use `--headless`: the dummy renderer drops the MultiMesh data.
- `tools/run_export.gd`: a headless export (`godot --headless --path project_script_forest_tunnel --script res://tools/run_export.gd`).
- `addons/vj_editor/`: a **Windows junction** → `../../addon_vj/`. See `project_script_example/README.md` for how to recreate it.
- `addons/gde_gozen/`: a **Windows junction** → `../../project_engine/addons/gde_gozen/` (the video decoder, used only by the F5 preview). Recreate it with:
  `New-Item -ItemType Junction -Path project_script_forest_tunnel\addons\gde_gozen -Target (Resolve-Path project_engine\addons\gde_gozen)`

## Animating things

`<path>` is the node's path from the root (`screens/screen_left`); `<id>` is its name.

| Track path | Exports as |
| --- | --- |
| `<path>:position` / `:rotation` / `:scale` | `transform` track |
| `<path>:visible` | `spawn` / `despawn` events |
| `<path>:shader_material:shader_parameter/<p>` (screens / layers) | `shader_param`, target `<id>.surface` / `<id>.layer` |
| `<path>:effect_<N>:shader_parameter/<p>` | `shader_param`, target `<id>.effect<N-1>` |
| `<path>:curvature` / `:vertical_curvature` / `:opacity` (screens, layers) | `shader_param`, target `<id>.display` |
| `<id>:material_override:shader_parameter/<p>` (e.g. `tunnel`) | `shader_param`, target `<id>.surface` |
| `<path>:opacity` / `:tint` / `:flash` / `:speed` / `:sort_offset` (VJ objects; opacity on screens and layers is the display row above) | `shader_param`, target `<id>.modifiers` |
| `<path>:spin` / `:pulse` (VJ objects) | `shader_param`, target `<id>.reactive` |
| `Viewer:position` / `:rotation` | `vr_cut` events |

On export, custom prefabs are copied into `scripts/forest_tunnel/prefabs/`, with
any external shaders or scripts embedded, so the script folder is
self-contained.

## Known gaps

- The viewer only *cuts*. The two cuts here return to the home pose, (0, 2, 8)
  looking down −Z, so their job is to cover the environment swap. The screens
  live in the player's `ScreenMount`, which is anchored at the origin, so
  moving the viewer far away would leave the screens behind.
- The editor's cubic interpolation is Godot's (smooth through each key). The
  player's `cubic` is a per-segment smoothstep (it eases in and out at every
  key), so motion timing differs slightly.
