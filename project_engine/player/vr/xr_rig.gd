class_name XRRig
extends XROrigin3D

## The VR-side counterpart to the desktop camera. Owns an XRCamera3D, two
## XRController3D, a wrist HUD on the left controller, an XRToolsFunctionPointer
## on the right controller, and a black fade quad parented to the camera for
## in-headset fade_to_black transitions (the CanvasLayer FadeOverlay only
## renders to the desktop mirror).
##
## Buttons and sticks mean nothing here: InputRouter (see `router`) turns
## them into commands from the user's bindings. The rig tells it when the
## laser is on a panel (the "menus" context: the right stick scrolls, the
## trigger clicks).
##
## The rig is added to the scene tree but stays hidden until VR is entered.
## The Stage shows and hides it with VR; main.gd does the wiring (the wrist
## HUD to the runner, menu_button to the floating panel).

## Debug: log every controller button press to stdout so it's easy to
## verify which action names the current headset's interaction profile is
## sending (what they do is up to InputRouter). Turn off once wiring is
## settled.
const DEBUG_LOG_BUTTONS := true

## Polls these controllers; set by the Stage.
var router: InputRouter:
	set(value):
		router = value
		if router != null:
			router.left = left_controller
			router.right = right_controller
		if movement != null:
			movement.router = router

@onready var xr_camera: XRCamera3D = $XRCamera3D
@onready var left_controller: XRController3D = $LeftController
@onready var right_controller: XRController3D = $RightController
@onready var wrist_panel: XRToolsViewport2DIn3D = $LeftController/WristHud
@onready var fade_quad: MeshInstance3D = $XRCamera3D/VRFade
@onready var movement: XRMovement = $Movement
@onready var pointer: XRToolsFunctionPointer = $RightController/FunctionPointer

var _fade_material: StandardMaterial3D


func _ready() -> void:
	# Fade quad starts fully transparent. Its material is duplicated per-rig
	# so multiple rigs (unlikely, but tidy) don't share alpha state.
	_fade_material = fade_quad.get_active_material(0).duplicate()
	_fade_material.render_priority = FloatingPanel.UI_RENDER_PRIORITY + 1
	fade_quad.material_override = _fade_material
	_set_fade_alpha(0.0)
	wrist_panel.material = FloatingPanel.ui_material()

	left_controller.button_pressed.connect(_on_button_pressed.bind("L"))
	right_controller.button_pressed.connect(_on_button_pressed.bind("R"))


func _process(_delta: float) -> void:
	# While the laser is on a panel its bindings (scroll, click) come first.
	if router != null:
		router.set_context("menus", pointer_panel_body() != null)


## The panel body (XRToolsViewport2DIn3D's StaticBody3D) the right laser is
## on, or null. Any pointer target that maps hits to viewport pixels counts.
func pointer_panel_body() -> Node3D:
	var t := pointer.last_target if pointer != null and pointer.enabled else null
	if t != null and is_instance_valid(t) and t.has_method("global_to_viewport"):
		return t
	return null


## Scroll the panel under the right laser by whole wheel notches (positive =
## up), as a mouse wheel at the laser's hit point.
func scroll_pointed_panel(notches: int) -> void:
	var body := pointer_panel_body()
	if body == null or notches == 0:
		return
	var sub := body.get_parent().get_node_or_null("Viewport") as SubViewport
	if sub == null:
		return
	var at: Vector2 = body.global_to_viewport(pointer.last_collided_at)
	var button := MOUSE_BUTTON_WHEEL_UP if notches > 0 else MOUSE_BUTTON_WHEEL_DOWN
	for _i in absi(notches):
		for pressed in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			ev.pressed = pressed
			ev.factor = 1.0
			ev.position = at
			ev.global_position = at
			sub.push_input(ev)


## The right controller's pointing ray as [origin, direction] (world space),
## the same ray the FunctionPointer laser uses.
func right_aim_ray() -> Array:
	var xf := right_controller.global_transform
	return [xf.origin, -xf.basis.z.normalized()]


## Whether a ray hits a quad of `size` centred on `quad_xform`'s origin in its
## local XY plane (a QuadMesh; scale in the transform is honoured). Front or
## back face both count. Static for tests.
static func ray_hits_quad(from: Vector3, dir: Vector3, quad_xform: Transform3D, size: Vector2) -> bool:
	var inv := quad_xform.affine_inverse()
	var o := inv * from
	var d := inv.basis * dir
	if absf(d.z) < 1e-6:
		return false
	var t := -o.z / d.z
	if t <= 0.0:
		return false
	var p := o + d * t
	return absf(p.x) <= size.x * 0.5 and absf(p.y) <= size.y * 0.5


## Toggle the wrist HUD's own `visible` flag. The Stage calls this on VR
## enter/exit instead of hiding the whole rig, because
## XRToolsViewport2DIn3D only re-enables its collider on its *own*
## visibility_changed signal — ancestor visibility flips don't fire it,
## so a whole-rig hide/show leaves the collider disabled and clicks
## silently drop.
func set_visuals_enabled(enabled: bool) -> void:
	wrist_panel.visible = enabled


## Return the 2D control tree hosted in the wrist panel's SubViewport. main.gd
## calls .bind(runner) on it once the runner exists.
func wrist_content() -> Node:
	var sub := wrist_panel.get_node_or_null("Viewport") as SubViewport
	if sub == null:
		return null
	# XRToolsViewport2DIn3D instantiates the scene under its Viewport child.
	# Grab the first (and only) child.
	for c in sub.get_children():
		return c
	return null


## Fade to black over half the duration, run at_black, fade back. Mirrors
## FadeOverlay.fade_through so the Stage can call one API regardless of mode.
func fade_through(duration: float, at_black: Callable) -> void:
	var half := duration * 0.5
	if half < 0.02:
		at_black.call()
		return
	var t := create_tween()
	t.tween_method(_set_fade_alpha, 0.0, 1.0, half)
	t.tween_callback(at_black)
	t.tween_method(_set_fade_alpha, 1.0, 0.0, half)


## Place the rig so the *headset* (not the rig origin) ends up at `pos`
## (XZ; eye height stays whatever tracking says) facing `yaw_deg`. Unlike
## set_view this cancels out where the user stands in their playspace and
## which way they're physically facing — what "reset view" should do.
func recenter(pos: Vector3, yaw_deg: float) -> void:
	global_transform = recentered_origin(xr_camera.transform, pos, yaw_deg)


## Origin transform that puts a head at `head_local` (relative to the
## origin) at `pos` XZ facing `yaw_deg`. Origin stays on the floor (Y=0) and
## upright. Static for tests.
static func recentered_origin(head_local: Transform3D, pos: Vector3, yaw_deg: float) -> Transform3D:
	var fwd := -head_local.basis.z
	var head_yaw := atan2(-fwd.x, -fwd.z)
	var origin_basis := Basis(Vector3.UP, deg_to_rad(yaw_deg) - head_yaw)
	var head_offset := origin_basis * Vector3(head_local.origin.x, 0.0, head_local.origin.z)
	return Transform3D(origin_basis, Vector3(pos.x, 0.0, pos.z) - head_offset)


## Snap the whole rig (XROrigin3D) to a new pose. rot_deg.y (yaw) is honored;
## pitch/roll are ignored — headset roll would be nauseating and the HMD
## already provides its own pitch/yaw offsets.
func set_view(pos: Vector3, rot_deg: Vector3) -> void:
	global_position = pos
	rotation = Vector3(0.0, deg_to_rad(rot_deg.y), 0.0)


func _on_button_pressed(action: String, hand: String) -> void:
	if DEBUG_LOG_BUTTONS:
		print("[XRRig] %s button_pressed: %s" % [hand, action])


func _set_fade_alpha(a: float) -> void:
	if _fade_material == null:
		return
	var c := _fade_material.albedo_color
	c.a = clampf(a, 0.0, 1.0)
	_fade_material.albedo_color = c
	fade_quad.visible = c.a > 0.001
