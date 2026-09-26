class_name StudioFlight
extends Node

## Noclip flight in Studio's Edit mode, in the headset (the desktop flies
## with WASD / E / Q already). The left stick flies where you look, up and
## down included, straight through anything; how far you push sets the
## speed (squared: small pushes are slow and precise). The right stick
## turns (snap) and, pushed up or down, rises or sinks, unless a grab is on
## (then Studio uses it to push / pull the object). While you move, a
## vignette narrows the view a little, which most people find easier on
## the stomach; the horizon never tilts.
##
## Reads the router's axes "studio_fly" (left stick) and
## "studio_right_stick"; moves the XR origin.

const MAX_SPEED := 4.0        # m/s at full push
const RISE_SPEED := 1.5       # m/s
const SNAP_DEGREES := 30.0
const SNAP_ON := 0.7
const SNAP_OFF := 0.3
## How dark the vignette's edge gets at full speed.
const VIGNETTE_MAX := 0.65

var router: InputRouter
var rig: XRRig
## Set by Studio each frame: the right stick belongs to a grab now.
var right_stick_busy := false
var enabled := false

var _snap_armed := true
var _vignette: MeshInstance3D
var _vignette_mat: ShaderMaterial
var _vignette_level := 0.0

const _VIGNETTE_SHADER := """shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, blend_mix;
uniform float strength = 0.0;
void fragment() {
	float r = length(UV - 0.5) * 2.0;
	ALBEDO = vec3(0.0);
	ALPHA = strength * smoothstep(0.55, 1.1, r);
}
"""


func _ready() -> void:
	if rig == null:
		return
	_vignette_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = _VIGNETTE_SHADER
	_vignette_mat.shader = shader
	_vignette_mat.render_priority = FloatingPanel.UI_RENDER_PRIORITY + 2
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	_vignette = MeshInstance3D.new()
	_vignette.mesh = quad
	_vignette.material_override = _vignette_mat
	_vignette.position = Vector3(0, 0, -0.35)
	_vignette.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vignette.visible = false
	rig.xr_camera.add_child(_vignette)


func _process(delta: float) -> void:
	var speed := 0.0
	if enabled and router != null and rig != null:
		speed = _fly(delta)
	_update_vignette(speed, delta)


## Moves the rig; returns how fast (0..1 of full speed) for the vignette.
func _fly(delta: float) -> float:
	var origin: XROrigin3D = rig
	var cam := rig.xr_camera
	var amount := 0.0
	# Left trigger + left stick scrubs instead (Studio's binding).
	var stick := router.axis("studio_fly")
	if stick != Vector2.ZERO and router.axis("studio_scrub") == Vector2.ZERO:
		var push := minf(stick.length(), 1.0)
		var dir := cam.global_transform.basis * Vector3(stick.x, 0.0, -stick.y).normalized()
		origin.global_position += dir * MAX_SPEED * push * push * delta
		amount = push * push
	var right := router.axis("studio_right_stick")
	if absf(right.x) > SNAP_ON and _snap_armed:
		_snap_armed = false
		# Turn about the head, not the room's centre.
		var head := cam.global_position
		origin.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(-SNAP_DEGREES * signf(right.x))), Vector3.ZERO) \
				.translated(head) * Transform3D(Basis(), -head) * origin.global_transform
	elif absf(right.x) < SNAP_OFF:
		_snap_armed = true
	if not right_stick_busy and absf(right.y) > 0.2:
		origin.global_position.y += right.y * RISE_SPEED * delta
		amount = maxf(amount, absf(right.y) * 0.6)
	return amount


func _update_vignette(target: float, delta: float) -> void:
	if _vignette == null:
		return
	# Ease in and out over about a quarter second.
	_vignette_level = move_toward(_vignette_level, target, delta * 4.0)
	_vignette.visible = _vignette_level > 0.01
	_vignette_mat.set_shader_parameter("strength", _vignette_level * VIGNETTE_MAX)
