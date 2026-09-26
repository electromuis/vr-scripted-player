class_name FloatingPanel
extends Node3D

## World-space UI panel with tabs (Camera / Files / Config / Presets).
## Toggled with the `toggle_menu` command (F2 / ≡ by default). On show,
## positions itself in front of the active camera at `distance_m`, facing
## the viewer. Both desktop mouse
## (via camera raycast → viewport push_input) and VR controllers (via
## XRToolsFunctionPointer, wired in Phase 4b) drive the same Control tree.
## In VR, holding the right grip drags it (begin_drag / end_drag).

const CONTENT_SCENE := preload("res://player/ui/floating_panel_content.tscn")
const VP2D3D_SCENE := preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
## Transparent objects draw in render-priority order before distance; UI
## panels sit above everything else (0) so a big or curved shader layer
## that sorts oddly never paints over them.
const UI_RENDER_PRIORITY := 100

@export var distance_m: float = 1.2
@export_range(0.5, 3.0) var world_width: float = 1.4
@export var viewport_px: Vector2 = Vector2(900, 600)

var _vp2d3d: XRToolsViewport2DIn3D
var _static_body: StaticBody3D
var _mouse_camera: Camera3D
var _mouse_last: Vector2 = Vector2.ZERO
var _mouse_over_panel: bool = false
var _drag_by: Node3D  # controller currently carrying the panel, or null
var _drag_offset: Vector3  # panel position in the carrying controller's frame


func _ready() -> void:
	visible = false
	_vp2d3d = VP2D3D_SCENE.instantiate()
	_vp2d3d.scene = CONTENT_SCENE
	_vp2d3d.viewport_size = viewport_px
	var aspect := viewport_px.x / maxf(viewport_px.y, 1.0)
	_vp2d3d.screen_size = Vector2(world_width, world_width / aspect)
	_vp2d3d.material = ui_material()
	add_child(_vp2d3d)
	_static_body = _vp2d3d.get_node_or_null("StaticBody3D")
	# Embed any popup windows (confirm dialogs, tooltips, etc.) inside the
	# SubViewport so they render inline on the 3D quad instead of opening as
	# native OS windows outside the headset. Note: FileDialog specifically is
	# NOT usable this way — its modal grab freezes the root viewport; the
	# Files tab uses an inline ItemList browser instead.
	var sub := _vp2d3d.get_node_or_null("Viewport") as SubViewport
	if sub != null:
		sub.gui_embed_subwindows = true


## Material for an XRToolsViewport2DIn3D panel: what it builds itself for
## unshaded + transparent, drawn at UI_RENDER_PRIORITY.
static func ui_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	m.render_priority = UI_RENDER_PRIORITY
	return m


## Attach the desktop camera whose mouse cursor should drive panel input.
func set_mouse_camera(cam: Camera3D) -> void:
	_mouse_camera = cam


## Return the 2D control tree hosted in the panel's SubViewport. Deferred:
## XRToolsViewport2DIn3D instantiates its scene during its own _ready +
## a post-draw frame, so callers should poll (see main.gd:_bind_panel_content).
func content() -> Node:
	var sub := _vp2d3d.get_node_or_null("Viewport") as SubViewport
	if sub == null:
		return null
	for c in sub.get_children():
		return c
	return null


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
	_face(cam_xform.origin)
	visible = true


## Carry the panel with `by` (a controller) until end_drag(), keeping it at
## the same offset from the controller and turned toward the viewer.
func begin_drag(by: Node3D) -> void:
	if not visible or by == null:
		return
	_drag_by = by
	_drag_offset = by.global_transform.affine_inverse() * global_position


func end_drag() -> void:
	_drag_by = null


## Face `target` (Y-up billboard). look_at points -Z at the target; the quad's
## front is +Z, so turn around.
func _face(target: Vector3) -> void:
	if global_position.is_equal_approx(target):
		return
	look_at(target, Vector3.UP)
	rotate_object_local(Vector3.UP, PI)


func hide_panel() -> void:
	# Hidden panels don't forward input, so a button still held now (e.g. the
	# click that picked a video and closed us) would never see its release and
	# stay stuck down in the SubViewport. Release it here instead.
	if _mouse_over_panel:
		for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if Input.is_mouse_button_pressed(button):
				var up := InputEventMouseButton.new()
				up.button_index = button
				up.pressed = false
				up.position = _mouse_last
				up.global_position = _mouse_last
				_push(up)
	_mouse_over_panel = false
	_drag_by = null
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _drag_by != null:
		global_position = _drag_by.global_transform * _drag_offset
		var cam := _active_camera()
		if cam != null:
			_face(cam.global_position)
	# The desktop mouse only drives the panel while the desktop camera is the
	# one rendering; in VR its stray motion would fight the controller laser.
	if _mouse_camera == null or _static_body == null or not _mouse_camera.current:
		_mouse_over_panel = false
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
		# Forward double-click so widgets like ItemList / Tree that discriminate
		# single vs. double see the correct flag.
		out.double_click = mb.double_click
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
