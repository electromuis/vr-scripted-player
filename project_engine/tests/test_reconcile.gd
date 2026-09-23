extends RefCounted

## Tests for the live-reload reconciliation model in ScriptRunner.

const RunnerScript := preload("res://player/runtime/script_runner.gd")


static func test_project_state_before_any_event(tc: TestCase) -> void:
	var events := [
		{"t": 5.0, "action": "spawn", "id": "a", "prefab": "p"},
		{"t": 10.0, "action": "spawn", "id": "b", "prefab": "p"}
	]
	var state := RunnerScript._project_state_at(events, 3.0)
	tc.assert_eq(state.size(), 0)


static func test_project_state_after_first_spawn(tc: TestCase) -> void:
	var events := [
		{"t": 5.0, "action": "spawn", "id": "a", "prefab": "p"},
		{"t": 10.0, "action": "spawn", "id": "b", "prefab": "p"}
	]
	var state := RunnerScript._project_state_at(events, 7.0)
	tc.assert_eq(state.size(), 1)
	tc.assert_true(state.has("a"))
	tc.assert_false(state.has("b"))


static func test_project_state_despawn_removes(tc: TestCase) -> void:
	var events := [
		{"t": 1.0, "action": "spawn", "id": "a", "prefab": "p"},
		{"t": 5.0, "action": "despawn", "target": "a"},
		{"t": 10.0, "action": "spawn", "id": "b", "prefab": "p"}
	]
	var state := RunnerScript._project_state_at(events, 6.0)
	tc.assert_false(state.has("a"))
	tc.assert_false(state.has("b"))

	var later := RunnerScript._project_state_at(events, 12.0)
	tc.assert_false(later.has("a"))
	tc.assert_true(later.has("b"))


static func test_event_idx_after(tc: TestCase) -> void:
	var events := [
		{"t": 5.0}, {"t": 10.0}, {"t": 15.0}
	]
	tc.assert_eq(RunnerScript._event_idx_after(0.0, events), 0)
	tc.assert_eq(RunnerScript._event_idx_after(5.0, events), 1)
	tc.assert_eq(RunnerScript._event_idx_after(12.0, events), 2)
	tc.assert_eq(RunnerScript._event_idx_after(100.0, events), 3)


static func _make_runner_with_stage() -> Array:
	var stage := Node3D.new()
	stage.name = "Stage"
	var runner := ScriptRunner.new()
	runner.name = "ScriptRunner"
	runner.live_reload = false  # don't spawn a FileWatcher without a scene tree
	stage.add_child(runner)
	runner._stage = stage
	runner._registry = ObjectRegistry.new()
	runner._registry.name = "ObjectRegistry"
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	return [runner, stage]


static func _make_stub_prefab() -> PackedScene:
	var scene := PackedScene.new()
	var node := Node3D.new()
	node.name = "Stub"
	scene.pack(node)
	return scene


static func _timeline_from(dict: Dictionary) -> TimelineData:
	var data := TimelineData.new()
	data.format_version = 1
	data.meta = dict.get("meta", {})
	data.media = dict.get("media", {"video": "x.mp4", "duration": 100.0})
	data.prefabs = dict.get("prefabs", {})
	data.shaders = dict.get("shaders", {})
	data.objects = dict.get("objects", [])
	data.tracks = dict.get("tracks", [])
	data.script_path = dict.get("script_path", "<memory>")
	return data


static func test_reconcile_removes_no_longer_expected(tc: TestCase) -> void:
	# Bypass prefab loading by pre-populating the registry with a fake owned
	# node, then swap in a timeline whose projected state at the playhead
	# doesn't include that node — it should be despawned.
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	# Initial timeline: spawn cube_1 at t=1, no despawn.
	var initial := _timeline_from({
		"tracks": [{"type": "event", "t": 1.0, "action": "spawn", "id": "cube_1", "prefab": "cube"}]
	})
	runner.load_timeline(initial)

	# Pretend the spawn happened by registering a stub node under that id.
	var stub := Node3D.new()
	stage.add_child(stub)
	runner.registry().register("cube_1", stub, false)
	runner.playhead = 3.0

	# New timeline drops the spawn entirely.
	var replacement := _timeline_from({"tracks": []})
	runner._reconcile_swap(replacement)

	tc.assert_false(runner.registry().has_id("cube_1"))
	stage.queue_free()


static func test_reconcile_preserves_external(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var video_quad := Node3D.new()
	stage.add_child(video_quad)
	runner.registry().register("main_screen", video_quad, true)  # external

	runner.load_timeline(_timeline_from({}))
	runner.playhead = 5.0
	# Reload with a timeline that says nothing about main_screen — it must survive.
	runner._reconcile_swap(_timeline_from({}))

	tc.assert_true(runner.registry().has_id("main_screen"))
	tc.assert_true(runner.registry().is_external("main_screen"))
	stage.queue_free()


static func test_seek_reprojects_owned_state(tc: TestCase) -> void:
	# Scrubbing forward past a spawn must materialize that object; scrubbing
	# back past its despawn must remove it. Same rebuild semantics as reload.
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	# Register a stub "cube_1" so the spawn side is a no-op (we already have
	# a node). This lets us test the despawn direction without prefab loading.
	# Also add a despawn event that runs at t=15 in the timeline.
	var initial := _timeline_from({
		"tracks": [
			{"type": "event", "t": 3.0, "action": "spawn", "id": "cube_1", "prefab": "cube"},
			{"type": "event", "t": 15.0, "action": "despawn", "target": "cube_1"}
		]
	})
	runner.load_timeline(initial)

	var stub := Node3D.new()
	stage.add_child(stub)
	runner.registry().register("cube_1", stub, false)

	# Seek to t=10 — cube_1 should still be expected.
	runner.seek(10.0)
	tc.assert_true(runner.registry().has_id("cube_1"), "cube_1 expected at t=10")

	# Seek to t=20 — cube_1 should be gone (despawn at t=15 crossed).
	runner.seek(20.0)
	tc.assert_false(runner.registry().has_id("cube_1"), "cube_1 despawned by t=20")
	stage.queue_free()


static func test_load_script_preserves_external(tc: TestCase) -> void:
	# A fresh load_timeline (not reconcile) should also preserve externals —
	# that's the point of the external flag.
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var video_quad := Node3D.new()
	stage.add_child(video_quad)
	runner.registry().register("main_screen", video_quad, true)

	# Also add an owned object.
	var owned := Node3D.new()
	stage.add_child(owned)
	runner.registry().register("owned_thing", owned, false)

	runner.load_timeline(_timeline_from({}))

	tc.assert_true(runner.registry().has_id("main_screen"))
	tc.assert_false(runner.registry().has_id("owned_thing"))
	stage.queue_free()
