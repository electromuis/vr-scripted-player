# project_script_example — Moving Screen

Godot authoring project for **one** VJ piece (the moving-screen demo). Edit
`main.tscn` in Godot, then run **Tools > VJ: Export current scene to
script.json…** to write the JSON the player consumes.

## Layout

- `project.godot` — enables the `vj_editor` plugin
- `addons/vj_editor/` — **Windows junction** → `../../addon_vj/` (the canonical
  addon lives at the repo root; this project just references it)
- `main.tscn` — the scene:
  - `Stage` (root, `VJScene` script) — holds meta / video path / export path
  - `main_screen` — `screen` prefab instance, animated position + rotation
  - `cube_1` — `cube` prefab instance, spawn/despawn via a `visible` track
  - `AnimationPlayer` with one animation `main` (length 18s)

## Recreating the addon junction

If you clone this repo fresh, `addons/vj_editor/` will be a broken junction.
Recreate it from PowerShell:

```powershell
Remove-Item project_script_example\addons\vj_editor -Force -ErrorAction SilentlyContinue
New-Item -ItemType Junction `
    -Path project_script_example\addons\vj_editor `
    -Target (Resolve-Path addon_vj)
```

## Export target

`Stage.output_path` currently points at
`c:/dev/VRmviewer/scripts/moving_screen/video.json`. Change it if your checkout
lives elsewhere. The player reads that same file (`project_engine` launched
with `--script <path>`).

## Adding new objects

1. Drag `addons/vj_editor/builtin_prefabs/screen.tscn` or `cube.tscn` into
   `Stage` (must be a direct child).
2. Rename it — the node name becomes the JSON `id`.
3. Set `metadata/vj_prefab` on the new node to `"screen"` or `"cube"` (or the
   `res://` path of a custom prefab).
4. Author position / rotation / scale / visibility tracks on the
   `AnimationPlayer`'s `main` animation.
5. Export.
