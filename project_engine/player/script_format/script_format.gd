class_name ScriptFormat
extends RefCounted

## Parser and validator for the VJ script JSON format (see docs/script_format.md,
## and Scripted VJ Video Player — Project Plan.md → "Script Format").
##
## Returns `{"ok": bool, "data"?: TimelineData, "error"?: String, "errors"?: Array[String]}`.
## Multiple errors are surfaced so authors don't have to fix-then-re-run repeatedly.

## What exporters write. Older versions still load (see _upgrade).
const SUPPORTED_VERSION := 2
const MIN_VERSION := 1

const TRACK_TRANSFORM := "transform"
const TRACK_SHADER_PARAM := "shader_param"
const TRACK_EVENT := "event"
const VALID_TRACK_TYPES := [TRACK_TRANSFORM, TRACK_SHADER_PARAM, TRACK_EVENT]

const TRANSFORM_CHANNELS := ["position", "rotation_deg", "scale"]

const EVENT_ACTIONS := ["spawn", "despawn", "vr_cut", "vr_teleport"]

const INTERP_MODES := ["linear", "cubic", "step", "ease", "bezier"]


static func load_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _err("File not found: %s" % path)
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return _err("File is empty or unreadable: %s" % path)
	return load_from_string(text, path)


static func load_from_string(text: String, source_path: String = "<memory>") -> Dictionary:
	var parsed = JSON.parse_string(text)
	if parsed == null:
		return _err("Invalid JSON in %s" % source_path)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _err("Top-level JSON must be an object (in %s)" % source_path)

	var errors: Array = []
	_validate(parsed, errors)
	if errors.size() > 0:
		return {"ok": false, "error": errors[0], "errors": errors}

	_upgrade(parsed)
	var data := TimelineData.new()
	data.format_version = int(parsed.get("format_version", 1))
	data.meta = parsed.get("meta", {})
	data.media = parsed.get("media", {})
	data.prefabs = parsed.get("prefabs", {})
	data.shaders = parsed.get("shaders", {})
	data.objects = parsed.get("objects", [])
	data.tracks = parsed.get("tracks", [])
	data.script_path = source_path
	data.base_dir = source_path.get_base_dir() if source_path != "<memory>" else ""

	return {"ok": true, "data": data}


# ---------- validation ----------

static func _validate(root: Dictionary, errors: Array) -> void:
	if not root.has("format_version"):
		errors.append("Missing required field: format_version")
	else:
		var v = root["format_version"]
		if typeof(v) not in [TYPE_INT, TYPE_FLOAT] or int(v) < MIN_VERSION or int(v) > SUPPORTED_VERSION:
			errors.append("format_version must be %d to %d (got %s)" % [MIN_VERSION, SUPPORTED_VERSION, v])

	_validate_media(root.get("media"), errors)
	_validate_string_map(root.get("prefabs", {}), "prefabs", errors)
	_validate_string_map(root.get("shaders", {}), "shaders", errors)
	_validate_objects(root.get("objects", []), errors)
	_validate_tracks(root.get("tracks", []), errors)


static func _validate_media(media, errors: Array) -> void:
	if media == null:
		errors.append("Missing required field: media")
		return
	if typeof(media) != TYPE_DICTIONARY:
		errors.append("'media' must be an object")
		return
	if not media.has("video") or typeof(media["video"]) != TYPE_STRING or String(media["video"]).is_empty():
		errors.append("media.video must be a non-empty string (relative path)")
	if media.has("audio") and media["audio"] != null and typeof(media["audio"]) != TYPE_STRING:
		errors.append("media.audio must be a string or null")
	if media.has("duration"):
		if typeof(media["duration"]) not in [TYPE_INT, TYPE_FLOAT]:
			errors.append("media.duration must be a number")
		elif float(media["duration"]) <= 0.0:
			errors.append("media.duration must be > 0")


static func _validate_string_map(m, name: String, errors: Array) -> void:
	if typeof(m) != TYPE_DICTIONARY:
		errors.append("'%s' must be an object mapping name → relative path" % name)
		return
	for k in m.keys():
		if typeof(m[k]) != TYPE_STRING or String(m[k]).is_empty():
			errors.append("%s['%s'] must be a non-empty string" % [name, k])


static func _validate_objects(objs, errors: Array) -> void:
	if typeof(objs) != TYPE_ARRAY:
		errors.append("'objects' must be an array")
		return
	var seen_ids: Dictionary = {}
	for i in objs.size():
		var o = objs[i]
		var loc := "objects[%d]" % i
		if typeof(o) != TYPE_DICTIONARY:
			errors.append("%s must be an object" % loc)
			continue
		var id = o.get("id")
		if typeof(id) != TYPE_STRING or String(id).is_empty():
			errors.append("%s.id must be a non-empty string" % loc)
		elif seen_ids.has(id):
			errors.append("%s.id '%s' is duplicated" % [loc, id])
		else:
			seen_ids[id] = true
		if not o.has("prefab") or typeof(o["prefab"]) != TYPE_STRING:
			errors.append("%s.prefab must be a string (a prefabs[] key)" % loc)
		if o.has("spawn_at") and typeof(o["spawn_at"]) not in [TYPE_INT, TYPE_FLOAT]:
			errors.append("%s.spawn_at must be a number" % loc)
		if o.has("despawn_at") and o["despawn_at"] != null and typeof(o["despawn_at"]) not in [TYPE_INT, TYPE_FLOAT]:
			errors.append("%s.despawn_at must be a number or null" % loc)


static func _validate_tracks(tracks, errors: Array) -> void:
	if typeof(tracks) != TYPE_ARRAY:
		errors.append("'tracks' must be an array")
		return
	for i in tracks.size():
		var t = tracks[i]
		var loc := "tracks[%d]" % i
		if typeof(t) != TYPE_DICTIONARY:
			errors.append("%s must be an object" % loc)
			continue
		var tt = t.get("type")
		if typeof(tt) != TYPE_STRING:
			errors.append("%s.type must be a string" % loc)
			continue
		if not VALID_TRACK_TYPES.has(tt):
			errors.append("%s.type '%s' is not one of %s" % [loc, tt, VALID_TRACK_TYPES])
			continue
		match tt:
			TRACK_TRANSFORM: _validate_transform_track(t, loc, errors)
			TRACK_SHADER_PARAM: _validate_shader_param_track(t, loc, errors)
			TRACK_EVENT: _validate_event(t, loc, errors)


static func _validate_transform_track(t: Dictionary, loc: String, errors: Array) -> void:
	if typeof(t.get("target")) != TYPE_STRING:
		errors.append("%s.target must be a string (an object id)" % loc)
	var ch = t.get("channel")
	if typeof(ch) != TYPE_STRING or not TRANSFORM_CHANNELS.has(ch):
		errors.append("%s.channel must be one of %s" % [loc, TRANSFORM_CHANNELS])
	_validate_keyframes(t.get("keyframes"), loc, 3, errors)


static func _validate_shader_param_track(t: Dictionary, loc: String, errors: Array) -> void:
	if typeof(t.get("target")) != TYPE_STRING:
		errors.append("%s.target must be a string (e.g. 'main_screen.surface')" % loc)
	if typeof(t.get("param")) != TYPE_STRING:
		errors.append("%s.param must be a string" % loc)
	_validate_keyframes(t.get("keyframes"), loc, -1, errors)


static func _validate_keyframes(kfs, loc: String, expected_len: int, errors: Array) -> void:
	if typeof(kfs) != TYPE_ARRAY or kfs.size() == 0:
		errors.append("%s.keyframes must be a non-empty array" % loc)
		return
	var last_t := -INF
	for i in kfs.size():
		var kf = kfs[i]
		var kloc := "%s.keyframes[%d]" % [loc, i]
		if typeof(kf) != TYPE_DICTIONARY:
			errors.append("%s must be an object" % kloc)
			continue
		var tv = kf.get("t")
		if typeof(tv) not in [TYPE_INT, TYPE_FLOAT]:
			errors.append("%s.t must be a number" % kloc)
		else:
			if float(tv) < last_t:
				errors.append("%s.t (%s) must be >= previous t (%s)" % [kloc, tv, last_t])
			last_t = float(tv)
		if not kf.has("value"):
			errors.append("%s.value is required" % kloc)
		elif expected_len > 0:
			var val = kf["value"]
			if typeof(val) != TYPE_ARRAY or val.size() != expected_len:
				errors.append("%s.value must be an array of %d numbers" % [kloc, expected_len])
		if kf.has("interp"):
			if not INTERP_MODES.has(kf["interp"]):
				errors.append("%s.interp must be one of %s" % [kloc, INTERP_MODES])
		for h in ["in", "out"]:
			if kf.has(h) and not _valid_handles(kf[h], kf.get("value")):
				errors.append("%s.%s must be a [dt, dv] pair (one per element for array values)" % [kloc, h])


## A bezier handle: [dt, dv], or one such pair per element of an array value.
static func _valid_handles(h, value) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return _is_pair(h)
	if typeof(h) != TYPE_ARRAY or h.size() != value.size():
		return false
	for pair in h:
		if not _is_pair(pair):
			return false
	return true


static func _is_pair(h) -> bool:
	return typeof(h) == TYPE_ARRAY and h.size() == 2 \
			and typeof(h[0]) in [TYPE_INT, TYPE_FLOAT] and typeof(h[1]) in [TYPE_INT, TYPE_FLOAT]


# ---------- upgrades ----------

## Brings an older (already validated) script up to the current meaning,
## in place. v1's "cubic" was a per-segment smoothstep, which v2 calls
## "ease" ("cubic" now runs through the keys like Godot's), so v1 scripts
## keep moving the way they always did.
static func _upgrade(root: Dictionary) -> void:
	if int(root.get("format_version", SUPPORTED_VERSION)) >= 2:
		return
	for track in root.get("tracks", []):
		for kf in track.get("keyframes", []):
			if typeof(kf) == TYPE_DICTIONARY and kf.get("interp") == "cubic":
				kf["interp"] = "ease"


static func _validate_event(e: Dictionary, loc: String, errors: Array) -> void:
	if typeof(e.get("t")) not in [TYPE_INT, TYPE_FLOAT]:
		errors.append("%s.t must be a number" % loc)
	var action = e.get("action")
	if typeof(action) != TYPE_STRING or not EVENT_ACTIONS.has(action):
		errors.append("%s.action must be one of %s" % [loc, EVENT_ACTIONS])
		return
	match action:
		"spawn":
			if typeof(e.get("id")) != TYPE_STRING:
				errors.append("%s.id required for spawn" % loc)
			if typeof(e.get("prefab")) != TYPE_STRING:
				errors.append("%s.prefab required for spawn" % loc)
			if e.has("parent") and (typeof(e["parent"]) != TYPE_STRING or e["parent"] == e.get("id")):
				errors.append("%s.parent must be another object's id" % loc)
			if e.has("config"):
				_validate_config(e["config"], loc + ".config", errors)
		"despawn":
			if typeof(e.get("target")) != TYPE_STRING:
				errors.append("%s.target required for despawn" % loc)
		"vr_cut", "vr_teleport":
			if typeof(e.get("to")) != TYPE_DICTIONARY:
				errors.append("%s.to must be an object with position/rotation_deg" % loc)


static func _validate_config(cfg, loc: String, errors: Array) -> void:
	if typeof(cfg) != TYPE_DICTIONARY:
		errors.append("%s must be an object" % loc)
		return
	for k in ["opacity", "curvature", "vertical_curvature", "render_scale", "resolution"]:
		if cfg.has(k) and typeof(cfg[k]) not in [TYPE_INT, TYPE_FLOAT]:
			errors.append("%s.%s must be a number" % [loc, k])
	for k in ["modifiers", "reactive"]:
		if cfg.has(k) and typeof(cfg[k]) != TYPE_DICTIONARY:
			errors.append("%s.%s must be an object" % [loc, k])
	if not cfg.has("effects"):
		return
	var effects = cfg["effects"]
	if typeof(effects) != TYPE_ARRAY:
		errors.append("%s.effects must be an array" % loc)
		return
	for i in effects.size():
		var e = effects[i]
		if typeof(e) != TYPE_DICTIONARY or typeof(e.get("shader")) != TYPE_STRING:
			errors.append("%s.effects[%d] must be an object with a shader (a shaders[] key)" % [loc, i])
		elif e.has("params") and typeof(e["params"]) != TYPE_DICTIONARY:
			errors.append("%s.effects[%d].params must be an object" % [loc, i])
		elif e.has("enabled") and typeof(e["enabled"]) != TYPE_BOOL:
			errors.append("%s.effects[%d].enabled must be true or false" % [loc, i])


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "errors": [msg]}
