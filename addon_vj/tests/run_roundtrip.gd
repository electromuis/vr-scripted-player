extends SceneTree

## Round trip for the importer: every script JSON under a folder is
## imported, exported, imported and exported again.
##
##   godot --headless --path project_script_example \
##       --script res://addons/vj_editor/tests/run_roundtrip.gd [-- <scripts dir>…]
##
## (default: the repo's scripts/, next to the authoring projects, and this
## folder's fixtures/).
## Checks, per script:
##   - it plays the same: events, meta, media and prefab / shader keys match
##     the original, and every track's value, sampled every 1/20 s through
##     the player's own Interpolation, stays within tolerance
##   - it's stable: exporting the second import gives the first export again
## Warnings the importer reports (things a scene can't say) are printed.

const ScriptImporterScript := preload("res://addons/vj_editor/importer/script_importer.gd")
const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")

const _TOLERANCE := 1e-3
const _SAMPLES_PER_SECOND := 20.0

var _interpolation: GDScript
var _fails := 0
var _tmp := ""


func _initialize() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var args := OS.get_cmdline_user_args()
	var dirs: Array = args if not args.is_empty() else [repo.path_join("scripts"),
			ProjectSettings.globalize_path("res://addons/vj_editor/tests/fixtures")]
	_interpolation = load(repo.path_join("project_engine/player/runtime/interpolation.gd"))
	if _interpolation == null:
		push_error("roundtrip: needs the player's interpolation.gd at %s" % repo.path_join("project_engine"))
		quit(2)
		return
	_tmp = OS.get_temp_dir().path_join("vj_roundtrip_%d" % Time.get_ticks_usec())
	var scripts: Array = []
	for dir in dirs:
		scripts.append_array(_find_json(dir))
	for path in scripts:
		_check(path)
	print("\nRound trip: %d script(s), %s" % [scripts.size(), "all ok" if _fails == 0 else "%d failure(s)" % _fails])
	quit(0 if _fails == 0 else 1)


func _find_json(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "json":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_find_json(dir.path_join(d)))
	return out


func _check(path: String) -> void:
	print("== %s" % path)
	var original = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not JSON.stringify(original.get("tracks", [])).contains('"spawn"'):
		print("   nothing spawned: nothing to round-trip (the exporter needs objects)")
		return
	var name := path.get_base_dir().get_file()
	var first := _import_export(path, _tmp.path_join(name + "_1"))
	if first.is_empty():
		return
	var second := _import_export(first.path, _tmp.path_join(name + "_2"))
	if second.is_empty():
		return
	if int(original.get("format_version", 1)) < 2:
		ScriptImporterScript._upgrade_v1(original.get("tracks", []))
	_same_playback(original, first.data)
	var diffs: Array = []
	_diff(_canonical(first.data), _canonical(second.data), "", diffs, 1e-6)
	for d in diffs.slice(0, 10):
		_fail("export not stable: " + d)


## Imports `json` (files under `dir`) and exports it to `dir`/video.json.
## {path, data} or {} (failed).
func _import_export(json: String, dir: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(dir)
	var built := ScriptImporterScript.build_scene(json, dir.path_join("project"))
	if not built.ok:
		_fail("import failed: %s" % built.error)
		return {}
	for w in built.warnings:
		print("   note: %s" % w)
	var out_dir := dir.path_join("export")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var res: Dictionary = SceneExporterScript._build_json(built.root, out_dir)
	built.root.free()
	if not res.ok:
		_fail("export failed: %s" % res.error)
		return {}
	var out := out_dir.path_join("video.json")
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(res.data, "  "))
	f.close()
	# Through JSON and back, so numbers compare the way the file holds them.
	return {"path": out, "data": JSON.parse_string(FileAccess.get_file_as_string(out))}


func _same_playback(a: Dictionary, b: Dictionary) -> void:
	var diffs: Array = []
	for k in ["meta", "media"]:
		var av: Dictionary = a.get(k, {}).duplicate()
		av.erase("audio")
		_diff(av, b.get(k, {}), k, diffs, _TOLERANCE)
	for k in ["prefabs", "shaders"]:
		_diff(a.get(k, {}).keys().filter(func(x): return _used(a, k, x)).map(func(x): return str(x)),
				b.get(k, {}).keys(), k, diffs, 0.0, true)
	_diff(_events(a), _events(b), "events", diffs, _TOLERANCE)
	var ta := _continuous(a)
	var tb := _continuous(b)
	_diff(ta.keys(), tb.keys(), "tracks", diffs, 0.0, true)
	var samples := 0
	for key in ta:
		if not tb.has(key):
			continue
		var end := maxf(float(ta[key][-1].t), float(tb[key][-1].t)) + 0.5
		for n in int(end * _SAMPLES_PER_SECOND) + 1:
			var t := n / _SAMPLES_PER_SECOND
			var va = _interpolation.evaluate(ta[key], t)
			var vb = _interpolation.evaluate(tb[key], t)
			var before := diffs.size()
			_diff(va, vb, "%s @ %.2fs" % [key, t], diffs, _TOLERANCE)
			samples += 1
			if diffs.size() > before:
				break  # one per track is enough
	for d in diffs.slice(0, 20):
		_fail("plays differently: " + d)
	print("   compared %d events, %d tracks (%d samples)" % [_events(a).size(), ta.size(), samples])


## Whether a prefabs / shaders key is used (the exporter only lists used ones).
func _used(data: Dictionary, map: String, key: String) -> bool:
	return JSON.stringify(data.get("tracks", [])).contains('"%s"' % key)


func _events(data: Dictionary) -> Array:
	var out: Array = data.get("tracks", []).filter(func(t): return t.get("type") == "event" and t.get("action") != "vr_teleport")
	out.sort_custom(func(x, y): return _event_key(x) < _event_key(y))
	return out


func _event_key(e: Dictionary) -> String:
	return "%012.4f|%s|%s" % [float(e.get("t", 0.0)), e.get("action", ""), e.get("id", e.get("target", ""))]


func _continuous(data: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for t in data.get("tracks", []):
		if t.get("type") in ["transform", "shader_param"]:
			out["%s|%s|%s" % [t.type, t.get("target", ""), t.get("channel", t.get("param", ""))]] = t.keyframes
	return out


func _canonical(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	var tracks: Array = out.get("tracks", [])
	tracks.sort_custom(func(x, y): return JSON.stringify(x) < JSON.stringify(y))
	return out


## Collects differences between `a` and `b` into `out` (numbers within
## `eps`, relative above 1). `as_set`: compare arrays ignoring order.
func _diff(a, b, where: String, out: Array, eps: float, as_set := false) -> void:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		if absf(float(a) - float(b)) > eps * maxf(1.0, absf(float(a))):
			out.append("%s: %s != %s" % [where, a, b])
		return
	if typeof(a) != typeof(b):
		out.append("%s: %s != %s" % [where, JSON.stringify(a), JSON.stringify(b)])
		return
	match typeof(a):
		TYPE_DICTIONARY:
			for k in a:
				if not b.has(k):
					out.append("%s.%s missing (was %s)" % [where, k, JSON.stringify(a[k])])
				else:
					_diff(a[k], b[k], "%s.%s" % [where, k], out, eps)
			for k in b:
				if not a.has(k):
					out.append("%s.%s added (%s)" % [where, k, JSON.stringify(b[k])])
		TYPE_ARRAY:
			if as_set:
				var sa: Array = a.duplicate()
				var sb: Array = b.duplicate()
				sa.sort()
				sb.sort()
				if sa != sb:
					out.append("%s: %s != %s" % [where, sa, sb])
				return
			if a.size() != b.size():
				out.append("%s: %d items != %d" % [where, a.size(), b.size()])
				return
			for i in a.size():
				_diff(a[i], b[i], "%s[%d]" % [where, i], out, eps)
		_:
			if a != b:
				out.append("%s: %s != %s" % [where, a, b])


func _fail(msg: String) -> void:
	_fails += 1
	print("   FAIL %s" % msg)
