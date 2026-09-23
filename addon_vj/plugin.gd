@tool
extends EditorPlugin

const _MENU_EXPORT := "VJ: Export current scene to script.json…"

const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")


func _enter_tree() -> void:
	add_tool_menu_item(_MENU_EXPORT, _on_export_pressed)


func _exit_tree() -> void:
	remove_tool_menu_item(_MENU_EXPORT)


func _on_export_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("VJ export: no scene open.")
		return
	SceneExporterScript.export_from_root(root)
