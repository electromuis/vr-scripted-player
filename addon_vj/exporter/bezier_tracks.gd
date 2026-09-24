@tool
extends RefCounted

## Bezier animation tracks: converting value tracks to them (so the
## Animation panel's curve editor can edit them) and the component helpers
## the exporter uses to regroup them.
##
## A bezier track animates one float, so a Vector3 / Color value track
## becomes one bezier track per component (`position` → `position:x`,
## `:y`, `:z`; `glow_tint` → `glow_tint:r` … `:a`). Converted keys keep
## their shape: linear tracks get "Linear" handles, cubic tracks get
## "Balanced" handles along the curve's own slopes. Tracks that can't
## become bezier stay value tracks:
## non-numeric values (`visible`), nearest / discrete tracks, angle
## interpolation, eased keys, and the viewer's (its keys are cuts).

const VJViewerScript := preload("res://addons/vj_editor/builtin_prefabs/vj_viewer.gd")

const _COMPONENT_INDEX := {"x": 0, "y": 1, "z": 2, "w": 3, "r": 0, "g": 1, "b": 2, "a": 3}
const _COMPONENTS := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_COLOR: ["r", "g", "b", "a"],
}
## Animation::HandleMode (not exposed to scripts).
const _HANDLE_MODE_LINEAR := 1
const _HANDLE_MODE_BALANCED := 2


## Converts every applicable value track in all of `player`'s animations,
## in place. Returns how many value tracks were converted.
static func convert_player(player: AnimationPlayer) -> int:
	var root := player.get_node_or_null(player.root_node)
	var count := 0
	for lib_name in player.get_animation_library_list():
		var lib := player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			count += convert_animation(lib.get_animation(anim_name), root)
	return count


## Converts `animation`'s applicable value tracks in place (paths resolve
## from `root`). Each becomes its bezier track(s) at the same position.
static func convert_animation(animation: Animation, root: Node) -> int:
	var count := 0
	# Backwards, so inserting the new tracks doesn't shift ones still to visit.
	for i in range(animation.get_track_count() - 1, -1, -1):
		if _convertible(animation, i, root):
			_convert_track(animation, i)
			count += 1
	return count


## Splits a bezier track's path into the property it animates and the
## component: `a/b:position:x` → [`a/b:position`, "x"]; a plain float
## property → [path, ""].
static func split_component(node: Node, path: NodePath) -> Array:
	var count := path.get_subname_count()
	var last := String(path.get_subname(count - 1))
	if count < 2 or not _COMPONENT_INDEX.has(last):
		return [path, ""]
	var subnames: Array = []
	for n in count - 1:
		subnames.append(String(path.get_subname(n)))
	var prop := ":".join(subnames)
	var value = node.get_indexed(NodePath(prop)) if node != null else null
	if value != null and not _COMPONENTS.has(typeof(value)):
		return [path, ""]  # a float property that happens to be named `x`
	return [NodePath(String(path).substr(0, String(path).length() - last.length() - 1)), last]


static func component_index(component: String) -> int:
	return _COMPONENT_INDEX[component]


static func component_count(value) -> int:
	return _COMPONENTS[typeof(value)].size()


## A zero value of the type the components `names` belong to (for a
## property with no value to start from, e.g. an unset shader parameter).
static func zero_for_components(names: Array):
	for c in names:
		if c in ["r", "g", "b", "a"]:
			return Color(0, 0, 0, 1)
	if names.has("w"):
		return Vector4()
	if names.has("z"):
		return Vector3()
	return Vector2()


static func _convertible(animation: Animation, i: int, root: Node) -> bool:
	if animation.track_get_type(i) != Animation.TYPE_VALUE or animation.track_get_key_count(i) == 0:
		return false
	var interp := animation.track_get_interpolation_type(i)
	if interp != Animation.INTERPOLATION_LINEAR and interp != Animation.INTERPOLATION_CUBIC:
		return false
	if animation.value_track_get_update_mode(i) == Animation.UPDATE_DISCRETE:
		return false
	var type := _key_type(animation, i)
	if type != TYPE_FLOAT and not _COMPONENTS.has(type):
		return false
	var all_int := true
	for k in animation.track_get_key_count(i):
		var v = animation.track_get_key_value(i, k)
		if (TYPE_FLOAT if v is int else typeof(v)) != type or animation.track_get_key_transition(i, k) != 1.0:
			return false
		all_int = all_int and v is int
	var path := animation.track_get_path(i)
	var node := root.get_node_or_null(NodePath(path.get_concatenated_names())) if root != null else null
	if node != null and node.get_script() == VJViewerScript:
		return false
	# Whole-number keys (`0` in a .tscn loads as an int) are fine on a float
	# property, but a real int property stays a value track.
	return not all_int or (node != null and node.get_indexed(NodePath(path.get_concatenated_subnames())) is float)


## The track's value type, ints counting as floats.
static func _key_type(animation: Animation, i: int) -> int:
	var v = animation.track_get_key_value(i, 0)
	return TYPE_FLOAT if v is int else typeof(v)


static func _convert_track(animation: Animation, i: int) -> void:
	var path := animation.track_get_path(i)
	var type := _key_type(animation, i)
	var components: Array = [""] if type == TYPE_FLOAT else _COMPONENTS[type]
	var linear := animation.track_get_interpolation_type(i) == Animation.INTERPOLATION_LINEAR
	var key_count := animation.track_get_key_count(i)
	for c in components.size():
		var comp: String = components[c]
		var track := animation.add_track(Animation.TYPE_BEZIER, i + 1 + c)
		animation.track_set_path(track, path if comp == "" else NodePath("%s:%s" % [path, comp]))
		animation.track_set_enabled(track, animation.track_is_enabled(i))
		# Written as the track's key data (like the .tscn stores it): handle
		# modes can't be set through the scripting API.
		var times := PackedFloat32Array()
		var points := PackedFloat32Array()
		var modes := PackedInt32Array()
		for k in key_count:
			var t := animation.track_get_key_time(i, k)
			var v := _component(animation.track_get_key_value(i, k), comp)
			# Linear keys need no handles (the "Linear" mode draws straight
			# segments); cubic keys get balanced handles a third of the way to
			# their neighbours, along the slope the value track has there
			# (averaged over both sides: Godot's cubic isn't quite smooth).
			var in_handle := Vector2.ZERO
			var out_handle := Vector2.ZERO
			if not linear and key_count > 1:
				var dt_in := t - animation.track_get_key_time(i, k - 1) if k > 0 else 0.0
				var dt_out := animation.track_get_key_time(i, k + 1) - t if k < key_count - 1 else 0.0
				var slopes: Array = []
				if dt_in > 0.0:
					slopes.append(_slope(animation, i, comp, t, -dt_in))
				if dt_out > 0.0:
					slopes.append(_slope(animation, i, comp, t, dt_out))
				var slope: float = slopes.reduce(func(a, b): return a + b, 0.0) / maxi(1, slopes.size())
				# End keys mirror their one real handle.
				dt_in = dt_in if dt_in > 0.0 else dt_out
				dt_out = dt_out if dt_out > 0.0 else dt_in
				in_handle = Vector2(-dt_in, -dt_in * slope) / 3.0
				out_handle = Vector2(dt_out, dt_out * slope) / 3.0
			var mode := _HANDLE_MODE_LINEAR if linear else _HANDLE_MODE_BALANCED
			times.append(t)
			points.append_array([v, in_handle.x, in_handle.y, out_handle.x, out_handle.y])
			modes.append(mode)
		animation.set("tracks/%d/keys" % track, {"times": times, "points": points, "handle_modes": modes})
	animation.remove_track(i)


## The value track's slope at key time `t`, measured over a small step
## towards the neighbour `dt` away (negative: the previous one).
static func _slope(animation: Animation, i: int, comp: String, t: float, dt: float) -> float:
	var h := dt * 0.001
	var a := _component(animation.value_track_interpolate(i, t), comp)
	var b := _component(animation.value_track_interpolate(i, t + h), comp)
	return (b - a) / h


static func _component(value, comp: String) -> float:
	return float(value) if comp == "" else float(value[_COMPONENT_INDEX[comp]])
