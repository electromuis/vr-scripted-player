# VJ Editor (addon)

Author VJ scripts natively in Godot: place prefab instances in a scene, drive
them with an `AnimationPlayer`, and export the whole thing to the JSON format
the player runtime consumes.

## Layout

- `plugin.gd` / `plugin.cfg` — `EditorPlugin`, registers the export menu item
- `builtin_prefabs/` — self-contained prefabs the artist drops into a scene
  - `vj_scene.gd` — `@tool` script for the scene root; holds meta/media/output-path
  - `screen.tscn` + `screen.gd` — video screen with an artist shader in a SubViewport
  - `screen_glow.gdshader` — the default glow shader used by the screen prefab
  - `cube.tscn` — placeholder solid object
- `exporter/scene_exporter.gd` — walks a scene + its `AnimationPlayer`, produces
  the JSON dict, writes it to the configured output path

## Scene convention (what the exporter expects)

- Scene root: a `Node3D` with `vj_scene.gd` attached. Its exported properties
  drive the JSON `meta` and `media` blocks and the output file path.
- Direct children of the root are the addressable VJ objects. Each child's
  `name` becomes the JSON object `id`. Each has a `vj_prefab` string metadata
  entry naming the prefab key (`"screen"`, `"cube"`, or a `res://…` path).
- A single `AnimationPlayer` child of the root holds one Animation named
  `"main"`. Tracks:
  - `<node>:position` → transform track, channel `position`
  - `<node>:rotation` → transform track, channel `rotation_deg` (radians → degrees)
  - `<node>:scale` → transform track, channel `scale`
  - `<node>:visible` → spawn / despawn events at the boolean transitions

## Sharing between projects

The canonical copy of this addon lives at `<repo-root>/addon_vj/`. Each Godot
project that uses it (`project_engine`, `project_script_example`) contains a
Windows junction at `addons/vj_editor/` pointing there. Create the junction
with:

```powershell
New-Item -ItemType Junction -Path "<project>/addons/vj_editor" -Target "<repo>/addon_vj"
```

## Not-yet-implemented

- Import (JSON → scene) — this addon is export-only for now
- Fade `transition` on despawn — the exporter emits a plain despawn event
- Custom track types for `vr_cut` / `vr_teleport`
- Multiple animations / clip chaining
