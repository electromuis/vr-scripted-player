class_name XRMovement
extends Node

## What the sticks do continuously, from InputRouter's axis commands (so
## which stick does what follows the user's bindings):
##  - "move": continuous walk, oriented by the XRCamera3D's yaw. Y
##    forward/back, X strafe.
##  - "turn": snap turn. Push past the threshold, the rig rotates by
##    snap_degrees, then rearms once the stick returns near zero.
##  - "scroll_menu": scrolls the panel the right laser is on (scroll_step).
## The router only reports an axis while its context owns that stick:
## "move" and "turn" need free movement, "scroll_menu" the laser on a panel.
## With movement locked the sticks are a media remote instead, which is
## plain commands (seek / volume flicks), handled by main.gd.
##
## Move speed is deliberately modest for a video-viewing app — this isn't
## a locomotion showcase, users mostly stand near a screen. Snap turn is
## used over smooth turn because it's the standard comfort default.

## Whole mouse-wheel notches to scroll the pointed-at panel (positive = up).
signal scroll_step(notches: int)

@export var move_speed: float = 1.5           # m/s
@export var snap_degrees: float = 30.0
@export var snap_threshold: float = 0.7       # stick magnitude to trigger
@export var rearm_threshold: float = 0.3      # stick must fall below to rearm
@export var scroll_notches_per_second: float = 14.0  # at full stick deflection

## Set by XRRig.
var router: InputRouter

@onready var _origin: XROrigin3D = get_parent()
@onready var _camera: XRCamera3D = _origin.get_node_or_null("XRCamera3D")

var _snap_armed: bool = true
var _scroll_acc: float = 0.0  # fractional wheel notches carried between frames


func _process(delta: float) -> void:
	if _origin == null or _camera == null or router == null:
		return
	_apply_scroll(router.axis("scroll_menu").y, delta)
	_apply_move(router.axis("move"), delta)
	_apply_snap_turn(router.axis("turn"))


## Continuous: speed scales with deflection. Stick up = scroll up.
func _apply_scroll(y: float, delta: float) -> void:
	if y == 0.0:
		_scroll_acc = 0.0
		return
	_scroll_acc += y * scroll_notches_per_second * delta
	var whole := int(_scroll_acc)  # truncates toward zero
	if whole != 0:
		_scroll_acc -= whole
		scroll_step.emit(whole)


func _apply_move(stick: Vector2, delta: float) -> void:
	if stick == Vector2.ZERO:
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
