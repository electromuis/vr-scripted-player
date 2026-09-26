extends RefCounted

## Spawn `parent` (groups), config resolution for effects / layers, and
## respawning objects whose spawn event changed.

const RunnerScript := preload("res://player/runtime/script_runner.gd")
const STUB_PATH := "res://__test_stub.tscn"
const CONFIGURABLE_PATH := "res://__test_configurable.tscn"


static func _make_runner() -> Array:
	var stage := Node3D.new()
	stage.name = "Stage"
	var runner := ScriptRunner.new()
	runner.name = "ScriptRunner"
	runner.live_reload = false
	stage.add_child(runner)
	runner._stage = stage
	runner._registry = ObjectRegistry.new()
	runner._registry.name = "ObjectRegistry"
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	# Pre-seed the prefab cache so no files are needed.
	runner._prefabs._cache[STUB_PATH] = _pack(Node3D.new())
	runner._prefabs._cache[CONFIGURABLE_PATH] = _pack(_configurable_node())
	return [runner, stage]


static func _pack(node: Node) -> PackedScene:
	var scene := PackedScene.new()
	scene.pack(node)
	node.free()
	return scene


## A Node3D whose configure(cfg, mat) keeps what it was given.
static func _configurable_node() -> Node3D:
	var gd := GDScript.new()
	gd.source_code = "extends Node3D\nvar got_cfg = null\nfunc configure(cfg, _mat):\n\tgot_cfg = cfg\n"
	gd.reload()
	var node := Node3D.new()
	node.set_script(gd)
	return node


static func _timeline(tracks: Array, shaders: Dictionary = {}) -> TimelineData:
	var data := TimelineData.new()
	data.format_version = 1
	data.media = {"video": "x.mp4", "duration": 100.0}
	data.prefabs = {"stub": STUB_PATH, "conf": CONFIGURABLE_PATH}
	data.shaders = shaders
	data.tracks = tracks
	data.script_path = "<memory>"
	return data


static func _spawn(t: float, id: String, parent: String = "", extra: Dictionary = {}) -> Dictionary:
	var ev := {"type": "event", "t": t, "action": "spawn", "id": id, "prefab": "stub",
			"transform": {"position": [1, 2, 3]}}
	if parent != "":
		ev["parent"] = parent
	ev.merge(extra, true)
	return ev


static func test_project_state_despawn_takes_children(tc: TestCase) -> void:
	var events := [
		{"t": 1.0, "action": "spawn", "id": "group", "prefab": "p"},
		{"t": 1.0, "action": "spawn", "id": "a", "prefab": "p", "parent": "group"},
		{"t": 1.0, "action": "spawn", "id": "b", "prefab": "p", "parent": "a"},
		{"t": 1.0, "action": "spawn", "id": "other", "prefab": "p"},
		{"t": 5.0, "action": "despawn", "target": "group"},
	]
	var state := RunnerScript._project_state_at(events, 6.0)
	tc.assert_eq(state.keys(), ["other"])


static func test_project_state_respawn_drops_children(tc: TestCase) -> void:
	var events := [
		{"t": 1.0, "action": "spawn", "id": "group", "prefab": "p"},
		{"t": 1.0, "action": "spawn", "id": "a", "prefab": "p", "parent": "group"},
		{"t": 5.0, "action": "spawn", "id": "group", "prefab": "p"},
	]
	var state := RunnerScript._project_state_at(events, 6.0)
	tc.assert_eq(state.keys(), ["group"])


static func test_same_time_events_keep_file_order(tc: TestCase) -> void:
	var tracks: Array = []
	for i in 20:
		tracks.append({"type": "event", "t": 1.0, "action": "spawn", "id": "o%d" % i, "prefab": "p"})
	var ids := _timeline(tracks).events_sorted().map(func(e): return e.id)
	tc.assert_eq(ids, tracks.map(func(e): return e.id))


static func test_child_spawns_under_parent_in_its_space(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	runner.load_timeline(_timeline([_spawn(0.0, "group"), _spawn(0.0, "child", "group")]))
	runner.tick(0.0)
	var group := runner.registry().get_node_by_id("group")
	var child := runner.registry().get_node_by_id("child")
	tc.assert_true(group != null and child != null, "both spawned")
	tc.assert_eq(child.get_parent(), group)
	tc.assert_eq(child.position, Vector3(1, 2, 3))
	stage.free()


static func test_missing_parent_skips_spawn(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	runner.load_timeline(_timeline([_spawn(0.0, "child", "nobody")]))
	runner.tick(0.0)
	tc.assert_false(runner.registry().has_id("child"))
	stage.free()


static func test_despawning_parent_forgets_children(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	runner.load_timeline(_timeline([
		_spawn(0.0, "group"), _spawn(0.0, "child", "group"),
		{"type": "event", "t": 2.0, "action": "despawn", "target": "group"},
	]))
	runner.tick(0.0)
	tc.assert_true(runner.registry().has_id("child"))
	runner.tick(3.0)
	tc.assert_false(runner.registry().has_id("group"))
	tc.assert_false(runner.registry().has_id("child"), "child goes with its group")
	stage.free()


static func test_seek_spawns_parents_first(tc: TestCase) -> void:
	# The child's spawn is listed first; seeking must still build the group
	# before putting the child in it.
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	runner.load_timeline(_timeline([_spawn(1.0, "child", "group"), _spawn(1.0, "group")]))
	runner.seek(5.0)
	var child := runner.registry().get_node_by_id("child")
	tc.assert_true(child != null, "child spawned")
	if child != null:
		tc.assert_eq(child.get_parent(), runner.registry().get_node_by_id("group"))
	stage.free()


static func test_reload_respawns_changed_objects(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	runner.load_timeline(_timeline([_spawn(0.0, "same"), _spawn(0.0, "moved")]))
	runner.tick(1.0)
	var same := runner.registry().get_node_by_id("same")
	var moved := runner.registry().get_node_by_id("moved")
	var changed := _spawn(0.0, "moved")
	changed.transform = {"position": [9, 9, 9]}
	runner._reconcile_swap(_timeline([_spawn(0.0, "same"), changed]))
	tc.assert_eq(runner.registry().get_node_by_id("same"), same, "unchanged object kept")
	var respawned := runner.registry().get_node_by_id("moved")
	tc.assert_true(respawned != moved, "changed object respawned")
	tc.assert_eq(respawned.position, Vector3(9, 9, 9))
	stage.free()


static func test_config_effect_keys_become_paths(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var ev := _spawn(0.0, "screen", "", {"prefab": "conf", "config": {
		"opacity": 0.5,
		"effects": [
			{"shader": "mask", "params": {"size": 0.4, "center": [0.5, 0.25]}},
			{"shader": "blur"},
		],
	}})
	runner.load_timeline(_timeline([ev], {
		"mask": "res://player/visualizer/effects/oval_mask.gdshader",
		"blur": "shaders/blur.gdshader",
	}))
	runner.timeline.base_dir = "C:/scripts/x"
	runner.tick(0.0)
	var cfg: Dictionary = runner.registry().get_node_by_id("screen").got_cfg
	tc.assert_eq(cfg.opacity, 0.5)
	tc.assert_eq(cfg.effects[0].shader, "res://player/visualizer/effects/oval_mask.gdshader")
	tc.assert_eq(cfg.effects[0].params.center, Vector2(0.5, 0.25))
	tc.assert_eq(cfg.effects[1].shader, "C:/scripts/x/shaders/blur.gdshader")
	tc.assert_eq(cfg.effects[1].params, {})
	stage.free()


static func test_screen_routes_effect_and_display_slots(tc: TestCase) -> void:
	var screen: Screen = load("res://player/prefabs/screen.tscn").instantiate()
	# No scene tree while tests run: run the @onready setup and _ready by hand.
	screen.notification(Node.NOTIFICATION_READY)
	screen.set_source_texture(ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8)))
	screen.configure({"opacity": 0.5, "effects": [
		{"shader": VisualizerShaders.OVAL_MASK, "params": {"size": 0.4}},
	]}, null)
	tc.assert_true(screen.is_scripted("opacity"))
	tc.assert_true(screen.is_scripted("effects"))
	tc.assert_false(screen.is_scripted("vertical_curvature"))
	screen.set_material_param("effect0", "size", 0.9)
	var pass_mat: ShaderMaterial = screen._passes[0].material
	tc.assert_eq(pass_mat.get_shader_parameter("size"), 0.9)
	screen.set_material_param("display", "opacity", 0.25)
	tc.assert_eq(screen._display_material.get_shader_parameter("opacity"), 0.25)
	screen.free()


static func test_validation_of_parent_and_config(tc: TestCase) -> void:
	var base := {"format_version": 1, "media": {"video": "v.mp4"}, "tracks": []}
	var good := base.duplicate(true)
	good.tracks = [{"type": "event", "t": 0, "action": "spawn", "id": "a", "prefab": "p",
			"parent": "g", "config": {"opacity": 1, "effects": [{"shader": "k", "params": {}}]}}]
	tc.assert_true(ScriptFormat.load_from_string(JSON.stringify(good)).ok)
	var self_parent := base.duplicate(true)
	self_parent.tracks = [{"type": "event", "t": 0, "action": "spawn", "id": "a", "prefab": "p", "parent": "a"}]
	tc.assert_false(ScriptFormat.load_from_string(JSON.stringify(self_parent)).ok)
	var bad_effects := base.duplicate(true)
	bad_effects.tracks = [{"type": "event", "t": 0, "action": "spawn", "id": "a", "prefab": "p",
			"config": {"effects": [{"params": {}}]}}]
	tc.assert_false(ScriptFormat.load_from_string(JSON.stringify(bad_effects)).ok)



## A switched-off effect stays in the file for editors but never runs, and
## doesn't count towards effect<N>: the next one is effect0's neighbour.
static func test_disabled_effects_are_skipped(tc: TestCase) -> void:
	var pair := _make_runner()
	var runner: ScriptRunner = pair[0]
	var stage: Node3D = pair[1]
	var ev := _spawn(0.0, "screen", "", {"prefab": "conf", "config": {"effects": [
		{"shader": "mask", "enabled": false},
		{"shader": "blur"},
	]}})
	runner.load_timeline(_timeline([ev], {
		"mask": "res://player/visualizer/effects/oval_mask.gdshader",
		"blur": "res://player/visualizer/effects/edge_blur.gdshader",
	}))
	runner.tick(0.0)
	var cfg: Dictionary = runner.registry().get_node_by_id("screen").got_cfg
	tc.assert_eq(cfg.effects.size(), 1)
	tc.assert_eq(cfg.effects[0].shader, "res://player/visualizer/effects/edge_blur.gdshader")
	stage.free()


static func test_effect_enabled_must_be_bool(tc: TestCase) -> void:
	var s := {"format_version": 2, "media": {"video": "v.mp4"}, "tracks": [{"type": "event", "t": 0, "action": "spawn",
			"id": "a", "prefab": "p", "config": {"effects": [{"shader": "k", "enabled": "no"}]}}]}
	tc.assert_err(ScriptFormat.load_from_string(JSON.stringify(s)), "enabled")
	s.tracks[0].config.effects[0].enabled = false
	tc.assert_ok(ScriptFormat.load_from_string(JSON.stringify(s)))
