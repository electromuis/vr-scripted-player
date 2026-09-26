class_name StudioEditTools
extends Node3D

## Studio's hands-on editing: pick an object, grab it (one hand carries it,
## a second hand scales and turns it), and let go to write the move into
## the piece as one undoable step. Controllers, the desktop mouse and tests
## all drive it the same way: a "hand" is just a name and a transform (its
## -Z is where it points).
##
## What letting go writes (see _commit):
##   auto-key on  — keys at the playhead on the channels that changed
##                  (position / rotation_deg / scale), tracks made as needed
##   auto-key off — the object's spawn placement; a channel that's already
##                  animated moves as a whole instead (every key shifted by
##                  the same amount), so the path keeps its shape
## Snapping rounds the placement while dragging (10 cm, 15°, 5 % scale).
##
## While a drag runs the runner leaves the object alone (ScriptRunner.held),
## so the live move shows even where tracks animate it.

signal said(text: String)

const SELECT_COLOR := Color(0.3, 0.79, 0.94)
const GRAB_COLOR := Color(1.0, 0.85, 0.3)
const SEAT_COLOR := Color(1.0, 0.82, 0.4)
const AXIS_LENGTH := 0.35
## Differences smaller than these don't count as a change on release.
const MOVE_EPS := 0.0005
const ANGLE_EPS := 0.01
const SCALE_EPS := 0.0005

var model: EditModel
var runner: ScriptRunner
var stage: Stage

var auto_key := false
var snap := false
var selected := ""

## The drag in progress: {id, node, primary, hands {name: Transform3D},
## offset, start (node-style dict), two ({} or {a0, b0, obj0})}.
var _grab: Dictionary = {}
var _lines: ImmediateMesh
var _lines_mesh: MeshInstance3D
var _bounds_cache: Dictionary = {}  # node instance id -> AABB


func _ready() -> void:
	_lines = ImmediateMesh.new()
	_lines_mesh = MeshInstance3D.new()
	_lines_mesh.mesh = _lines
	_lines_mesh.top_level = true
	_lines_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_lines_mesh.extra_cull_margin = 16384.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.render_priority = 50
	_lines_mesh.material_override = mat
	add_child(_lines_mesh)


# ---------- picking and selection ----------

## Every object of the piece that's on stage now: [{id, xf, bounds}].
func candidates() -> Array:
	if model == null or runner == null:
		return []
	var registry := runner.registry()
	var nodes: Dictionary = {}
	for id in model.object_ids():
		var n := registry.get_node_by_id(id)
		if n != null and is_instance_valid(n) and n.is_inside_tree() and n.is_visible_in_tree():
			nodes[id] = n
	var others: Array = nodes.values()
	var out: Array = []
	for id in nodes:
		var n: Node3D = nodes[id]
		out.append({"id": id, "xf": n.global_transform, "bounds": StudioPicker.local_bounds(n, others)})
	return out


func pick(origin: Vector3, dir: Vector3) -> String:
	return StudioPicker.pick(origin, dir.normalized(), candidates())


## Select `id` ("" deselects).
func select(id: String) -> void:
	if id == selected:
		return
	selected = id
	_bounds_cache.clear()
	if id != "":
		_say("Selected %s." % id)


# ---------- grabbing ----------

func is_grabbing() -> bool:
	return not _grab.is_empty()


func grabbed_id() -> String:
	return String(_grab.get("id", ""))


## Start carrying `id` with the hand called `hand` (at `hand_xf`).
func grab(id: String, hand: String, hand_xf: Transform3D) -> bool:
	if id == "" or runner == null or is_grabbing():
		return false
	var node := runner.registry().get_node_by_id(id)
	if node == null or not node.is_inside_tree():
		return false
	select(id)
	runner.held[id] = true
	_grab = {
		"id": id, "node": node, "primary": hand, "hands": {hand: hand_xf},
		"offset": GrabMath.grip_offset(hand_xf, node.global_transform),
		"start": GrabMath.to_dict(node.transform), "two": {},
	}
	return true


func move_hand(hand: String, hand_xf: Transform3D) -> void:
	if not is_grabbing() or not _grab.hands.has(hand):
		return
	_grab.hands[hand] = hand_xf
	_apply()


## A second hand takes hold too: from now on the distance between the two
## scales the object and their turn turns it.
func add_hand(hand: String, hand_xf: Transform3D) -> void:
	if not is_grabbing() or _grab.hands.has(hand) or _grab.hands.size() >= 2:
		return
	_grab.hands[hand] = hand_xf
	var node: Node3D = _grab.node
	_grab.two = {"a0": (_grab.hands[_grab.primary] as Transform3D).origin, "b0": hand_xf.origin,
			"obj0": node.global_transform, "other": hand}


## A hand lets go: with two, the other carries on alone; with one, the
## grab ends and is written (returns the undo label, or "").
func release_hand(hand: String) -> String:
	if not is_grabbing() or not _grab.hands.has(hand):
		return ""
	if _grab.hands.size() == 1:
		return release()
	_grab.hands.erase(hand)
	_grab.two = {}
	_grab.primary = _grab.hands.keys()[0]
	var node: Node3D = _grab.node
	_grab.offset = GrabMath.grip_offset(_grab.hands[_grab.primary], node.global_transform)
	return ""


## Push the carried object further along the hand (negative pulls).
func push(metres: float) -> void:
	if not is_grabbing() or not _grab.two.is_empty() or metres == 0.0:
		return
	_grab.offset = GrabMath.pushed(_grab.offset, metres)
	_apply()


## End the grab and write it. Returns the undo label ("" if nothing moved).
func release() -> String:
	if not is_grabbing():
		return ""
	var id: String = _grab.id
	var node: Node3D = _grab.node
	var label := ""
	if is_instance_valid(node):
		label = _commit(id, _grab.start, GrabMath.to_dict(node.transform))
	runner.held.erase(id)
	_grab = {}
	return label


## Drop the grab without writing anything; the runner puts it back.
func cancel() -> void:
	if not is_grabbing():
		return
	runner.held.erase(String(_grab.id))
	_grab = {}
	runner.apply_edit(model.timeline(), false)


func _apply() -> void:
	var node: Node3D = _grab.node
	if not is_instance_valid(node):
		_grab = {}
		return
	var global: Transform3D
	if not _grab.two.is_empty():
		var two: Dictionary = _grab.two
		global = GrabMath.two_handed(two.a0, two.b0, (_grab.hands[_grab.primary] as Transform3D).origin,
				(_grab.hands[two.other] as Transform3D).origin, two.obj0)
	else:
		global = GrabMath.carried(_grab.hands[_grab.primary], _grab.offset)
	var local := GrabMath.to_local(node.get_parent().global_transform, global) if node.get_parent() is Node3D else global
	if snap:
		local = GrabMath.from_dict(StudioSnap.snapped(GrabMath.to_dict(local)))
	node.transform = local


# ---------- writing ----------

## Key the selection where it is now, on all three channels, at the
## playhead (the "key it" button, whatever auto-key says).
func key_selection() -> String:
	if selected == "" or model == null:
		return ""
	var node := runner.registry().get_node_by_id(selected)
	if node == null:
		return ""
	var now := GrabMath.to_dict(node.transform)
	var t := runner.playhead
	var label := "Key %s at %s" % [selected, StudioStatus.timecode(t)]
	var id := selected
	model.batch(label, func():
		for ch in ["position", "rotation_deg", "scale"]:
			model.set_key(ScriptFormat.TRACK_TRANSFORM, id, ch, t, now[ch]))
	_say(label + ".")
	return label


## Write a move from `before` to `after` (node-style dicts, local).
func _commit(id: String, before: Dictionary, after: Dictionary) -> String:
	var changed := _changed_channels(before, after)
	if changed.is_empty():
		runner.apply_edit(model.timeline(), false)  # snap the runner's view back
		return ""
	var t := runner.playhead
	var label: String
	if auto_key:
		label = "Key %s at %s" % [id, StudioStatus.timecode(t)]
		model.batch(label, func():
			for ch in changed:
				model.set_key(ScriptFormat.TRACK_TRANSFORM, id, ch, t, after[ch]))
	else:
		label = "Move %s" % id
		model.batch(label, func():
			var spawn := _spawn_transform(id)
			var spawn_changed := false
			for ch in changed:
				var ti := model.find_track(ScriptFormat.TRACK_TRANSFORM, id, ch)
				if ti >= 0:
					model.set_keyframes(ti, _shifted_keys(model.tracks()[ti].get("keyframes", []), ch, before[ch], after[ch]))
				else:
					spawn[ch] = after[ch]
					spawn_changed = true
			if spawn_changed:
				model.set_spawn_transform(id, spawn))
	_say(label + ".")
	return label


func _changed_channels(before: Dictionary, after: Dictionary) -> Array:
	var out: Array = []
	var eps := {"position": MOVE_EPS, "rotation_deg": ANGLE_EPS, "scale": SCALE_EPS}
	for ch in ["position", "rotation_deg", "scale"]:
		var a := Interpolation.to_vec3(before.get(ch))
		var b := Interpolation.to_vec3(after.get(ch))
		if ch == "rotation_deg":
			# Same orientation written differently (e.g. -180 and 180) isn't a change.
			var qa := Basis.from_euler(a * PI / 180.0)
			var qb := Basis.from_euler(b * PI / 180.0)
			if qa.get_rotation_quaternion().angle_to(qb.get_rotation_quaternion()) > deg_to_rad(eps[ch]):
				out.append(ch)
		elif a.distance_to(b) > eps[ch]:
			out.append(ch)
	return out


## The spawn transform as the file has it, filled in (a copy).
func _spawn_transform(id: String) -> Dictionary:
	var i := model.spawn_index(id)
	var t = model.tracks()[i].get("transform", {}) if i >= 0 else {}
	var out: Dictionary = (t as Dictionary).duplicate(true) if typeof(t) == TYPE_DICTIONARY else {}
	for pair in [["position", [0.0, 0.0, 0.0]], ["rotation_deg", [0.0, 0.0, 0.0]], ["scale", [1.0, 1.0, 1.0]]]:
		if not out.has(pair[0]):
			out[pair[0]] = pair[1]
	return out


## A channel's keys moved as a whole by what the drag did to it: added for
## position and rotation, scaled for scale (handles follow).
static func _shifted_keys(kfs: Array, ch: String, before, after) -> Array:
	var a := Interpolation.to_vec3(before)
	var b := Interpolation.to_vec3(after)
	var out: Array = kfs.duplicate(true)
	for kf in out:
		var v := Interpolation.to_vec3(kf.get("value"))
		var nv: Vector3
		if ch == "scale":
			var ratio := Vector3(b.x / a.x if a.x != 0 else 1.0, b.y / a.y if a.y != 0 else 1.0, b.z / a.z if a.z != 0 else 1.0)
			nv = v * ratio
			for h in ["in", "out"]:
				if typeof(kf.get(h)) == TYPE_ARRAY and kf[h].size() == 3:
					for c in 3:
						kf[h][c][1] = float(kf[h][c][1]) * ratio[c]
		else:
			nv = v + (b - a)
		kf["value"] = [nv.x, nv.y, nv.z]
	return out


# ---------- drawing ----------

func _process(_delta: float) -> void:
	_lines.clear_surfaces()
	var id := selected
	var node := runner.registry().get_node_by_id(id) if runner != null and id != "" else null
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		_draw_seat()
		return
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	var key := node.get_instance_id()
	if not _bounds_cache.has(key):
		var others: Array = model.object_ids().map(func(o): return runner.registry().get_node_by_id(o)) if model != null else []
		_bounds_cache = {key: StudioPicker.local_bounds(node, others)}
	var box: AABB = _bounds_cache[key]
	var xf := node.global_transform
	var color := GRAB_COLOR if is_grabbing() else SELECT_COLOR
	if box.size != Vector3.ZERO:
		for e in _box_edges(box):
			_line(xf * e[0], xf * e[1], color)
	var o := xf.origin
	var b := xf.basis.orthonormalized()
	_line(o, o + b.x * AXIS_LENGTH, Color(1, 0.36, 0.36))
	_line(o, o + b.y * AXIS_LENGTH, Color(0.43, 0.88, 0.48))
	_line(o, o + b.z * AXIS_LENGTH, Color(0.36, 0.55, 1))
	if is_grabbing() and snap:
		_draw_grid(o, node)
	_draw_seat_lines()
	_lines.surface_end()


## The snapping grid: 10 cm lines on the object's parent's horizontal plane
## around it (1 m across).
func _draw_grid(at: Vector3, node: Node3D) -> void:
	var parent := node.get_parent() as Node3D
	var pxf := parent.global_transform if parent != null else Transform3D()
	var local := pxf.affine_inverse() * at
	var c := Color(1.0, 0.85, 0.3, 0.45)
	for i in range(-5, 6):
		var off := i * StudioSnap.GRID
		_line(pxf * (local + Vector3(off, 0, -0.5)), pxf * (local + Vector3(off, 0, 0.5)), c)
		_line(pxf * (local + Vector3(-0.5, 0, off)), pxf * (local + Vector3(0.5, 0, off)), c)


func _draw_seat() -> void:
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	_draw_seat_lines()
	_lines.surface_end()


## Where the audience sits at the playhead: a ring on the floor, a line up
## to eye height and an arrow for where they face.
func _draw_seat_lines() -> void:
	if stage == null:
		# ImmediateMesh needs at least one vertex in an open surface.
		_line(Vector3.ZERO, Vector3.ZERO, Color.TRANSPARENT)
		return
	var seat := stage.seat_pose()
	var eye: Vector3 = seat.position
	var floor := Vector3(eye.x, 0.0, eye.z)
	var n := 24
	for i in n:
		var a0 := TAU * i / n
		var a1 := TAU * (i + 1) / n
		_line(floor + Vector3(cos(a0), 0, sin(a0)) * 0.35, floor + Vector3(cos(a1), 0, sin(a1)) * 0.35, SEAT_COLOR)
	_line(floor, eye, Color(SEAT_COLOR, 0.5))
	var fwd := Basis(Vector3.UP, deg_to_rad(float(seat.yaw_deg))) * Vector3(0, 0, -1)
	var tip := floor + fwd * 0.6
	var side := fwd.cross(Vector3.UP) * 0.12
	_line(floor, tip, SEAT_COLOR)
	_line(tip, tip - fwd * 0.18 + side, SEAT_COLOR)
	_line(tip, tip - fwd * 0.18 - side, SEAT_COLOR)


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(a)
	_lines.surface_set_color(color)
	_lines.surface_add_vertex(b)


static func _box_edges(box: AABB) -> Array:
	var p := box.position
	var s := box.size
	var c := [p, p + Vector3(s.x, 0, 0), p + Vector3(s.x, 0, s.z), p + Vector3(0, 0, s.z)]
	var top := c.map(func(v): return v + Vector3(0, s.y, 0))
	var out: Array = []
	for i in 4:
		out.append([c[i], c[(i + 1) % 4]])
		out.append([top[i], top[(i + 1) % 4]])
		out.append([c[i], top[i]])
	return out


func _say(text: String) -> void:
	said.emit(text)
