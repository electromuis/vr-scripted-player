@tool
extends RefCounted

## Walks a VJScene root and its child AnimationPlayer, produces a JSON dict
## matching the player's script format (see docs/script_format.md), writes it
## to VJScene.output_path.
##
## Convention (see addon README):
##   - Root is a Node3D with vj_scene.gd (VJScene) attached
##   - Its children are VJ objects: builtin prefab instances (`vj_prefab`
##     metadata "screen" / "layer" / "cube"), instances of any other .tscn
##     in the project (custom prefabs, bundled next to the JSON), or plain
##     Node3Ds (optionally with vj_object.gd), which are groups. Nodes added under an object (in this
##     scene, not inside its prefab) are objects too, spawned with
##     `parent`: they move with it and go when it does. Node names are the
##     ids, so they must be unique across the scene
##   - An optional VJViewer child (vj_viewer.gd) is the viewer; its keys
##     become vr_cut events
##   - A single AnimationPlayer child holds one Animation named "main"
##   - Track paths are relative to root, any depth (`<path>` below is e.g.
##     `screens/screen_left`):
##       <path>:position / :rotation / :scale         → transform tracks
##       <path>:visible                               → spawn / despawn events
##       <path>:<...>:shader_parameter/<name>         → shader_param "<id>.surface"
##                                                      ("<id>.layer" on layers)
##       <path>/<effect>:material:shader_parameter/<name>
##                                                    → shader_param "<id>.effect<N>"
##         (<effect> a VJEffect child of a screen or layer, N its place
##         among the enabled ones)
##       <path>:curvature / :vertical_curvature / :opacity (screens, layers)
##                                                    → shader_param "<id>.display"
##       <path>:opacity / :tint / :flash / :speed / :sort_offset (VJObject;
##         opacity only where it's not a screen's or layer's display fade)
##                                                    → shader_param "<id>.modifiers"
##       <path>:spin / :pulse (VJObject)              → shader_param "<id>.reactive"
##       <viewer>:position / :rotation                → vr_cut events
##     Value and bezier tracks both work; bezier tracks (one per component,
##     e.g. `<path>:position:x`) are baked to linear keys.
##
## Scripts are referenced via preload rather than `class_name` so the exporter
## can be run headlessly against a fresh project (before Godot has populated
## the global class cache).

const VJSceneScript := preload("res://addons/vj_editor/builtin_prefabs/vj_scene.gd")
const VJScreenScript := preload("res://addons/vj_editor/builtin_prefabs/screen.gd")
const VJLayerScript := preload("res://addons/vj_editor/builtin_prefabs/layer.gd")
const VJViewerScript := preload("res://addons/vj_editor/builtin_prefabs/vj_viewer.gd")
const VJObjectScript := preload("res://addons/vj_editor/modifiers/vj_object.gd")
const VJEffectScript := preload("res://addons/vj_editor/builtin_prefabs/effect.gd")
const BezierTracksScript := preload("res://addons/vj_editor/exporter/bezier_tracks.gd")

const _ANIMATION_NAME := "main"
## The addon's copies of the player's layer / effect shaders and their
## includes map to the player's own (same file names under this folder).
const _VISUALIZER_ADDON_DIR := "res://addons/vj_editor/visualizer/"
const _VISUALIZER_PLAYER_DIR := "res://player/visualizer/"
const _SHADER_PARAM_PREFIX := "shader_parameter/"
const _DISPLAY_PROPS := ["curvature", "vertical_curvature", "opacity"]
## Bezier tracks are baked to linear keys: samples per second, and how far
## (in the property's units) a dropped sample may stray from the line.
const _BEZIER_BAKE_FPS := 30.0
const _BEZIER_BAKE_TOLERANCE := 0.001
## Builtin prefab keys → the player's copies.
const _PLAYER_PREFABS := {
	"screen": "res://player/prefabs/screen.tscn",
	"layer": "res://player/prefabs/layer.tscn",
	"cube": "res://player/prefabs/cube.tscn",
	"group": "res://player/prefabs/group.tscn",
}
## Uniforms a layer's preview feeds (not authored params).
const _LAYER_INPUTS := ["iChannel0", "iChannel1", "iChannel2", "iChannel3", "iChannelResolution",
		"iResolution", "video_stereo", "audio_level", "audio_bass", "audio_mid", "audio_high"]


## Exports and returns the absolute path of the written JSON ("" on failure).
static func export_from_root(root: Node) -> String:
	if root == null or root.get_script() != VJSceneScript:
		push_error("VJ export: scene root is not a VJScene. Attach vj_scene.gd to the root Node3D.")
		return ""
	var scene := root
	var abs_path := output_path_of(scene)
	if abs_path.is_empty():
		push_error("VJ export: VJScene.output_path is empty.")
		return ""
	var out_dir := abs_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(out_dir)

	var result := _build_json(scene, out_dir)
	if not result.ok:
		push_error("VJ export failed: %s" % result.error)
		return ""

	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		push_error("VJ export: could not open '%s' for writing (error %d)" % [abs_path, FileAccess.get_open_error()])
		return ""
	f.store_string(JSON.stringify(result.data, "  ", false))
	f.close()
	print("VJ export: wrote %s" % abs_path)
	return abs_path


## Absolute filesystem path the scene exports to ("" if unset).
static func output_path_of(scene: Node) -> String:
	var out_path := String(scene.output_path)
	if out_path.is_empty():
		return ""
	if out_path.begins_with("res://") or out_path.begins_with("user://"):
		out_path = ProjectSettings.globalize_path(out_path)
	return out_path.simplify_path()


static func _build_json(scene, out_dir: String) -> Dictionary:
	var collected := _collect_objects(scene, out_dir)
	if not collected.ok:
		return collected
	var objects: Array = collected.objects
	if objects.is_empty():
		return _err("scene has no VJ objects (add prefab instances as children of the root)")

	var player := _find_animation_player(scene)
	var animation: Animation = null
	if player != null and player.has_animation(_ANIMATION_NAME):
		animation = player.get_animation(_ANIMATION_NAME)

	var shaders: Dictionary = {}
	# Spawn / despawn events from each object's (and its parents') visibility.
	# Mid-timeline spawn events get the object's config attached so shader
	# params travel with them.
	var tracks := _presence_events(scene, animation, objects, out_dir, shaders)

	# Animation-derived tracks (transform channels, shader params).
	if animation != null:
		for t in _tracks_from_animation(scene, animation, objects):
			tracks.append(t)
		var viewer := _find_viewer(scene)
		if viewer != null:
			for e in _viewer_cuts(animation, viewer):
				tracks.append(e)

	var media := {"video": String(scene.video_relative_path)}
	if float(scene.duration) > 0.0:
		media["duration"] = float(scene.duration)
	var meta := {
		"title": String(scene.title),
		"author": String(scene.author),
		"created": String(scene.created),
	}

	# Objects reference prefabs by key; every key used in a spawn event must
	# be present here.
	var prefabs: Dictionary = {}
	for obj in objects:
		prefabs[obj.prefab_key] = obj.prefab_path

	var json_root := {
		"format_version": 1,
		"meta": meta,
		"media": media,
		"prefabs": prefabs,
		"shaders": shaders,
		"objects": [],
		"tracks": tracks,
	}
	return {"ok": true, "data": json_root}


# ---------- object collection ----------

class _Obj:
	var id: String
	var prefab_key: String   # key used in the JSON prefabs map + spawn.prefab
	var prefab_path: String  # value in the prefabs map (what the player resolves)
	var node: Node3D
	var parent: _Obj         # null: a child of the root
	var path: String         # NodePath from the root, as tracks name it


## {ok, objects: Array[_Obj] parents before children} or {ok: false, error}.
static func _collect_objects(scene, out_dir: String) -> Dictionary:
	var out: Array = []
	var bundled: Dictionary = {}  # source scene path -> {key, path}
	_collect_under(scene, scene, null, out_dir, bundled, out)
	var seen: Dictionary = {}
	for obj in out:
		if seen.has(obj.id):
			return _err("two objects are named '%s' ('%s' and '%s'); names are the script's ids, so they must be unique across the scene" % [obj.id, seen[obj.id], obj.path])
		seen[obj.id] = obj.path
	return {"ok": true, "objects": out}


static func _collect_under(scene: Node, node: Node, parent: _Obj, out_dir: String, bundled: Dictionary, out: Array) -> void:
	for child in node.get_children():
		# Only nodes placed in this scene: not the insides of a prefab instance.
		if child.owner != scene:
			continue
		if child is AnimationPlayer or not (child is Node3D):
			continue
		# Standard scene furniture (and the viewer) — not VJ objects.
		if child is Camera3D or child is Light3D or child is WorldEnvironment:
			continue
		var resolved = _resolve_prefab(child, out_dir, bundled)
		if resolved == null:
			continue
		var o := _Obj.new()
		o.id = child.name
		o.prefab_key = resolved.key
		o.prefab_path = resolved.path
		o.node = child
		o.parent = parent
		o.path = String(scene.get_path_to(child))
		out.append(o)
		_collect_under(scene, child, o, out_dir, bundled, out)


## {key, path} for `node`'s prefab, or null (skipped, with a warning).
static func _resolve_prefab(node: Node, out_dir: String, bundled: Dictionary):
	var prefab_meta: String = ""
	if node.has_meta("vj_prefab"):
		prefab_meta = String(node.get_meta("vj_prefab"))
	if prefab_meta.is_empty():
		# Fall back to the scene file if instanced from one.
		prefab_meta = String(node.scene_file_path)
	if prefab_meta.is_empty():
		if node.get_class() == "Node3D" and (node.get_script() == null or node.get_script() == VJObjectScript):
			return {"key": "group", "path": _PLAYER_PREFABS["group"]}
		push_warning("VJ export: '%s' has no vj_prefab metadata and no scene_file_path; skipping." % node.name)
		return null
	var resolved = _resolve_builtin_prefab(prefab_meta)
	if resolved != null:
		return resolved
	if bundled.has(prefab_meta):
		return bundled[prefab_meta]
	resolved = _bundle_prefab(prefab_meta, out_dir)
	if resolved != null:
		bundled[prefab_meta] = resolved
	return resolved


## Short builtin keys ("screen" / "layer" / "cube", or the addon's own
## scenes) map to the player's copies of those prefabs. Returns null for
## anything else.
static func _resolve_builtin_prefab(prefab_meta: String):
	var key := ""
	if _PLAYER_PREFABS.has(prefab_meta):
		key = prefab_meta
	elif prefab_meta.contains("vj_editor"):
		for k in ["screen", "layer", "cube"]:
			if prefab_meta.ends_with("/%s.tscn" % k):
				key = k
	if key.is_empty():
		return null
	return {"key": key, "path": _PLAYER_PREFABS[key]}


## Saves a custom prefab next to the JSON (`prefabs/<name>.tscn`) with all
## its external resources — scripts, shaders, materials — embedded, so the
## script folder is self-contained and the player can load it from disk.
## A prefab with no external dependencies is copied byte-for-byte: re-saving
## under --headless would drop data the dummy renderer doesn't keep (e.g.
## MultiMesh instance buffers).
static func _bundle_prefab(src_path: String, out_dir: String):
	var key := src_path.get_file().get_basename()
	var rel := "prefabs/%s.%s" % [key, src_path.get_extension()]
	var dst := out_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	if ResourceLoader.get_dependencies(src_path).is_empty():
		var copy_err := DirAccess.copy_absolute(ProjectSettings.globalize_path(src_path), dst)
		if copy_err != OK:
			push_error("VJ export: could not copy prefab '%s' to '%s' (error %d)." % [src_path, dst, copy_err])
			return null
		return {"key": key, "path": rel}
	var packed := load(src_path) as PackedScene
	if packed == null:
		push_error("VJ export: could not load prefab '%s'." % src_path)
		return null
	var err := ResourceSaver.save(packed, dst, ResourceSaver.FLAG_BUNDLE_RESOURCES)
	if err != OK:
		push_error("VJ export: could not bundle prefab '%s' to '%s' (error %d)." % [src_path, dst, err])
		return null
	return {"key": key, "path": rel}


static func _find_animation_player(scene) -> AnimationPlayer:
	for child in scene.get_children():
		if child is AnimationPlayer:
			return child
	return null


static func _find_viewer(scene) -> Node3D:
	for child in scene.get_children():
		if child.get_script() == VJViewerScript:
			return child
	return null


# ---------- spawn / despawn ----------

## Walks every time a `visible` key changes something and emits a spawn when
## an object becomes present (it and all its parents visible) and a despawn
## when it stops being — except when its parent goes at the same moment,
## which takes it along in the player. Objects come parents-first, so at a
## shared time a group's spawn precedes its children's.
static func _presence_events(scene: Node, animation: Animation, objects: Array, out_dir: String, shaders: Dictionary) -> Array:
	var vis_tracks: Dictionary = {}  # id -> track index
	var times: Array = [0.0]
	if animation != null:
		for obj in objects:
			var track := animation.find_track(NodePath(obj.path + ":visible"), Animation.TYPE_VALUE)
			if track < 0:
				continue
			vis_tracks[obj.id] = track
			for k in animation.track_get_key_count(track):
				var t := maxf(0.0, animation.track_get_key_time(track, k))
				if not times.has(t):
					times.append(t)
	times.sort()

	var out: Array = []
	var present: Dictionary = {}  # id -> bool, as of the previous time
	for t in times:
		var now: Dictionary = {}
		for obj in objects:
			var parent_here: bool = obj.parent == null or now[obj.parent.id]
			var here := parent_here and _visible_at(animation, vis_tracks.get(obj.id, -1), obj.node, t)
			var was: bool = present.get(obj.id, false)
			if here and not was:
				out.append(_make_spawn_event(obj, t, out_dir, shaders))
			elif was and not here and parent_here:
				out.append({"type": "event", "t": t, "action": "despawn", "target": obj.id})
			now[obj.id] = here
		present = now
	return out


## The node's visibility at `t`: its last `visible` key at or before `t`,
## or the scene's value before the first key (or without a track).
static func _visible_at(animation: Animation, track: int, node: Node3D, t: float) -> bool:
	var v := node.visible
	if track < 0:
		return v
	for k in animation.track_get_key_count(track):
		if animation.track_get_key_time(track, k) > t:
			break
		v = bool(animation.track_get_key_value(track, k))
	return v


static func _make_spawn_event(obj: _Obj, t: float, out_dir: String, shaders: Dictionary) -> Dictionary:
	var ev := {
		"type": "event",
		"t": t,
		"action": "spawn",
		"id": obj.id,
		"prefab": obj.prefab_key,
		"transform": _transform_to_dict(obj.node.transform),
	}
	if obj.parent != null:
		ev["parent"] = obj.parent.id
	var cfg := _config_for(obj.node, out_dir, shaders)
	if not cfg.is_empty():
		ev["config"] = cfg
	return ev


# ---------- track conversion ----------

static func _tracks_from_animation(scene: Node, animation: Animation, objects: Array) -> Array:
	var out: Array = []
	var by_path: Dictionary = {}
	for obj in objects:
		by_path[obj.path] = obj

	# property path String -> {obj, node, effect, path, comps: {component -> track}}
	var bezier_groups: Dictionary = {}
	for i in animation.get_track_count():
		var type := animation.track_get_type(i)
		if type != Animation.TYPE_VALUE and type != Animation.TYPE_BEZIER:
			continue
		var path: NodePath = animation.track_get_path(i)
		var names: Array = []
		for n in path.get_name_count():
			names.append(String(path.get_name(n)))
		var obj: _Obj = by_path.get("/".join(names))
		var node: Node = obj.node if obj != null else null
		var effect := -1
		if obj == null and names.size() > 1:
			# A VJEffect under a screen or layer: its params go to the
			# parent's `effect<N>` slot.
			obj = by_path.get("/".join(names.slice(0, -1)))
			node = scene.get_node_or_null(NodePath("/".join(names)))
			if obj == null or node == null or node.get_script() != VJEffectScript:
				continue
			effect = obj.node.call("effect_nodes").find(node) if obj.node.has_method("effect_nodes") else -1
			if effect < 0:
				continue  # disabled, or no shader: not exported
		if obj == null:
			continue
		if path.get_subname_count() == 0:
			push_warning("VJ export: track '%s' must target a property — skipped." % path)
			continue
		if type == Animation.TYPE_VALUE:
			_route_track(out, obj, effect, path, _value_track_keys(animation, i))
			continue
		# Bezier tracks animate one float each; a vector's or colour's
		# components (`position:x`, `glow_tint:r`) are regrouped into the
		# property and baked together.
		var split := BezierTracksScript.split_component(node, path)
		var prop_path: NodePath = split[0]
		var group: Dictionary = bezier_groups.get(String(prop_path), {})
		if group.is_empty():
			group = {"obj": obj, "node": node, "effect": effect, "path": prop_path, "comps": {}}
			bezier_groups[String(prop_path)] = group
		group.comps[split[1]] = i
	for group in bezier_groups.values():
		_route_track(out, group.obj, group.effect, group.path, _bake_bezier(animation, group.node, group.path, group.comps))
	return out


## `effect` >= 0: the track animates that effect (a VJEffect child of
## `obj`); only its shader params export.
static func _route_track(out: Array, obj: _Obj, effect: int, path: NodePath, keys: Array) -> void:
	if effect < 0:
		_append_track(out, obj, path, keys)
		return
	var last := String(path.get_subname(path.get_subname_count() - 1))
	if String(path.get_subname(0)) != "material" or not last.begins_with(_SHADER_PARAM_PREFIX):
		push_warning("VJ export: only an effect's material:shader_parameter/<name> animates ('%s') — skipped." % path)
		return
	out.append(_shader_param_track(keys, "%s.effect%d" % [obj.id, effect], last.substr(_SHADER_PARAM_PREFIX.length())))


## Routes one animated property of `obj` to its player track. `keys` are
## {t, value, interp?} with the raw Godot values.
static func _append_track(out: Array, obj: _Obj, path: NodePath, keys: Array) -> void:
	var id := obj.id
	var prop := String(path.get_subname(0))
	var mod_slot := _modifier_slot(obj.node, prop)
	if mod_slot != "":
		out.append(_shader_param_track(keys, "%s.%s" % [id, mod_slot], prop, true))
		return
	var last := String(path.get_subname(path.get_subname_count() - 1))
	if last.begins_with(_SHADER_PARAM_PREFIX):
		var slot := "layer" if obj.node.get_script() == VJLayerScript else "surface"
		out.append(_shader_param_track(keys, "%s.%s" % [id, slot], last.substr(_SHADER_PARAM_PREFIX.length())))
		return
	match prop:
		"position":
			out.append(_transform_track(keys, id, "position", false))
		"rotation":
			out.append(_transform_track(keys, id, "rotation_deg", true))
		"scale":
			out.append(_transform_track(keys, id, "scale", false))
		"visible":
			pass  # _presence_events
		_:
			if prop in _DISPLAY_PROPS:
				out.append(_shader_param_track(keys, id + ".display", prop))
			else:
				push_warning("VJ export: unsupported animated property '%s' on '%s' — skipped." % [path.get_concatenated_subnames(), obj.path])


static func _transform_track(keys: Array, target: String, channel: String, radians_to_degrees: bool) -> Dictionary:
	var kfs: Array = []
	for key in keys:
		kfs.append(_keyframe(key, _vec3_to_array(key.value, radians_to_degrees)))
	return {
		"type": "transform",
		"target": target,
		"channel": channel,
		"keyframes": kfs,
	}


## `with_alpha`: colours keep their alpha (modifiers' flash uses it).
static func _shader_param_track(keys: Array, target: String, param: String, with_alpha: bool = false) -> Dictionary:
	var kfs: Array = []
	for key in keys:
		kfs.append(_keyframe(key, _value_to_json(key.value, with_alpha)))
	return {
		"type": "shader_param",
		"target": target,
		"param": param,
		"keyframes": kfs,
	}


static func _keyframe(key: Dictionary, value) -> Dictionary:
	var kf := {"t": float(key.t), "value": value}
	var interp: String = key.get("interp", "linear")
	if interp != "linear":
		kf["interp"] = interp
	return kf


## A value track's keys. They carry the track-level interp so the JSON is
## per-key (matches Interpolation.evaluate's expected shape). Discrete
## tracks hold each value until the next key, i.e. "step".
static func _value_track_keys(animation: Animation, track_idx: int) -> Array:
	var interp := _interp_str(animation.track_get_interpolation_type(track_idx))
	if animation.value_track_get_update_mode(track_idx) == Animation.UPDATE_DISCRETE:
		interp = "step"
	var keys: Array = []
	for k in animation.track_get_key_count(track_idx):
		keys.append({
			"t": animation.track_get_key_time(track_idx, k),
			"value": animation.track_get_key_value(track_idx, k),
			"interp": interp,
		})
	return keys


## Samples a property's bezier tracks (`comps`: component -> track, "" for
## a plain float) into linear keys: every key time plus _BEZIER_BAKE_FPS
## samples between, dropping samples a straight line already reproduces
## (so a linear segment stays two keys). Components without a track hold
## the node's current value.
static func _bake_bezier(animation: Animation, node: Node, prop_path: NodePath, comps: Dictionary) -> Array:
	var key_times: Array = []
	for track in comps.values():
		for k in animation.track_get_key_count(track):
			var t := animation.track_get_key_time(track, k)
			if not key_times.has(t):
				key_times.append(t)
	key_times.sort()
	if key_times.is_empty():
		return []

	var base = 0.0 if comps.has("") else node.get_indexed(NodePath(prop_path.get_concatenated_subnames()))
	if base == null:
		base = BezierTracksScript.zero_for_components(comps.keys())
	var sample := func(t: float):
		if comps.has(""):
			return animation.bezier_track_interpolate(comps[""], t)
		var v = base
		for c in comps:
			v[BezierTracksScript.component_index(c)] = animation.bezier_track_interpolate(comps[c], t)
		return v

	var keys: Array = [{"t": key_times[0], "value": sample.call(key_times[0])}]
	for s in range(1, key_times.size()):
		var t0: float = key_times[s - 1]
		var t1: float = key_times[s]
		var steps := maxi(1, ceili((t1 - t0) * _BEZIER_BAKE_FPS))
		var run: Array = []  # samples after the previous key time, ending at t1
		for n in range(1, steps + 1):
			var t := t1 if n == steps else t0 + (t1 - t0) * n / steps
			run.append({"t": t, "value": sample.call(t)})
		# Greedy: extend the line from the last kept key while every sample
		# it skips stays on it; keep the sample where it would break. Each
		# skipped sample narrows the slopes the line may have (per
		# component), so checking the next sample is O(1), not a rescan.
		var i := 0
		while i < run.size():
			var a: Dictionary = keys[-1]
			var a_v := _float_components(a.value)
			var lo := PackedFloat64Array()
			var hi := PackedFloat64Array()
			lo.resize(a_v.size())
			hi.resize(a_v.size())
			lo.fill(-INF)
			hi.fill(INF)
			var j := i
			while j + 1 < run.size():
				_narrow_slopes(lo, hi, a.t, a_v, run[j])
				if not _slopes_allow(lo, hi, a.t, a_v, run[j + 1]):
					break
				j += 1
			keys.append(run[j])
			i = j + 1
	return keys


## Narrows each component's allowed slope range (from anchor time `a_t`,
## values `a_v`) so a line through the anchor passes within
## _BEZIER_BAKE_TOLERANCE of sample `p`.
static func _narrow_slopes(lo: PackedFloat64Array, hi: PackedFloat64Array, a_t: float, a_v: PackedFloat64Array, p: Dictionary) -> void:
	var dt: float = p.t - a_t
	var v := _float_components(p.value)
	for c in a_v.size():
		lo[c] = maxf(lo[c], (v[c] - _BEZIER_BAKE_TOLERANCE - a_v[c]) / dt)
		hi[c] = minf(hi[c], (v[c] + _BEZIER_BAKE_TOLERANCE - a_v[c]) / dt)


## Whether the line from the anchor to `b` stays inside every slope range.
static func _slopes_allow(lo: PackedFloat64Array, hi: PackedFloat64Array, a_t: float, a_v: PackedFloat64Array, b: Dictionary) -> bool:
	var dt: float = b.t - a_t
	var v := _float_components(b.value)
	for c in a_v.size():
		var slope := (v[c] - a_v[c]) / dt
		if slope < lo[c] or slope > hi[c]:
			return false
	return true


static func _float_components(value) -> PackedFloat64Array:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return PackedFloat64Array([float(value)])
	var out := PackedFloat64Array()
	for c in BezierTracksScript.component_count(value):
		out.append(value[c])
	return out


## Every viewer key after t=0 is a cut. With a fade, the event starts half
## the fade early so the jump happens at peak black, on the key's time —
## which is also when the editor preview (the camera itself) jumps.
static func _viewer_cuts(animation: Animation, viewer: Node3D) -> Array:
	var pos_track := animation.find_track(NodePath("%s:position" % viewer.name), Animation.TYPE_VALUE)
	var rot_track := animation.find_track(NodePath("%s:rotation" % viewer.name), Animation.TYPE_VALUE)
	var times: Array = []
	for track in [pos_track, rot_track]:
		if track < 0:
			continue
		for k in animation.track_get_key_count(track):
			var t := float(animation.track_get_key_time(track, k))
			if t > 0.0 and not times.has(t):
				times.append(t)
	times.sort()

	var fade := float(viewer.fade_duration) if String(viewer.transition) == "fade_to_black" else 0.0
	var out: Array = []
	for t in times:
		var pos: Vector3 = animation.value_track_interpolate(pos_track, t) if pos_track >= 0 else viewer.position
		var rot: Vector3 = animation.value_track_interpolate(rot_track, t) if rot_track >= 0 else viewer.rotation
		var ev := {
			"type": "event",
			"t": maxf(0.0, t - fade * 0.5),
			"action": "vr_cut",
			"to": {
				"position": _vec3_to_array(pos, false),
				"rotation_deg": _vec3_to_array(rot, true),
			},
		}
		if fade > 0.0:
			ev["transition"] = {"type": "fade_to_black", "duration": fade}
		out.append(ev)
	return out


# ---------- config ----------

## An object's spawn config: a screen's or layer's own settings, plus its
## VJObject modifier / reactive fields (non-default ones). Registers the
## shaders it uses in `shaders` (copying custom ones next to the JSON).
static func _config_for(node: Node3D, out_dir: String, shaders: Dictionary) -> Dictionary:
	var cfg := _look_config(node, out_dir, shaders)
	if not node.has_method("modifier_values"):
		return cfg
	var mods := {}
	for field in VJObjectScript.MODIFIER_FIELDS:
		if _modifier_slot(node, field) == "":
			continue  # a screen's opacity: already in cfg
		var v = node.get(field)
		if v != VJObjectScript.Mods.DEFAULTS[field]:
			mods[field] = _value_to_json(v, true)
	if not mods.is_empty():
		cfg["modifiers"] = mods
	var reactive := {}
	for field in VJObjectScript.REACTIVE_FIELDS:
		var v = node.get(field)
		if v != VJObjectScript.Mods.REACTIVE_DEFAULTS[field]:
			reactive[field] = _value_to_json(v)
	if not reactive.is_empty():
		cfg["reactive"] = reactive
	return cfg


## "modifiers" / "reactive" when `prop` is one of the object's VJObject
## fields, else "" (a screen's or layer's opacity is its display fade).
static func _modifier_slot(node: Node, prop: String) -> String:
	if not node.has_method("modifier_values"):
		return ""
	if prop in VJObjectScript.REACTIVE_FIELDS:
		return "reactive"
	if prop in VJObjectScript.MODIFIER_FIELDS:
		var script = node.get_script()
		var is_screen: bool = script == VJScreenScript or script == VJLayerScript
		return "" if is_screen and prop == "opacity" else "modifiers"
	return ""


## A screen's or layer's own settings; {} for anything else.
static func _look_config(node: Node3D, out_dir: String, shaders: Dictionary) -> Dictionary:
	var script = node.get_script()
	if script != VJScreenScript and script != VJLayerScript:
		return {}
	var is_layer: bool = script == VJLayerScript
	var cfg: Dictionary = {}
	var mat: ShaderMaterial = node.call("get_shader_material")
	if mat != null and mat.shader != null:
		var key := _register_shader(mat.shader, out_dir, shaders)
		if not key.is_empty():
			cfg["shader"] = key
		# Only authored values travel (no defaults from the shader header).
		var params := _authored_params(mat, _LAYER_INPUTS if is_layer else ["screen_tex"])
		if not params.is_empty():
			cfg["params" if is_layer else "shader_params"] = params
	var rscale: float = float(node.get("render_scale"))
	if rscale != 1.0 and rscale > 0.0:
		cfg["resolution" if is_layer else "render_scale"] = rscale
	for prop in ["curvature", "vertical_curvature"]:
		if float(node.get(prop)) > 0.0:
			cfg[prop] = float(node.get(prop))
	if float(node.get("opacity")) < 1.0:
		cfg["opacity"] = float(node.get("opacity"))
	var effects := _effects_config(node, out_dir, shaders)
	if not effects.is_empty():
		cfg["effects"] = effects
	return cfg


## The enabled VJEffect children, in order, as `config.effects` (their
## index is the `effect<N>` track target).
static func _effects_config(node: Node3D, out_dir: String, shaders: Dictionary) -> Array:
	if not node.call("legacy_effects").is_empty():
		push_warning("VJ export: '%s' still has effect_1..4 slots, which no longer export. Run Tools > VJ: Convert effect slots to nodes." % node.name)
	var out: Array = []
	for mat in node.call("effect_materials"):
		var e := {"shader": _register_shader(mat.shader, out_dir, shaders)}
		var params := _authored_params(mat, ["input_tex", "display_aspect", "picture_rect", "picture_corners", "prepass_tex", "prepass"])
		if not params.is_empty():
			e["params"] = params
		out.append(e)
	return out


## The material's explicitly set `shader_parameter/<name>` values, minus
## `skip`, as JSON values.
static func _authored_params(mat: ShaderMaterial, skip: Array) -> Dictionary:
	var params := {}
	for p in mat.get_property_list():
		var full: String = String(p.get("name", ""))
		if not full.begins_with(_SHADER_PARAM_PREFIX):
			continue
		var short_name := full.substr(_SHADER_PARAM_PREFIX.length())
		if skip.has(short_name):
			continue
		var val = mat.get_shader_parameter(short_name)
		if val == null or val is Object:
			continue
		params[short_name] = _value_to_json(val)
	return params


## The addon's copies of the player's layer / effect shaders map to the
## player's builtin copies; any other shader file is
## copied to `shaders/` next to the JSON, its includes of the addon's
## visualizer files pointed at the player's. Returns the key.
static func _register_shader(shader: Shader, out_dir: String, shaders: Dictionary) -> String:
	var src := shader.resource_path
	if src.is_empty() or src.contains("::"):
		push_warning("VJ export: built-in (unsaved) shaders aren't supported — save the shader to a .gdshader file.")
		return ""
	var key := src.get_file().get_basename()
	if src.begins_with(_VISUALIZER_ADDON_DIR):
		shaders[key] = _VISUALIZER_PLAYER_DIR + src.substr(_VISUALIZER_ADDON_DIR.length())
		return key
	var rel := "shaders/%s" % src.get_file()
	var dst := out_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		push_error("VJ export: could not write shader '%s'." % dst)
		return ""
	f.store_string(shader.code.replace(_VISUALIZER_ADDON_DIR, _VISUALIZER_PLAYER_DIR))
	f.close()
	shaders[key] = rel
	return key


# ---------- helpers ----------

static func _value_to_json(v, with_alpha: bool = false):
	match typeof(v):
		TYPE_VECTOR2: return [v.x, v.y]
		TYPE_VECTOR3: return [v.x, v.y, v.z]
		TYPE_VECTOR4: return [v.x, v.y, v.z, v.w]
		TYPE_COLOR: return [v.r, v.g, v.b, v.a] if with_alpha else [v.r, v.g, v.b]
		_: return v


static func _transform_to_dict(x: Transform3D) -> Dictionary:
	# Orthonormalized: get_euler() on a scaled basis gives wrong angles.
	var euler := x.basis.orthonormalized().get_euler()
	return {
		"position": [x.origin.x, x.origin.y, x.origin.z],
		"rotation_deg": [rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z)],
		"scale": [x.basis.get_scale().x, x.basis.get_scale().y, x.basis.get_scale().z],
	}


static func _vec3_to_array(v, radians_to_degrees: bool) -> Array:
	if v is Vector3:
		if radians_to_degrees:
			return [rad_to_deg(v.x), rad_to_deg(v.y), rad_to_deg(v.z)]
		return [v.x, v.y, v.z]
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		return [float(v[0]), float(v[1]), float(v[2])]
	return [0.0, 0.0, 0.0]


static func _interp_str(godot_interp: int) -> String:
	match godot_interp:
		Animation.INTERPOLATION_NEAREST: return "step"
		Animation.INTERPOLATION_CUBIC, Animation.INTERPOLATION_CUBIC_ANGLE: return "cubic"
		_: return "linear"


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
