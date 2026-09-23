class_name XRMovement
extends Node

## Basic VR locomotion for the XR rig:
##  - Left thumbstick (primary axis): continuous move, oriented by the
##    XRCamera3D's yaw. Y forward/back, X strafe.
##  - Right thumbstick (secondary axis): snap turn. Push past the
##    threshold, rig rotates by snap_degrees, then rearms once the stick
##    returns near zero.
##
## Move speed is deliberately modest for a video-viewing app — this isn't
## a locomotion showcase, users mostly stand near a screen. Snap turn is
## used over smooth turn because it's the standard comfort default.

@export var move_speed: float = 1.5           # m/s
@export var snap_degrees: float = 30.0
@export var snap_threshold: float = 0.7       # stick magnitude to trigger
@export var rearm_threshold: float = 0.3      # stick must fall below to rearm
@export var dead_zone: float = 0.15

@onready var _origin: XROrigin3D = get_parent()
@onready var _camera: XRCamera3D = _origin.get_node_or_null("XRCamera3D")
@onready var _left: XRController3D = _origin.get_node_or_null("LeftController")
@onready var _right: XRController3D = _origin.get_node_or_null("RightController")

var _snap_armed: bool = true


func _process(delta: float) -> void:
	if _origin == null or _camera == null:
		return
	if _left != null:
		_apply_move(_left.get_vector2("primary"), delta)
	if _right != null:
		_apply_snap_turn(_right.get_vector2("primary"))


func _apply_move(stick: Vector2, delta: float) -> void:
	if stick.length() < dead_zone:
		return
	# Camera yaw only — pitch/roll shouldn't affect move direction (nausea).
	var yaw := _camera.global_rotation.y
	var basis_yaw := Basis(Vector3.UP, yaw)
	# XR convention: stick Y+ is forward → world -Z in local frame.
	var local_move := Vector3(stick.x, 0.0, -stick.y)
	var world_move := basis_yaw * local_move * move_speed * delta
	_origin.global_position += world_move


func _apply_snap_turn(stick: Vector2) -> void:
	var x := stick.x
	if _snap_armed and absf(x) > snap_threshold:
		var dir := -1.0 if x > 0.0 else 1.0
		_origin.rotate_y(deg_to_rad(snap_degrees) * dir)
		_snap_armed = false
	elif not _snap_armed and absf(x) < rearm_threshold:
		_snap_armed = true
