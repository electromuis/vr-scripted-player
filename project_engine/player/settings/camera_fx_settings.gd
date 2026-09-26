class_name CameraFxSettings
extends RefCounted

## The camera effect a preset carries (see CameraFx / CameraFxShaders):
##   shader    — a CameraFxShaders key ("builtin:kaleidoscope" or a file
##               path); "" = none
##   strength  — 0..1, how much of the effect is blended over the view
##   params    — {uniform: value} for the effect's hinted uniforms; missing
##               ones keep the effect's defaults

signal changed
## The shader changed (its sliders need rebuilding).
signal structure_changed

var shader: String = "": set = _set_shader
var strength: float = 1.0: set = _set_strength
var params: Dictionary = {}


func from_dict(d: Dictionary) -> void:
	var p = d.get("params", {})
	shader = String(d.get("shader", ""))  # clears params when it changes
	params = p.duplicate() if typeof(p) == TYPE_DICTIONARY else {}
	strength = clampf(float(d.get("strength", 1.0)), 0.0, 1.0)
	structure_changed.emit()
	changed.emit()


## {} when there's no effect, so presets without one stay as they were.
func to_dict() -> Dictionary:
	if shader == "":
		return {}
	return {"shader": shader, "strength": strength, "params": params.duplicate()}


func set_param(param: String, value: Variant) -> void:
	if params.get(param) == value:
		return
	params[param] = value
	changed.emit()


func _set_shader(v: String) -> void:
	if v == shader:
		return
	shader = v
	params = {}
	structure_changed.emit()
	changed.emit()


func _set_strength(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(v, strength):
		return
	strength = v
	changed.emit()
