@tool
extends EditorPlugin

## Tools menu:
##   VJ: Export current scene to script.json…  — write the JSON
##   VJ: Preview in player                     — export, then run the player on it
##   VJ: Make VJ object                        — attach vj_object.gd to the selection
##                                               (also in the Scene dock's right-click menu)
##   VJ: Convert value tracks to Bezier        — so the curve editor can edit them
##                                               (exporter/bezier_tracks.gd; undoable)
##   VJ: Convert effect slots to nodes         — old effect_1..4 → VJEffect children
##                                               (builtin_prefabs/effect_tools.gd; undoable)
## The Scene dock's right-click menu on a screen or layer also has
## "Add VJ effect ▸ <shader>".
## The preview is also a button in the 3D editor's toolbar.
##
## Preview launches the engine project with this editor's own Godot binary
## (`vj_editor/player/engine_project`), or an exported player when
## `vj_editor/player/executable` is set. It starts at the AnimationPlayer's
## current scrub time, on desktop even with a headset connected (Enter VR / F1
## in the player switches; `vj_editor/player/start_in_vr` changes the default).
##
## The player connects back over live sync (live_sync/live_sync.gd, port
## `vj_editor/live_sync/port`): scrubbing and playing the animation drive the
## player, and pausing the player moves the Animation panel's playhead. While
## it is connected, Preview and saving the scene re-export and hot-reload it
## at the scrub time instead of starting another player.

const _MENU_EXPORT := "VJ: Export current scene to script.json…"
const _MENU_PREVIEW := "VJ: Preview in player"
const _MENU_MAKE_OBJECT := "VJ: Make VJ object"
const _MENU_TO_BEZIER := "VJ: Convert value tracks to Bezier"
const _MENU_EFFECT_SLOTS := "VJ: Convert effect slots to nodes"
const _SETTING_ENGINE := "vj_editor/player/engine_project"
const _SETTING_EXE := "vj_editor/player/executable"
const _SETTING_PORT := "vj_editor/live_sync/port"
const _SETTING_VR := "vj_editor/player/start_in_vr"
const _DEFAULT_ENGINE := "res://../project_engine"

const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")
const LiveSyncScript := preload("res://addons/vj_editor/live_sync/live_sync.gd")
const BezierTracksScript := preload("res://addons/vj_editor/exporter/bezier_tracks.gd")
const MakeVJObjectScript := preload("res://addons/vj_editor/modifiers/make_vj_object.gd")
const EffectToolsScript := preload("res://addons/vj_editor/builtin_prefabs/effect_tools.gd")

var _preview_button: Button
var _live_label: Label
var _live_sync: Node
var _player_pid: int = -1
var _make_object: EditorContextMenuPlugin
var _effect_tools: EditorContextMenuPlugin


func _enter_tree() -> void:
	add_tool_menu_item(_MENU_EXPORT, _on_export_pressed)
	add_tool_menu_item(_MENU_PREVIEW, _on_preview_pressed)
	_make_object = MakeVJObjectScript.new()
	_make_object.undo_redo = get_undo_redo()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _make_object)
	add_tool_menu_item(_MENU_MAKE_OBJECT, func(): _make_object.make(EditorInterface.get_selection().get_selected_nodes()))
	add_tool_menu_item(_MENU_TO_BEZIER, _on_convert_bezier_pressed)
	_effect_tools = EffectToolsScript.new()
	_effect_tools.undo_redo = get_undo_redo()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _effect_tools)
	add_tool_menu_item(_MENU_EFFECT_SLOTS, _on_convert_effect_slots_pressed)
	_add_setting(_SETTING_ENGINE, _DEFAULT_ENGINE, PROPERTY_HINT_DIR, "")
	_add_setting(_SETTING_EXE, "", PROPERTY_HINT_GLOBAL_FILE, "*.exe")
	_add_setting(_SETTING_PORT, LiveSyncScript.DEFAULT_PORT, PROPERTY_HINT_RANGE, "1024,65535")
	_add_setting(_SETTING_VR, false, PROPERTY_HINT_NONE, "")
	_preview_button = Button.new()
	_preview_button.text = "▶ Preview in player"
	_preview_button.flat = true
	_preview_button.tooltip_text = "Export this VJ scene and play it in the player, from the current animation time.\nIf the player is already open it just hot-reloads."
	_preview_button.pressed.connect(_on_preview_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _preview_button)
	_live_label = Label.new()
	_live_label.text = "● live"
	_live_label.visible = false
	_live_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_live_label.add_theme_color_override("font_color", Color(0.45, 0.85, 0.45))
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _live_label)
	_live_sync = LiveSyncScript.new()
	_live_sync.name = "VJLiveSync"
	add_child(_live_sync)
	_live_sync.connection_changed.connect(_on_live_connection_changed)
	scene_saved.connect(_on_scene_saved)


func _exit_tree() -> void:
	remove_tool_menu_item(_MENU_EXPORT)
	remove_tool_menu_item(_MENU_PREVIEW)
	remove_tool_menu_item(_MENU_MAKE_OBJECT)
	remove_tool_menu_item(_MENU_TO_BEZIER)
	remove_tool_menu_item(_MENU_EFFECT_SLOTS)
	if _effect_tools != null:
		remove_context_menu_plugin(_effect_tools)
		_effect_tools = null
	if _make_object != null:
		remove_context_menu_plugin(_make_object)
		_make_object = null
	if _preview_button != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _preview_button)
		_preview_button.queue_free()
		_preview_button = null
	if _live_label != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _live_label)
		_live_label.queue_free()
		_live_label = null
	if _live_sync != null:
		_live_sync.queue_free()  # its _exit_tree closes the server
		_live_sync = null


func _on_export_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("VJ export: no scene open.")
		return
	SceneExporterScript.export_from_root(root)


## Swaps each animation for a converted copy, so undo swaps the original back.
func _on_convert_bezier_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var player: AnimationPlayer = SceneExporterScript._find_animation_player(root) if root != null else null
	if player == null:
		push_warning("VJ: no AnimationPlayer under the scene root.")
		return
	var undo := get_undo_redo()
	undo.create_action("Convert value tracks to Bezier")
	var count := 0
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var original := lib.get_animation(anim_name)
			var converted: Animation = original.duplicate(true)
			var n := BezierTracksScript.convert_animation(converted, player.get_node_or_null(player.root_node))
			if n == 0:
				continue
			count += n
			undo.add_do_method(lib, "add_animation", anim_name, converted)
			undo.add_undo_method(lib, "add_animation", anim_name, original)
	undo.commit_action()
	print("VJ: converted %d value track(s) to Bezier." % count)


func _on_convert_effect_slots_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("VJ: no scene open.")
		return
	var n: int = _effect_tools.convert_slots(root, SceneExporterScript._find_animation_player(root))
	print("VJ: moved %d effect slot(s) into VJEffect nodes." % n)


func _on_preview_pressed() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("VJ preview: no scene open.")
		return
	var json_path := SceneExporterScript.export_from_root(root)
	if json_path.is_empty():
		return
	var t := _scrub_time(root)
	var playing := _is_animation_playing(root)
	_live_sync.start(int(ProjectSettings.get_setting(_SETTING_PORT, LiveSyncScript.DEFAULT_PORT)))
	if _live_sync.open(root.scene_file_path, json_path, t, playing):
		print("VJ preview: reloaded %s in the player at %.2fs" % [json_path.get_file(), t])
		return
	if _player_pid > 0 and OS.is_process_running(_player_pid):
		print("VJ preview: player already running — it will hot-reload %s" % json_path.get_file())
		return

	var user_args := PackedStringArray(["--script", json_path, "--start", str(t)])
	# Match the Animation panel: paused there means paused in the player.
	if not playing:
		user_args.append("--paused")
	if _live_sync.is_listening():
		user_args.append_array(["--live-sync", str(_live_sync.port)])
	# Authoring happens on desktop: don't jump into the headset just because
	# one is plugged in. F1 / Enter VR in the player switches when wanted.
	if not bool(ProjectSettings.get_setting(_SETTING_VR, false)):
		user_args.append("--desktop")
	var exe := String(ProjectSettings.get_setting(_SETTING_EXE, ""))
	var args := PackedStringArray()
	if exe.is_empty():
		exe = OS.get_executable_path()
		var engine := String(ProjectSettings.get_setting(_SETTING_ENGINE, _DEFAULT_ENGINE))
		engine = ProjectSettings.globalize_path(engine).simplify_path()
		if not FileAccess.file_exists(engine.path_join("project.godot")):
			push_error("VJ preview: no project.godot in '%s'. Set Project Settings > %s." % [engine, _SETTING_ENGINE])
			return
		args.append_array(["--path", engine])
	args.append("--")
	args.append_array(user_args)
	_player_pid = OS.create_process(exe, args)
	if _player_pid <= 0:
		push_error("VJ preview: failed to start '%s'." % exe)
		return
	print("VJ preview: started player (pid %d): %s %s" % [_player_pid, exe, " ".join(args)])


## Saving the previewed scene pushes it to the connected player, like Preview.
func _on_scene_saved(filepath: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.scene_file_path != filepath:
		return
	if not _live_sync.is_connected_to_player() or not _live_sync.is_previewing(filepath):
		return
	var json_path := SceneExporterScript.export_from_root(root)
	if not json_path.is_empty():
		_live_sync.open(filepath, json_path, _scrub_time(root))


func _on_live_connection_changed(connected: bool) -> void:
	_live_label.visible = connected
	_live_label.tooltip_text = "Player connected (live sync on port %d).
Scrub or play the animation to drive it; pause it there to move this playhead.
Preview or save to hot-reload it." % _live_sync.port


## Where the Animation panel's playhead is, so the preview starts there.
func _scrub_time(root: Node) -> float:
	for child in root.get_children():
		if child is AnimationPlayer and String(child.assigned_animation) != "":
			return snappedf(child.current_animation_position, 0.001)
	return 0.0


## Whether the scene's animation is playing in the editor right now.
func _is_animation_playing(root: Node) -> bool:
	for child in root.get_children():
		if child is AnimationPlayer and String(child.assigned_animation) != "":
			return child.is_playing()
	return false


func _add_setting(name: String, default: Variant, hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)
	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({"name": name, "type": typeof(default), "hint": hint, "hint_string": hint_string})
