class_name TimelineData
extends Resource

var format_version: int = 1
var meta: Dictionary = {}
var media: Dictionary = {}
var prefabs: Dictionary = {}
var shaders: Dictionary = {}
var objects: Array = []
var tracks: Array = []
## The script's camera block: {"effects": [{shader, params, strength, enabled}]}.
var camera: Dictionary = {}

var script_path: String = ""
var base_dir: String = ""
## True for timelines the player built itself (e.g. a plain video file);
## script_path then points at the media, not at a watchable .json.
var synthetic: bool = false


func title() -> String:
	return String(meta.get("title", script_path.get_file()))


func duration() -> float:
	return float(media.get("duration", 0.0))


func continuous_tracks() -> Array:
	var out: Array = []
	for t in tracks:
		var tt = t.get("type", "")
		if tt == "transform" or tt == "shader_param":
			out.append(t)
	return out


## Events by time; ones at the same time keep their file order, so a
## group's spawn listed before its children's also fires first.
func events_sorted() -> Array:
	var keyed: Array = []  # [t, file index, event]
	for i in tracks.size():
		if tracks[i].get("type", "") == "event":
			keyed.append([float(tracks[i].get("t", 0.0)), i, tracks[i]])
	keyed.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return keyed.map(func(k): return k[2])


func resolve(rel_path: String) -> String:
	if rel_path.begins_with("res://") or rel_path.begins_with("user://") or rel_path.begins_with(CameraFxShaders.BUILTIN_PREFIX):
		return rel_path
	if rel_path.is_absolute_path():
		return rel_path
	if base_dir == "":
		return rel_path
	return base_dir.path_join(rel_path)


func resolve_prefab(prefab_key: String) -> String:
	var rel = prefabs.get(prefab_key, "")
	if rel == "":
		return ""
	return resolve(rel)


func resolve_shader(shader_key: String) -> String:
	var rel = shaders.get(shader_key, "")
	if rel == "":
		return ""
	return resolve(rel)
