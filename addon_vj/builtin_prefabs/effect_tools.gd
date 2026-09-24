@tool
extends EditorContextMenuPlugin

## Editor tools for VJEffect nodes (effect.gd):
##   - "Add VJ effect ▸ <shader>" in the Scene dock's right-click menu on a
##     screen or layer: adds a VJEffect child with a fresh ShaderMaterial of
##     one of visualizer/effects/. Undoable.
##   - convert_slots(): Tools > VJ: Convert effect slots to nodes. Moves the old
##     effect_1..4 slots of every screen and layer into VJEffect children
##     and rewrites the tracks that animated them
##     (`main_screen:effect_2:shader_parameter/size` →
##     `main_screen/oval_mask:material:shader_parameter/size`). Undoable.

const EffectScript := preload("res://addons/vj_editor/builtin_prefabs/effect.gd")
const ScreenScript := preload("res://addons/vj_editor/builtin_prefabs/screen.gd")
const ICON := "res://addons/vj_editor/builtin_prefabs/effect_icon.svg"
const EFFECTS_DIR := "res://addons/vj_editor/visualizer/effects/"
const LABEL := "Add VJ effect"

var undo_redo: EditorUndoRedoManager
var _menu: PopupMenu
var _shaders: Array[String] = []


func _init() -> void:
	_menu = PopupMenu.new()
	_menu.id_pressed.connect(_on_shader_picked)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_menu):
		_menu.free()


func _popup_menu(_paths: PackedStringArray) -> void:
	if _targets().is_empty():
		return
	_menu.clear()
	_shaders.clear()
	for file in DirAccess.get_files_at(EFFECTS_DIR):
		if file.get_extension() == "gdshader":
			_shaders.append(EFFECTS_DIR + file)
	for i in _shaders.size():
		_menu.add_item(_shaders[i].get_file().get_basename().capitalize(), i)
	_menu.add_separator()
	_menu.add_item("Empty (pick a shader)", _shaders.size())
	add_context_submenu_item(LABEL, _menu, load(ICON) as Texture2D)


## Selected screens and layers.
static func _targets() -> Array[Node]:
	var out: Array[Node] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node.has_method("effect_nodes"):
			out.append(node)
	return out


func _on_shader_picked(id: int) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var targets := _targets()
	if root == null or targets.is_empty():
		return
	var shader_path := _shaders[id] if id < _shaders.size() else ""
	var base := shader_path.get_file().get_basename() if shader_path != "" else "effect"
	undo_redo.create_action(LABEL)
	var added: Array[Node] = []
	for parent in targets:
		var eff = _new_effect(parent, base, [])
		if shader_path != "":
			eff.material = ShaderMaterial.new()
			eff.material.shader = load(shader_path)
		_add_child_undoable(parent, eff, root)
		added.append(eff)
	undo_redo.commit_action()
	if added.size() == 1:
		EditorInterface.edit_node(added[0])


# ---------- converting effect_1..4 ----------

## Converts the edited scene. Returns how many slots were moved.
func convert_slots(root: Node, player: AnimationPlayer) -> int:
	var screens: Array[Node] = []
	for node in [root] + root.find_children("*", "", true, false):
		if node.has_method("legacy_effects") and not node.legacy_effects().is_empty() \
				and (node == root or node.owner == root):
			screens.append(node)
	if screens.is_empty():
		return 0
	var anim_root: Node = player.get_node_or_null(player.root_node) if player != null else null
	undo_redo.create_action("Convert effect slots to nodes")
	var count := 0
	for screen in screens:
		var legacy: Dictionary = screen.legacy_effects()
		var renames: Dictionary = {}  # slot -> effect node name
		var taken: Array = []
		for slot in ScreenScript.LEGACY_EFFECT_SLOTS:
			var mat: ShaderMaterial = legacy.get(slot)
			if mat == null:
				continue
			var base := "effect"
			if mat.shader != null and mat.shader.resource_path != "" and not mat.shader.resource_path.contains("::"):
				base = mat.shader.resource_path.get_file().get_basename()
			var eff = _new_effect(screen, base, taken)
			taken.append(String(eff.name))
			eff.material = mat
			_add_child_undoable(screen, eff, root)
			undo_redo.add_do_method(screen, "set", slot, null)
			undo_redo.add_undo_method(screen, "set", slot, mat)
			renames[slot] = String(eff.name)
			count += 1
		if anim_root != null:
			_rewrite_tracks(player, String(anim_root.get_path_to(screen)), renames)
	undo_redo.commit_action()
	return count


## `<screen>:effect_N:<rest>` → `<screen>/<name>:material:<rest>` in every
## animation of `player`.
func _rewrite_tracks(player: AnimationPlayer, screen_path: String, renames: Dictionary) -> void:
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim := lib.get_animation(anim_name)
			for i in anim.get_track_count():
				var path := anim.track_get_path(i)
				if String(path.get_concatenated_names()) != screen_path or path.get_subname_count() < 2:
					continue
				var slot := String(path.get_subname(0))
				if not renames.has(slot):
					continue
				var rest: Array = []
				for n in range(1, path.get_subname_count()):
					rest.append(String(path.get_subname(n)))
				var new_path := NodePath("%s/%s:material:%s" % [screen_path, renames[slot], ":".join(rest)])
				undo_redo.add_do_method(anim, "track_set_path", i, new_path)
				undo_redo.add_undo_method(anim, "track_set_path", i, path)


# ---------- helpers ----------

## A VJEffect named `base` (numbered if `parent` or `taken` has it).
static func _new_effect(parent: Node, base: String, taken: Array) -> Node:
	var eff_name := base
	var n := 2
	while parent.has_node(NodePath(eff_name)) or taken.has(eff_name):
		eff_name = "%s%d" % [base, n]
		n += 1
	var eff: Node = EffectScript.new()
	eff.name = eff_name
	return eff


func _add_child_undoable(parent: Node, child: Node, root: Node) -> void:
	undo_redo.add_do_method(parent, "add_child", child)
	undo_redo.add_do_property(child, "owner", root)
	undo_redo.add_do_reference(child)
	undo_redo.add_undo_method(parent, "remove_child", child)
