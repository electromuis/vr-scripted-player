extends SceneTree

## Headless runner for the VJ scene exporter. Loads main.tscn, invokes the
## exporter, quits. Useful for CI or a one-shot export from the command line:
##
##   godot --headless --path project_script_forest_tunnel --script res://tools/run_export.gd

const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")


func _initialize() -> void:
	var packed: PackedScene = load("res://main.tscn")
	if packed == null:
		push_error("run_export: could not load res://main.tscn")
		quit(1)
		return
	var root: Node = packed.instantiate()
	if root == null:
		push_error("run_export: instantiate returned null")
		quit(1)
		return
	var out := SceneExporterScript.export_from_root(root)
	root.free()
	quit(0 if out != "" else 1)
