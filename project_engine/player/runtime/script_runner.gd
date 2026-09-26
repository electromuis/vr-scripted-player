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
## The playhead reached the end of the timeline while ticking. Once per
## arrival: a seek (or loading another timeline) re-arms it.
signal reached_end

const Modifiers := preload("res://player/runtime/modifiers.gd")

@export var stage_path: NodePath
@export var autostart: bool = false
@export var live_reload: bool = true
## Give timelines without their own `main_screen` the player's default
## screen (see DefaultScreen). Off by default so tests see raw timelines.
@export var inject_default_screen: bool = false

var timeline: TimelineData
var playhead: float = 0.0
var playing: bool = false
## Stops the clock without leaving play: main.gd sets it while the video is
## opening or seeking so the timeline doesn't run ahead of the picture.
var hold: bool = false
## The music's bass level (0..1) for `pulse` (see Modifiers); main.gd feeds
## it from the audio analyzer while wants_audio().
var audio_bass: float = 0.0

var _registry: ObjectRegistry
var _prefabs: PrefabLibrary
var _stage: Node3D
var _events_sorted: Array = []
var _next_event_idx: int = 0
var _watcher: FileWatcher
var _video_duration: float = 0.0  # set externally when the video reports its length
var _ended: bool = false  # reached_end already fired for this arrival at the end
## id -> the spawn event each owned object came from, so a seek or reload
## respawns objects whose event changed (new config, parent, ...).
var _spawned_from: Dictionary = {}
## id -> reactive state (see Modifiers): node, spin, pulse, spin_kfs, plus
## the transform bookkeeping Modifiers keeps in it.
var _reactive: Dictionary = {}
## A node's own modifier values live in this metadata (runtime only).
const _MODS_META := "_vj_mods"
## Target id of the camera effect's tracks (`$camera.effect0`).
const CAMERA_TARGET := "$camera"
## slot ("effect0") -> {param: value} from `$camera` tracks at the playhead.
var _camera_params: Dictionary = {}
var _mods_lookup := func(n: Node) -> Dictionary: return n.get_meta(_MODS_META, {})


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
	_ended = false  # seeking onto the end while playing counts as reaching it
	_next_event_idx = _event_idx_after(playhead, _events_sorted)
	# Determinism: rebuild the owned-object set to match what should exist at
	# this playhead. Continuous tracks (transform / shader_param) then snap to
	# their interpolated value even if we're paused.
	_reproject_owned_objects()
	_reactive_begin()
	_evaluate_continuous_tracks()
	_reactive_end()
	seeked.emit(playhead)


func _reproject_owned_objects() -> void:
	if timeline == null:
		return
	_sync_owned(_project_state_at(_events_sorted, playhead))


## Make the owned objects match `expected` (id -> spawn event): despawn the
## ones not expected or spawned from a different event, then spawn what's
## missing, parents before their children.
func _sync_owned(expected: Dictionary) -> void:
	for id in _registry.owned_ids():
		if not expected.has(id) or (_spawned_from.has(id) and _spawned_from[id] != expected[id]):
			_registry.despawn(id, 0.0)
	for id in expected.keys():
		_spawn_expected(id, expected, 0)


func _spawn_expected(id: String, expected: Dictionary, depth: int) -> void:
	if _registry.has_id(id) or depth > expected.size():
		return
	var parent := String(expected[id].get("parent", ""))
	if parent != "" and expected.has(parent):
		_spawn_expected(parent, expected, depth + 1)
	_do_spawn(expected[id])


func tick(delta: float) -> void:
	if timeline == null:
		return
	playhead = clampf(playhead + delta, 0.0, _duration())
	_fire_pending_events()
	_reactive_begin()
	_evaluate_continuous_tracks()
	_reactive_end()
	_registry.tick_fades(delta)
	# Duration is 0 until the video reports its length: not an end yet.
	if not _ended and _duration() > 0.0 and playhead >= _duration():
		_ended = true
		reached_end.emit()


func _process(delta: float) -> void:
	if not playing or hold:
		return
	tick(delta)


# ---------- timeline load / reconcile ----------

func _apply_timeline(data: TimelineData, preserve_playhead: bool) -> void:
	if inject_default_screen:
		DefaultScreen.inject(data)
	timeline = data
	_camera_params = {}
	_events_sorted = data.events_sorted()
	if preserve_playhead:
		_next_event_idx = _event_idx_after(playhead, _events_sorted)
	else:
		playhead = 0.0
		_next_event_idx = 0
		_video_duration = 0.0  # the new video reports its own once loaded
		_ended = false
		_registry.clear_owned()
		_spawned_from.clear()
		_reactive.clear()
	_update_watched_files()
	script_loaded.emit(timeline)


func _reconcile_swap(new_timeline: TimelineData) -> void:
	# Compute expected owned objects at the current playhead from the new
	# timeline, then diff against currently-owned. Spawn/despawn deltas only.
	# External objects (main_screen, etc.) are never touched.
	if inject_default_screen:
		DefaultScreen.inject(new_timeline)
	var new_events := new_timeline.events_sorted()
	var expected := _project_state_at(new_events, playhead)
	var old_timeline := timeline
	timeline = new_timeline
	_events_sorted = new_events
	_next_event_idx = _event_idx_after(playhead, _events_sorted)
	_sync_owned(expected)
	_update_watched_files()
	script_reloaded.emit(timeline)


static func _project_state_at(sorted_events: Array, t: float) -> Dictionary:
	# Returns id -> the spawn event that created it, considering events with t <= playhead.
	# Despawning (or respawning) an object takes its children with it.
	var state: Dictionary = {}
	for ev in sorted_events:
		if float(ev.get("t", 0.0)) > t:
			break
		match ev.get("action", ""):
			"spawn":
				var id := String(ev.get("id", ""))
				if id != "":
					if state.has(id):
						_drop_children(state, id)  # a respawn starts it empty
					state[id] = ev
			"despawn":
				var target := String(ev.get("target", ""))
				_drop_children(state, target)
				state.erase(target)
	return state


static func _drop_children(state: Dictionary, id: String) -> void:
	for child in state.keys():
		if state.has(child) and String(state[child].get("parent", "")) == id:
			_drop_children(state, child)
			state.erase(child)


static func _event_idx_after(t: float, sorted_events: Array) -> int:
	for i in sorted_events.size():
		if float(sorted_events[i].get("t", 0.0)) > t:
			return i
	return sorted_events.size()


func _update_watched_files() -> void:
	if _watcher == null or timeline == null:
		return
	_watcher.reset()
	if timeline.script_path != "" and timeline.script_path != "<memory>" and not timeline.synthetic:
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
		# If parse fails (e.g. editor is mid-write), the next mtime bump retries.
		reload()
		return
	# Prefab or shader changed. Invalidate the cache; running instances keep
	# their (now-stale) material until they're respawned. That's an acceptable
	# tradeoff for a Phase-3 MVP.
	_prefabs.invalidate(path)


## Re-parse the script file now and reconcile, keeping the playhead (what a
## file change does). If it doesn't parse, the current timeline stays and
## this returns false.
func reload() -> bool:
	if timeline == null or timeline.synthetic or timeline.script_path in ["", "<memory>"]:
		return false
	var r := ScriptFormat.load_from_file(timeline.script_path)
	if not r.ok:
		push_warning("Live-reload parse failed (keeping current): %s" % r.error)
		return false
	_reconcile_swap(r.data)
	return true


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
	var parent := _stage
	var parent_id := String(ev.get("parent", ""))
	if parent_id != "":
		parent = _registry.get_node_by_id(parent_id)
		if parent == null or not is_instance_valid(parent):
			push_warning("spawn '%s': parent '%s' isn't there" % [id, parent_id])
			return
	var packed := _prefabs.load_prefab(abs_path)
	if packed == null:
		return
	var xform := _read_transform(ev.get("transform", {}))
	var node := _registry.spawn(id, packed, parent, xform)
	if node == null:
		return
	_spawned_from[id] = ev
	var cfg = ev.get("config", null)
	if typeof(cfg) == TYPE_DICTIONARY and node.has_method("configure"):
		# A layer loads its own shader (it may be Shadertoy code); a screen
		# gets a material built here.
		var is_layer := node is Visualizer
		var shader_key = cfg.get("shader", "")
		var mat: ShaderMaterial = null
		if not is_layer and typeof(shader_key) == TYPE_STRING and shader_key != "":
			mat = _build_shader_material(String(shader_key), cfg.get("shader_params", {}))
		node.configure(_resolve_config(cfg, is_layer), mat)
	_setup_modifiers(id, node, cfg if typeof(cfg) == TYPE_DICTIONARY else {})


## The spawn config's `modifiers` and `reactive` blocks. Modifiers are
## refreshed for every new object, so it takes on its parents' too.
func _setup_modifiers(id: String, node: Node3D, cfg: Dictionary) -> void:
	_reactive.erase(id)
	var mods = cfg.get("modifiers")
	if typeof(mods) == TYPE_DICTIONARY and not mods.is_empty():
		var values := {}
		for k in mods:
			values[k] = Modifiers.normalize(k, mods[k])
		node.set_meta(_MODS_META, values)
	Modifiers.refresh(node, _mods_lookup)
	var reactive = cfg.get("reactive")
	var spin_kfs: Array = []
	var pulse_track := false
	for track in timeline.continuous_tracks():
		if track.get("type") == "shader_param" and track.get("target") == id + ".reactive":
			if track.get("param") == "spin":
				spin_kfs = track.get("keyframes", [])
			elif track.get("param") == "pulse":
				pulse_track = true
	if typeof(reactive) != TYPE_DICTIONARY and spin_kfs.is_empty() and not pulse_track:
		return
	if typeof(reactive) != TYPE_DICTIONARY:
		reactive = {}
	_reactive[id] = {
		"node": node,
		"spin": Modifiers.normalize("spin", reactive.get("spin", [0, 0, 0])),
		"pulse": float(reactive.get("pulse", 0.0)),
		"spin_kfs": spin_kfs,
		"uses_audio": pulse_track or float(reactive.get("pulse", 0.0)) > 0.0,
	}


## Whether any object pulses with the music (main.gd runs the analyzer).
func wants_audio() -> bool:
	for state in _reactive.values():
		if state.uses_audio:
			return true
	return false


func _reactive_begin() -> void:
	for id in _reactive.keys():
		var state: Dictionary = _reactive[id]
		if not is_instance_valid(state.node) or not _registry.has_id(id):
			_reactive.erase(id)
			continue
		Modifiers.begin_frame(state.node, state)


func _reactive_end() -> void:
	for state in _reactive.values():
		var spin_at := func(t: float) -> Vector3:
			if state.spin_kfs.is_empty():
				return state.spin
			return Interpolation.to_vec3(Interpolation.evaluate(state.spin_kfs, t))
		var angle := Modifiers.spin_angle(state, spin_at, playhead)
		Modifiers.end_frame(state.node, state, angle, 1.0 + float(state.pulse) * audio_bass)


## `cfg` with shader keys swapped for the files they name (what Screen /
## Visualizer.set_effects and Visualizer.set_shader take), and JSON arrays
## in effect params turned into vectors.
func _resolve_config(cfg: Dictionary, is_layer: bool) -> Dictionary:
	var out := cfg.duplicate(true)
	if is_layer:
		out["shader"] = _shader_path(String(cfg.get("shader", "")))
		var params = cfg.get("params", {})
		if typeof(params) == TYPE_DICTIONARY:
			out["params"] = _shader_values(params)
	var effects = cfg.get("effects")
	if typeof(effects) == TYPE_ARRAY:
		var list: Array = []
		for e in effects:
			if typeof(e) != TYPE_DICTIONARY or e.get("enabled", true) == false:
				continue  # switched off: kept for editors, skipped (and not counted in effect<N>)
			var params = e.get("params", {})
			list.append({
				"shader": _shader_path(String(e.get("shader", ""))),
				"params": _shader_values(params) if typeof(params) == TYPE_DICTIONARY else {},
			})
		out["effects"] = list
	return out


func _shader_path(key: String) -> String:
	if key == "":
		return ""
	var path := timeline.resolve_shader(key)
	if path == "":
		push_warning("shader key '%s' not found" % key)
	return path


static func _shader_values(params: Dictionary) -> Dictionary:
	var out := {}
	for k in params:
		out[k] = shader_value(params[k])
	return out


func _build_shader_material(shader_key: String, params) -> ShaderMaterial:
	var path := timeline.resolve_shader(shader_key)
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("shader key '%s' not found" % shader_key)
		return null
	var shader: Shader = load(path)
	if shader == null:
		return null
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if typeof(params) == TYPE_DICTIONARY:
		for k in params.keys():
			mat.set_shader_parameter(String(k), shader_value(params[k]))
	return mat


## JSON has no vector type: numeric arrays of length 2/3/4 become
## Vector2/3/4 (a plain Array doesn't convert to a vecN uniform — it would
## silently read as zero). Everything else passes through.
static func shader_value(v: Variant) -> Variant:
	if typeof(v) != TYPE_ARRAY:
		return v
	match v.size():
		2: return Vector2(float(v[0]), float(v[1]))
		3: return Vector3(float(v[0]), float(v[1]), float(v[2]))
		4: return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	return v


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
	if parts[0] == CAMERA_TARGET:
		_apply_camera_track(parts[1], track)
		return
	var node := _registry.get_node_by_id(parts[0])
	if node == null:
		return
	var kfs: Array = track.get("keyframes", [])
	var value = Interpolation.evaluate(kfs, playhead)
	if value == null:
		return
	var param: String = String(track.get("param", ""))
	value = shader_value(value)
	if parts[1] == "modifiers":
		var mods: Dictionary = node.get_meta(_MODS_META, {}).duplicate()
		value = Modifiers.normalize(param, value)
		if mods.get(param) != value:
			mods[param] = value
			node.set_meta(_MODS_META, mods)
			Modifiers.refresh(node, _mods_lookup)
		return
	if parts[1] == "reactive":
		if _reactive.has(parts[0]) and param == "pulse":
			_reactive[parts[0]].pulse = float(value)
		return  # spin is integrated from its keyframes in _reactive_end
	# Prefabs with several materials (e.g. Screen: artist shader + display
	# pass) route by slot name. Otherwise prefer a get_shader_material()
	# hook, then fall back to GeometryInstance3D's active material.
	if node.has_method("set_material_param"):
		node.call("set_material_param", parts[1], param, value)
		return
	var mat: ShaderMaterial = null
	if node.has_method("get_shader_material"):
		mat = node.call("get_shader_material")
	elif node is GeometryInstance3D:
		var active: Material = (node as GeometryInstance3D).get_active_material(0)
		if active is ShaderMaterial:
			mat = active
	if mat != null:
		mat.set_shader_parameter(param, value)


## `$camera.effect<N>` tracks: the camera effect's params (and `strength`),
## read back through camera_effect().
func _apply_camera_track(slot: String, track: Dictionary) -> void:
	var value = Interpolation.evaluate(track.get("keyframes", []), playhead)
	if value == null:
		return
	if not _camera_params.has(slot):
		_camera_params[slot] = {}
	_camera_params[slot][String(track.get("param", ""))] = value


## The script's camera effect for CameraFx: {key, params, strength} with
## the tracks' current values applied, or {} if the script has none. Only
## the first enabled effect runs for now.
func camera_effect() -> Dictionary:
	if timeline == null:
		return {}
	var enabled: Array = timeline.camera.get("effects", []).filter(
			func(e): return typeof(e) == TYPE_DICTIONARY and e.get("enabled", true) != false)
	if enabled.is_empty():
		return {}
	var e: Dictionary = enabled[0]
	var params: Dictionary = e.get("params", {}).duplicate() if typeof(e.get("params")) == TYPE_DICTIONARY else {}
	var live: Dictionary = _camera_params.get("effect0", {})
	for k in live:
		params[k] = live[k]
	var strength := float(live.get("strength", e.get("strength", 1.0)))
	params.erase("strength")
	return {"key": _shader_path(String(e.get("shader", ""))), "params": params, "strength": strength}


func _read_transform(t: Dictionary) -> Transform3D:
	var pos := Interpolation.to_vec3(t.get("position", [0, 0, 0]))
	var rot_deg := Interpolation.to_vec3(t.get("rotation_deg", [0, 0, 0]))
	var scl_arr = t.get("scale", [1, 1, 1])
	var scl := Interpolation.to_vec3(scl_arr) if typeof(scl_arr) == TYPE_ARRAY else Vector3.ONE
	var basis := Basis.from_euler(Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z)))
	basis = basis.scaled(scl)
	return Transform3D(basis, pos)
