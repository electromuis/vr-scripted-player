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


static func test_minimal_example_file_parses(tc: TestCase) -> void:
	var r := ScriptFormat.load_from_file("res://examples/minimal/script.json")
	tc.assert_ok(r, "examples/minimal/script.json must parse")


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
