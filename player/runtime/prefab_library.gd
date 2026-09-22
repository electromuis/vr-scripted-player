class_name PrefabLibrary
extends RefCounted

var _cache: Dictionary = {}


func load_prefab(abs_path: String) -> PackedScene:
	if _cache.has(abs_path):
		return _cache[abs_path]
	if not FileAccess.file_exists(abs_path):
		push_warning("Prefab not found: %s" % abs_path)
		return null
	var scene := ResourceLoader.load(abs_path) as PackedScene
	if scene == null:
		push_warning("Failed to load prefab: %s" % abs_path)
		return null
	_cache[abs_path] = scene
	return scene


func invalidate(abs_path: String) -> void:
	_cache.erase(abs_path)


func clear() -> void:
	_cache.clear()
