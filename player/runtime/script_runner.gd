class_name ScriptRunner
extends Node

## Owns the current TimelineData and playhead. Each tick():
##   1. advance playhead
##   2. fire discrete events crossed since last frame
##   3. evaluate continuous tracks and apply to registered objects
##
## Also handles live reload: watches the script file (and its referenced
## prefabs / shaders) via FileWatcher. On change, re-parses and reconciles
## the stage against the new timeline — spawn what's newly expected,
## despawn what's no longer expected, keep the playhead where it was.

signal script_loaded(data: TimelineData)
signal script_load_failed(error: String)
signal script_reloaded(data: TimelineData)
signal event_fired(event: Dictionary)
signal seeked(t: float)
signal play_state_changed(is_playing: bool)

@export var stage_path: NodePath
@export var autostart: bool = false
@export var live_reload: bool = true

var timeline: TimelineData
var playhead: float = 0.0
var playing: bool = false

var _registry: ObjectRegistry
var _prefabs: PrefabLibrary
var _stage: Node3D
var _events_sorted: Array = []
var _next_event_idx: int = 0
var _watcher: FileWatcher
var _video_duration: float = 0.0  # set externally when the video reports its length


func _ready() -> void:
	_registry = ObjectRegistry.new()
	_registry.name = "ObjectRegistry"
	add_child(_registry)
	_prefabs = PrefabLibrary.new()
	if stage_path:
		_stage = get_node_or_null(stage_path)
	if live_reload:
		_watcher = FileWatcher.new()
		_watcher.name = "FileWatcher"
		add_child(_watcher)
		_watcher.file_changed.connect(_on_file_changed)


func registry() -> ObjectRegistry:
	return _registry


func set_video_duration(seconds: float) -> void:
	# Called by the video bridge when the underlying file has loaded and its
	# length is known. Extends the effective timeline so playhead / scrub don't
	# stop early if the script omitted an explicit media.duration.
	_video_duration = maxf(0.0, seconds)


func effective_duration() -> float:
	# Timeline runs for the longer of the JSON-declared duration and the
	# video's actual length. Authors get to override upward (declaring a
	# longer piece than the video for overlays), and downward is respected
	# too — but only if declared above zero.
	var declared := timeline.duration() if timeline != null else 0.0
	if declared > 0.0:
		return maxf(declared, _video_duration)
	return _video_duration


func load_script(path: String) -> bool:
	var result := ScriptFormat.load_from_file(path)
	if not result.ok:
		script_load_failed.emit(result.error)
		push_error("Script load failed: %s" % result.error)
		return false
	_apply_timeline(result.data, false)
	if autostart:
		playing = true
	return true


func load_timeline(data: TimelineData) -> void:
	# Direct-load path for tests.
	_apply_timeline(data, false)


func play() -> void:
	if not playing:
		playing = true
		play_state_changed.emit(true)


func pause() -> void:
	if playing:
		playing = false
		play_state_changed.emit(false)


func seek(t: float) -> void:
	if timeline == null:
		return
	playhead = clampf(t, 0.0, _duration())
	_next_event_idx = _event_idx_after(playhead, _events_sorted)
	# Determinism: rebuild the owned-object set to match what should exist at
	# this playhead. Continuous tracks (transform / shader_param) then snap to
	# their interpolated value even if we're paused.
	_reproject_owned_objects()
	_evaluate_continuous_tracks()
	seeked.emit(playhead)


func _reproject_owned_objects() -> void:
	if timeline == null:
		return
	var expected := _project_state_at(_events_sorted, playhead)
	for id in _registry.owned_ids():
		if not expected.has(id):
			_registry.despawn(id, 0.0)
	for id in expected.keys():
		if _registry.has_id(id):
			continue
		_do_spawn(expected[id])


func tick(delta: float) -> void:
	if timeline == null:
		return
	playhead = clampf(playhead + delta, 0.0, _duration())
	_fire_pending_events()
	_evaluate_continuous_tracks()
	_registry.tick_fades(delta)


func _process(delta: float) -> void:
	if not playing:
		return
	tick(delta)


# ---------- timeline load / reconcile ----------

func _apply_timeline(data: TimelineData, preserve_playhead: bool) -> void:
	timeline = data
	_events_sorted = data.events_sorted()
	if preserve_playhead:
		_next_event_idx = _event_idx_after(playhead, _events_sorted)
	else:
		playhead = 0.0
		_next_event_idx = 0
		_registry.clear_owned()
	_update_watched_files()
	script_loaded.emit(timeline)


func _reconcile_swap(new_timeline: TimelineData) -> void:
	# Compute expected owned objects at the current playhead from the new
	# timeline, then diff against currently-owned. Spawn/despawn deltas only.
	# External objects (main_screen, etc.) are never touched.
	var new_events := new_timeline.events_sorted()
	var expected := _project_state_at(new_events, playhead)
	var old_timeline := timeline
	timeline = new_timeline
	_events_sorted = new_events
	_next_event_idx = _event_idx_after(playhead, _events_sorted)

	for id in _registry.owned_ids():
		if not expected.has(id):
			_registry.despawn(id, 0.0)
	for id in expected.keys():
		if _registry.has_id(id):
			continue
		_do_spawn(expected[id])

	_update_watched_files()
	script_reloaded.emit(timeline)


static func _project_state_at(sorted_events: Array, t: float) -> Dictionary:
	# Returns id -> the spawn event that created it, considering events with t <= playhead.
	var state: Dictionary = {}
	for ev in sorted_events:
		if float(ev.get("t", 0.0)) > t:
			break
		match ev.get("action", ""):
			"spawn":
				var id := String(ev.get("id", ""))
				if id != "":
					state[id] = ev
			"despawn":
				state.erase(String(ev.get("target", "")))
	return state


static func _event_idx_after(t: float, sorted_events: Array) -> int:
	for i in sorted_events.size():
		if float(sorted_events[i].get("t", 0.0)) > t:
			return i
	return sorted_events.size()


func _update_watched_files() -> void:
	if _watcher == null or timeline == null:
		return
	_watcher.reset()
	if timeline.script_path != "" and timeline.script_path != "<memory>":
		_watcher.watch(timeline.script_path)
	for key in timeline.shaders.keys():
		var p := timeline.resolve_shader(key)
		if p != "":
			_watcher.watch(p)
	for key in timeline.prefabs.keys():
		var p := timeline.resolve_prefab(key)
		if p != "":
			_watcher.watch(p)


func _on_file_changed(path: String) -> void:
	if timeline == null:
		return
	if path == timeline.script_path:
		# Full re-parse + reconcile. If parse fails (e.g. editor is mid-write),
		# keep current state — the next mtime bump will retry.
		var r := ScriptFormat.load_from_file(path)
		if not r.ok:
			push_warning("Live-reload parse failed (keeping current): %s" % r.error)
			return
		_reconcile_swap(r.data)
		return
	# Prefab or shader changed. Invalidate the cache; running instances keep
	# their (now-stale) material until they're respawned. That's an acceptable
	# tradeoff for a Phase-3 MVP.
	_prefabs.invalidate(path)


# ---------- runtime evaluation ----------

func _duration() -> float:
	return effective_duration()


func _fire_pending_events() -> void:
	while _next_event_idx < _events_sorted.size():
		var ev: Dictionary = _events_sorted[_next_event_idx]
		var t := float(ev.get("t", 0.0))
		if t > playhead:
			return
		_dispatch_event(ev)
		event_fired.emit(ev)
		_next_event_idx += 1


func _dispatch_event(ev: Dictionary) -> void:
	match ev.get("action", ""):
		"spawn": _do_spawn(ev)
		"despawn": _do_despawn(ev)
		"vr_cut", "vr_teleport":
			pass  # Camera application lives in main.gd via event_fired.


func _do_spawn(ev: Dictionary) -> void:
	if _stage == null:
		return
	var id: String = String(ev.get("id", ""))
	var prefab_key: String = String(ev.get("prefab", ""))
	if id.is_empty() or prefab_key.is_empty():
		return
	var abs_path := timeline.resolve_prefab(prefab_key)
	if abs_path.is_empty():
		push_warning("spawn: unknown prefab key '%s'" % prefab_key)
		return
	var packed := _prefabs.load_prefab(abs_path)
	if packed == null:
		return
	var xform := _read_transform(ev.get("transform", {}))
	_registry.spawn(id, packed, _stage, xform)


func _do_despawn(ev: Dictionary) -> void:
	var target: String = String(ev.get("target", ""))
	if target.is_empty():
		return
	var fade := 0.0
	var tr = ev.get("transition")
	if typeof(tr) == TYPE_DICTIONARY and tr.get("type", "") == "fade":
		fade = float(tr.get("duration", 0.0))
	_registry.despawn(target, fade)


func _evaluate_continuous_tracks() -> void:
	if timeline == null:
		return
	for track in timeline.continuous_tracks():
		match track.get("type", ""):
			"transform": _apply_transform_track(track)
			"shader_param": _apply_shader_param_track(track)


func _apply_transform_track(track: Dictionary) -> void:
	var target: String = String(track.get("target", ""))
	var node := _registry.get_node_by_id(target)
	if node == null:
		return
	var kfs: Array = track.get("keyframes", [])
	var value = Interpolation.evaluate(kfs, playhead)
	if value == null:
		return
	var vec := Interpolation.to_vec3(value)
	match track.get("channel", ""):
		"position":
			node.position = vec
		"rotation_deg":
			node.rotation = Vector3(deg_to_rad(vec.x), deg_to_rad(vec.y), deg_to_rad(vec.z))
		"scale":
			node.scale = vec


func _apply_shader_param_track(track: Dictionary) -> void:
	var target_path: String = String(track.get("target", ""))
	var parts := target_path.split(".", false, 1)
	if parts.size() != 2:
		return
	var node := _registry.get_node_by_id(parts[0])
	if node == null or not (node is GeometryInstance3D):
		return
	var gi := node as GeometryInstance3D
	var mat: Material = gi.get_active_material(0)
	if mat == null:
		return
	var kfs: Array = track.get("keyframes", [])
	var value = Interpolation.evaluate(kfs, playhead)
	if value == null:
		return
	var param: String = String(track.get("param", ""))
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter(param, value)


func _read_transform(t: Dictionary) -> Transform3D:
	var pos := Interpolation.to_vec3(t.get("position", [0, 0, 0]))
	var rot_deg := Interpolation.to_vec3(t.get("rotation_deg", [0, 0, 0]))
	var scl_arr = t.get("scale", [1, 1, 1])
	var scl := Interpolation.to_vec3(scl_arr) if typeof(scl_arr) == TYPE_ARRAY else Vector3.ONE
	var basis := Basis.from_euler(Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z)))
	basis = basis.scaled(scl)
	return Transform3D(basis, pos)
