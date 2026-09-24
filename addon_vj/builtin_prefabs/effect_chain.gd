@tool
extends Node

## Editor preview of a screen's or layer's effects (its VJEffect children):
## one SubViewport pass per effect shader, each reading the previous output
## as `input_tex`, like the player's Screen does. The authored materials
## are never rendered directly; each pass runs a copy, re-synced every
## frame so scrubbing an effect param shows. A Padding effect grows its
## pass and the ones after it, and `pad_scale` is how much the quad grows
## to keep the picture the same size (see the player's Screen.pad()). Each
## pass gets `picture_rect` (and past a Rounded corners effect
## `picture_corners`), and an effect declaring `prepass_tex` gets a
## prepass at `prepass_scale` of its size, as in the player's Screen.

const PADDING_FILE := "padding.gdshader"
const ROUNDED_CORNERS_FILE := "rounded_corners.gdshader"
## Uniforms the chain sets itself; never copied from the authored material.
const CHAIN_INPUTS := ["input_tex", "display_aspect", "picture_rect", "picture_corners", "prepass_tex", "prepass"]

## The quad's growth from Padding effects, as (width, height) factors.
var pad_scale: Vector2 = Vector2.ONE

var _sources: Array[ShaderMaterial] = []
var _passes: Array[Dictionary] = []  # {material, viewport, source, prepass}
var _built: Array = []  # [material, shader] per source when built, to notice changes


## (Re)build the passes after `src` for `materials` (nulls and materials
## without a shader are skipped). Returns the texture to display.
func build(src: Texture2D, materials: Array[ShaderMaterial], px: Vector2i, aspect: float) -> Texture2D:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_passes.clear()
	_sources.clear()
	_built.clear()
	for m in materials:
		_built.append([m, m.shader if m != null else null])
		if m != null and m.shader != null:
			_sources.append(m)
	var tex := src
	for m in _sources:
		var pre: Texture2D = null
		if m.shader.code.contains("prepass_tex"):
			pre = _add_pass(m, tex, true)
		var out := _add_pass(m, tex, false)
		if pre != null:
			_passes[-1].material.set_shader_parameter("prepass_tex", pre)
		tex = out
	sync(px, aspect)
	return tex


func _add_pass(source: ShaderMaterial, input: Texture2D, prepass: bool) -> Texture2D:
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := source.duplicate() as ShaderMaterial
	mat.set_shader_parameter("input_tex", input)
	mat.set_shader_parameter("prepass", prepass)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)
	_passes.append({"material": mat, "viewport": vp, "source": source, "prepass": prepass})
	return vp.get_texture()


## Whether `materials` still matches what was built (same materials in the
## same order, same shaders).
func is_current(materials: Array[ShaderMaterial]) -> bool:
	if materials.size() != _built.size():
		return false
	for i in materials.size():
		var m := materials[i]
		if m != _built[i][0] or (m.shader if m != null else null) != _built[i][1]:
			return false
	return true


## Copy the authored params into the passes and size them: `px` is the
## picture's pixel size and `aspect` its width / height before padding.
func sync(px: Vector2i, aspect: float) -> void:
	var w := aspect
	var h := 1.0
	var size := Vector2(px)
	var corners := Vector2.ZERO
	for p in _passes:
		var src: ShaderMaterial = p.source
		var mat: ShaderMaterial = p.material
		for u in src.shader.get_shader_uniform_list():
			if not CHAIN_INPUTS.has(u.name):
				mat.set_shader_parameter(u.name, src.get_shader_parameter(u.name))
		if src.shader.resource_path.get_file() == PADDING_FILE:
			var m := maxf(float(_uniform(src, "amount", 0.0)), 0.0) * h
			size *= Vector2((w + 2.0 * m) / w, (h + 2.0 * m) / h)
			w += 2.0 * m
			h += 2.0 * m
		mat.set_shader_parameter("display_aspect", w / h)
		mat.set_shader_parameter("picture_rect", Vector4(0.5 - 0.5 * aspect / w, 0.5 - 0.5 / h, aspect / w, 1.0 / h))
		mat.set_shader_parameter("picture_corners", corners)
		if src.shader.resource_path.get_file() == ROUNDED_CORNERS_FILE and not p.prepass:
			corners = Vector2(float(_uniform(src, "radius_x", 0.0)), float(_uniform(src, "radius_y", 0.0)))
		var vp: SubViewport = p.viewport
		var fit := size
		if p.prepass:
			fit *= clampf(float(_uniform(src, "prepass_scale", 1.0)), 0.05, 1.0)
		if fit.x > 4096.0 or fit.y > 4096.0:
			fit *= 4096.0 / maxf(fit.x, fit.y)
		vp.size = Vector2i(fit.round()).max(Vector2i.ONE * 16)
	pad_scale = Vector2(w / aspect, h)


## `name`'s value on `mat`, else the shader's default, else `fallback`.
static func _uniform(mat: ShaderMaterial, name: String, fallback: Variant) -> Variant:
	var v = mat.get_shader_parameter(name)
	if v == null:
		v = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), name)
	return v if v != null else fallback
