@tool
extends Node

## Editor preview of a screen's or layer's effects (VJScreen.effect_1..4):
## one SubViewport pass per effect shader, each reading the previous output
## as `input_tex`, like the player's Screen does. The authored materials
## are never rendered directly; each pass runs a copy, re-synced every
## frame so scrubbing an effect param shows. A Padding effect grows its
## pass and the ones after it, and `pad_scale` is how much the quad grows
## to keep the picture the same size (see the player's Screen.pad()).

const PADDING_FILE := "padding.gdshader"

## The quad's growth from Padding effects, as (width, height) factors.
var pad_scale: Vector2 = Vector2.ONE

var _sources: Array[ShaderMaterial] = []
var _passes: Array[Dictionary] = []  # {material, viewport, source}
var _shaders: Array = []  # each source's shader when built, to notice re-picks


## (Re)build the passes after `src` for `materials` (nulls and materials
## without a shader are skipped). Returns the texture to display.
func build(src: Texture2D, materials: Array[ShaderMaterial], px: Vector2i, aspect: float) -> Texture2D:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_passes.clear()
	_sources.clear()
	_shaders.clear()
	for m in materials:
		_shaders.append(m.shader if m != null else null)
		if m != null and m.shader != null:
			_sources.append(m)
	var tex := src
	for m in _sources:
		var vp := SubViewport.new()
		vp.transparent_bg = true
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := m.duplicate() as ShaderMaterial
		mat.set_shader_parameter("input_tex", tex)
		rect.material = mat
		vp.add_child(rect)
		add_child(vp)
		_passes.append({"material": mat, "viewport": vp, "source": m})
		tex = vp.get_texture()
	sync(px, aspect)
	return tex


## Whether `materials` still matches what was built (same slots, shaders).
func is_current(materials: Array[ShaderMaterial]) -> bool:
	if materials.size() != _shaders.size():
		return false
	for i in materials.size():
		var s = materials[i].shader if materials[i] != null else null
		if s != _shaders[i]:
			return false
	return true


## Copy the authored params into the passes and size them: `px` is the
## picture's pixel size and `aspect` its width / height before padding.
func sync(px: Vector2i, aspect: float) -> void:
	var w := aspect
	var h := 1.0
	var size := Vector2(px)
	for p in _passes:
		var src: ShaderMaterial = p.source
		var mat: ShaderMaterial = p.material
		for u in src.shader.get_shader_uniform_list():
			if u.name != "input_tex" and u.name != "display_aspect":
				mat.set_shader_parameter(u.name, src.get_shader_parameter(u.name))
		if src.shader.resource_path.get_file() == PADDING_FILE:
			var amount = src.get_shader_parameter("amount")
			if amount == null:
				amount = RenderingServer.shader_get_parameter_default(src.shader.get_rid(), "amount")
			var m := maxf(float(amount) if amount != null else 0.0, 0.0) * h
			size *= Vector2((w + 2.0 * m) / w, (h + 2.0 * m) / h)
			w += 2.0 * m
			h += 2.0 * m
		mat.set_shader_parameter("display_aspect", w / h)
		var vp: SubViewport = p.viewport
		var fit := size
		if fit.x > 4096.0 or fit.y > 4096.0:
			fit *= 4096.0 / maxf(fit.x, fit.y)
		vp.size = Vector2i(fit.round()).max(Vector2i.ONE * 16)
	pad_scale = Vector2(w / aspect, h)
