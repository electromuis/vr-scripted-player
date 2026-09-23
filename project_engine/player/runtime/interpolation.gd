class_name Interpolation
extends RefCounted

## Keyframe evaluation for continuous tracks.
##
## Keyframes: [{ "t": float, "value": (float | Array[float]), "interp": String }, ...]
## Interp modes: "linear" (default), "cubic" (Catmull-Rom-ish smoothstep), "step".
## Values may be scalars OR fixed-length numeric arrays (e.g. Vector3 as [x,y,z]).
## Arrays are element-wise interpolated.


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
	var mode: String = a.get("interp", "linear")
	var u := _shape(raw_u, mode)
	return _blend(a.get("value"), b.get("value"), u)


static func _find_segment(keyframes: Array, t: float) -> int:
	# Linear scan is fine for typical timeline sizes; upgrade to binary search
	# if track sizes explode.
	for i in range(keyframes.size() - 1):
		var tb := float(keyframes[i + 1].get("t", 0.0))
		if t < tb:
			return i
	return keyframes.size() - 2


static func _shape(u: float, mode: String) -> float:
	match mode:
		"step": return 0.0
		"cubic": return u * u * (3.0 - 2.0 * u)  # smoothstep
		_: return u  # linear (default)


static func _blend(a, b, u: float):
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY and a.size() == b.size():
		var out: Array = []
		out.resize(a.size())
		for i in a.size():
			out[i] = lerp(float(a[i]), float(b[i]), u)
		return out
	return lerp(float(a), float(b), u)


static func to_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
