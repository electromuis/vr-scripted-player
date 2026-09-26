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


static func test_cut_in_effect_at_the_playhead(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var start := {"type": "event", "t": 0.0, "action": "vr_cut", "to": {"position": [0, 2, 3]}}
	var cut := {"type": "event", "t": 4.0, "action": "vr_cut", "to": {"position": [5, 2, 0]}}
	var tele := {"type": "event", "t": 9.0, "action": "vr_teleport", "to": {"position": [1, 1, 1]}}
	var data := _timeline_from({"tracks": [
		tele,
		{"type": "event", "t": 6.0, "action": "despawn", "target": "a"},
		cut,
		start,
	]})
	runner.load_timeline(data)
	var sorted := data.events_sorted()
	tc.assert_eq(ScriptRunner.cut_at(sorted, 0.0), start, "the t=0 start pose counts at 0")
	tc.assert_eq(ScriptRunner.cut_at(sorted, 3.99), start)
	tc.assert_eq(ScriptRunner.cut_at(sorted, 4.0), cut, "at the cut's own time")
	tc.assert_eq(ScriptRunner.cut_at(sorted, 8.0), cut, "other events don't count")
	tc.assert_eq(ScriptRunner.cut_at(sorted, 20.0), tele)
	tc.assert_eq(ScriptRunner.cut_at(sorted.slice(1), 3.0), {}, "none before the first")
	runner.seek(7.0)
	tc.assert_eq(runner.cut_at_playhead(), cut, "seeking back past the teleport")
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


static func test_shader_value_coerces_arrays(tc: TestCase) -> void:
	tc.assert_eq(ScriptRunner.shader_value([1, 2]), Vector2(1, 2))
	tc.assert_eq(ScriptRunner.shader_value([1, 2, 3]), Vector3(1, 2, 3))
	tc.assert_eq(ScriptRunner.shader_value([1, 2, 3, 4]), Vector4(1, 2, 3, 4))
	tc.assert_eq(ScriptRunner.shader_value(0.5), 0.5)
	tc.assert_eq(ScriptRunner.shader_value([1, 2, 3, 4, 5]), [1, 2, 3, 4, 5])


static func test_shader_param_array_reaches_vec_uniform(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var mi := MeshInstance3D.new()
	mi.mesh = QuadMesh.new()
	var shader := Shader.new()
	shader.code = "shader_type spatial; uniform vec2 uv_offset = vec2(0.0); void fragment() { ALBEDO = vec3(uv_offset, 0.0); }"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mi.material_override = mat
	stage.add_child(mi)
	runner.load_timeline(_timeline_from({
		"tracks": [{
			"type": "shader_param", "target": "col.surface", "param": "uv_offset",
			"keyframes": [{"t": 0.0, "value": [0.0, 0.0]}, {"t": 1.0, "value": [1.0, 0.0]}]
		}]
	}))
	runner.registry().register("col", mi)
	runner.tick(0.5)
	tc.assert_eq(mat.get_shader_parameter("uv_offset"), Vector2(0.5, 0.0))
	stage.queue_free()


static func test_shader_param_routes_by_slot(tc: TestCase) -> void:
	# Prefabs exposing set_material_param() (e.g. Screen) get the slot name,
	# so `<id>.display` and `<id>.surface` can reach different materials.
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var script := GDScript.new()
	script.source_code = "extends Node3D
var calls: Array = []
func set_material_param(slot, param, value):
	calls.append([slot, param, value])
"
	script.reload()
	var node := Node3D.new()
	node.set_script(script)
	stage.add_child(node)
	runner.load_timeline(_timeline_from({
		"tracks": [{
			"type": "shader_param", "target": "scr.display", "param": "curvature",
			"keyframes": [{"t": 0.0, "value": 0.4}]
		}]
	}))
	runner.registry().register("scr", node)
	runner.tick(0.1)
	tc.assert_eq(node.get("calls"), [["display", "curvature", 0.4]])
	stage.queue_free()


static func test_reached_end_fires_once_and_rearms_on_seek(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var ends := [0]
	runner.reached_end.connect(func(): ends[0] += 1)
	runner.load_timeline(_timeline_from({"media": {"video": "x.mp4", "duration": 10.0}}))
	runner.tick(9.0)
	tc.assert_eq(ends[0], 0, "not at the end yet")
	runner.tick(2.0)
	tc.assert_eq(ends[0], 1)
	runner.tick(1.0)
	tc.assert_eq(ends[0], 1, "staying at the end doesn't fire again")
	runner.seek(0.0)
	runner.tick(10.0)
	tc.assert_eq(ends[0], 2, "a seek re-arms it (loop)")
	stage.queue_free()


static func test_reached_end_waits_for_duration(tc: TestCase) -> void:
	var pair := _make_runner_with_stage()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var ends := [0]
	runner.reached_end.connect(func(): ends[0] += 1)
	# No declared duration: 0 until the video reports its length.
	runner.load_timeline(_timeline_from({"media": {"video": "x.mp4"}}))
	runner.seek(0.0)
	runner.tick(0.0)
	tc.assert_eq(ends[0], 0, "unknown length is not an end")
	runner.set_video_duration(5.0)
	runner.tick(6.0)
	tc.assert_eq(ends[0], 1)
	stage.queue_free()


## A spawn transform means what Node3D's rotation / scale do: scale along
## the object's own axes. Rotated 90° about Z and stretched 2× on its X,
## the object is 2 wide along world Y, not world X.
static func test_spawn_transform_scales_along_own_axes(tc: TestCase) -> void:
	var xf := ScriptRunner._read_transform({"position": [1, 2, 3], "rotation_deg": [0, 0, 90], "scale": [2, 1, 1]})
	var node := Node3D.new()
	node.transform = xf
	tc.assert_true(node.scale.is_equal_approx(Vector3(2, 1, 1)), "scale %s" % node.scale)
	tc.assert_true(node.rotation_degrees.is_equal_approx(Vector3(0, 0, 90)), "rotation %s" % node.rotation_degrees)
	tc.assert_true((xf.basis * Vector3.RIGHT).is_equal_approx(Vector3(0, 2, 0)), "own X points up, 2 long: %s" % (xf.basis * Vector3.RIGHT))
	tc.assert_true(xf.origin.is_equal_approx(Vector3(1, 2, 3)))
	node.free()
