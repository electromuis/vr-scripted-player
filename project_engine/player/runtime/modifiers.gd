extends RefCounted

## Object modifiers and reactive motion, shared by the player (ScriptRunner)
## and the authoring addon (VJObject, vj_object.gd). The addon
## keeps an identical copy at addon_vj/modifiers/modifiers.gd
## (project_engine/tests/test_addon_shader_copies.gd checks).
##
## Modifiers are Godot-native properties, set on every mesh, particle system
## and AnimationPlayer under an object and combined down the tree (a group's
## opacity multiplies its children's):
##   opacity  0..1   GeometryInstance3D.transparency
##   tint     Color  multiplies the colour (a multiply-blend material_overlay)
##   flash    Color  adds light, alpha = strength (an additive overlay pass)
##   speed    ×      speed_scale of particles and AnimationPlayers
##   sort_offset  m  VisualInstance3D.sorting_offset, added down the tree:
##                   see-through things draw back to front by their centre,
##                   so a big faded object (a forest around the viewer) can
##                   sort in front of what's inside it; negative pushes it back
## `lookup` gives a node's own modifier values ({} = none): the player keeps
## them in node metadata, the editor on VJObject nodes. A node no
## modifier reaches is left alone; one that was touched gets its own values
## back when the modifiers go (restore()).
##
## Reactive motion is computed on top of the object's (animated) transform:
##   spin   degrees per second on each axis, integrated over the timeline
##   pulse  0..1: scale 1 + pulse × the music's bass
## Call begin_frame() before the transform tracks write (the player) or
## right after an AnimationPlayer applied them (the editor's F5 preview), and
## end_frame() after, so the offset never feeds back into the base.

const DEFAULTS := {"opacity": 1.0, "tint": Color.WHITE, "flash": Color(1, 1, 1, 0), "speed": 1.0, "sort_offset": 0.0}
const REACTIVE_DEFAULTS := {"spin": Vector3.ZERO, "pulse": 0.0}
const SPIN_STEP := 0.05  # seconds, when integrating an animated spin

## Instance id -> the node's own values before any modifier touched it.
static var _originals: Dictionary = {}
## Instance id -> [multiply pass, additive pass] overlay materials.
static var _overlays: Dictionary = {}


## Apply the modifiers of `object` and its ancestors to everything under it.
static func refresh(object: Node, lookup: Callable) -> void:
	for node in _targets(object):
		var mods := _combined(node, lookup)
		var id := node.get_instance_id()
		if mods.is_empty() and not _originals.has(id):
			continue
		if not _originals.has(id):
			_originals[id] = _read(node)
		_write(node, _originals[id], mods)


## Give everything under `object` its own values back (the editor does this
## before saving the scene, so modified values never get saved).
static func restore(object: Node) -> void:
	for node in _targets(object):
		var id := node.get_instance_id()
		if _originals.has(id):
			_write(node, _originals[id], {})
			_originals.erase(id)
			_overlays.erase(id)


## A modifier value from JSON or the Inspector as its proper type.
static func normalize(param: String, value: Variant) -> Variant:
	match param:
		"tint", "flash":
			return _color(value, DEFAULTS[param])
		"spin":
			if value is Vector3:
				return value
			if value is Array and value.size() == 3:
				return Vector3(float(value[0]), float(value[1]), float(value[2]))
			return Vector3.ZERO
	return float(value)


# ---------- reactive ----------

## `base` spun by `angle_deg` and scaled by `scale`, in its own space.
static func reactive_transform(base: Transform3D, angle_deg: Vector3, scale: float) -> Transform3D:
	var spin := Basis.from_euler(Vector3(deg_to_rad(angle_deg.x), deg_to_rad(angle_deg.y), deg_to_rad(angle_deg.z)))
	return Transform3D(base.basis * spin * Basis.from_scale(Vector3.ONE * scale), base.origin)


## Take the last reactive offset off `node`. The offset only turns and
## scales, so it comes off the basis, and only if nothing has set a new
## rotation or scale since (then that is the base). A moved origin is kept.
static func begin_frame(node: Node3D, state: Dictionary) -> void:
	if state.has("applied") and node.basis.is_equal_approx(state.applied.basis):
		node.basis = state.base.basis


## The node's transform now is the base; put the offset on top.
static func end_frame(node: Node3D, state: Dictionary, angle_deg: Vector3, scale: float) -> void:
	state.base = node.transform
	node.transform = reactive_transform(state.base, angle_deg, scale)
	state.applied = node.transform


## Total spin angle at `t` from `spin_at(time) -> Vector3` (deg/s), carried
## over from `state` when time moved a little forward, else integrated from 0.
static func spin_angle(state: Dictionary, spin_at: Callable, t: float) -> Vector3:
	var last: float = state.get("t", -1.0)
	var angle: Vector3
	if last >= 0.0 and t >= last and t - last <= 0.5:
		angle = state.get("angle", Vector3.ZERO) + spin_at.call((last + t) * 0.5) * (t - last)
	else:
		angle = Vector3.ZERO
		var s := 0.0
		while s < t:
			var step := minf(SPIN_STEP, t - s)
			angle += spin_at.call(s + step * 0.5) * step
			s += step
	state.t = t
	state.angle = angle
	return angle


# ---------- internals ----------

static func _targets(object: Node) -> Array[Node]:
	var out: Array[Node] = []
	for node in [object] + object.find_children("*", "", true, false):
		if node is GeometryInstance3D or "speed_scale" in node:
			out.append(node)
	return out


## The modifiers from `node` up to the root, combined; {} if there are none.
static func _combined(node: Node, lookup: Callable) -> Dictionary:
	var found := false
	var opacity := 1.0
	var tint := Color.WHITE
	var flash := Color(0, 0, 0, 0)
	var speed := 1.0
	var sort_offset := 0.0
	var n := node
	while n != null:
		var m: Dictionary = lookup.call(n)
		if not m.is_empty():
			found = true
			opacity *= float(m.get("opacity", 1.0))
			var t := _color(m.get("tint", Color.WHITE), Color.WHITE)
			tint = Color(tint.r * t.r, tint.g * t.g, tint.b * t.b)
			var f := _color(m.get("flash", DEFAULTS.flash), DEFAULTS.flash)
			flash += Color(f.r * f.a, f.g * f.a, f.b * f.a, 0.0)
			speed *= float(m.get("speed", 1.0))
			sort_offset += float(m.get("sort_offset", 0.0))
		n = n.get_parent()
	if not found:
		return {}
	return {"opacity": opacity, "tint": tint, "flash": flash, "speed": speed, "sort_offset": sort_offset}


static func _read(node: Node) -> Dictionary:
	var out := {}
	if node is GeometryInstance3D:
		out.transparency = node.transparency
		out.overlay = node.material_overlay
		out.sorting_offset = node.sorting_offset
	if "speed_scale" in node:
		out.speed = node.speed_scale
	return out


static func _write(node: Node, orig: Dictionary, mods: Dictionary) -> void:
	if node is GeometryInstance3D:
		node.transparency = 1.0 - (1.0 - float(orig.transparency)) * float(mods.get("opacity", 1.0))
		node.sorting_offset = float(orig.sorting_offset) + float(mods.get("sort_offset", 0.0))
		var tint: Color = mods.get("tint", Color.WHITE)
		var flash: Color = mods.get("flash", Color(0, 0, 0, 0))
		if tint != Color.WHITE or flash.r + flash.g + flash.b > 0.0:
			node.material_overlay = _overlay(node.get_instance_id(), tint, flash)
		else:
			node.material_overlay = orig.overlay
	if "speed_scale" in node and orig.has("speed"):
		node.speed_scale = float(orig.speed) * float(mods.get("speed", 1.0))


static func _overlay(id: int, tint: Color, flash: Color) -> Material:
	if not _overlays.has(id):
		var passes: Array[StandardMaterial3D] = []
		for mode in [BaseMaterial3D.BLEND_MODE_MUL, BaseMaterial3D.BLEND_MODE_ADD]:
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.blend_mode = mode
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			passes.append(m)
		passes[0].next_pass = passes[1]
		_overlays[id] = passes
	var p: Array = _overlays[id]
	p[0].albedo_color = Color(tint.r, tint.g, tint.b)
	p[1].albedo_color = Color(flash.r, flash.g, flash.b)
	return p[0]


static func _color(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Vector4:
		return Color(v.x, v.y, v.z, v.w)
	if v is Vector3:
		return Color(v.x, v.y, v.z)
	if v is Array and v.size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]), float(v[3]) if v.size() > 3 else 1.0)
	return fallback
