class_name CameraFx
extends Node

## Full-view camera effects: kaleidoscopes, colour cycling, warps over
## everything the viewer sees. main.gd picks what shows (`show_effect`: the
## script's camera effect while one plays, else the preset's), the user's
## limits (`enabled`, `max_strength`) cap it, and the menus stay readable
## (`mask_panels` are left untouched).
##
## Renders through CameraFxEffect, a compositor pass on the
## WorldEnvironment, so it covers every camera in the world: the desktop
## view and both eyes in VR. Writing an effect: see CameraFxShaders.

## The user's switch and cap (Config tab); a script can't go past them.
var enabled: bool = true
var max_strength: float = 1.0
## Feeds the audio inputs; null = silence.
var audio: AudioAnalyzer
## XRToolsViewport2DIn3D panels whose quads the effect leaves alone.
var mask_panels: Array[Node3D] = []

var effect := CameraFxEffect.new()

var _key := ""
var _code := ""
var _specs: Array = []
var _params: Dictionary = {}
var _strength := 0.0


## Put the effect on `env`'s compositor (made if it has none).
func attach(env: WorldEnvironment) -> void:
	var comp := env.compositor if env.compositor != null else Compositor.new()
	var list := comp.compositor_effects
	if not list.has(effect):
		list.append(effect)
	comp.compositor_effects = list
	env.compositor = comp


## Which effect shows: a CameraFxShaders key ("" = none), its param values
## and its strength (0..1, before the user's cap).
func show_effect(key: String, params: Dictionary, strength: float) -> void:
	if key != _key:
		_key = key
		_code = CameraFxShaders.code_for(key)
		_specs = CameraFxShaders.params_of(_code)
	_params = params
	_strength = strength


## The strength actually applied.
func applied_strength() -> float:
	if not enabled or _code == "":
		return 0.0
	return clampf(_strength, 0.0, 1.0) * clampf(max_strength, 0.0, 1.0)


func is_running() -> bool:
	return applied_strength() > 0.0


## The current effect's compile error, "" if none (or not compiled yet).
func error_text() -> String:
	return effect.error


func _process(_delta: float) -> void:
	effect.code = _code
	effect.values = CameraFxShaders.param_values(_specs, _params)
	effect.strength = applied_strength()
	if audio != null and audio.texture != null:
		effect.audio = Vector4(audio.level, audio.bass, audio.mid, audio.high)
		effect.audio_texture = RenderingServer.texture_get_rd_texture(audio.texture.get_rid())
	else:
		effect.audio = Vector4.ZERO
		effect.audio_texture = RID()
	var masks: Array[PackedVector3Array] = []
	for panel in mask_panels:
		if is_instance_valid(panel) and panel.is_visible_in_tree():
			masks.append(panel_corners(panel))
	effect.masks = masks


## A Viewport2DIn3D panel's four world-space corners, in order around it.
static func panel_corners(panel: Node3D) -> PackedVector3Array:
	var size: Vector2 = panel.get("screen_size") if panel.get("screen_size") != null else Vector2.ONE
	var xf := panel.global_transform
	var h := size * 0.5
	return PackedVector3Array([xf * Vector3(-h.x, h.y, 0), xf * Vector3(h.x, h.y, 0),
			xf * Vector3(h.x, -h.y, 0), xf * Vector3(-h.x, -h.y, 0)])
