extends RefCounted

## Studio's edits reaching the runner (ScriptRunner.apply_edit): key edits
## re-evaluate in place, structural ones respawn only what changed.

const DOC := {
	"format_version": 2,
	"media": {"video": "x.mp4", "duration": 20.0},
	"prefabs": {"cube": "res://player/prefabs/cube.tscn"},
	"tracks": [
		{"type": "event", "t": 0, "action": "spawn", "id": "a", "prefab": "cube"},
		{"type": "event", "t": 0, "action": "spawn", "id": "b", "prefab": "cube",
			"transform": {"position": [2, 0, 0]}},
		{"type": "transform", "target": "a", "channel": "position", "keyframes": [
			{"t": 0, "value": [0, 0, 0]}, {"t": 10, "value": [10, 0, 0]}]},
	],
}


static func _setup(tc: TestCase) -> Array:
	var stage := Node3D.new()
	var runner := ScriptRunner.new()
	runner.live_reload = false
	stage.add_child(runner)
	runner._stage = stage
	runner._registry = ObjectRegistry.new()
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	var r := EditModel.from_text(JSON.stringify(DOC))
	tc.assert_ok(r)
	var model: EditModel = r.model
	model.changed.connect(func(structural: bool): runner.apply_edit(model.timeline(), structural))
	runner.load_timeline(model.timeline())
	runner.seek(5.0)
	return [runner, model, stage]


static func _node(runner: ScriptRunner, id: String) -> Node3D:
	return runner.registry().get_node_by_id(id)


static func test_key_edit_applies_in_place(tc: TestCase) -> void:
	var s := _setup(tc)
	var runner: ScriptRunner = s[0]
	var model: EditModel = s[1]
	var a := _node(runner, "a")
	tc.assert_true(a != null, "a spawned")
	tc.assert_eq(a.position, Vector3(5, 0, 0))
	model.set_key("transform", "a", "position", 10.0, [0, 0, 20])
	tc.assert_eq(_node(runner, "a"), a, "not respawned")
	tc.assert_eq(a.position, Vector3(0, 0, 10), "paused view shows the edit")
	tc.assert_eq(runner.playhead, 5.0, "playhead kept")
	model.undo()
	tc.assert_eq(a.position, Vector3(5, 0, 0), "undo shows too")
	s[2].free()


static func test_structural_edit_respawns_only_what_changed(tc: TestCase) -> void:
	var s := _setup(tc)
	var runner: ScriptRunner = s[0]
	var model: EditModel = s[1]
	var a := _node(runner, "a")
	var b := _node(runner, "b")
	tc.assert_eq(b.position, Vector3(2, 0, 0))
	model.set_spawn_transform("b", {"position": [0, 3, 0]})
	tc.assert_eq(_node(runner, "a"), a, "a untouched")
	tc.assert_true(_node(runner, "b") != b, "b respawned")
	tc.assert_eq(_node(runner, "b").position, Vector3(0, 3, 0))
	tc.assert_eq(a.position, Vector3(5, 0, 0), "a still at its track's value")
	model.remove_object("b")
	tc.assert_false(runner.registry().has_id("b"))
	model.undo()
	tc.assert_eq(_node(runner, "b").position, Vector3(0, 3, 0), "back after undo")
	model.add_object({"id": "c", "prefab": "cube", "t": 8.0})
	tc.assert_false(runner.registry().has_id("c"), "spawns later than the playhead")
	runner.seek(9.0)
	tc.assert_true(runner.registry().has_id("c"))
	s[2].free()
