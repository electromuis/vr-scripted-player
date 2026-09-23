class_name XRRig
extends XROrigin3D

## The VR-side counterpart to the desktop camera. Owns an XRCamera3D, two
## XRController3D, a wrist HUD on the left controller, an XRToolsFunctionPointer
## on the right controller, and a black fade quad parented to the camera for
## in-headset fade_to_black transitions (the CanvasLayer FadeOverlay only
## renders to the desktop mirror).
##
## The rig is added to the scene tree but stays hidden until VR is entered.
## main.gd owns lifecycle (show/hide, wiring the wrist HUD to the runner,
## routing menu_button to the floating panel).

## Debug: log every controller button press to stdout so it's easy to
## verify which action names the current headset's interaction profile is
## sending. Turn off once wiring is settled.
const DEBUG_LOG_BUTTONS := true

signal menu_button_pressed  ## Either controller's menu — toggles floating panel.

@onready var xr_camera: XRCamera3D = $XRCamera3D
@onready var left_controller: XRController3D = $LeftController
@onready var right_controller: XRController3D = $RightController
@onready var wrist_panel: XRToolsViewport2DIn3D = $LeftController/WristHud
@onready var fade_quad: MeshInstance3D = $XRCamera3D/VRFade

var _fade_material: StandardMaterial3D


func _ready() -> void:
	# Fade quad starts fully transparent. Its material is duplicated per-rig
	# so multiple rigs (unlikely, but tidy) don't share alpha state.
	_fade_material = fade_quad.get_active_material(0).duplicate()
	fade_quad.material_override = _fade_material
	_set_fade_alpha(0.0)

	left_controller.button_pressed.connect(_on_button_pressed.bind("L"))
	right_controller.button_pressed.connect(_on_button_pressed.bind("R"))


## Toggle the wrist HUD's own `visible` flag. main.gd calls this on VR
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
## FadeOverlay.fade_through so main.gd can call one API regardless of mode.
func fade_through(duration: float, at_black: Callable) -> void:
	var half := duration * 0.5
	if half < 0.02:
		at_black.call()
		return
	var t := create_tween()
	t.tween_method(_set_fade_alpha, 0.0, 1.0, half)
	t.tween_callback(at_black)
	t.tween_method(_set_fade_alpha, 1.0, 0.0, half)


## Snap the whole rig (XROrigin3D) to a new pose. rot_deg.y (yaw) is honored;
## pitch/roll are ignored — headset roll would be nauseating and the HMD
## already provides its own pitch/yaw offsets.
func set_view(pos: Vector3, rot_deg: Vector3) -> void:
	global_position = pos
	rotation = Vector3(0.0, deg_to_rad(rot_deg.y), 0.0)


func _on_button_pressed(action: String, hand: String) -> void:
	if DEBUG_LOG_BUTTONS:
		print("[XRRig] %s button_pressed: %s" % [hand, action])
	if action == "menu_button":
		menu_button_pressed.emit()


func _set_fade_alpha(a: float) -> void:
	if _fade_material == null:
		return
	var c := _fade_material.albedo_color
	c.a = clampf(a, 0.0, 1.0)
	_fade_material.albedo_color = c
	fade_quad.visible = c.a > 0.001
