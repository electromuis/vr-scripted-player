class_name PresetStore
extends RefCounted

## JSON-file preset store for the F2 floating panel. Each preset is one file
## under `user://presets/preset_N.json`, and reuses the same
## `format_version` convention as the timeline script format so presets are
## versionable/diffable the same way scripts are. Preset 1 is the default
## and is auto-created on first launch; it can't be deleted.
##
## A preset holds the main screen's values (`screen`, including its
## effects), the shader layers' (`layers`: a LayerSettings dict each, in
## stack order) and the camera effect (`camera_fx`, a CameraFxSettings dict;
## absent = none). Presets from before the layer stack had at most a
## `visualizer` block, or `foreground` / `background` ones; those load as
## the equivalent layers.
##
## Preset 0, "Script (defaults)", is built in and locked: never a file, it
## can't be saved over, renamed or deleted. It is the software defaults with
## no effects or layers, and main.gd switches to it while a script plays so
## the piece looks as authored.
##
## Also tracks which preset is active (last applied; shared by the Camera
## and Presets tabs) and which one loads at startup (`startup.cfg`).

const PRESET_DIR := "user://presets"
const FORMAT_VERSION := 1
const KIND := "camera_preset"
const DEFAULT_PRESET_INDEX := 1
const SCRIPT_PRESET_INDEX := 0
const SCRIPT_PRESET_NAME := "Script (defaults)"
const STARTUP_FILE := "startup.cfg"

signal preset_saved(index: int)
## Any preset added, overwritten, renamed or deleted, or the startup one changed.
signal presets_changed
signal active_changed(index: int)

## The preset whose values were last applied or saved; -1 = none yet.
var active_index: int = -1

var _dir: String


## `dir` is overridable so tests don't touch the user's real presets.
func _init(dir: String = PRESET_DIR) -> void:
	_dir = dir


func load_preset(index: int) -> Dictionary:
	if index == SCRIPT_PRESET_INDEX:
		return _script_preset()
	var path := _path_for(index)
	if not FileAccess.file_exists(path):
		if index == DEFAULT_PRESET_INDEX:
			var d := _default_preset()
			_write(index, d)
			return d
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PresetStore: %s is not a JSON object" % path)
		return {}
	return parsed


func save_preset(index: int, name: String, screen_data: Dictionary, layers_data: Array = [], camera_fx_data: Dictionary = {}) -> bool:
	if is_locked(index):
		return false
	var data := {
		"format_version": FORMAT_VERSION,
		"kind": KIND,
		"name": name,
		"screen": screen_data,
	}
	if not layers_data.is_empty():
		data["layers"] = layers_data
	if not camera_fx_data.is_empty():
		data["camera_fx"] = camera_fx_data
	if not _write(index, data):
		return false
	preset_saved.emit(index)
	presets_changed.emit()
	return true


func has_preset(index: int) -> bool:
	return index == SCRIPT_PRESET_INDEX or FileAccess.file_exists(_path_for(index))


## Built in: can't be saved over, renamed or deleted.
static func is_locked(index: int) -> bool:
	return index == SCRIPT_PRESET_INDEX


func rename_preset(index: int, name: String) -> bool:
	if is_locked(index):
		return false
	var d := load_preset(index)
	if d.is_empty() or name.strip_edges() == "":
		return false
	d["name"] = name.strip_edges()
	if not _write(index, d):
		return false
	presets_changed.emit()
	return true


## Preset 1 is the fallback for everything else, so it stays.
func delete_preset(index: int) -> bool:
	if index == DEFAULT_PRESET_INDEX or is_locked(index) or not has_preset(index):
		return false
	if DirAccess.remove_absolute(_path_for(index)) != OK:
		return false
	if startup_index() == index:
		set_startup_index(DEFAULT_PRESET_INDEX)
	if active_index == index:
		set_active(DEFAULT_PRESET_INDEX)
	presets_changed.emit()
	return true


## Load a preset's screen values into `settings` (and its layers and
## camera effect into `layers`, if given) and make it active.
func apply(index: int, settings: ScreenSettings, layers: LayerStack = null) -> bool:
	var preset := load_preset(index)
	var screen = preset.get("screen", null)
	if typeof(screen) != TYPE_DICTIONARY:
		return false
	settings.from_dict(screen)
	if layers != null:
		layers.from_array(layers_of(preset))
		var fx = preset.get("camera_fx", {})
		layers.camera_fx.from_dict(fx if typeof(fx) == TYPE_DICTIONARY else {})
	set_active(index)
	return true


## A preset's layer dicts, converting the older single-layer blocks (those
## with no shader were off, so they're dropped).
static func layers_of(preset: Dictionary) -> Array:
	var list = preset.get("layers", null)
	if typeof(list) == TYPE_ARRAY:
		return list
	var out: Array = []
	for spec in [["background", true, false], ["foreground", false, true], ["visualizer", false, true]]:
		var block = preset.get(spec[0], null)
		if typeof(block) == TYPE_DICTIONARY and String(block.get("shader", "")) != "":
			out.append(LayerSettings.from_legacy(block, spec[1], spec[2]))
			if spec[0] == "foreground":
				break  # a preset with `foreground` has no `visualizer`
	return out


func set_active(index: int) -> void:
	if index == active_index:
		return
	active_index = index
	active_changed.emit(index)


## The preset applied at launch; falls back to preset 1 if it's gone.
func startup_index() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(_dir.path_join(STARTUP_FILE)) != OK:
		return DEFAULT_PRESET_INDEX
	var idx := int(cfg.get_value("presets", "startup", DEFAULT_PRESET_INDEX))
	return idx if has_preset(idx) else DEFAULT_PRESET_INDEX


func set_startup_index(index: int) -> void:
	_ensure_dir()
	var cfg := ConfigFile.new()
	cfg.set_value("presets", "startup", index)
	cfg.save(_dir.path_join(STARTUP_FILE))
	presets_changed.emit()


func list_presets() -> Array:
	var out: Array = [{"index": SCRIPT_PRESET_INDEX, "name": SCRIPT_PRESET_NAME}]
	_ensure_dir()
	var dir := DirAccess.open(_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.begins_with("preset_") and file.ends_with(".json"):
			var idx_str := file.trim_prefix("preset_").trim_suffix(".json")
			if idx_str.is_valid_int():
				var idx := int(idx_str)
				var d := load_preset(idx)
				out.append({
					"index": idx,
					"name": String(d.get("name", "Preset %d" % idx)),
				})
		file = dir.get_next()
	out.sort_custom(func(a, b): return a.index < b.index)
	return out


func default_preset_index() -> int:
	return DEFAULT_PRESET_INDEX


func next_free_index() -> int:
	var used: Dictionary = {}
	for item in list_presets():
		used[int(item.index)] = true
	var i := 1
	while used.has(i):
		i += 1
	return i


func _default_preset() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"kind": KIND,
		"name": "Default",
		"screen": {
			"size": 1.0,
			"distance": 0.0,
			"height": 0.0,
			"tilt": 0.0,
			"curvature": 0.0,
			"opacity": 1.0,
		},
	}


static func _script_preset() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"kind": KIND,
		"name": SCRIPT_PRESET_NAME,
		"screen": ScreenSettings.new().to_dict(),
	}


func _path_for(index: int) -> String:
	return _dir.path_join("preset_%d.json" % index)


func _ensure_dir() -> void:
	if DirAccess.dir_exists_absolute(_dir):
		return
	DirAccess.make_dir_recursive_absolute(_dir)


func _write(index: int, data: Dictionary) -> bool:
	_ensure_dir()
	var path := _path_for(index)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("PresetStore: cannot write %s (err %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(data, "  "))
	return true
