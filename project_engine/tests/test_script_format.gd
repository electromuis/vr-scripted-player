extends RefCounted

## Tests for player/script_format/script_format.gd.
## Discovered and run by tests/run.gd — every `func test_*` runs as a case.

const MINIMAL := """
{
  "format_version": 1,
  "media": { "video": "video.mp4", "duration": 30.0 }
}
"""


static func test_minimal_valid(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string(MINIMAL)
	tc.assert_ok(r)
	var data: TimelineData = r.data
	tc.assert_eq(data.format_version, 1)
	tc.assert_eq(data.media.get("video"), "video.mp4")


static func test_missing_format_version(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string('{"media":{"video":"x.mp4"}}')
	tc.assert_err(r, "format_version")


static func test_wrong_format_version(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string('{"format_version":99,"media":{"video":"x.mp4"}}')
	tc.assert_err(r, "format_version")


static func test_missing_media(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string('{"format_version":1}')
	tc.assert_err(r, "media")


static func test_missing_video(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string('{"format_version":1,"media":{}}')
	tc.assert_err(r, "media.video")


static func test_invalid_json(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_string('this is not json')
	tc.assert_err(r, "Invalid JSON")


static func test_bad_track_type(tc: TestCase) -> void:
	var s := '{"format_version":1,"media":{"video":"x.mp4"},"tracks":[{"type":"nonsense"}]}'
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "not one of")


static func test_transform_track_valid(tc: TestCase) -> void:
	var s := """
	{ "format_version": 1, "media": {"video":"x.mp4"},
	  "tracks": [
		{ "type": "transform", "target": "screen", "channel": "position",
		  "keyframes": [ {"t":0.0,"value":[0,0,0]}, {"t":1.0,"value":[1,2,3]} ] }
	  ] }
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_ok(r)


static func test_transform_track_bad_channel(tc: TestCase) -> void:
	var s := """
	{ "format_version": 1, "media":{"video":"x.mp4"},
	  "tracks":[{"type":"transform","target":"s","channel":"nonsense",
		"keyframes":[{"t":0.0,"value":[0,0,0]}]}]}
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "channel")


static func test_transform_track_wrong_vector_length(tc: TestCase) -> void:
	var s := """
	{ "format_version": 1, "media":{"video":"x.mp4"},
	  "tracks":[{"type":"transform","target":"s","channel":"position",
		"keyframes":[{"t":0.0,"value":[0,0]}]}]}
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "array of 3 numbers")


static func test_keyframes_must_be_ordered(tc: TestCase) -> void:
	var s := """
	{ "format_version":1, "media":{"video":"x.mp4"},
	  "tracks":[{"type":"transform","target":"s","channel":"position",
		"keyframes":[{"t":1.0,"value":[0,0,0]},{"t":0.0,"value":[1,1,1]}]}]}
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "must be >= previous")


static func test_event_spawn_requires_id_and_prefab(tc: TestCase) -> void:
	var s := '{"format_version":1,"media":{"video":"x.mp4"},"tracks":[{"type":"event","t":1.0,"action":"spawn"}]}'
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "spawn")


static func test_event_vr_cut_requires_to(tc: TestCase) -> void:
	var s := '{"format_version":1,"media":{"video":"x.mp4"},"tracks":[{"type":"event","t":1.0,"action":"vr_cut"}]}'
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "to")


static func test_event_vr_cut_valid(tc: TestCase) -> void:
	var s := """
	{ "format_version":1, "media":{"video":"x.mp4"},
	  "tracks":[{"type":"event","t":10.0,"action":"vr_cut",
		"to":{"position":[0,1.6,-5],"rotation_deg":[0,180,0]},
		"transition":{"type":"fade_to_black","duration":0.5}}]}
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_ok(r)


static func test_duplicate_object_ids(tc: TestCase) -> void:
	var s := """
	{ "format_version":1, "media":{"video":"x.mp4"},
	  "objects":[{"id":"a","prefab":"p"},{"id":"a","prefab":"p"}] }
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_err(r, "duplicated")


## Example scripts live in the repo's scripts/ folder, next to project_engine.
static func _example(rel: String) -> String:
	return ProjectSettings.globalize_path("res://../scripts").simplify_path().path_join(rel)


static func test_example_scripts_parse(tc: TestCase) -> void:
	for rel in ["minimal/video.json", "moving_screen/video.json", "forest_tunnel/video.json"]:
		tc.assert_ok(ScriptFormat.load_from_file(_example(rel)), "scripts/%s must parse" % rel)


static func test_forest_tunnel_prefabs_load(tc: TestCase) -> void:
	# Bundled prefabs are loaded from disk by absolute path, not res://.
	var r := ScriptFormat.load_from_file(_example("forest_tunnel/video.json"))
	tc.assert_ok(r)
	if not r.ok:
		return
	var data: TimelineData = r.data
	for key in ["forest", "tunnel", "screen"]:
		var path := data.resolve_prefab(key)
		tc.assert_true(ResourceLoader.load(path) is PackedScene, "prefab '%s' loads from %s" % [key, path])


static func test_forest_tunnel_scene_states(tc: TestCase) -> void:
	# The story's shape, not its timings (they move whenever the scene is
	# re-edited and re-exported): forest on one screen, a split into three
	# screens in the tunnel, and back to one screen in the forest.
	var r := ScriptFormat.load_from_file(_example("forest_tunnel/video.json"))
	tc.assert_ok(r)
	if not r.ok:
		return
	var events: Array = r.data.events_sorted()
	# The state after every event time, plus the start.
	var times: Array = [0.0]
	for ev in events:
		if not times.has(float(ev.get("t", 0.0))):
			times.append(float(ev.get("t", 0.0)))
	var split_seen := false
	var states: Array = []
	for t in times:
		var ids: Dictionary = ScriptRunner._project_state_at(events, t)
		states.append(ids)
		var at := " at %.1f s" % t
		# Groups that hold the screens stay the whole time.
		tc.assert_true(ids.has("screens") and ids.has("screen_master"), "screen groups exist" + at)
		# `backdrop` lives inside main_screen and goes with it.
		tc.assert_eq(ids.has("backdrop"), ids.has("main_screen"), "backdrop follows main_screen" + at)
		# One screen or the three columns, never both, and the columns together.
		var columns: int = int(ids.has("screen_left")) + int(ids.has("screen_center")) + int(ids.has("screen_right"))
		tc.assert_true(columns == 0 or columns == 3, "all three columns or none" + at)
		tc.assert_true(ids.has("main_screen") != (columns == 3), "main_screen xor the columns" + at)
		# `rings` live inside the split screens' group and only show while split.
		if ids.has("rings"):
			tc.assert_eq(columns, 3, "rings only while split" + at)
		if columns == 3:
			split_seen = true
			tc.assert_true(ids.has("tunnel") or not ids.has("forest"), "split happens away from the forest" + at)
	tc.assert_true(split_seen, "the screen splits into three at some point")
	tc.assert_true(states.front().has("forest") and states.front().has("main_screen"), "starts in the forest on one screen")
	tc.assert_true(states.back().has("forest") and states.back().has("main_screen"), "ends in the forest on one screen")


static func test_timeline_helpers(tc: TestCase) -> void:
	var s := """
	{ "format_version":1, "media":{"video":"x.mp4","duration":42.5},
	  "meta":{"title":"Hello"},
	  "tracks":[
		{"type":"event","t":5.0,"action":"despawn","target":"a"},
		{"type":"event","t":1.0,"action":"despawn","target":"b"},
		{"type":"transform","target":"s","channel":"position",
			"keyframes":[{"t":0.0,"value":[0,0,0]}]}
	  ] }
	"""
	var r := ScriptFormat.load_from_string(s)
	tc.assert_ok(r)
	var data: TimelineData = r.data
	tc.assert_eq(data.title(), "Hello")
	tc.assert_eq(data.duration(), 42.5)
	tc.assert_eq(data.continuous_tracks().size(), 1)
	var events := data.events_sorted()
	tc.assert_eq(events.size(), 2)
	tc.assert_eq(events[0].t, 1.0)
	tc.assert_eq(events[1].t, 5.0)


static func test_resolve_relative_and_absolute(tc: TestCase) -> void:
	var data := TimelineData.new()
	data.base_dir = "res://examples/minimal"
	tc.assert_eq(data.resolve("video.mp4"), "res://examples/minimal/video.mp4")
	tc.assert_eq(data.resolve("res://foo.mp4"), "res://foo.mp4")
