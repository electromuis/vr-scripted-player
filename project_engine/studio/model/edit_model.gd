class_name EditModel
extends RefCounted

## Studio's in-memory copy of a script JSON, and the only way Studio
## changes it. Every edit is a command that knows how to undo itself; the
## undo stack has redo, and a dirty flag. The app turns the document into a
## TimelineData for the runner (timeline()) after each change.
##
## A command is a list of changes, each replacing the value at a path in
## the document ("tracks", 3, "keyframes") with a new one, or removing it.
## Undo puts the old values back in reverse order. Values are deep-copied
## on the way in, so callers can't change the document behind its back.
##
## Saving goes through ScriptFormat's validator. While the document is as
## it was loaded (nothing changed, or everything undone), save writes the
## file's original text back unchanged, so opening and saving a piece never
## rewrites it. After edits it writes JSON with the file's own indentation.
## A v1 script is upgraded to v2 on load (as the player does), and an
## edited one is saved as v2.

## After every command, undo or redo. `structural`: spawn / despawn events
## or spawn configs changed (the runner reconciles which objects exist);
## otherwise only continuous tracks did (the runner re-evaluates them).
signal changed(structural: bool)

## Keys closer than this in time are the same key (set_key replaces it).
const SAME_TIME := 0.0005

## The file this came from and saves to.
var path: String = ""

var _doc: Dictionary = {}
var _undo: Array = []  # commands: {label, structural, changes: [{path, had_old, old, has_new, new}]}
var _redo: Array = []
## Undo depth at the last save / at load; -1 once that state can't be
## reached any more (undone past it, then something new was done).
var _saved_depth: int = 0
var _loaded_depth: int = 0
var _original_text: String = ""
## While batch() runs: its commands' changes, gathered into one undo step.
var _batching := false
var _batch_changes: Array = []
var _batch_structural := false
var _indent: String = "  "


## {ok: true, model} or {ok: false, error, errors}.
static func open(file_path: String) -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {"ok": false, "error": "File not found: %s" % file_path, "errors": ["File not found: %s" % file_path]}
	return from_text(FileAccess.get_file_as_string(file_path), file_path)


static func from_text(text: String, file_path: String = "") -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Not a script JSON: %s" % file_path, "errors": ["Not a script JSON: %s" % file_path]}
	var check := ScriptFormat.load_from_dict(parsed.duplicate(true), file_path if file_path != "" else "<memory>")
	if not check.ok:
		return check
	var m := EditModel.new()
	m.path = file_path
	m._original_text = text
	m._indent = _detect_indent(text)
	ScriptFormat.upgrade(parsed)
	parsed["format_version"] = ScriptFormat.SUPPORTED_VERSION
	m._doc = parsed
	return {"ok": true, "model": m}


## The document, to read. Change it only through the commands below.
func document() -> Dictionary:
	return _doc


## A fresh TimelineData for the runner (its own copy of the document).
func timeline() -> TimelineData:
	var r := ScriptFormat.load_from_dict(_doc.duplicate(true), path if path != "" else "<memory>")
	return r.data if r.ok else null


func is_dirty() -> bool:
	return _undo.size() != _saved_depth


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


## What undo / redo would do next ("" if nothing).
func undo_label() -> String:
	return String(_undo.back().label) if can_undo() else ""


func redo_label() -> String:
	return String(_redo.back().label) if can_redo() else ""


## Returns the label of what was undone, "" if nothing was.
func undo() -> String:
	if _undo.is_empty():
		return ""
	var cmd: Dictionary = _undo.pop_back()
	for i in range(cmd.changes.size() - 1, -1, -1):
		var c: Dictionary = cmd.changes[i]
		_put(c.path, c.had_old, c.old)
	_redo.append(cmd)
	changed.emit(cmd.structural)
	return cmd.label


func redo() -> String:
	if _redo.is_empty():
		return ""
	var cmd: Dictionary = _redo.pop_back()
	for c in cmd.changes:
		_put(c.path, c.has_new, c.new)
	_undo.append(cmd)
	changed.emit(cmd.structural)
	return cmd.label


# ---------- saving ----------

## Validate and write the document (to `to_path`, else where it came
## from). {ok: true} or {ok: false, error}.
func save(to_path: String = "") -> Dictionary:
	var target := to_path if to_path != "" else path
	if target == "":
		return {"ok": false, "error": "No file to save to"}
	var check := ScriptFormat.load_from_dict(_doc.duplicate(true), target)
	if not check.ok:
		return {"ok": false, "error": "Not saved, the script would be invalid: %s" % check.error}
	var text := _original_text if _undo.size() == _loaded_depth else to_text()
	# Write next to it, then swap, so a failed write never leaves half a file.
	var tmp := target + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Could not write %s (error %d)" % [tmp, FileAccess.get_open_error()]}
	f.store_string(text)
	f.close()
	var err := DirAccess.rename_absolute(tmp, target)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return {"ok": false, "error": "Could not replace %s (error %d)" % [target, err]}
	if target == path:
		_saved_depth = _undo.size()
	return {"ok": true}


## The document as JSON, in the original file's indentation (and with its
## final newline, if it had one). Keys keep their order.
func to_text() -> String:
	var text := JSON.stringify(_doc, _indent, false)
	if _original_text.ends_with("\n"):
		text += "\n"
	return text


static func _detect_indent(text: String) -> String:
	for line in text.split("\n"):
		if line.strip_edges() == "":
			continue
		var n := 0
		while n < line.length() and (line[n] == " " or line[n] == "\t"):
			n += 1
		if n > 0:
			return line.substr(0, n)
	return "  "


# ---------- queries ----------

func tracks() -> Array:
	return _doc.get("tracks", [])


## Ids of every spawned object, in file order (first spawn of each).
func object_ids() -> Array:
	var out: Array = []
	for t in tracks():
		if t.get("type") == "event" and t.get("action") == "spawn" and not out.has(t.get("id")):
			out.append(t.get("id"))
	return out


## Index in tracks() of `id`'s first spawn event, -1 if none.
func spawn_index(id: String) -> int:
	var list := tracks()
	for i in list.size():
		if list[i].get("type") == "event" and list[i].get("action") == "spawn" and list[i].get("id") == id:
			return i
	return -1


## The transform or shader_param track for `target` and `name` (a channel
## for transforms, a param for shader params), -1 if none.
func find_track(type: String, target: String, name: String) -> int:
	var field := "channel" if type == ScriptFormat.TRACK_TRANSFORM else "param"
	var list := tracks()
	for i in list.size():
		if list[i].get("type") == type and list[i].get("target") == target and list[i].get(field) == name:
			return i
	return -1


# ---------- commands ----------
# Each returns false (and changes nothing) if it doesn't apply.

## Where `id` spawns: {position, rotation_deg, scale}, any subset. Every
## spawn of `id` (a piece can bring an object back later) moves together.
func set_spawn_transform(id: String, transform: Dictionary) -> bool:
	var changes: Array = []
	var list := tracks()
	for i in list.size():
		if list[i].get("type") == "event" and list[i].get("action") == "spawn" and list[i].get("id") == id:
			changes.append(_change(["tracks", i, "transform"], transform))
	if changes.is_empty():
		return false
	return _do("Move %s" % id, true, changes)


## Replace track `ti`'s keys (e.g. a path shifted as a whole).
func set_keyframes(ti: int, kfs: Array, label: String = "") -> bool:
	if _keyframes(ti) == null or kfs.is_empty():
		return false
	var track: Dictionary = tracks()[ti]
	if label == "":
		label = "Edit %s %s" % [track.get("target", ""), track.get("channel", track.get("param", ""))]
	return _do(label, _is_structural_track(track), [_change(["tracks", ti, "keyframes"], kfs)])


## A value in `id`'s spawn config: `key` is a field ("opacity") or a path
## into it (["modifiers", "tint"]). A null value removes it.
func set_config(id: String, key, value) -> bool:
	var i := spawn_index(id)
	if i < 0:
		return false
	var keys: Array = key if typeof(key) == TYPE_ARRAY else [key]
	if keys.is_empty():
		return false
	var p: Array = ["tracks", i, "config"]
	# Create missing parents along the way (as part of the same command).
	var changes: Array = []
	var node = _value_at(p)
	for k in keys.slice(0, keys.size() - 1):
		if node == null or typeof(node) != TYPE_DICTIONARY:
			return _set_config_whole(id, i, keys, value)
		p = p + [k]
		node = node.get(k)
	if node == null or typeof(node) != TYPE_DICTIONARY:
		return _set_config_whole(id, i, keys, value)
	p = p + [keys.back()]
	changes.append(_change(p, value) if value != null else _removal(p))
	return _do("Set %s %s" % [id, ".".join(keys.map(func(k): return str(k)))], true, changes)


## set_config where a parent dictionary is missing: build the config anew.
func _set_config_whole(id: String, i: int, keys: Array, value) -> bool:
	if value == null:
		return false  # nothing to remove
	var cfg = _value_at(["tracks", i, "config"])
	cfg = cfg.duplicate(true) if typeof(cfg) == TYPE_DICTIONARY else {}
	var node: Dictionary = cfg
	for k in keys.slice(0, keys.size() - 1):
		if typeof(node.get(k)) != TYPE_DICTIONARY:
			node[k] = {}
		node = node[k]
	node[keys.back()] = value
	return _do("Set %s %s" % [id, ".".join(keys.map(func(k): return str(k)))], true, [_change(["tracks", i, "config"], cfg)])


## A key at `t` on the `type` track of `target` / `name` (made if there's
## none); it replaces a key at the same time. `interp` "" keeps the
## replaced key's (or leaves it out, which is linear).
func set_key(type: String, target: String, name: String, t: float, value, interp: String = "") -> bool:
	if type != ScriptFormat.TRACK_TRANSFORM and type != ScriptFormat.TRACK_SHADER_PARAM:
		return false
	if interp != "" and not ScriptFormat.INTERP_MODES.has(interp):
		return false
	if type == ScriptFormat.TRACK_TRANSFORM and (typeof(value) != TYPE_ARRAY or value.size() != 3):
		return false
	var key := {"t": t, "value": value}
	var ti := find_track(type, target, name)
	var label := "Key %s %s at %s" % [target, name, _time_label(t)]
	if ti < 0:
		if interp != "":
			key["interp"] = interp
		var track := {"type": type, "target": target}
		track["channel" if type == ScriptFormat.TRACK_TRANSFORM else "param"] = name
		track["keyframes"] = [key]
		var list := tracks().duplicate()
		list.append(track)
		return _do(label, _is_structural_track(track), [_change(["tracks"], list)])
	var track: Dictionary = tracks()[ti]
	var kfs: Array = track.get("keyframes", []).duplicate(true)
	var at := _key_at(kfs, t)
	if at >= 0:
		var same_shape: bool = typeof(kfs[at].get("value")) == typeof(value) \
				and (typeof(value) != TYPE_ARRAY or kfs[at].get("value").size() == value.size())
		for k in kfs[at]:
			if k in ["t", "value"] or (k in ["in", "out"] and not same_shape):
				continue
			key[k] = kfs[at][k]  # interp, bezier handles, anything else it carried
		kfs[at] = key
	else:
		kfs.insert(_insert_index(kfs, t), key)
	if interp != "":
		key["interp"] = interp
	return _do(label, _is_structural_track(track), [_change(["tracks", ti, "keyframes"], kfs)])


## Retime key `ki` of track `ti` to `new_t` (it replaces a key already there).
func move_key(ti: int, ki: int, new_t: float) -> bool:
	var kfs = _keyframes(ti)
	if kfs == null or ki < 0 or ki >= kfs.size():
		return false
	kfs = kfs.duplicate(true)
	var key: Dictionary = kfs[ki]
	kfs.remove_at(ki)
	var clash := _key_at(kfs, new_t)
	if clash >= 0:
		kfs.remove_at(clash)
	key["t"] = new_t
	kfs.insert(_insert_index(kfs, new_t), key)
	var track: Dictionary = tracks()[ti]
	return _do("Move key to %s" % _time_label(new_t), _is_structural_track(track), [_change(["tracks", ti, "keyframes"], kfs)])


## Remove key `ki` of track `ti`; the last one takes its track with it.
func delete_key(ti: int, ki: int) -> bool:
	var kfs = _keyframes(ti)
	if kfs == null or ki < 0 or ki >= kfs.size():
		return false
	var track: Dictionary = tracks()[ti]
	var label := "Delete key at %s" % _time_label(float(kfs[ki].get("t", 0.0)))
	if kfs.size() == 1:
		var list := tracks().duplicate()
		list.remove_at(ti)
		return _do(label, _is_structural_track(track), [_change(["tracks"], list)])
	kfs = kfs.duplicate(true)
	kfs.remove_at(ki)
	return _do(label, _is_structural_track(track), [_change(["tracks", ti, "keyframes"], kfs)])


## Add an object: `spawn` is a spawn event without "type" / "action"
## (id, prefab, t, transform, config, parent). Its prefab key must exist.
## With `despawn_at`, a despawn event goes with it.
func add_object(spawn: Dictionary, despawn_at = null) -> bool:
	var id := String(spawn.get("id", ""))
	if id == "" or id.begins_with("$") or spawn_index(id) >= 0:
		return false
	if not _doc.get("prefabs", {}).has(spawn.get("prefab", "")):
		return false
	var ev := {"type": "event", "t": float(spawn.get("t", 0.0)), "action": "spawn"}
	for k in spawn:
		if k not in ["type", "action", "t"]:
			ev[k] = spawn[k]
	var list := tracks().duplicate()
	list.append(ev)
	if despawn_at != null:
		list.append({"type": "event", "t": float(despawn_at), "action": "despawn", "target": id})
	return _do("Add %s" % id, true, [_change(["tracks"], list)])


## Remove an object: its spawn / despawn events and tracks, and the same
## for the objects inside it.
func remove_object(id: String) -> bool:
	if spawn_index(id) < 0:
		return false
	var gone := {id: true}
	var grew := true
	while grew:  # children, grandchildren, ...
		grew = false
		for t in tracks():
			if t.get("action") == "spawn" and gone.has(t.get("parent", "")) and not gone.has(t.get("id")):
				gone[t.get("id")] = true
				grew = true
	var list := tracks().filter(func(t): return not _belongs_to(t, gone))
	return _do("Remove %s" % id, true, [_change(["tracks"], list)])


static func _belongs_to(t: Dictionary, ids: Dictionary) -> bool:
	match t.get("type"):
		"event":
			return ids.has(t.get("id", "")) if t.get("action") == "spawn" else ids.has(t.get("target", ""))
		_:
			return ids.has(String(t.get("target", "")).split(".")[0])


# ---------- internals ----------

## Shader params of `reactive` are read at spawn (spin keys), so they
## need the runner to respawn the object.
static func _is_structural_track(track: Dictionary) -> bool:
	return String(track.get("target", "")).ends_with(".reactive")


func _keyframes(ti: int):
	if ti < 0 or ti >= tracks().size():
		return null
	var kfs = tracks()[ti].get("keyframes")
	return kfs if typeof(kfs) == TYPE_ARRAY else null


static func _key_at(kfs: Array, t: float) -> int:
	for i in kfs.size():
		if absf(float(kfs[i].get("t", 0.0)) - t) < SAME_TIME:
			return i
	return -1


## After any keys at the same time or earlier (keys stay sorted).
static func _insert_index(kfs: Array, t: float) -> int:
	var i := 0
	while i < kfs.size() and float(kfs[i].get("t", 0.0)) <= t:
		i += 1
	return i


static func _time_label(t: float) -> String:
	return "%d:%05.2f" % [floori(t / 60.0), fmod(t, 60.0)]


## New values go in as JSON would read them back (every number a float),
## so they compare equal to what the file holds.
func _change(p: Array, value) -> Dictionary:
	var had := _has_path(p)
	return {"path": p, "had_old": had, "old": _copy(_value_at(p)) if had else null, "has_new": true, "new": _as_json(value)}


static func _as_json(v):
	if typeof(v) == TYPE_DICTIONARY or typeof(v) == TYPE_ARRAY:
		return JSON.parse_string(JSON.stringify(v))
	if typeof(v) == TYPE_INT:
		return float(v)
	return v


func _removal(p: Array) -> Dictionary:
	var had := _has_path(p)
	return {"path": p, "had_old": had, "old": _copy(_value_at(p)) if had else null, "has_new": false, "new": null}


## Several commands as one undo step (a drag that keys three channels):
## `body` runs them; `changed` fires once, after. False if nothing changed.
func batch(label: String, body: Callable) -> bool:
	if _batching:
		body.call()  # nested: part of the outer batch
		return true
	_batching = true
	_batch_changes = []
	_batch_structural = false
	body.call()
	_batching = false
	if _batch_changes.is_empty():
		return false
	_record(label, _batch_structural, _batch_changes)
	return true


## Apply a new command. Nothing happens (and false) if it changes nothing.
func _do(label: String, structural: bool, changes: Array) -> bool:
	changes = changes.filter(func(c): return c.had_old != c.has_new or JSON.stringify(c.old) != JSON.stringify(c.new))
	if changes.is_empty():
		return false
	for c in changes:
		_put(c.path, c.has_new, c.new)
	if _batching:
		_batch_changes.append_array(changes)
		_batch_structural = _batch_structural or structural
		return true
	_record(label, structural, changes)
	return true


## Push an applied command onto the undo stack and tell listeners.
func _record(label: String, structural: bool, changes: Array) -> void:
	_undo.append({"label": label, "structural": structural, "changes": changes})
	if _redo.size() > 0:
		_redo.clear()
		# States only reachable through redo are gone for good.
		if _saved_depth >= _undo.size():
			_saved_depth = -1
		if _loaded_depth >= _undo.size():
			_loaded_depth = -1
	changed.emit(structural)


func _value_at(p: Array):
	var node = _doc
	for k in p:
		if typeof(node) == TYPE_DICTIONARY:
			if not node.has(k):
				return null
			node = node[k]
		elif typeof(node) == TYPE_ARRAY:
			if typeof(k) != TYPE_INT or k < 0 or k >= node.size():
				return null
			node = node[k]
		else:
			return null
	return node


func _has_path(p: Array) -> bool:
	var parent = _value_at(p.slice(0, p.size() - 1))
	var k = p.back()
	if typeof(parent) == TYPE_DICTIONARY:
		return parent.has(k)
	if typeof(parent) == TYPE_ARRAY:
		return typeof(k) == TYPE_INT and k >= 0 and k < parent.size()
	return false


## Set (or with `present` false, remove) the value at `p`. Values are
## copied, so the undo record keeps its own.
func _put(p: Array, present: bool, value) -> void:
	var parent = _value_at(p.slice(0, p.size() - 1))
	var k = p.back()
	if typeof(parent) == TYPE_DICTIONARY:
		if present:
			parent[k] = _copy(value)
		else:
			parent.erase(k)
	elif typeof(parent) == TYPE_ARRAY and present:
		parent[k] = _copy(value)


static func _copy(v):
	if typeof(v) == TYPE_DICTIONARY or typeof(v) == TYPE_ARRAY:
		return v.duplicate(true)
	return v
