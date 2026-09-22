extends Camera3D

## Free-flying desktop camera: WASD to move, space/shift for up/down,
## right-click to hold-look. Disabled automatically when the app switches
## into VR mode.

@export var move_speed: float = 5.0
@export var boost_multiplier: float = 3.0
@export var mouse_sensitivity: float = 0.003

var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false


func _ready() -> void:
	var e := transform.basis.get_euler()
	_yaw = e.y
	_pitch = e.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, -PI * 0.49, PI * 0.49)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if not current:
		return
	var input := Vector3.ZERO
	input.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input.z = Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	input.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
	if input == Vector3.ZERO:
		return
	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= boost_multiplier
	var basis_yaw := Basis(Vector3.UP, _yaw)
	var world_move := basis_yaw * input.normalized() * speed * delta
	global_position += world_move
