extends RefCounted

## Deterministic tests of ScriptRunner behavior — feed a TimelineData,
## register a stub Node3D, tick, assert state.
##
## We instantiate ScriptRunner directly (no scene tree entry). This works
## because tick() is decoupled from _process, and the ObjectRegistry it owns
## is a plain Node (no engine _process dependency).


static func _make_runner_with_stage() -> Array:
	# Returns [ScriptRunner, stage_node] — caller frees when done.
	var stage := Node3D.new()
	stage.name = "Stage"
	var runner := ScriptRunner.new()
	runner.name = "ScriptRunner"
	stage.add_child(runner)
	# Give the runner a valid stage node reference by touching _ready manually.
	# stage_path is empty in a bare instance, so wire _stage directly for tests.
	runner._stage = stage
	# _ready wasn't triggered outside SceneTree; do the registry setup manually.
	runner._registry = ObjectRegistry.new()
	runner._registry.name = "ObjectRegistry"
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	return [runner, stage]


static func _timeline_from(dict: Dictionary) -> TimelineData:
	var data := TimelineData.new()
	data.format_version = 1
	data.meta = dict.get("meta", {})
	data.media = dict.get("media", {"video": "x.mp4", "duration": 100.0})
	data.prefabs = dict.get("prefabs", {})
	data.shaders = dict.get("shaders", {})
	data.objects = dict.get("objects", [])
	data.tracks = dict.get("tracks", [])
	return data


static func test_transform_track_moves_registered_node(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var target := Node3D.new()
	stage.add_child(target)
	var data := _timeline_from({
		"tracks": [{
			"type": "transform",
			"target": "movee",
			"channel": "position",
			"keyframes": [
				{"t": 0.0, "value": [0, 0, 0]},
				{"t": 10.0, "value": [10, 0, 0]}
			]
		}]
	})
	runner.load_timeline(data)
	runner.registry().register("movee", target)

	runner.tick(0.0)
	tc.assert_eq(target.position.x, 0.0)
	runner.tick(5.0)
	tc.assert_eq(target.position.x, 5.0)
	runner.tick(5.0)
	tc.assert_eq(target.position.x, 10.0)
	stage.queue_free()


static func test_rotation_track_applied_in_radians(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var target := Node3D.new()
	stage.add_child(target)
	var data := _timeline_from({
		"tracks": [{
			"type": "transform",
			"target": "spinner",
			"channel": "rotation_deg",
			"keyframes": [
				{"t": 0.0, "value": [0, 0, 0]},
				{"t": 1.0, "value": [0, 180, 0]}
			]
		}]
	})
	runner.load_timeline(data)
	runner.registry().register("spinner", target)

	runner.tick(1.0)
	tc.assert_true(abs(target.rotation.y - PI) < 0.001, "rot.y should be ~PI")
	stage.queue_free()


static func test_event_fires_after_playhead_crosses_time(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var fired: Array = []
	runner.event_fired.connect(func(ev): fired.append(ev))
	var data := _timeline_from({
		"tracks": [
			{"type": "event", "t": 2.0, "action": "despawn", "target": "x"},
			{"type": "event", "t": 5.0, "action": "despawn", "target": "y"}
		]
	})
	runner.load_timeline(data)

	runner.tick(1.0)
	tc.assert_eq(fired.size(), 0)
	runner.tick(1.5)   # playhead now 2.5, first event should fire
	tc.assert_eq(fired.size(), 1)
	tc.assert_eq(fired[0].target, "x")
	runner.tick(3.0)   # playhead 5.5, second event should fire
	tc.assert_eq(fired.size(), 2)
	tc.assert_eq(fired[1].target, "y")
	stage.queue_free()


static func test_seek_resets_event_cursor(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	var fired: Array = []
	runner.event_fired.connect(func(ev): fired.append(ev))
	var data := _timeline_from({
		"tracks": [
			{"type": "event", "t": 2.0, "action": "despawn", "target": "a"},
			{"type": "event", "t": 5.0, "action": "despawn", "target": "b"}
		]
	})
	runner.load_timeline(data)
	runner.tick(6.0)
	tc.assert_eq(fired.size(), 2)

	# Rewind before 'b' and tick forward — 'b' should fire again, 'a' should not.
	runner.seek(4.0)
	fired.clear()
	runner.tick(2.0)  # playhead 6.0, past 'b' but not past 'a'
	tc.assert_eq(fired.size(), 1)
	tc.assert_eq(fired[0].target, "b")
	stage.queue_free()


static func test_effective_duration_declared_wins_when_longer(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var data := _timeline_from({"media": {"video": "x.mp4", "duration": 60.0}})
	runner.load_timeline(data)
	runner.set_video_duration(30.0)
	tc.assert_eq(runner.effective_duration(), 60.0)
	stage.queue_free()


static func test_effective_duration_video_wins_when_longer(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var data := _timeline_from({"media": {"video": "x.mp4", "duration": 30.0}})
	runner.load_timeline(data)
	runner.set_video_duration(120.0)
	tc.assert_eq(runner.effective_duration(), 120.0)
	stage.queue_free()


static func test_effective_duration_video_when_undeclared(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	# Script has no media.duration — timeline.duration() returns 0.
	var data := _timeline_from({"media": {"video": "x.mp4"}})
	runner.load_timeline(data)
	runner.set_video_duration(45.5)
	tc.assert_eq(runner.effective_duration(), 45.5)
	stage.queue_free()


static func test_shader_param_track_applied(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]

	# Set up a MeshInstance3D with a ShaderMaterial that has a scalar uniform.
	var mi := MeshInstance3D.new()
	mi.mesh = QuadMesh.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform float glow = 0.0; void fragment() { ALBEDO = vec3(glow); }"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mi.material_override = mat
	stage.add_child(mi)

	var data := _timeline_from({
		"tracks": [{
			"type": "shader_param",
			"target": "screen.surface",
			"param": "glow",
			"keyframes": [
				{"t": 0.0, "value": 0.0},
				{"t": 1.0, "value": 1.0}
			]
		}]
	})
	runner.load_timeline(data)
	runner.registry().register("screen", mi)

	runner.tick(0.5)
	tc.assert_true(abs(mat.get_shader_parameter("glow") - 0.5) < 0.001, "glow should be ~0.5")
	stage.queue_free()
