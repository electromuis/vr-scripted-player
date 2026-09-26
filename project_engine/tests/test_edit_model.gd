extends RefCounted

## Studio's edit model (studio/model/edit_model.gd): commands, undo / redo,
## the dirty flag, and saving (byte-identical while nothing changed).

const TMP_DIR := "user://test_edit_model_tmp"

const DOC := """{
	"format_version": 2,
	"media": {"video": "clip.mp4"},
	"prefabs": {"screen": "res://player/prefabs/screen.tscn", "group": "res://player/prefabs/group.tscn"},
	"shaders": {},
	"tracks": [
		{"type": "event", "t": 0, "action": "spawn", "id": "rig", "prefab": "group"},
		{"type": "event", "t": 0, "action": "spawn", "id": "scr", "prefab": "screen", "parent": "rig",
			"transform": {"position": [0, 1, -3]}, "config": {"opacity": 0.5}},
		{"type": "event", "t": 8, "action": "despawn", "target": "rig"},
		{"type": "transform", "target": "scr", "channel": "position", "keyframes": [
			{"t": 0, "value": [0, 1, -3]},
			{"t": 4, "value": [1, 1, -3], "interp": "ease"}
		]},
		{"type": "shader_param", "target": "scr.display", "param": "curvature", "keyframes": [{"t": 1, "value": 0.2}]}
	]
}
"""


static func _example(rel: String) -> String:
	return ProjectSettings.globalize_path("res://../scripts").simplify_path().path_join(rel)


static func _model(tc: TestCase, text: String = DOC) -> EditModel:
	var r := EditModel.from_text(text, "")
	tc.assert_ok(r, "document loads")
	return r.get("model")


static func _tmp(name: String) -> String:
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	return TMP_DIR.path_join(name)


static func _keys(m: EditModel, ti: int) -> String:
	return JSON.stringify(m.tracks()[ti].keyframes.map(func(k): return [k.t, k.value]))


## JSON as the document holds it (numbers as floats).
static func _j(v) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(v)))


static func test_save_unchanged_is_byte_identical(tc: TestCase) -> void:
	for rel in ["forest_tunnel/video.json", "moving_screen/video.json", "minimal/video.json"]:
		var src := _example(rel)
		var r := EditModel.open(src)
		tc.assert_ok(r, rel)
		if not r.ok:
			continue
		var m: EditModel = r.model
		tc.assert_false(m.is_dirty(), rel)
		var out := _tmp(rel.get_base_dir() + ".json")
		tc.assert_ok(m.save(out), rel)
		tc.assert_eq(FileAccess.get_file_as_string(out), FileAccess.get_file_as_string(src), "%s saved byte-identical" % rel)
		# Changed and changed back: still the original bytes.
		var ids := m.object_ids()
		if not ids.is_empty():
			tc.assert_true(m.set_config(ids[0], "opacity", 0.25), rel)
			tc.assert_true(m.is_dirty(), rel)
			m.undo()
			tc.assert_false(m.is_dirty(), rel)
			tc.assert_ok(m.save(out), rel)
			tc.assert_eq(FileAccess.get_file_as_string(out), FileAccess.get_file_as_string(src), "%s after undo" % rel)


static func test_edited_save_is_valid_and_keeps_style(tc: TestCase) -> void:
	var m := _model(tc)
	tc.assert_true(m.set_key("transform", "scr", "position", 2.0, [5, 1, -3]))
	var out := _tmp("edited.json")
	tc.assert_ok(m.save(out))
	var text := FileAccess.get_file_as_string(out)
	tc.assert_true(text.begins_with("{\n\t\"format_version\""), "tab indentation like the original")
	tc.assert_true(text.ends_with("}\n"), "final newline like the original")
	var back := ScriptFormat.load_from_file(out)
	tc.assert_ok(back, "saved file loads in the player")
	# Keys keep their order.
	tc.assert_true(text.find("\"media\"") < text.find("\"prefabs\"") and text.find("\"prefabs\"") < text.find("\"tracks\""))


static func test_set_key_inserts_replaces_and_creates(tc: TestCase) -> void:
	var m := _model(tc)
	var ti := m.find_track("transform", "scr", "position")
	tc.assert_true(m.set_key("transform", "scr", "position", 2.0, [9, 9, 9]))
	tc.assert_eq(_keys(m, ti), _j([[0, [0, 1, -3]], [2.0, [9, 9, 9]], [4, [1, 1, -3]]]), "inserted in order")
	# Same time: replaced, keeping its interpolation.
	tc.assert_true(m.set_key("transform", "scr", "position", 4.0002, [2, 2, 2]))
	tc.assert_eq(m.tracks()[ti].keyframes.size(), 3)
	tc.assert_eq(m.tracks()[ti].keyframes[2].get("interp"), "ease", "interp kept")
	tc.assert_true(m.set_key("transform", "scr", "position", 4.0, [2, 2, 2], "step"))
	tc.assert_eq(m.tracks()[ti].keyframes[2].get("interp"), "step")
	# No track yet: made.
	tc.assert_eq(m.find_track("shader_param", "scr.display", "opacity"), -1)
	tc.assert_true(m.set_key("shader_param", "scr.display", "opacity", 3.0, 0.7))
	var ni := m.find_track("shader_param", "scr.display", "opacity")
	tc.assert_true(ni >= 0)
	tc.assert_eq(_keys(m, ni), _j([[3.0, 0.7]]))
	# Bad input changes nothing.
	tc.assert_false(m.set_key("transform", "scr", "position", 1.0, [1, 2]), "transform needs 3 numbers")
	tc.assert_false(m.set_key("transform", "scr", "position", 1.0, [1, 2, 3], "wobbly"))
	tc.assert_false(m.set_key("event", "scr", "x", 1.0, 1))
	# Undo walks it all back.
	while m.can_undo():
		m.undo()
	tc.assert_eq(JSON.stringify(m.document()), JSON.stringify(_model(tc).document()), "all undone")


static func test_same_value_is_not_a_command(tc: TestCase) -> void:
	var m := _model(tc)
	tc.assert_false(m.set_key("transform", "scr", "position", 0.0, [0, 1, -3]), "no change")
	tc.assert_false(m.can_undo())
	tc.assert_false(m.is_dirty())


static func test_move_and_delete_keys(tc: TestCase) -> void:
	var m := _model(tc)
	var ti := m.find_track("transform", "scr", "position")
	tc.assert_true(m.move_key(ti, 0, 6.0))
	tc.assert_eq(_keys(m, ti), _j([[4, [1, 1, -3]], [6.0, [0, 1, -3]]]), "re-sorted")
	tc.assert_true(m.move_key(ti, 1, 4.0), "onto another key: replaces it")
	tc.assert_eq(_keys(m, ti), _j([[4.0, [0, 1, -3]]]))
	tc.assert_false(m.move_key(ti, 5, 1.0))
	tc.assert_true(m.delete_key(ti, 0), "the last key")
	tc.assert_eq(m.find_track("transform", "scr", "position"), -1, "took its track")
	m.undo()
	m.undo()
	m.undo()
	tc.assert_eq(_keys(m, m.find_track("transform", "scr", "position")), _j([[0, [0, 1, -3]], [4, [1, 1, -3]]]))


static func test_spawn_transform_and_config(tc: TestCase) -> void:
	var m := _model(tc)
	var si := m.spawn_index("scr")
	tc.assert_true(m.set_spawn_transform("scr", {"position": [0, 2, -4], "rotation_deg": [0, 30, 0]}))
	tc.assert_eq(_j(m.tracks()[si].transform.position), _j([0, 2, -4]))
	tc.assert_true(m.set_config("scr", "opacity", 0.9))
	tc.assert_eq(m.tracks()[si].config.opacity, 0.9)
	tc.assert_true(m.set_config("scr", ["modifiers", "tint"], [1, 0, 0, 1]), "missing parent made")
	tc.assert_eq(_j(m.tracks()[si].config.modifiers), _j({"tint": [1, 0, 0, 1]}))
	tc.assert_true(m.set_config("scr", ["modifiers", "flash"], 0.5))
	tc.assert_eq(m.tracks()[si].config.modifiers.size(), 2)
	tc.assert_true(m.set_config("scr", "opacity", null), "null removes")
	tc.assert_false(m.tracks()[si].config.has("opacity"))
	tc.assert_false(m.set_config("scr", "opacity", null), "already gone")
	tc.assert_true(m.set_config("rig", "opacity", 1.0), "no config yet: made")
	tc.assert_eq(m.tracks()[m.spawn_index("rig")].get("config"), {"opacity": 1.0})
	tc.assert_false(m.set_config("nobody", "opacity", 1.0))
	for i in 6:
		m.undo()
	tc.assert_eq(JSON.stringify(m.document()), JSON.stringify(_model(tc).document()), "all undone")


static func test_add_and_remove_objects(tc: TestCase) -> void:
	var m := _model(tc)
	tc.assert_false(m.add_object({"id": "scr", "prefab": "screen"}), "id taken")
	tc.assert_false(m.add_object({"id": "x", "prefab": "nope"}), "unknown prefab")
	tc.assert_false(m.add_object({"id": "$viewer", "prefab": "screen"}), "reserved id")
	tc.assert_true(m.add_object({"id": "b", "prefab": "screen", "t": 2, "transform": {"position": [1, 1, -2]}}, 5.0))
	tc.assert_eq(m.object_ids(), ["rig", "scr", "b"])
	var data := m.timeline()
	tc.assert_true(data != null, "still a valid timeline")
	tc.assert_eq(data.events_sorted().filter(func(e): return e.get("target") == "b" or e.get("id") == "b").size(), 2, "spawn + despawn")
	# Removing the group takes its child, the child's tracks and the despawn.
	var before := m.tracks().size()
	tc.assert_true(m.remove_object("rig"))
	tc.assert_eq(m.object_ids(), ["b"])
	tc.assert_eq(m.tracks().size(), before - 5)
	tc.assert_eq(m.find_track("shader_param", "scr.display", "curvature"), -1)
	m.undo()
	tc.assert_eq(m.object_ids(), ["rig", "scr", "b"])
	tc.assert_eq(m.tracks().size(), before)


static func test_undo_redo_and_dirty(tc: TestCase) -> void:
	var m := _model(tc)
	var seen: Array = []
	m.changed.connect(func(structural: bool): seen.append(structural))
	tc.assert_false(m.can_undo() or m.can_redo())
	m.set_key("transform", "scr", "position", 2.0, [9, 9, 9])
	m.set_config("scr", "opacity", 0.1)
	tc.assert_eq(seen, [false, true], "keys aren't structural, configs are")
	tc.assert_eq(m.undo_label(), "Set scr opacity")
	tc.assert_eq(m.undo(), "Set scr opacity")
	tc.assert_eq(m.redo_label(), "Set scr opacity")
	tc.assert_eq(m.redo(), "Set scr opacity")
	tc.assert_eq(m.tracks()[m.spawn_index("scr")].config.opacity, 0.1)
	tc.assert_eq(seen, [false, true, true, true])
	tc.assert_eq(m.redo(), "", "nothing to redo")
	# Saved, undone, then something new: the saved state is gone for good.
	var out := _tmp("dirty.json")
	m.path = out
	tc.assert_ok(m.save())
	tc.assert_false(m.is_dirty())
	m.undo()
	tc.assert_true(m.is_dirty())
	m.redo()
	tc.assert_false(m.is_dirty(), "back at the save")
	m.undo()
	m.set_config("scr", "opacity", 0.1)
	tc.assert_true(m.is_dirty(), "same values, but not the saved state's history")
	tc.assert_false(m.can_redo(), "a new command clears redo")
	tc.assert_eq(m.undo(), "Set scr opacity")
	tc.assert_eq(m.undo(), "Key scr position at 0:02.00")
	tc.assert_eq(m.undo(), "")


static func test_invalid_document_is_not_saved(tc: TestCase) -> void:
	var m := _model(tc)
	var out := _tmp("invalid.json")
	if FileAccess.file_exists(out):
		DirAccess.remove_absolute(out)
	m.set_config("scr", "opacity", "very")
	var r := m.save(out)
	tc.assert_err({"ok": r.ok, "errors": [r.get("error", "")]}, "opacity must be a number")
	tc.assert_false(FileAccess.file_exists(out), "nothing written")
	tc.assert_false(FileAccess.file_exists(out + ".tmp"))
	tc.assert_true(m.is_dirty())


static func test_bad_files_do_not_open(tc: TestCase) -> void:
	tc.assert_err(EditModel.open("user://nope.json"), "not found")
	tc.assert_err(EditModel.from_text("[1, 2]"), "Not a script JSON")
	tc.assert_err(EditModel.from_text('{"format_version": 2, "media": {}}'), "media.video")


static func test_v1_is_upgraded(tc: TestCase) -> void:
	var v1 := DOC.replace('"format_version": 2', '"format_version": 1').replace('"interp": "ease"', '"interp": "cubic"')
	var m := _model(tc, v1)
	var ti := m.find_track("transform", "scr", "position")
	tc.assert_eq(m.tracks()[ti].keyframes[1].interp, "ease", "v1 cubic meant ease")
	tc.assert_eq(m.document().format_version, 2)
	var out := _tmp("v1.json")
	tc.assert_ok(m.save(out))
	tc.assert_eq(FileAccess.get_file_as_string(out), v1, "unchanged: written as it was")
	m.set_key("transform", "scr", "position", 2.0, [9, 9, 9])
	tc.assert_ok(m.save(out))
	var back := ScriptFormat.load_from_file(out)
	tc.assert_ok(back)
	tc.assert_eq(back.data.format_version, 2, "edited: saved as v2")
	var kfs: Array = back.data.tracks[ti].keyframes
	tc.assert_eq(kfs[2].interp, "ease", "and still eases")


static func test_timeline_is_a_copy(tc: TestCase) -> void:
	var m := _model(tc)
	var data := m.timeline()
	data.tracks[3].keyframes[0].value = [7, 7, 7]
	tc.assert_eq(_j(m.tracks()[3].keyframes[0].value), _j([0, 1, -3]), "the runner can't change the document")
	# And the document can't change a value handed in.
	var tr := {"position": [1, 2, 3]}
	m.set_spawn_transform("scr", tr)
	tr.position[0] = 100
	tc.assert_eq(_j(m.tracks()[1].transform.position), _j([1, 2, 3]))
