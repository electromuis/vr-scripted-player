class_name TimelineData
extends Resource

var format_version: int = 1
var meta: Dictionary = {}
var media: Dictionary = {}
var prefabs: Dictionary = {}
var shaders: Dictionary = {}
var objects: Array = []
var tracks: Array = []

var script_path: String = ""
var base_dir: String = ""


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


func events_sorted() -> Array:
	var out: Array = []
	for t in tracks:
		if t.get("type", "") == "event":
			out.append(t)
	out.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	return out


func resolve(rel_path: String) -> String:
	if rel_path.begins_with("res://") or rel_path.begins_with("user://"):
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
