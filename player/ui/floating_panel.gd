class_name FloatingPanel
extends Node3D

## World-space UI panel with tabs (Camera / Files / Config / Presets).
## Toggled with `toggle_panel` action. On show, positions itself in front of
## the active camera at `distance_m`, facing the viewer. Both desktop mouse
## (via camera raycast → viewport push_input) and VR controllers (via
## XRToolsFunctionPointer, wired in Phase 4b) drive the same Control tree.

const CONTENT_SCENE := preload("res://player/ui/floating_panel_content.tscn")
const VP2D3D_SCENE := preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")

@export var distance_m: float = 1.2
@export_range(0.5, 3.0) var world_width: float = 1.4
@export var viewport_px: Vector2 = Vector2(900, 600)

var _vp2d3d: XRToolsViewport2DIn3D
var _static_body: StaticBody3D
var _mouse_camera: Camera3D
var _mouse_last: Vector2 = Vector2.ZERO
var _mouse_over_panel: bool = false


func _ready() -> void:
	visible = false
	_vp2d3d = VP2D3D_SCENE.instantiate()
	_vp2d3d.scene = CONTENT_SCENE
	_vp2d3d.viewport_size = viewport_px
	var aspect := viewport_px.x / maxf(viewport_px.y, 1.0)
	_vp2d3d.screen_size = Vector2(world_width, world_width / aspect)
	_vp2d3d.unshaded = true
	add_child(_vp2d3d)
	_static_body = _vp2d3d.get_node_or_null("StaticBody3D")


## Attach the desktop camera whose mouse cursor should drive panel input.
func set_mouse_camera(cam: Camera3D) -> void:
	_mouse_camera = cam


func toggle() -> void:
	if visible:
		hide_panel()
	else:
		show_in_front_of(_active_camera())


## Currently-rendering camera from the viewport (VR camera when in VR,
## desktop camera otherwise). Falls back to the stored mouse camera if
## the viewport has none for some reason.
func _active_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	return cam if cam != null else _mouse_camera


func show_in_front_of(cam: Camera3D) -> void:
	if cam == null:
		return
	var cam_xform := cam.global_transform
	var forward := -cam_xform.basis.z
	global_position = cam_xform.origin + forward * distance_m
	# Face the viewer (Y-up billboard).
	look_at(cam_xform.origin, Vector3.UP)
	# look_at points -Z at target; we want +Z (front of quad) at viewer.
	rotate_object_local(Vector3.UP, PI)
	visible = true


func hide_panel() -> void:
	visible = false


func _process(_delta: float) -> void:
	if not visible or _mouse_camera == null or _static_body == null:
		return
	_forward_mouse()


func _forward_mouse() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var mouse_pos := viewport.get_mouse_position()
	var space := _mouse_camera.get_world_3d().direct_space_state
	var from := _mouse_camera.project_ray_origin(mouse_pos)
	var to := from + _mouse_camera.project_ray_normal(mouse_pos) * 100.0
	var query := PhysicsRayQueryParameters3D.create(from, to, _static_body.collision_layer)
	var hit := space.intersect_ray(query)
	if hit.is_empty() or hit.collider != _static_body:
		if _mouse_over_panel:
			_mouse_over_panel = false
		return
	_mouse_over_panel = true
	var vp_pos: Vector2 = _static_body.global_to_viewport(hit.position)
	if vp_pos != _mouse_last:
		var motion := InputEventMouseMotion.new()
		motion.position = vp_pos
		motion.global_position = vp_pos
		motion.relative = vp_pos - _mouse_last
		motion.button_mask = _button_mask()
		_push(motion)
		_mouse_last = vp_pos


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not _mouse_over_panel:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var out := InputEventMouseButton.new()
		out.button_index = mb.button_index
		out.pressed = mb.pressed
		out.position = _mouse_last
		out.global_position = _mouse_last
		out.button_mask = _button_mask()
		_push(out)
		get_viewport().set_input_as_handled()


func _button_mask() -> int:
	var mask := 0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		mask |= MOUSE_BUTTON_MASK_LEFT
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		mask |= MOUSE_BUTTON_MASK_RIGHT
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		mask |= MOUSE_BUTTON_MASK_MIDDLE
	return mask


func _push(event: InputEvent) -> void:
	var sub := _vp2d3d.get_node_or_null("Viewport") as SubViewport
	if sub != null:
		sub.push_input(event)
