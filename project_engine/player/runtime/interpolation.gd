class_name Interpolation
extends RefCounted

## Keyframe evaluation for continuous tracks.
##
## Keyframes: [{ "t": float, "value": (float | Array[float]), "interp": String }, ...]
## A key's interp shapes the segment that starts at it:
##   "linear" (default)
##   "step"   holds the value until the next key
##   "ease"   per-segment smoothstep: eases out of and into every key
##   "cubic"  a spline through the keys, its slope at each key taken from
##            the neighbours — Godot's cubic value-track interpolation
##   "bezier" Godot's bezier curve: the key's "out" handle and the next
##            key's "in" handle, each [dt, dv] (relative to its key; dt in
##            seconds) — or, for array values, one [dt, dv] per element
## Values may be scalars OR fixed-length numeric arrays (e.g. Vector3 as [x,y,z]).
## Arrays are element-wise interpolated.

## Bisection steps solving a bezier segment's time for its curve parameter
## (Animation::bezier_track_interpolate uses the same, so we match it).
const _BEZIER_ITERATIONS := 10


static func evaluate(keyframes: Array, t: float):
	if keyframes.is_empty():
		return null
	if t <= float(keyframes[0].get("t", 0.0)):
		return keyframes[0].get("value")
	var last: Dictionary = keyframes[keyframes.size() - 1]
	if t >= float(last.get("t", 0.0)):
		return last.get("value")
	var i := _find_segment(keyframes, t)
	var a: Dictionary = keyframes[i]
	var b: Dictionary = keyframes[i + 1]
	var ta := float(a.get("t", 0.0))
	var tb := float(b.get("t", 0.0))
	var span := tb - ta
	if span <= 0.0:
		return b.get("value")
	var raw_u := (t - ta) / span
	match a.get("interp", "linear"):
		"step":
			return a.get("value")
		"ease":
			return _blend(a.get("value"), b.get("value"), raw_u * raw_u * (3.0 - 2.0 * raw_u))
		"cubic":
			return _cubic(keyframes, i, raw_u)
		"bezier":
			return _bezier(a, b, t - ta, span)
		_:
			return _blend(a.get("value"), b.get("value"), raw_u)


static func _find_segment(keyframes: Array, t: float) -> int:
	# Linear scan is fine for typical timeline sizes; upgrade to binary search
	# if track sizes explode.
	for i in range(keyframes.size() - 1):
		var tb := float(keyframes[i + 1].get("t", 0.0))
		if t < tb:
			return i
	return keyframes.size() - 2


static func _blend(a, b, u: float):
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY and a.size() == b.size():
		var out: Array = []
		out.resize(a.size())
		for i in a.size():
			out[i] = lerp(float(a[i]), float(b[i]), u)
		return out
	return lerp(float(a), float(b), u)


## Segment i → i+1 of a cubic track, like Godot's value tracks: a
## time-aware Catmull-Rom through the keys either side. At the ends the
## missing neighbour is the end key itself.
static func _cubic(keyframes: Array, i: int, u: float):
	var pre: Dictionary = keyframes[maxi(i - 1, 0)]
	var a: Dictionary = keyframes[i]
	var b: Dictionary = keyframes[i + 1]
	var post: Dictionary = keyframes[mini(i + 2, keyframes.size() - 1)]
	var ta := float(a.get("t", 0.0))
	var to_t := float(b.get("t", 0.0)) - ta
	var pre_t := float(pre.get("t", 0.0)) - ta
	var post_t := float(post.get("t", 0.0)) - ta
	var va = a.get("value")
	var vb = b.get("value")
	var vpre = pre.get("value")
	var vpost = post.get("value")
	if typeof(va) == TYPE_ARRAY and typeof(vb) == TYPE_ARRAY and va.size() == vb.size():
		var out: Array = []
		out.resize(va.size())
		for c in va.size():
			out[c] = cubic_interpolate_in_time(float(va[c]), float(vb[c]),
					_element(vpre, c, va[c]), _element(vpost, c, vb[c]), u, to_t, pre_t, post_t)
		return out
	return cubic_interpolate_in_time(float(va), float(vb), float(vpre), float(vpost), u, to_t, pre_t, post_t)


## Segment a → b of a bezier track, `dt` seconds into it. Array values
## run one curve per element.
static func _bezier(a: Dictionary, b: Dictionary, dt: float, span: float):
	var va = a.get("value")
	var vb = b.get("value")
	var outs = a.get("out")
	var ins = b.get("in")
	if typeof(va) == TYPE_ARRAY and typeof(vb) == TYPE_ARRAY and va.size() == vb.size():
		var out: Array = []
		out.resize(va.size())
		for c in va.size():
			out[c] = bezier_segment(float(va[c]), _handle(outs, c), float(vb[c]), _handle(ins, c), dt, span)
		return out
	return bezier_segment(float(va), _handle(outs, -1), float(vb), _handle(ins, -1), dt, span)


## One bezier segment from value `a` (with out handle `a_out`) to `b` (in
## handle `b_in`) over `span` seconds, evaluated `dt` seconds in. Handles
## are (dt, dv) relative to their key. Solved the way Godot's
## Animation::bezier_track_interpolate does it, so the player matches the
## editor.
static func bezier_segment(a: float, a_out: Vector2, b: float, b_in: Vector2, dt: float, span: float) -> float:
	var p0 := Vector2(0.0, a)
	var p1 := p0 + a_out
	var p3 := Vector2(span, b)
	var p2 := p3 + b_in
	var low := 0.0
	var high := 1.0
	for i in _BEZIER_ITERATIONS:
		var middle := (low + high) / 2.0
		if p0.bezier_interpolate(p1, p2, p3, middle).x < dt:
			low = middle
		else:
			high = middle
	var low_pos := p0.bezier_interpolate(p1, p2, p3, low)
	var high_pos := p0.bezier_interpolate(p1, p2, p3, high)
	var c := (dt - low_pos.x) / (high_pos.x - low_pos.x) if high_pos.x != low_pos.x else 0.0
	return low_pos.lerp(high_pos, c).y


## Element `c` of a handle list ([dt, dv] per element), or the single
## [dt, dv] handle when `c` is -1. Missing handles are flat (0, 0).
static func _handle(handles, c: int) -> Vector2:
	var h = handles
	if c >= 0:
		if typeof(handles) != TYPE_ARRAY or c >= handles.size():
			return Vector2.ZERO
		h = handles[c]
	if typeof(h) != TYPE_ARRAY or h.size() != 2:
		return Vector2.ZERO
	return Vector2(float(h[0]), float(h[1]))


static func _element(value, c: int, fallback) -> float:
	if typeof(value) == TYPE_ARRAY and c < value.size():
		return float(value[c])
	return float(fallback)


static func to_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
