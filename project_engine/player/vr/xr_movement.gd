class_name XRMovement
extends Node

## Thumbstick handling for the XR rig, in one of two modes:
##
## Free (locked = false) — basic locomotion:
##  - Left thumbstick (primary axis): continuous move, oriented by the
##    XRCamera3D's yaw. Y forward/back, X strafe.
##  - Right thumbstick (secondary axis): snap turn. Push past the
##    threshold, rig rotates by snap_degrees, then rearms once the stick
##    returns near zero.
##
## Locked (the media-player default) — the viewer never moves; either stick
## becomes a media remote instead:
##  - left/right: seek_step(-1 / +1)
##  - up/down:    volume_step(+1 / -1)
## Same flick-and-rearm behavior as snap turn, so one push = one step.
##
## In either mode, while the right laser is on a UI panel (right_scrolls, set
## by XRRig) the right stick's up/down scrolls that panel instead, and its
## other stick functions pause so browsing doesn't seek or turn.
##
## Move speed is deliberately modest for a video-viewing app — this isn't
## a locomotion showcase, users mostly stand near a screen. Snap turn is
## used over smooth turn because it's the standard comfort default.

signal seek_step(direction: int)
signal volume_step(direction: int)
## Whole mouse-wheel notches to scroll the pointed-at panel (positive = up).
signal scroll_step(notches: int)

@export var locked: bool = true
@export var move_speed: float = 1.5           # m/s
@export var snap_degrees: float = 30.0
@export var snap_threshold: float = 0.7       # stick magnitude to trigger
@export var rearm_threshold: float = 0.3      # stick must fall below to rearm
@export var dead_zone: float = 0.15
@export var scroll_notches_per_second: float = 14.0  # at full stick deflection

## Set each frame by XRRig: the right laser is on a UI panel.
var right_scrolls: bool = false

@onready var _origin: XROrigin3D = get_parent()
@onready var _camera: XRCamera3D = _origin.get_node_or_null("XRCamera3D")
@onready var _left: XRController3D = _origin.get_node_or_null("LeftController")
@onready var _right: XRController3D = _origin.get_node_or_null("RightController")

var _snap_armed: bool = true
var _flick_armed: Dictionary = {}  # controller -> bool, for locked-mode steps
var _scroll_acc: float = 0.0  # fractional wheel notches carried between frames


func _process(delta: float) -> void:
	if _origin == null or _camera == null:
		return
	var right_free := _right != null and not right_scrolls
	if _right != null and right_scrolls:
		_apply_scroll(_right.get_vector2("primary").y, delta)
	else:
		_scroll_acc = 0.0
	if locked:
		if _left != null:
			_apply_media_flick(_left, _left.get_vector2("primary"))
		if right_free:
			_apply_media_flick(_right, _right.get_vector2("primary"))
		return
	if _left != null:
		_apply_move(_left.get_vector2("primary"), delta)
	if right_free:
		_apply_snap_turn(_right.get_vector2("primary"))


## Continuous: speed scales with deflection. Stick up = scroll up.
func _apply_scroll(y: float, delta: float) -> void:
	if absf(y) < dead_zone:
		_scroll_acc = 0.0
		return
	_scroll_acc += y * scroll_notches_per_second * delta
	var whole := int(_scroll_acc)  # truncates toward zero
	if whole != 0:
		_scroll_acc -= whole
		scroll_step.emit(whole)


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


func _apply_media_flick(controller: XRController3D, stick: Vector2) -> void:
	var armed: bool = _flick_armed.get(controller, true)
	if armed and stick.length() > snap_threshold:
		# Dominant axis wins so a diagonal push doesn't fire both.
		if absf(stick.x) >= absf(stick.y):
			seek_step.emit(1 if stick.x > 0.0 else -1)
		else:
			volume_step.emit(1 if stick.y > 0.0 else -1)
		_flick_armed[controller] = false
	elif not armed and stick.length() < rearm_threshold:
		_flick_armed[controller] = true
