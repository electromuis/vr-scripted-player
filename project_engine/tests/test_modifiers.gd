extends RefCounted

## Object modifiers (opacity / tint / flash / speed) and reactive motion
## (spin / pulse): the shared Modifiers helper and the runner's use of it.

const Modifiers := preload("res://player/runtime/modifiers.gd")
const MESH_PATH := "res://__test_mesh.tscn"

static var _lookup := func(n: Node) -> Dictionary: return n.get_meta("_vj_mods", {})


static func _group_with_mesh() -> Array:
	var group := Node3D.new()
	var mesh := MeshInstance3D.new()
	group.add_child(mesh)
	return [group, mesh]


static func test_opacity_combines_down_the_tree_and_restores(tc: TestCase) -> void:
	var pair := _group_with_mesh()
	var group: Node3D = pair[0]
	var mesh: MeshInstance3D = pair[1]
	mesh.transparency = 0.2  # the prefab's own value
	group.set_meta("_vj_mods", {"opacity": 0.5})
	mesh.set_meta("_vj_mods", {"opacity": 0.5})
	Modifiers.refresh(group, _lookup)
	tc.assert_true(is_equal_approx(mesh.transparency, 1.0 - 0.8 * 0.25), "own 0.8 × 0.5 × 0.5")
	Modifiers.restore(group)
	tc.assert_true(is_equal_approx(mesh.transparency, 0.2), "own value back")
	group.free()


static func test_untouched_nodes_keep_their_values(tc: TestCase) -> void:
	var pair := _group_with_mesh()
	var mesh: MeshInstance3D = pair[1]
	mesh.transparency = 0.3
	var overlay := StandardMaterial3D.new()
	mesh.material_overlay = overlay
	Modifiers.refresh(pair[0], _lookup)
	tc.assert_true(is_equal_approx(mesh.transparency, 0.3), "own transparency kept")
	tc.assert_eq(mesh.material_overlay, overlay)
	pair[0].free()


static func test_tint_and_flash_use_an_overlay(tc: TestCase) -> void:
	var pair := _group_with_mesh()
	var group: Node3D = pair[0]
	var mesh: MeshInstance3D = pair[1]
	group.set_meta("_vj_mods", {"tint": Color(1, 0.5, 0.5), "flash": Color(1, 1, 1, 0.5)})
	Modifiers.refresh(group, _lookup)
	var mul := mesh.material_overlay as StandardMaterial3D
	tc.assert_true(mul != null, "overlay set")
	tc.assert_eq(mul.blend_mode, BaseMaterial3D.BLEND_MODE_MUL)
	tc.assert_eq(mul.albedo_color, Color(1, 0.5, 0.5))
	tc.assert_eq((mul.next_pass as StandardMaterial3D).albedo_color, Color(0.5, 0.5, 0.5))
	group.set_meta("_vj_mods", {"tint": Color.WHITE})
	Modifiers.refresh(group, _lookup)
	tc.assert_eq(mesh.material_overlay, null, "neutral values drop the overlay")
	group.free()


static func test_speed_scales_particles_and_players(tc: TestCase) -> void:
	var group := Node3D.new()
	var particles := CPUParticles3D.new()
	particles.speed_scale = 2.0
	var player := AnimationPlayer.new()
	group.add_child(particles)
	group.add_child(player)
	group.set_meta("_vj_mods", {"speed": 0.5})
	Modifiers.refresh(group, _lookup)
	tc.assert_eq(particles.speed_scale, 1.0)
	tc.assert_eq(player.speed_scale, 0.5)
	group.free()


static func test_spin_angle_integrates_an_animated_spin(tc: TestCase) -> void:
	# 0 → 90 deg/s over 0..2 s: 90 degrees turned by t = 2.
	var spin_at := func(t: float) -> Vector3: return Vector3(0, 45.0 * minf(t, 2.0), 0)
	var angle := Modifiers.spin_angle({}, spin_at, 2.0)
	tc.assert_true(absf(angle.y - 90.0) < 0.01, "integral %s" % angle.y)
	# Small steps forward carry on from the last value.
	var state := {}
	Modifiers.spin_angle(state, spin_at, 1.0)
	angle = Modifiers.spin_angle(state, spin_at, 1.1)
	tc.assert_true(absf(angle.y - (22.5 + 45.0 * 1.05 * 0.1)) < 0.01, "step %s" % angle.y)


static func _runner(tracks: Array) -> Array:
	var stage := Node3D.new()
	var runner := ScriptRunner.new()
	runner.live_reload = false
	stage.add_child(runner)
	runner._stage = stage
	runner._registry = ObjectRegistry.new()
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	var mesh_scene := PackedScene.new()
	var root := MeshInstance3D.new()
	mesh_scene.pack(root)
	root.free()
	runner._prefabs._cache[MESH_PATH] = mesh_scene
	var data := TimelineData.new()
	data.media = {"video": "x.mp4", "duration": 100.0}
	data.prefabs = {"m": MESH_PATH}
	data.tracks = tracks
	data.script_path = "<memory>"
	runner.load_timeline(data)
	return [runner, stage]


static func test_runner_applies_modifier_config_and_tracks(tc: TestCase) -> void:
	var pair := _runner([
		{"type": "event", "t": 0, "action": "spawn", "id": "obj", "prefab": "m",
				"config": {"modifiers": {"opacity": 0.5, "flash": [1, 1, 1, 0]}}},
		{"type": "shader_param", "target": "obj.modifiers", "param": "opacity",
				"keyframes": [{"t": 1.0, "value": 0.5}, {"t": 3.0, "value": 0.0}]},
	])
	var runner: ScriptRunner = pair[0]
	runner.tick(0.0)
	var node := runner.registry().get_node_by_id("obj") as MeshInstance3D
	tc.assert_true(is_equal_approx(node.transparency, 0.5), "config opacity")
	tc.assert_eq(node.material_overlay, null, "zero-strength flash adds no overlay")
	runner.seek(2.0)
	tc.assert_true(is_equal_approx(node.transparency, 0.75), "track opacity 0.25")
	pair[1].free()


static func test_runner_spin_follows_playhead_under_transform_tracks(tc: TestCase) -> void:
	var pair := _runner([
		{"type": "event", "t": 0, "action": "spawn", "id": "obj", "prefab": "m",
				"config": {"reactive": {"spin": [0, 90, 0]}}},
		{"type": "transform", "target": "obj", "channel": "position",
				"keyframes": [{"t": 0.0, "value": [0, 0, 0]}, {"t": 10.0, "value": [10, 0, 0]}]},
	])
	var runner: ScriptRunner = pair[0]
	runner.tick(0.0)
	var node := runner.registry().get_node_by_id("obj")
	for i in 30:
		runner.tick(1.0 / 30.0)
	# 1 s at 90 deg/s: a quarter turn, not compounded frame over frame.
	tc.assert_true(node.basis.z.distance_to(Vector3(1, 0, 0)) < 0.01, "quarter turn, got %s" % node.basis.z)
	tc.assert_true(absf(node.position.x - 1.0) < 0.001, "position track still applies")
	runner.seek(3.0)  # a jump: integrated from 0
	tc.assert_true(node.basis.z.distance_to(Vector3(-1, 0, 0)) < 0.01, "270 degrees at 3 s, got %s" % node.basis.z)
	pair[1].free()
