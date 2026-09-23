@tool
extends RefCounted

## Walks a VJScene root and its child AnimationPlayer, produces a JSON dict
## matching the player's script format (see docs/script_format.md), writes it
## to VJScene.output_path.
##
## Convention (see addon README):
##   - Root is a Node3D with vj_scene.gd (VJScene) attached
##   - Direct children of root are VJ objects, each with `vj_prefab` metadata
##   - A single AnimationPlayer child holds one Animation named "main"
##   - Track paths are relative to root: "<child_name>:position" / ":rotation"
##     / ":scale" / ":visible"
##
## Scripts are referenced via preload rather than `class_name` so the exporter
## can be run headlessly against a fresh project (before Godot has populated
## the global class cache).

const VJSceneScript := preload("res://addons/vj_editor/builtin_prefabs/vj_scene.gd")
const VJScreenScript := preload("res://addons/vj_editor/builtin_prefabs/screen.gd")

const _ANIMATION_NAME := "main"
const _SHADER_KEY_GLOW := "glow"
## Where the player looks for the glow shader when it opens the JSON. Hardcoded
## for now — a future revision can source this from the scene's ShaderMaterial.
const _GLOW_SHADER_PLAYER_PATH := "res://player/screen_glow.gdshader"


static func export_from_root(root: Node) -> void:
	if root == null or root.get_script() != VJSceneScript:
		push_error("VJ export: scene root is not a VJScene. Attach vj_scene.gd to the root Node3D.")
		return
	var scene := root
	if String(scene.output_path).is_empty():
		push_error("VJ export: VJScene.output_path is empty.")
		return

	var result := _build_json(scene)
	if not result.ok:
		push_error("VJ export failed: %s" % result.error)
		return

	var out_path: String = String(scene.output_path)
	var abs_path := ProjectSettings.globalize_path(out_path) if out_path.begins_with("res://") else out_path
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		push_error("VJ export: could not open '%s' for writing (error %d)" % [abs_path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(result.data, "  ", false))
	f.close()
	print("VJ export: wrote %s" % abs_path)


static func _build_json(scene) -> Dictionary:
	var objects := _collect_objects(scene)
	if objects.is_empty():
		return _err("scene has no VJ objects (add prefab instances as direct children of the root)")

	var player := _find_animation_player(scene)
	var animation: Animation = null
	if player != null and player.has_animation(_ANIMATION_NAME):
		animation = player.get_animation(_ANIMATION_NAME)

	var tracks: Array = []
	var uses_glow_shader := false

	# Initial-spawn pass. Any object with `visible = true` in the scene gets
	# a spawn event at t=0 carrying its authored transform and config. A
	# visibility track on the same object then emits transitions *relative
	# to that baseline*, so a track that starts with `true` at t=0 doesn't
	# produce a duplicate spawn.
	for obj in objects:
		if not _node_visible(obj.node):
			continue
		var spawn_event := _make_spawn_event(obj, 0.0)
		var cfg := _config_for(obj.node)
		if not cfg.is_empty():
			spawn_event["config"] = cfg
			if cfg.get("shader", "") == _SHADER_KEY_GLOW:
				uses_glow_shader = true
		tracks.append(spawn_event)

	# Animation-derived tracks (transform channels + visibility → spawn/despawn).
	# Mid-timeline spawn events get the object's config attached so shader
	# params travel with them (matches the initial-spawn pass above).
	if animation != null:
		var by_id: Dictionary = {}
		for o in objects:
			by_id[o.id] = o
		var derived := _tracks_from_animation(animation, objects)
		for t in derived:
			if t.get("action", "") == "spawn":
				var target_obj = by_id.get(String(t.get("id", "")), null)
				if target_obj != null:
					var cfg2 := _config_for(target_obj.node)
					if not cfg2.is_empty():
						t["config"] = cfg2
						if cfg2.get("shader", "") == _SHADER_KEY_GLOW:
							uses_glow_shader = true
			tracks.append(t)

	# Emission order matches the reference JSON: initial spawns first, then
	# transform tracks, then mid-timeline visibility transitions.

	var media := {"video": String(scene.video_relative_path)}
	var meta := {
		"title": String(scene.title),
		"author": String(scene.author),
		"created": String(scene.created),
	}

	var prefabs: Dictionary = {}
	for obj in objects:
		prefabs[obj.prefab_key] = obj.prefab_path
	# Objects reference prefabs by key; every id used in a spawn event must
	# be present here.

	var shaders: Dictionary = {}
	if uses_glow_shader:
		shaders[_SHADER_KEY_GLOW] = _GLOW_SHADER_PLAYER_PATH

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
	var prefab_path: String  # value in the prefabs map (res:// path the player resolves)
	var prefab: String       # alias for spawn.prefab; equals prefab_key
	var node: Node3D


static func _collect_objects(scene) -> Array:
	var out: Array = []
	for child in scene.get_children():
		if child is AnimationPlayer:
			continue
		if not (child is Node3D):
			continue
		# Standard scene furniture — not VJ objects, skip quietly.
		if child is Camera3D or child is Light3D or child is WorldEnvironment:
			continue
		var prefab_meta: String = ""
		if child.has_meta("vj_prefab"):
			prefab_meta = String(child.get_meta("vj_prefab"))
		if prefab_meta.is_empty():
			# Fall back to the scene file if instanced from one.
			var sfp: String = String(child.scene_file_path)
			if not sfp.is_empty():
				prefab_meta = sfp
		if prefab_meta.is_empty():
			push_warning("VJ export: child '%s' has no vj_prefab metadata and no scene_file_path; skipping." % child.name)
			continue

		var resolved := _resolve_prefab(prefab_meta)
		var o := _Obj.new()
		o.id = child.name
		o.prefab_key = resolved.key
		o.prefab = resolved.key
		o.prefab_path = resolved.path
		o.node = child
		out.append(o)
	return out


## Resolves a `vj_prefab` metadata value (either a short builtin key like
## "screen" / "cube", or a `res://…` scene path) to the {key, path} pair that
## goes into the JSON. Short builtin keys map to the player's own prefab
## copies since the player doesn't currently mount the addon.
static func _resolve_prefab(prefab_meta: String) -> Dictionary:
	match prefab_meta:
		"screen": return {"key": "screen", "path": "res://player/prefabs/screen.tscn"}
		"cube": return {"key": "cube", "path": "res://player/prefabs/cube.tscn"}
	if prefab_meta.contains("vj_editor") and prefab_meta.ends_with("/screen.tscn"):
		return {"key": "screen", "path": "res://player/prefabs/screen.tscn"}
	if prefab_meta.contains("vj_editor") and prefab_meta.ends_with("/cube.tscn"):
		return {"key": "cube", "path": "res://player/prefabs/cube.tscn"}
	# Custom prefab path — use the file basename as the key.
	var key := prefab_meta.get_file().get_basename()
	if key.is_empty():
		key = prefab_meta
	return {"key": key, "path": prefab_meta}


static func _find_animation_player(scene) -> AnimationPlayer:
	for child in scene.get_children():
		if child is AnimationPlayer:
			return child
	return null


# ---------- track conversion ----------

static func _tracks_from_animation(animation: Animation, objects: Array) -> Array:
	var out: Array = []
	var by_name: Dictionary = {}
	for obj in objects:
		by_name[obj.id] = obj

	for i in animation.get_track_count():
		if animation.track_get_type(i) != Animation.TYPE_VALUE:
			continue
		var path: NodePath = animation.track_get_path(i)
		var target_name := String(path.get_name(0)) if path.get_name_count() > 0 else ""
		if target_name.is_empty() or not by_name.has(target_name):
			continue
		var prop := ""
		if path.get_subname_count() > 0:
			prop = String(path.get_subname(0))
		match prop:
			"position":
				out.append(_transform_track(animation, i, target_name, "position", false))
			"rotation":
				out.append(_transform_track(animation, i, target_name, "rotation_deg", true))
			"scale":
				out.append(_transform_track(animation, i, target_name, "scale", false))
			"visible":
				var events := _visibility_events(animation, i, target_name, by_name[target_name])
				for e in events:
					out.append(e)
			_:
				push_warning("VJ export: unsupported animated property '%s' on '%s' — skipped." % [prop, target_name])
	return out


static func _transform_track(animation: Animation, track_idx: int, target: String, channel: String, radians_to_degrees: bool) -> Dictionary:
	var interp_str := _interp_str(animation.track_get_interpolation_type(track_idx))
	var kfs: Array = []
	for k in animation.track_get_key_count(track_idx):
		var t := float(animation.track_get_key_time(track_idx, k))
		var val = animation.track_get_key_value(track_idx, k)
		var arr := _vec3_to_array(val, radians_to_degrees)
		var kf := {"t": t, "value": arr}
		# Keyframes carry the track-level interp so the JSON is per-key
		# (matches Interpolation.evaluate's expected shape).
		if interp_str != "linear":
			kf["interp"] = interp_str
		kfs.append(kf)
	return {
		"type": "transform",
		"target": target,
		"channel": channel,
		"keyframes": kfs,
	}


static func _visibility_events(animation: Animation, track_idx: int, target: String, obj: _Obj) -> Array:
	# Baseline is the node's authored visibility in the scene. Transitions
	# in the track relative to that baseline become spawn/despawn events.
	var out: Array = []
	var count := animation.track_get_key_count(track_idx)
	if count == 0:
		return out
	var prev_visible := _node_visible(obj.node)
	for k in count:
		var t := float(animation.track_get_key_time(track_idx, k))
		var v := bool(animation.track_get_key_value(track_idx, k))
		if v == prev_visible:
			continue
		if v:
			out.append(_make_spawn_event(obj, t))
		else:
			out.append({
				"type": "event",
				"t": t,
				"action": "despawn",
				"target": obj.id,
			})
		prev_visible = v
	return out


static func _make_spawn_event(obj: _Obj, t: float) -> Dictionary:
	return {
		"type": "event",
		"t": t,
		"action": "spawn",
		"id": obj.id,
		"prefab": obj.prefab_key,
		"transform": _transform_to_dict(obj.node.transform),
	}


static func _node_visible(node: Node) -> bool:
	if node is Node3D:
		return (node as Node3D).visible
	return true


# ---------- helpers ----------

static func _config_for(node: Node3D) -> Dictionary:
	if node.get_script() != VJScreenScript:
		return {}
	var cfg: Dictionary = {"shader": _SHADER_KEY_GLOW}
	var mat: ShaderMaterial = node.call("get_shader_material")
	if mat != null:
		# Iterate ShaderMaterial's explicit `shader_parameter/<name>` slots
		# rather than the shader's uniform list — the property-list approach
		# works on every Godot 4.x and only surfaces authored values (no
		# defaults from the shader header).
		var params := {}
		for p in mat.get_property_list():
			var full: String = String(p.get("name", ""))
			var prefix := "shader_parameter/"
			if not full.begins_with(prefix):
				continue
			var short_name := full.substr(prefix.length())
			if short_name == "screen_tex":
				continue
			var val = mat.get_shader_parameter(short_name)
			if val == null:
				continue
			params[short_name] = _value_to_json(val)
		if not params.is_empty():
			cfg["shader_params"] = params
	var rscale: float = float(node.get("render_scale"))
	if rscale != 1.0 and rscale > 0.0:
		cfg["render_scale"] = rscale
	return cfg


static func _value_to_json(v):
	match typeof(v):
		TYPE_VECTOR2: return [v.x, v.y]
		TYPE_VECTOR3: return [v.x, v.y, v.z]
		TYPE_VECTOR4: return [v.x, v.y, v.z, v.w]
		TYPE_COLOR: return [v.r, v.g, v.b]
		_: return v


static func _transform_to_dict(x: Transform3D) -> Dictionary:
	var euler := x.basis.get_euler()
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
