class_name GrabMath
extends RefCounted

## The maths behind grabbing, without any nodes: where an object goes when
## a hand (or two) carries it, and how that reads back as the script's
## {position, rotation_deg, scale}. All transforms are global unless named
## local.

## Push / pull never brings an object closer than this to the hand (m).
const MIN_REACH := 0.1


## The object's transform relative to the hand at grab time: keeping this
## fixed is what makes it follow without jumping.
static func grip_offset(hand: Transform3D, object: Transform3D) -> Transform3D:
	return hand.affine_inverse() * object


## Where a one-hand grab puts the object now.
static func carried(hand: Transform3D, offset: Transform3D) -> Transform3D:
	return hand * offset


## `offset` moved `metres` further along the hand's pointing direction (-Z;
## negative pulls it in), never closer than MIN_REACH.
static func pushed(offset: Transform3D, metres: float) -> Transform3D:
	var out := offset
	var reach := -out.origin.z
	var new_reach := maxf(reach + metres, MIN_REACH)
	out.origin.z = -new_reach
	return out


## Two hands: the object scales with the distance between them and turns
## (about the vertical axis and the tilt of the line between them) with it,
## around their midpoint. `start_*` are the hands' positions at the moment
## the second hand joined, `object` the object then.
static func two_handed(start_a: Vector3, start_b: Vector3, a: Vector3, b: Vector3, object: Transform3D) -> Transform3D:
	var d0 := start_b - start_a
	var d1 := b - a
	if d0.length() < 0.001 or d1.length() < 0.001:
		return object
	var factor := d1.length() / d0.length()
	var turn := Basis(Quaternion(d0.normalized(), d1.normalized()))
	var mid0 := (start_a + start_b) * 0.5
	var mid1 := (a + b) * 0.5
	var about := Transform3D(Basis(), mid1) * Transform3D(turn.scaled(Vector3.ONE * factor), Vector3.ZERO) \
			* Transform3D(Basis(), -mid0)
	return about * object


## `global` in the space of a parent at `parent_global` (a node's transform).
static func to_local(parent_global: Transform3D, global: Transform3D) -> Transform3D:
	return parent_global.affine_inverse() * global


## A node-style transform as the script writes it: position, rotation in
## degrees (Euler YXZ, Godot's default), scale along the object's own axes.
static func to_dict(xf: Transform3D) -> Dictionary:
	var scale := xf.basis.get_scale()
	var euler := xf.basis.orthonormalized().get_euler()
	return {
		"position": [xf.origin.x, xf.origin.y, xf.origin.z],
		"rotation_deg": [rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z)],
		"scale": [scale.x, scale.y, scale.z],
	}


## The inverse of to_dict (missing parts: zero / no rotation / one).
static func from_dict(d: Dictionary) -> Transform3D:
	return ScriptRunner._read_transform(d)
