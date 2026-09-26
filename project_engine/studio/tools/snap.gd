class_name StudioSnap
extends RefCounted

## Snapping for Studio's moves: round what a drag produced to tidy values.
## Pure functions on node-style values (local position in metres, rotation
## in degrees, scale).

const GRID := 0.1       # metres
const ANGLE := 15.0     # degrees
const SCALE_STEP := 0.05


static func position(p: Vector3, grid: float = GRID) -> Vector3:
	return (p / grid).round() * grid


static func rotation_deg(r: Vector3, step: float = ANGLE) -> Vector3:
	return (r / step).round() * step


## Scale in SCALE_STEP steps of itself (5 % steps), per axis.
static func scale(s: Vector3, step: float = SCALE_STEP) -> Vector3:
	var out := Vector3()
	for i in 3:
		var v: float = s[i]
		out[i] = maxf(roundf(v / step) * step, step) if v > 0.0 else v
	return out


## All three, on a node-style transform dict ({position, rotation_deg, scale}).
static func snapped(d: Dictionary) -> Dictionary:
	var p := Interpolation.to_vec3(d.get("position", [0, 0, 0]))
	var r := Interpolation.to_vec3(d.get("rotation_deg", [0, 0, 0]))
	var s := Interpolation.to_vec3(d.get("scale", [1, 1, 1]))
	p = position(p)
	r = rotation_deg(r)
	s = scale(s)
	return {"position": [p.x, p.y, p.z], "rotation_deg": [r.x, r.y, r.z], "scale": [s.x, s.y, s.z]}


## No roll or pitch: only the turn about the vertical axis stays.
static func level(r: Vector3) -> Vector3:
	return Vector3(0.0, r.y, 0.0)


## The yaw (degrees) that turns an object at `from` to face `to` (its front
## is +Z, like a screen's picture side facing the viewer).
static func face_yaw(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return rad_to_deg(atan2(d.x, d.z))
