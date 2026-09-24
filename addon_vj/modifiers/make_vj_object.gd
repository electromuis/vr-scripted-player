@tool
extends EditorContextMenuPlugin

## "Make VJ object" in the Scene dock's right-click menu (and Tools > VJ:
## Make VJ object): attaches vj_object.gd to the selected 3D nodes, so their
## modifier and reactive fields show up in the Inspector. Undoable. Nodes
## that already have a script are left alone: a prefab root with its own
## script can extend vj_object.gd instead.

const VJ_OBJECT_PATH := "res://addons/vj_editor/modifiers/vj_object.gd"
const VJObjectScript := preload(VJ_OBJECT_PATH)
const LABEL := "Make VJ object"

var undo_redo: EditorUndoRedoManager


func _popup_menu(_paths: PackedStringArray) -> void:
	for node in EditorInterface.get_selection().get_selected_nodes():
		if can_make(node):
			add_context_menu_item(LABEL, make)
			return


## A 3D node in the edited scene, not its root, without a script yet.
static func can_make(node: Node) -> bool:
	return node is Node3D and node.get_script() == null \
			and node != EditorInterface.get_edited_scene_root() \
			and not (node is Camera3D or node is Light3D or node is WorldEnvironment)


func make(nodes: Array) -> void:
	var targets := nodes.filter(can_make)
	for node in nodes:
		if node is Node3D and node.get_script() != null and not node.has_method("modifier_values"):
			push_warning("VJ: '%s' already has a script; make that script extend %s to give it the VJ fields." % [node.name, VJ_OBJECT_PATH])
	if targets.is_empty():
		return
	undo_redo.create_action(LABEL)
	for node in targets:
		undo_redo.add_do_property(node, "script", VJObjectScript)
		undo_redo.add_undo_property(node, "script", null)
	undo_redo.commit_action()
