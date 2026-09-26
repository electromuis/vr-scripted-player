class_name ScreenSettings
extends RefCounted

## User-facing screen preferences applied to a wrapper `ScreenMount` node
## that parents `main_screen`. Because these live on the mount and the
## runner's transform tracks write to the child, offsets never drift with
## script animation.
##
## Units:
##   size       — scale multiplier on the mount (dimensionless), about
##                the screen's centre (the `pivot` passed in), so resizing
##                doesn't shift the screen up or down
##   distance   — meters pushed along -Z (positive = further from viewer)
##   height     — meters added to Y (positive = up)
##   tilt       — degrees the screen orbits around the viewer's eye
##                (positive = swings up overhead and faces down, for
##                reclined viewing; it stays at the same distance)
##   curvature  — 0..1, flat to half-cylinder; not a mount transform —
##                the Stage pushes it to the screen's display shader
##   vertical_curvature — 0..1, the same bend top-to-bottom
##   opacity    — 0..1, likewise a display-shader value, not a transform
##   resolution — RESOLUTION_MIN..RESOLUTION_MAX multiplier on the pixel
##                size the shader and effect passes render at (see
##                Screen.set_resolution_scale); lower is cheaper and softer
##   effects    — effect shaders run in order over the picture:
##                [{shader: VisualizerShaders key ("" = none picked),
##                params: {uniform: value}}] (see Screen.set_effects)

signal changed

const RESOLUTION_MIN := 0.1
const RESOLUTION_MAX := 2.0
## Effects added, removed or re-picked, or everything replaced by
## from_dict: controls built from the effect list need rebuilding.
## `changed` fires too.
signal structure_changed

var size: float = 1.0: set = _set_size
var distance: float = 0.0: set = _set_distance
var height: float = 0.0: set = _set_height
var tilt: float = 0.0: set = _set_tilt
var curvature: float = 0.0: set = _set_curvature
var vertical_curvature: float = 0.0: set = _set_vertical_curvature
var opacity: float = 1.0: set = _set_opacity
var resolution: float = 1.0: set = _set_resolution
var effects: Array[Dictionary] = []


func from_dict(d: Dictionary) -> void:
	# Bypass setters so we emit `changed` once at the end, not four times.
	size = float(d.get("size", 1.0))
	distance = float(d.get("distance", 0.0))
	height = float(d.get("height", 0.0))
	tilt = float(d.get("tilt", 0.0))
	curvature = float(d.get("curvature", 0.0))
	vertical_curvature = float(d.get("vertical_curvature", 0.0))
	opacity = float(d.get("opacity", 1.0))
	resolution = float(d.get("resolution", 1.0))
	effects.clear()
	var list = d.get("effects", [])
	if typeof(list) == TYPE_ARRAY:
		for e in list:
			if typeof(e) == TYPE_DICTIONARY:
				var params = e.get("params", {})
				effects.append({
					"shader": String(e.get("shader", "")),
					"params": params.duplicate() if typeof(params) == TYPE_DICTIONARY else {},
				})
	# The built-in oval mask of an earlier version becomes an Oval mask effect.
	var mask = d.get("mask", {})
	if typeof(mask) == TYPE_DICTIONARY and bool(mask.get("enabled", false)):
		effects.append({"shader": VisualizerShaders.OVAL_MASK, "params": {
			"outside": bool(mask.get("outside", true)),
			"size": float(mask.get("size", 1.0)),
			"ratio": float(mask.get("ratio", 16.0 / 9.0)),
			"blur": float(mask.get("feather", 0.2)),
			"level": float(mask.get("level", 0)),
		}})
	structure_changed.emit()
	changed.emit()


func to_dict() -> Dictionary:
	return {
		"size": size,
		"distance": distance,
		"height": height,
		"tilt": tilt,
		"curvature": curvature,
		"vertical_curvature": vertical_curvature,
		"opacity": opacity,
		"resolution": resolution,
		"effects": effects.duplicate(true),
	}


## Append an effect running `key` ("" = none picked yet).
func add_effect(key: String = "") -> void:
	effects.append({"shader": key, "params": {}})
	structure_changed.emit()
	changed.emit()


func remove_effect(index: int) -> void:
	if index < 0 or index >= effects.size():
		return
	effects.remove_at(index)
	structure_changed.emit()
	changed.emit()


## Move effect `index` by `step` places (-1 = up, runs earlier). No-op at
## the ends of the list.
func move_effect(index: int, step: int) -> void:
	var to := index + step
	if index < 0 or index >= effects.size() or to < 0 or to >= effects.size() or step == 0:
		return
	var effect: Dictionary = effects[index]
	effects.remove_at(index)
	effects.insert(to, effect)
	structure_changed.emit()
	changed.emit()


## Re-pick effect `index`'s shader; its params go back to the defaults.
func set_effect_shader(index: int, key: String) -> void:
	if index < 0 or index >= effects.size() or effects[index].shader == key:
		return
	effects[index] = {"shader": key, "params": {}}
	structure_changed.emit()
	changed.emit()


func set_effect_param(index: int, param: String, value: Variant) -> void:
	if index < 0 or index >= effects.size():
		return
	var params: Dictionary = effects[index].params
	if params.get(param) == value:
		return
	params[param] = value
	changed.emit()


## Apply size + position offsets to a mount node. Called whenever the
## settings change or the mount is (re)created. `viewer` is the viewer's eye
## in the mount's parent space: tilt orbits the screen around it (about the
## viewer's right axis, from `viewer_yaw_deg`), so the screen keeps facing
## the viewer at the same distance instead of pitching in place. `pivot` is
## the screen's centre in the mount's space, which size scales about.
func apply_to_mount(mount: Node3D, viewer: Vector3 = Vector3.ZERO, viewer_yaw_deg: float = 0.0,
		pivot: Vector3 = Vector3.ZERO) -> void:
	if mount == null:
		return
	mount.transform = mount_transform(viewer, viewer_yaw_deg, pivot)


## The mount transform apply_to_mount sets. Separate for tests.
func mount_transform(viewer: Vector3 = Vector3.ZERO, viewer_yaw_deg: float = 0.0,
		pivot: Vector3 = Vector3.ZERO) -> Transform3D:
	var scaled := Transform3D(Basis(), pivot) 			* Transform3D(Basis.from_scale(Vector3.ONE * size), Vector3.ZERO) 			* Transform3D(Basis(), -pivot)
	var offset := Transform3D(Basis(), Vector3(0.0, height, -distance)) * scaled
	var right := Basis(Vector3.UP, deg_to_rad(viewer_yaw_deg)) * Vector3.RIGHT
	# Positive rotation about the right axis lifts a point in front of the
	# viewer (-Z) and turns its +Z face down toward them.
	var orbit := Transform3D(Basis(), viewer) 			* Transform3D(Basis(right, deg_to_rad(tilt)), Vector3.ZERO) 			* Transform3D(Basis(), -viewer)
	return orbit * offset


func _set_size(v: float) -> void:
	if v == size:
		return
	size = v
	changed.emit()


func _set_distance(v: float) -> void:
	if v == distance:
		return
	distance = v
	changed.emit()


func _set_height(v: float) -> void:
	if v == height:
		return
	height = v
	changed.emit()


func _set_tilt(v: float) -> void:
	if v == tilt:
		return
	tilt = v
	changed.emit()


func _set_curvature(v: float) -> void:
	if v == curvature:
		return
	curvature = v
	changed.emit()


func _set_opacity(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if v == opacity:
		return
	opacity = v
	changed.emit()


func _set_resolution(v: float) -> void:
	v = clampf(v, RESOLUTION_MIN, RESOLUTION_MAX)
	if v == resolution:
		return
	resolution = v
	changed.emit()


func _set_vertical_curvature(v: float) -> void:
	if v == vertical_curvature:
		return
	vertical_curvature = v
	changed.emit()
