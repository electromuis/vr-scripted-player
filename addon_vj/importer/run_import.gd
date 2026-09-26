extends SceneTree

## Headless import of a script JSON into the current (empty) project:
##
##   godot --headless --path <empty project with addons/vj_editor> \
##       --script res://addons/vj_editor/importer/run_import.gd -- <script.json>
##
## Writes res://main.tscn (the main scene), prefabs/ and shaders/. Same as
## Tools > VJ: Import script.json.

const ScriptImporterScript := preload("res://addons/vj_editor/importer/script_importer.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("run_import: pass the script JSON after --")
		quit(2)
		return
	var result := ScriptImporterScript.import_into_project(args[0])
	if result.ok:
		print("VJ import: wrote %s (%d warning(s))" % [result.scene_path, result.warnings.size()])
	quit(0 if result.ok else 1)
