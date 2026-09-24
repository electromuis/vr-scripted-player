class_name LayerSettings
extends ScreenSettings

## ScreenSettings for one shader layer. The layer is parented to the main
## screen, so size / distance / height / tilt are relative to it (defaults
## put it on the screen) and it moves whenever the screen does. Plus:
##   shader          — a VisualizerShaders key (file path); "" = layer blank
##   params          — {uniform: value} for the shader's hinted uniforms;
##                     missing ones keep the shader's defaults
##   lock_to_screen  — centre the layer on the main screen and follow it;
##                     height / tilt are then unused and distance moves it
##                     along the screen's facing (positive = behind it)
## Layers, the video and everything else see-through draw back to front by
## depth, so distance decides what's in front.

var shader: String = "": set = _set_shader
var params: Dictionary = {}

const LEGACY_BEHIND := 0.1  # metres
var lock_to_screen: bool = false: set = _set_lock_to_screen


func from_dict(d: Dictionary) -> void:
	shader = String(d.get("shader", ""))
	var p = d.get("params", {})
	params = p.duplicate() if typeof(p) == TYPE_DICTIONARY else {}
	lock_to_screen = bool(d.get("lock_to_screen", false))
	super.from_dict(d)  # last: emits structure_changed + changed


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["shader"] = shader
	d["params"] = params.duplicate()
	d["lock_to_screen"] = lock_to_screen
	return d


func set_param(param: String, value: Variant) -> void:
	if params.get(param) == value:
		return
	params[param] = value
	changed.emit()


## A layer dict from an earlier preset's single-layer block (`visualizer`,
## `foreground` or `background`): its key-black flag becomes a leading
## Key black effect (`key_default` when the block predates the flag), and a
## background is pushed LEGACY_BEHIND further away so it stays behind the
## video now that depth decides.
static func from_legacy(d: Dictionary, behind: bool, key_default: bool) -> Dictionary:
	var out := d.duplicate(true)
	if behind:
		out["distance"] = float(d.get("distance", 0.0)) + LEGACY_BEHIND
	var effects: Array = []
	if bool(d.get("key_black", key_default)):
		effects.append({"shader": VisualizerShaders.KEY_BLACK, "params": {}})
	out["effects"] = effects
	return out


func _set_shader(v: String) -> void:
	if v == shader:
		return
	shader = v
	params = {}
	structure_changed.emit()
	changed.emit()


func _set_lock_to_screen(v: bool) -> void:
	if v == lock_to_screen:
		return
	lock_to_screen = v
	changed.emit()
