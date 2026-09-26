@tool
extends RefCounted

## Builds a VJ scene (VJScene root, prefab instances, AnimationPlayer "main",
## VJViewer) from a script JSON: the exporter (exporter/scene_exporter.gd)
## in reverse. The JSON stays the master copy: import it into an empty
## project, edit, and the scene's output_path points the export back at it.
##
## Exact for what the exporter writes, so exporting an imported script gives
## the same script. Hand-written scripts can say things a scene can't; those
## are converted and reported as warnings:
##   - a track mixing interpolations becomes Bezier tracks ("ease" and
##     "cubic" segments turn into the handles that draw the same curve; a
##     "step" among others holds until 1 ms before the next key)
##   - an "ease" track becomes Bezier (Godot has no smoothstep track)
##   - an object spawned more than once keeps its first spawn's prefab,
##     transform, parent and config
##   - cuts share one transition in the scene (VJViewer's); vr_teleport,
##     top-level `objects` and media.audio have no place in the scene
##
## Files: a bundled custom prefab (`prefabs/x.tscn` next to the JSON) is
## copied into `<dest_dir>/prefabs/`, a custom shader into
## `<dest_dir>/shaders/` (its includes of the player's visualizer files
## pointed at the addon's copies). The player's own prefabs and shaders map
## to the addon's builtins.

const VJSceneScript := preload("res://addons/vj_editor/builtin_prefabs/vj_scene.gd")
const VJScreenScript := preload("res://addons/vj_editor/builtin_prefabs/screen.gd")
const VJLayerScript := preload("res://addons/vj_editor/builtin_prefabs/layer.gd")
const VJViewerScript := preload("res://addons/vj_editor/builtin_prefabs/vj_viewer.gd")
const VJObjectScript := preload("res://addons/vj_editor/modifiers/vj_object.gd")
const VJEffectScript := preload("res://addons/vj_editor/builtin_prefabs/effect.gd")
const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")

const SUPPORTED_VERSION := 2
const _ANIMATION_NAME := "main"
const _ADDON_PREFABS := {
	"screen": "res://addons/vj_editor/builtin_prefabs/screen.tscn",
	"layer": "res://addons/vj_editor/builtin_prefabs/layer.tscn",
	"cube": "res://addons/vj_editor/builtin_prefabs/cube.tscn",
}
const _PLAYER_VISUALIZER := "res://player/visualizer/"
const _ADDON_VISUALIZER := "res://addons/vj_editor/visualizer/"
const _COMPONENTS := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_COLOR: ["r", "g", "b", "a"],
}
## A "step" segment inside a Bezier track holds until this long before the
## next key, then jumps (Bezier tracks can't hold).
const _STEP_EDGE := 0.001


## Builds the scene for the script at `json_path`, copying custom prefabs
## and shaders under `dest_dir`. Returns {ok, root, warnings} (the caller
## owns `root`) or {ok: false, error}.
static func build_scene(json_path: String, dest_dir: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(json_path)
	if text.is_empty():
		return _err("could not read '%s'" % json_path)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return _err("'%s' is not a JSON object" % json_path)
	var version := int(data.get("format_version", 0))
	if version < 1 or version > SUPPORTED_VERSION:
		return _err("format_version %s isn't supported (1 to %d)" % [data.get("format_version"), SUPPORTED_VERSION])
	var ctx := _Ctx.new()
	ctx.base_dir = ProjectSettings.globalize_path(json_path).get_base_dir()
	ctx.dest_dir = dest_dir
	ctx.prefabs = data.get("prefabs", {})
	ctx.shader_keys = data.get("shaders", {})
	var tracks: Array = data.get("tracks", [])
	if version < 2:
		_upgrade_v1(tracks)

	var root := Node3D.new()
	root.name = "Main"
	root.set_script(VJSceneScript)
	ctx.root = root
	var meta: Dictionary = data.get("meta", {})
	root.title = String(meta.get("title", ""))
	root.author = String(meta.get("author", ""))
	root.created = String(meta.get("created", ""))
	for k in meta:
		if not k in ["title", "author", "created"]:
			ctx.warn("meta.%s has no place in the scene; dropped" % k)
	var media: Dictionary = data.get("media", {})
	root.video_relative_path = String(media.get("video", ""))
	root.duration = float(media.get("duration", 0.0))
	if media.get("audio") != null:
		ctx.warn("media.audio isn't supported by the scene; dropped")
	root.output_path = ProjectSettings.globalize_path(json_path)
	if not data.get("objects", []).is_empty():
		ctx.warn("top-level `objects` are ignored by the player; dropped (use spawn events)")

	var anim := Animation.new()
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	player.owner = root
	var lib := AnimationLibrary.new()
	lib.add_animation(_ANIMATION_NAME, anim)
	player.add_animation_library("", lib)
	player.autoplay = _ANIMATION_NAME
	ctx.anim = anim

	var events: Array = []
	var cuts: Array = []
	for t in tracks:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		if t.get("type") == "event":
			match String(t.get("action", "")):
				"spawn", "despawn": events.append(t)
				"vr_cut": cuts.append(t)
				var action: ctx.warn("%s event at %.3fs has no place in the scene; dropped" % [action, float(t.get("t", 0.0))])
	# By time, keeping the file's order at equal times (parents spawn first).
	var order: Array = range(events.size())
	order.sort_custom(func(a, b):
		var ta := float(events[a].get("t", 0.0))
		var tb := float(events[b].get("t", 0.0))
		return ta < tb or (ta == tb and a < b))
	events = order.map(func(i): return events[i])
	_build_objects(ctx, events)
	_build_presence(ctx, events)
	for t in tracks:
		if typeof(t) == TYPE_DICTIONARY and t.get("type") in ["transform", "shader_param"]:
			_build_track(ctx, t)
	_build_viewer(ctx, cuts)
	var length := float(media.get("duration", 0.0))
	for i in anim.get_track_count():
		for k in anim.track_get_key_count(i):
			length = maxf(length, anim.track_get_key_time(i, k))
	anim.length = maxf(length, 0.001)
	return {"ok": true, "root": root, "warnings": ctx.warnings}


## Imports `json_path` into this project: res://main.tscn (made the main
## scene) plus prefabs/ and shaders/. Only into an empty project — one with
## no scenes outside addons/ — so nothing already there gets merged.
## Returns {ok, scene_path, warnings} or {ok: false, error}.
static func import_into_project(json_path: String) -> Dictionary:
	var existing := _scenes_under("res://")
	if not existing.is_empty():
		return _err("the project already has scenes (%s); import only into an empty project" % ", ".join(existing.slice(0, 3)))
	var built := build_scene(json_path, "res://")
	if not built.ok:
		return built
	var root: Node = built.root
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK:
		return _err("could not pack the scene (error %d)" % err)
	var scene_path := "res://main.tscn"
	err = ResourceSaver.save(packed, scene_path)
	if err != OK:
		return _err("could not save %s (error %d)" % [scene_path, err])
	ProjectSettings.set_setting("application/run/main_scene", scene_path)
	ProjectSettings.save()
	return {"ok": true, "scene_path": scene_path, "warnings": built.warnings}


# ---------- context ----------

class _Ctx:
	var root: Node3D
	var anim: Animation
	var base_dir: String   # the JSON's folder (absolute)
	var dest_dir: String   # where custom prefabs / shaders are copied
	var prefabs: Dictionary
	var shader_keys: Dictionary
	var nodes: Dictionary = {}     # id -> Node3D
	var parents: Dictionary = {}   # id -> parent id ("" at the root)
	var shaders: Dictionary = {}   # key -> Shader (null: unresolvable)
	var packed: Dictionary = {}    # prefab key -> PackedScene (null: unresolvable)
	var warnings: Array = []

	func warn(msg: String) -> void:
		warnings.append(msg)
		push_warning("VJ import: " + msg)


static func _err(msg: String) -> Dictionary:
	push_error("VJ import: " + msg)
	return {"ok": false, "error": msg}


## v1's "cubic" was the per-segment smoothstep v2 calls "ease".
static func _upgrade_v1(tracks: Array) -> void:
	for t in tracks:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		for kf in t.get("keyframes", []):
			if typeof(kf) == TYPE_DICTIONARY and kf.get("interp") == "cubic":
				kf["interp"] = "ease"


static func _scenes_under(dir: String) -> Array:
	var out: Array = []
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() in ["tscn", "scn"]:
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with(".") or (dir == "res://" and d == "addons"):
			continue
		out.append_array(_scenes_under(dir.path_join(d)))
	return out


# ---------- objects ----------

## One node per id, from its first spawn (parents before children: the
## player spawns in time order, so a parent's first spawn comes first).
static func _build_objects(ctx: _Ctx, events: Array) -> void:
	var first: Dictionary = {}  # id -> spawn event
	for ev in events:
		if ev.action != "spawn":
			continue
		var id := String(ev.get("id", ""))
		if id.is_empty():
			continue
		if not first.has(id):
			first[id] = ev
			_spawn_node(ctx, ev)
		elif not _same_spawn(first[id], ev):
			ctx.warn("'%s' is spawned again at %.3fs with a different prefab, transform, parent or config; the scene keeps the first" % [id, float(ev.get("t", 0.0))])


static func _same_spawn(a: Dictionary, b: Dictionary) -> bool:
	for k in ["prefab", "transform", "parent", "config"]:
		if JSON.stringify(a.get(k)) != JSON.stringify(b.get(k)):
			return false
	return true


static func _spawn_node(ctx: _Ctx, ev: Dictionary) -> void:
	var id := String(ev.id)
	var node := _instantiate(ctx, String(ev.get("prefab", "")), id)
	if node == null:
		return
	node.name = id
	if String(node.name) != id:
		ctx.warn("id '%s' isn't a valid node name; it becomes '%s'" % [id, node.name])
	var parent_id := String(ev.get("parent", ""))
	var parent: Node = ctx.root
	if not parent_id.is_empty():
		if ctx.nodes.has(parent_id):
			parent = ctx.nodes[parent_id]
		else:
			ctx.warn("'%s' has parent '%s', which isn't spawned before it; put at the top" % [id, parent_id])
			parent_id = ""
	parent.add_child(node)
	node.owner = ctx.root
	ctx.nodes[id] = node
	ctx.parents[id] = parent_id
	node.transform = _transform_from(ev.get("transform", {}))
	_apply_config(ctx, node, ev.get("config", {}), id)


## The addon's builtin for a player prefab, a plain Node3D (VJObject) for a
## group, or the bundled custom prefab copied into the project.
static func _instantiate(ctx: _Ctx, key: String, id: String) -> Node3D:
	var path := String(ctx.prefabs.get(key, ""))
	if path.is_empty():
		ctx.warn("'%s' uses prefab '%s', which isn't in `prefabs`; skipped" % [id, key])
		return null
	var builtin := ""
	for k in SceneExporterScript._PLAYER_PREFABS:
		if SceneExporterScript._PLAYER_PREFABS[k] == path:
			builtin = k
	if builtin == "group":
		var group := Node3D.new()
		group.set_script(VJObjectScript)
		return group
	if not builtin.is_empty():
		return (load(_ADDON_PREFABS[builtin]) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if not ctx.packed.has(key):
		ctx.packed[key] = _copy_prefab(ctx, key, path)
	var scene: PackedScene = ctx.packed[key]
	if scene == null:
		return null
	var node := scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if not node is Node3D:
		ctx.warn("prefab '%s' isn't a 3D scene; '%s' skipped" % [key, id])
		node.free()
		return null
	# Opacity, tint, spin & co. live on VJObject (the prefab file stays as is).
	if node.get_script() == null:
		node.set_script(VJObjectScript)
	return node


## Copies a bundled prefab to `<dest_dir>/prefabs/<key>.<ext>` (named by its
## key, which is what the exporter will call it again) and loads it.
static func _copy_prefab(ctx: _Ctx, key: String, path: String) -> PackedScene:
	if path.begins_with("res://"):
		ctx.warn("prefab '%s' is the player's own '%s', which the addon has no copy of" % [key, path])
		return null
	var src := path if path.is_absolute_path() else ctx.base_dir.path_join(path).simplify_path()
	if not FileAccess.file_exists(src):
		ctx.warn("prefab '%s': '%s' not found" % [key, src])
		return null
	var dst := ctx.dest_dir.path_join("prefabs/%s.%s" % [key, src.get_extension()])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
	var err := DirAccess.copy_absolute(src, ProjectSettings.globalize_path(dst))
	if err != OK:
		ctx.warn("prefab '%s': could not copy to '%s' (error %d)" % [key, dst, err])
		return null
	var scene := ResourceLoader.load(dst, "PackedScene", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	if scene == null:
		ctx.warn("prefab '%s': '%s' didn't load" % [key, dst])
	return scene


static func _transform_from(t: Dictionary) -> Transform3D:
	var pos := _vec3(t.get("position", [0, 0, 0]))
	var rot := _vec3(t.get("rotation_deg", [0, 0, 0]))
	var scl := _vec3(t.get("scale", [1, 1, 1]))
	var basis := Basis.from_euler(Vector3(deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z)))
	return Transform3D(basis * Basis.from_scale(scl), pos)


static func _apply_config(ctx: _Ctx, node: Node3D, cfg, id: String) -> void:
	if typeof(cfg) != TYPE_DICTIONARY:
		return
	var script = node.get_script()
	var is_layer: bool = script == VJLayerScript
	if script == VJScreenScript or is_layer:
		if cfg.has("shader"):
			var shader := _shader(ctx, String(cfg.shader))
			if shader != null:
				var mat := ShaderMaterial.new()
				mat.shader = shader
				_set_params(mat, cfg.get("params" if is_layer else "shader_params", {}))
				node.shader_material = mat
		var rscale := "resolution" if is_layer else "render_scale"
		if cfg.has(rscale):
			node.render_scale = float(cfg[rscale])
		for prop in ["curvature", "vertical_curvature", "opacity"]:
			if cfg.has(prop):
				node.set(prop, float(cfg[prop]))
		var names: Dictionary = {}
		for e in cfg.get("effects", []):
			_add_effect(ctx, node, e, names)
	elif cfg.has("shader") or cfg.has("effects") or cfg.has("shader_params"):
		ctx.warn("'%s' isn't a screen or layer; its shader / effects config is dropped" % id)
	for group in ["modifiers", "reactive"]:
		var values = cfg.get(group, {})
		if typeof(values) != TYPE_DICTIONARY or values.is_empty():
			continue
		if not node.has_method("modifier_values"):
			ctx.warn("'%s' has its own script, so no VJObject fields; its %s are dropped" % [id, group])
			continue
		for field in values:
			if field in VJObjectScript.MODIFIER_FIELDS or field in VJObjectScript.REACTIVE_FIELDS:
				node.set(field, _to_type(values[field], node.get(field)))


static func _add_effect(ctx: _Ctx, node: Node3D, e, names: Dictionary) -> void:
	if typeof(e) != TYPE_DICTIONARY:
		return
	var key := String(e.get("shader", ""))
	var shader := _shader(ctx, key)
	if shader == null:
		return
	var effect := Node.new()
	effect.set_script(VJEffectScript)
	names[key] = int(names.get(key, 0)) + 1
	effect.name = key if names[key] == 1 else "%s_%d" % [key, names[key]]
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_set_params(mat, e.get("params", {}))
	effect.material = mat
	effect.enabled = e.get("enabled", true) != false
	node.add_child(effect)
	effect.owner = ctx.root


## The Shader for a `shaders` key: the addon's copy of a player builtin, or a
## custom file copied into `<dest_dir>/shaders/` (named by its key).
static func _shader(ctx: _Ctx, key: String) -> Shader:
	if ctx.shaders.has(key):
		return ctx.shaders[key]
	var shader: Shader = null
	var path := String(ctx.shader_keys.get(key, ""))
	if path.is_empty():
		ctx.warn("shader '%s' isn't in `shaders`" % key)
	elif path.begins_with(_PLAYER_VISUALIZER):
		var addon_path := _ADDON_VISUALIZER + path.substr(_PLAYER_VISUALIZER.length())
		shader = load(addon_path) as Shader if ResourceLoader.exists(addon_path) else null
		if shader == null:
			ctx.warn("shader '%s': the addon has no copy of '%s'" % [key, path])
	elif path.begins_with("res://"):
		ctx.warn("shader '%s' is the player's '%s', which the addon has no copy of" % [key, path])
	else:
		var src := path if path.is_absolute_path() else ctx.base_dir.path_join(path).simplify_path()
		if src.get_extension() != "gdshader":
			ctx.warn("shader '%s': only .gdshader files import ('%s')" % [key, path])
		elif not FileAccess.file_exists(src):
			ctx.warn("shader '%s': '%s' not found" % [key, src])
		else:
			var dst := ctx.dest_dir.path_join("shaders/%s.gdshader" % key)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dst.get_base_dir()))
			var f := FileAccess.open(dst, FileAccess.WRITE)
			f.store_string(FileAccess.get_file_as_string(src).replace(_PLAYER_VISUALIZER, _ADDON_VISUALIZER))
			f.close()
			shader = ResourceLoader.load(dst, "Shader", ResourceLoader.CACHE_MODE_REPLACE) as Shader
	ctx.shaders[key] = shader
	return shader


static func _set_params(mat: ShaderMaterial, params) -> void:
	if typeof(params) != TYPE_DICTIONARY:
		return
	for name in params:
		mat.set_shader_parameter(name, _to_type(params[name], _uniform_default(mat.shader, name)))


## A value of the uniform's type (null if the shader has no such uniform).
static func _uniform_default(shader: Shader, name: String):
	for u in shader.get_shader_uniform_list():
		if u.name == name:
			match int(u.type):
				TYPE_COLOR: return Color()
				TYPE_VECTOR2: return Vector2()
				TYPE_VECTOR3: return Vector3()
				TYPE_VECTOR4: return Vector4()
				TYPE_INT: return 0
				TYPE_BOOL: return false
				_: return 0.0
	return null


# ---------- presence ----------

## Spawns and despawns as `visible` keys, walked the way the player runs
## them: a despawn takes the object's children along, so they're hidden
## then too (the exporter leaves out their despawn again).
static func _build_presence(ctx: _Ctx, events: Array) -> void:
	var present: Dictionary = {}
	var keys: Dictionary = {}  # id -> [[t, visible], ...]
	for ev in events:
		var t := float(ev.get("t", 0.0))
		if ev.action == "spawn":
			var id := String(ev.get("id", ""))
			if ctx.nodes.has(id):
				present[id] = true
				_key_presence(keys, id, t, true)
		else:
			var target := String(ev.get("target", ""))
			if not ctx.nodes.has(target):
				ctx.warn("despawn at %.3fs of unknown '%s'; dropped" % [t, target])
				continue
			for id in _with_descendants(ctx, target):
				if present.get(id, false):
					present[id] = false
					_key_presence(keys, id, t, false)
	for id in ctx.nodes:
		var node: Node3D = ctx.nodes[id]
		var list: Array = keys.get(id, [])
		var at_start: bool = not list.is_empty() and list[0][0] <= 0.0 and list[0][1]
		node.visible = at_start
		if list.size() == 1 and at_start:
			continue  # there from the start and never goes: no track
		var track := ctx.anim.add_track(Animation.TYPE_VALUE)
		ctx.anim.track_set_path(track, "%s:visible" % ctx.root.get_path_to(node))
		ctx.anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		ctx.anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
		if list.is_empty() or list[0][0] > 0.0:
			ctx.anim.track_insert_key(track, 0.0, false)
		for k in list:
			ctx.anim.track_insert_key(track, k[0], k[1])


static func _key_presence(keys: Dictionary, id: String, t: float, visible: bool) -> void:
	var list: Array = keys.get(id, [])
	if not list.is_empty() and list[-1][0] == t:
		list[-1][1] = visible  # the later event at the same time wins
	else:
		list.append([t, visible])
	keys[id] = list


static func _with_descendants(ctx: _Ctx, id: String) -> Array:
	var out: Array = [id]
	for other in ctx.parents:
		if ctx.parents[other] == id:
			out.append_array(_with_descendants(ctx, other))
	return out


# ---------- tracks ----------

static func _build_track(ctx: _Ctx, t: Dictionary) -> void:
	var kfs: Array = t.get("keyframes", [])
	if kfs.is_empty():
		return
	var target := String(t.get("target", ""))
	var target_id := target.get_slice(".", 0)
	var node: Node3D = ctx.nodes.get(target_id)
	if node == null:
		ctx.warn("%s track for unknown '%s'; dropped" % [t.type, target_id])
		return
	var path := String(ctx.root.get_path_to(node))
	var prop := ""
	var template = null
	var dv_scale := 1.0  # JSON units per scene unit (degrees per radian)
	if t.type == "transform":
		match String(t.get("channel", "")):
			"position": prop = "position"
			"rotation_deg":
				prop = "rotation"
				dv_scale = rad_to_deg(1.0)
			"scale": prop = "scale"
		template = Vector3()
	else:
		var slot := target.get_slice(".", 1) if target.contains(".") else ""
		var param := String(t.get("param", ""))
		var resolved := _param_path(ctx, node, slot, param, target)
		if resolved.is_empty():
			return
		path = resolved[0]
		prop = resolved[1]
		template = resolved[2]
	if prop.is_empty():
		ctx.warn("track for '%s' names no property; dropped" % target)
		return
	var full := "%s:%s" % [path, prop]
	if ctx.anim.find_track(NodePath(full), Animation.TYPE_VALUE) >= 0 or ctx.anim.find_track(NodePath(full), Animation.TYPE_BEZIER) >= 0 \
			or ctx.anim.find_track(NodePath(full + ":x"), Animation.TYPE_BEZIER) >= 0 or ctx.anim.find_track(NodePath(full + ":r"), Animation.TYPE_BEZIER) >= 0:
		ctx.warn("a second track animates %s; dropped" % full)
		return
	_add_keys(ctx, full, kfs, template, dv_scale)


## [node path, property, value template] for a shader_param track (see the
## exporter's _append_track / _route_track), or [] (warned).
static func _param_path(ctx: _Ctx, node: Node3D, slot: String, param: String, target: String) -> Array:
	var path := String(ctx.root.get_path_to(node))
	var script = node.get_script()
	var is_screen: bool = script == VJScreenScript or script == VJLayerScript
	match slot:
		"display":
			if is_screen and param in ["curvature", "vertical_curvature", "opacity"]:
				return [path, param, 0.0]
		"modifiers", "reactive":
			var fields: Array = VJObjectScript.MODIFIER_FIELDS if slot == "modifiers" else VJObjectScript.REACTIVE_FIELDS
			if node.has_method("modifier_values") and param in fields and not (is_screen and param == "opacity"):
				return [path, param, node.get(param)]
		_:
			if slot.begins_with("effect") and slot.substr(6).is_valid_int():
				var effects: Array = node.call("effect_nodes") if node.has_method("effect_nodes") else []
				var n := slot.substr(6).to_int()
				if n < effects.size():
					var effect: Node = effects[n]
					return ["%s/%s" % [path, effect.name], "material:shader_parameter/" + param,
							_uniform_default(effect.material.shader, param)]
			elif is_screen:
				var mat: ShaderMaterial = node.shader_material
				if mat != null:
					return [path, "shader_material:shader_parameter/" + param, _uniform_default(mat.shader, param)]
			else:
				var mat_prop := _custom_material_property(node)
				if not mat_prop.is_empty():
					var mat: ShaderMaterial = node.get_indexed(NodePath(mat_prop))
					return [path, mat_prop + ":shader_parameter/" + param, _uniform_default(mat.shader, param)]
	ctx.warn("shader_param track '%s' / '%s' has no matching property in the scene; dropped" % [target, param])
	return []


## Where a custom prefab's shader material is, as the player finds it (the
## root's active material): material_override, the surface override, or
## the mesh's own.
static func _custom_material_property(node: Node) -> String:
	if not node is GeometryInstance3D:
		return ""
	if node.material_override is ShaderMaterial:
		return "material_override"
	if node is MeshInstance3D and node.mesh != null:
		if node.get_surface_override_material(0) is ShaderMaterial:
			return "surface_material_override/0"
		if node.mesh.surface_get_material(0) is ShaderMaterial:
			return "mesh:surface_0/material"
	return ""


## Keys `kfs` onto `path`: a value track when every segment shares a mode
## Godot's value tracks have (linear, cubic, step), otherwise Bezier tracks.
static func _add_keys(ctx: _Ctx, path: String, kfs: Array, template, dv_scale: float) -> void:
	var modes: Dictionary = {}
	for i in kfs.size() - 1:
		modes[String(kfs[i].get("interp", "linear"))] = true
	if modes.size() <= 1 and not modes.has("ease") and not modes.has("bezier"):
		var mode: String = modes.keys()[0] if modes.size() == 1 else "linear"
		var track := ctx.anim.add_track(Animation.TYPE_VALUE)
		ctx.anim.track_set_path(track, path)
		match mode:
			"cubic": ctx.anim.track_set_interpolation_type(track, Animation.INTERPOLATION_CUBIC)
			"step":
				ctx.anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
				ctx.anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		for kf in kfs:
			ctx.anim.track_insert_key(track, float(kf.t), _to_type(_scaled(kf.value, 1.0 / dv_scale), template))
		return
	if modes.has("step"):
		ctx.warn("%s mixes step with other interpolations; each step holds until %.0f ms before its next key" % [path, _STEP_EDGE * 1000.0])
		kfs = _expand_steps(kfs)
	_add_bezier(ctx, path, kfs, template, dv_scale)


## Step segments as a hold key just before the next key, then linear.
static func _expand_steps(kfs: Array) -> Array:
	var out: Array = []
	for i in kfs.size():
		var kf: Dictionary = kfs[i].duplicate()
		if i + 1 < kfs.size() and kf.get("interp", "linear") == "step":
			kf["interp"] = "linear"
			out.append(kf)
			var t0 := float(kf.t)
			var t1 := float(kfs[i + 1].t)
			out.append({"t": maxf(t0, t1 - minf(_STEP_EDGE, (t1 - t0) * 0.5)), "value": kf.value})
		else:
			out.append(kf)
	return out


## One Bezier track per component (`path:x` …, or `path` for a float),
## every segment's handles drawing the curve its JSON interp describes.
static func _add_bezier(ctx: _Ctx, path: String, kfs: Array, template, dv_scale: float) -> void:
	var names: Array = _COMPONENTS.get(typeof(template), [""])
	var count := _value_size(kfs[0].value)
	for c in names.size():
		if names[c] != "" and c >= count:
			continue  # a colour without alpha keeps the default
		var track := ctx.anim.add_track(Animation.TYPE_BEZIER)
		ctx.anim.track_set_path(track, path if names[c] == "" else "%s:%s" % [path, names[c]])
		var ins: Array = []
		var outs: Array = []
		for i in kfs.size():
			ins.append(Vector2.ZERO)
			outs.append(Vector2.ZERO)
		for i in kfs.size() - 1:
			var h := _segment_handles(kfs, i, c if names[c] != "" else -1)
			outs[i] = Vector2(h[0].x, h[0].y / dv_scale)
			ins[i + 1] = Vector2(h[1].x, h[1].y / dv_scale)
		for i in kfs.size():
			var v := _component(kfs[i].value, c if names[c] != "" else -1) / dv_scale
			ctx.anim.bezier_track_insert_key(track, float(kfs[i].t), v, ins[i], outs[i])


## [out handle of key i, in handle of key i+1] in JSON units, for element
## `c` (-1: scalar), drawing segment i as its interp says.
static func _segment_handles(kfs: Array, i: int, c: int) -> Array:
	var a: Dictionary = kfs[i]
	var b: Dictionary = kfs[i + 1]
	var span := float(b.t) - float(a.t)
	match String(a.get("interp", "linear")):
		"bezier":
			return [_handle(a.get("out"), c), _handle(b.get("in"), c)]
		"ease":
			# y = smoothstep(u) is exactly a cubic with flat handles a third in.
			return [Vector2(span / 3.0, 0.0), Vector2(-span / 3.0, 0.0)]
		"cubic":
			# Godot's cubic is a cubic in time: the Bezier through its values
			# at 1/3 and 2/3 of the segment is the same curve.
			var pre: Dictionary = kfs[maxi(i - 1, 0)]
			var post: Dictionary = kfs[mini(i + 2, kfs.size() - 1)]
			var ta := float(a.t)
			var args := [_component(a.value, c), _component(b.value, c), _component(pre.value, c), _component(post.value, c)]
			var y := func(u: float) -> float:
				return cubic_interpolate_in_time(args[0], args[1], args[2], args[3], u, span, float(pre.t) - ta, float(post.t) - ta)
			var p0: float = args[0]
			var p3: float = args[1]
			var ca: float = 27.0 * y.call(1.0 / 3.0) - 8.0 * p0 - p3
			var cb: float = 27.0 * y.call(2.0 / 3.0) - p0 - 8.0 * p3
			var p1 := (2.0 * ca - cb) / 18.0
			var p2 := (2.0 * cb - ca) / 18.0
			return [Vector2(span / 3.0, p1 - p0), Vector2(-span / 3.0, p2 - p3)]
	return [Vector2.ZERO, Vector2.ZERO]  # linear


static func _handle(h, c: int) -> Vector2:
	if c >= 0:
		h = h[c] if typeof(h) == TYPE_ARRAY and c < h.size() else null
	if typeof(h) == TYPE_ARRAY and h.size() == 2:
		return Vector2(float(h[0]), float(h[1]))
	return Vector2.ZERO


# ---------- viewer ----------

## Cuts become VJViewer keys (at the cut's jump, half a fade after the
## event starts); a hard cut at t=0 is its start pose.
static func _build_viewer(ctx: _Ctx, cuts: Array) -> void:
	var viewer := Camera3D.new()
	viewer.name = "Viewer"
	viewer.set_script(VJViewerScript)
	ctx.root.add_child(viewer)
	viewer.owner = ctx.root
	viewer.position = SceneExporterScript.VIEWER_HOME_POSITION
	if cuts.is_empty():
		return
	var fades: Dictionary = {}
	var keys: Array = []  # [t, position, rotation (radians)]
	for ev in cuts:
		var to: Dictionary = ev.get("to", {})
		var pos := _vec3(to.get("position", [0, 0, 0]))
		var rot_deg := _vec3(to.get("rotation_deg", [0, 0, 0]))
		var rot := Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z))
		var tr = ev.get("transition")
		var fade := float(tr.get("duration", 0.5)) if typeof(tr) == TYPE_DICTIONARY and tr.get("type") == "fade_to_black" else 0.0
		var t := float(ev.get("t", 0.0))
		if t <= 0.0 and fade == 0.0:
			viewer.position = pos
			viewer.rotation = rot
			continue
		fades[fade] = true
		keys.append([t + fade * 0.5, pos, rot])
	if fades.size() > 1:
		ctx.warn("cuts use different transitions; the scene's viewer has one, so all use the first cut's")
	if not keys.is_empty():
		var fade: float = fades.keys()[0]
		viewer.transition = "fade_to_black" if fade > 0.0 else "none"
		if fade > 0.0:
			viewer.fade_duration = fade
	var pos_track := ctx.anim.add_track(Animation.TYPE_VALUE)
	var rot_track := ctx.anim.add_track(Animation.TYPE_VALUE)
	ctx.anim.track_set_path(pos_track, "%s:position" % viewer.name)
	ctx.anim.track_set_path(rot_track, "%s:rotation" % viewer.name)
	for track in [pos_track, rot_track]:
		ctx.anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
		ctx.anim.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
	ctx.anim.track_insert_key(pos_track, 0.0, viewer.position)
	ctx.anim.track_insert_key(rot_track, 0.0, viewer.rotation)
	for k in keys:
		ctx.anim.track_insert_key(pos_track, k[0], k[1])
		ctx.anim.track_insert_key(rot_track, k[0], k[2])


# ---------- values ----------

static func _vec3(v) -> Vector3:
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO


static func _value_size(v) -> int:
	return v.size() if typeof(v) == TYPE_ARRAY else 1


static func _component(v, c: int) -> float:
	if c < 0:
		return float(v) if typeof(v) != TYPE_ARRAY else float(v[0])
	return float(v[c]) if typeof(v) == TYPE_ARRAY and c < v.size() else 0.0


static func _scaled(v, s: float):
	if s == 1.0:
		return v
	if typeof(v) == TYPE_ARRAY:
		return v.map(func(x): return float(x) * s)
	return float(v) * s


## A JSON value as the type of `template` (a colour from 3 or 4 numbers;
## without a template, arrays become vectors by length).
static func _to_type(v, template):
	if typeof(v) == TYPE_ARRAY:
		var f: Array = v.map(func(x): return float(x))
		match typeof(template):
			TYPE_COLOR:
				return Color(f[0], f[1], f[2], f[3] if f.size() > 3 else 1.0)
			TYPE_VECTOR2: return Vector2(f[0], f[1])
			TYPE_VECTOR3: return Vector3(f[0], f[1], f[2])
			TYPE_VECTOR4: return Vector4(f[0], f[1], f[2], f[3])
		match f.size():
			2: return Vector2(f[0], f[1])
			3: return Vector3(f[0], f[1], f[2])
			4: return Vector4(f[0], f[1], f[2], f[3])
		return v
	match typeof(template):
		TYPE_INT: return int(v)
		TYPE_BOOL: return bool(v)
	return float(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else v
