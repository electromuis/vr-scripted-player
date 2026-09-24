@tool
class_name VJScreen
extends "res://addons/vj_editor/modifiers/vj_object.gd"

## Video screen prefab for the VJ authoring project. Runs an artist shader
## over a video texture inside a SubViewport at reduced resolution, then
## its effects (VJEffect children, effect.gd) in their own passes, then
## samples the result on a 3D quad. Mirrors the runtime Screen used by the
## player so what the artist sees in the template project roughly matches
## what the audience sees.
##
## There's no video decoder in the authoring project, so the source is a
## still: the owning VJScene's `preview_image`, or a generated three-column
## test card. The player swaps in the live video via `set_source_texture()`.
## Without an artist shader the source goes straight to the effects, as in
## the player; glows, crops and masks are all effects.
##
## Everything animatable lives on this root node so AnimationPlayer tracks
## don't need editable children:
##   main_screen:shader_material:shader_parameter/<name>  → shader_param (slot "surface")
##   main_screen:curvature / :vertical_curvature / :opacity → shader_param (slot "display")
##   main_screen/<effect>:material:shader_parameter/<name> → shader_param (slot "effect<N>")
##
## VJLayer (layer.gd) extends this with a layer shader in place of the
## artist shader; the _render_size / _input_uniforms / _bind_inputs /
## _base_scale hooks are where they differ.
##
## The modifier and reactive fields come from VJObject; `opacity` among them
## is this screen's display fade (exported as `config.opacity` and
## `<id>.display` tracks), not a mesh transparency.

const _SOURCE_TEX_UNIFORM := "screen_tex"
const _BASE_RENDER_RES := Vector2i(1920, 1080)
const _QUAD_ASPECT := 16.0 / 9.0
const _DISPLAY_SHADER := preload("res://addons/vj_editor/builtin_prefabs/screen_preview_display.gdshader")
## Stands in for a missing artist shader in the preview (never exported).
const _PASSTHROUGH_CODE := "shader_type canvas_item;
uniform sampler2D screen_tex : source_color, filter_linear;
void fragment() { COLOR = texture(screen_tex, UV); }
"
const _EffectChain := preload("res://addons/vj_editor/builtin_prefabs/effect_chain.gd")
const _EffectScript := preload("res://addons/vj_editor/builtin_prefabs/effect.gd")
## The effect slots scenes used before effects became child nodes. Still
## loaded and saved (not shown) so Tools > VJ: Convert effect slots to
## nodes can move them; the preview and export ignore them.
const LEGACY_EFFECT_SLOTS := ["effect_1", "effect_2", "effect_3", "effect_4"]

## The artist shader, optional (none shows the video as is). Exported as
## `config.shader` + `config.shader_params`. Give each instance its own
## material.
@export var shader_material: ShaderMaterial:
	set(value):
		shader_material = value
		_apply_material()

## Fraction of the base 1920×1080 render target used for the artist shader.
## Lower = faster (fewer fragments) but softer. Surfaced to the exporter as
## `config.render_scale`.
@export_range(0.05, 2.0, 0.05) var render_scale: float = 1.0:
	set(value):
		render_scale = clampf(value, 0.05, 2.0)
		_apply_render_scale()

@export_group("Display")
## Bends the quad toward the viewer: 0 = flat, 1 = half-cylinder.
## Exported as `config.curvature`; animate it for a `<id>.display` track.
@export_range(0.0, 1.0, 0.01) var curvature: float = 0.0:
	set(value):
		curvature = clampf(value, 0.0, 1.0)
		_apply_display()

## The same bend top-to-bottom. Exported as `config.vertical_curvature`.
@export_range(0.0, 1.0, 0.01) var vertical_curvature: float = 0.0:
	set(value):
		vertical_curvature = clampf(value, 0.0, 1.0)
		_apply_display()

var _display_material: ShaderMaterial
var _source_texture: Texture2D
## What the canvas actually renders with: a private copy of
## shader_material, so the preview texture never gets saved into the
## author's scene. Params are mirrored every frame (AnimationPlayer
## scrubbing writes to shader_material).
var _render_material: ShaderMaterial
var _param_names: Array[StringName] = []
var _chain: Node  # effect_chain.gd; internal, never saved
var _legacy_effects: Dictionary = {}  # LEGACY_EFFECT_SLOTS name -> ShaderMaterial

static var _test_card: ImageTexture
static var _passthrough: Shader


func _ready() -> void:
	var viewport := _render_viewport()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.disable_3d = true

	_display_material = ShaderMaterial.new()
	_display_material.shader = _DISPLAY_SHADER
	($Mesh as MeshInstance3D).material_override = _display_material
	_chain = _EffectChain.new()
	_chain.name = "_EffectPasses"
	add_child(_chain)

	_apply_render_scale()
	_apply_display()
	_apply_material()
	_rebuild_effects()
	super._ready()


func _process(_delta: float) -> void:
	var authored: Shader = shader_material.shader if shader_material != null else null
	var rendered: Shader = _render_material.shader if _render_material != null else null
	if rendered == _passthrough:
		rendered = null
	if rendered != authored:
		_apply_material()
	elif authored != null:
		for p in _param_names:
			_render_material.set_shader_parameter(p, shader_material.get_shader_parameter(p))
	if _chain == null:
		return
	if not _chain.is_current(effect_materials()):
		_rebuild_effects()
	else:
		_chain.sync(_render_size(), _picture_aspect())
		_apply_mesh_scale()


## Opacity fades the display pass (see the class notes).
func _opacity_changed() -> void:
	_apply_display()


## What reaches the meshes under this screen: everything but opacity, which
## the display pass does.
func modifier_values() -> Dictionary:
	var values := super.modifier_values()
	values.erase("opacity")
	return values


func get_shader_material() -> ShaderMaterial:
	# Works before _ready too (the exporter instantiates without a tree).
	return shader_material


func set_shader_material(mat: ShaderMaterial) -> void:
	shader_material = mat


## The VJEffect children that take part, in order.
func effect_nodes() -> Array[Node]:
	var out: Array[Node] = []
	for c in get_children():
		if c.get_script() == _EffectScript and c.is_active():
			out.append(c)
	return out


## effect_nodes()' materials.
func effect_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for e in effect_nodes():
		out.append(e.material)
	return out


## The old effect_1..4 values still on this node (slot name -> material).
func legacy_effects() -> Dictionary:
	return _legacy_effects


func _set(property: StringName, value: Variant) -> bool:
	if String(property) in LEGACY_EFFECT_SLOTS:
		if value == null:
			_legacy_effects.erase(String(property))
		else:
			_legacy_effects[String(property)] = value
		notify_property_list_changed()
		return true
	return false


func _get(property: StringName) -> Variant:
	if String(property) in LEGACY_EFFECT_SLOTS:
		return _legacy_effects.get(String(property))
	return null


func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in LEGACY_EFFECT_SLOTS:
		if _legacy_effects.has(slot):
			out.append({"name": slot, "type": TYPE_OBJECT, "hint": PROPERTY_HINT_RESOURCE_TYPE,
					"hint_string": "ShaderMaterial", "usage": PROPERTY_USAGE_STORAGE})
	return out


## Live source (the player's video). Null falls back to the preview still.
func set_source_texture(tex: Texture2D) -> void:
	_source_texture = tex
	_apply_material()


func set_render_scale(scale: float) -> void:
	render_scale = scale


## Re-read the preview still (VJScene calls this when it changes).
func refresh_preview() -> void:
	_apply_material()


func _render_viewport() -> SubViewport:
	return get_node_or_null("RenderViewport") as SubViewport


func _canvas() -> ColorRect:
	return get_node_or_null("RenderViewport/Canvas") as ColorRect


func _apply_material() -> void:
	var canvas := _canvas()
	if canvas == null:
		return
	_param_names.clear()
	_render_material = null
	if shader_material != null and shader_material.shader != null:
		_render_material = shader_material.duplicate() as ShaderMaterial
		var inputs := _input_uniforms()
		for u in shader_material.shader.get_shader_uniform_list():
			if not inputs.has(u.name):
				_param_names.append(StringName(u.name))
	elif _input_uniforms().has(_SOURCE_TEX_UNIFORM):
		if _passthrough == null:
			_passthrough = Shader.new()
			_passthrough.code = _PASSTHROUGH_CODE
		_render_material = ShaderMaterial.new()
		_render_material.shader = _passthrough
	if _render_material != null:
		_bind_inputs(_render_material)
	canvas.material = _render_material
	_apply_render_scale()


# ---------- hooks (VJLayer overrides these) ----------

## Pixel size the shader renders at.
func _render_size() -> Vector2i:
	return Vector2i(Vector2(_BASE_RENDER_RES) * render_scale)


## Uniforms fed by the preview rather than mirrored from shader_material.
func _input_uniforms() -> Array:
	return [_SOURCE_TEX_UNIFORM]


func _bind_inputs(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter(_SOURCE_TEX_UNIFORM, _source_texture if _source_texture != null else _preview_texture())


## The quad's scale before padding: a screen always fills its 16:9 box.
func _base_scale() -> Vector2:
	return Vector2.ONE


# ---------- display ----------

func _apply_render_scale() -> void:
	var viewport := _render_viewport()
	if viewport != null:
		viewport.size = _render_size()


func _apply_display() -> void:
	if _display_material == null:
		return
	_display_material.set_shader_parameter("curvature", curvature)
	_display_material.set_shader_parameter("vertical_curvature", vertical_curvature)
	_display_material.set_shader_parameter("opacity", clampf(opacity, 0.0, 1.0))


func _rebuild_effects() -> void:
	if _chain == null or _display_material == null:
		return
	var out: Texture2D = _chain.build(_render_viewport().get_texture(), effect_materials(),
			_render_size(), _picture_aspect())
	_display_material.set_shader_parameter("frame_tex", out)
	_apply_mesh_scale()


## Width / height of the picture on the quad, before padding.
func _picture_aspect() -> float:
	var b := _base_scale()
	return _QUAD_ASPECT * b.x / maxf(b.y, 0.001)


func _apply_mesh_scale() -> void:
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null or _chain == null:
		return
	var s: Vector2 = _base_scale() * _chain.pad_scale
	mesh.scale = Vector3(s.x, s.y, 1.0)


func _preview_texture() -> Texture2D:
	# The VJScene root, however deep this screen sits (groups, layers).
	var node := get_parent()
	while node != null and not node.has_method("get_preview_texture"):
		node = node.get_parent()
	if node != null:
		var tex: Texture2D = node.get_preview_texture()
		if tex != null:
			return tex
	return _get_test_card()


## Three tinted columns with 1/2/3 bars, so UV sub-rects (split screens)
## are easy to read in the preview.
static func _get_test_card() -> ImageTexture:
	if _test_card != null:
		return _test_card
	var w := 480
	var h := 270
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var tints := [Color(0.85, 0.3, 0.3), Color(0.3, 0.8, 0.4), Color(0.3, 0.45, 0.9)]
	for y in h:
		for x in w:
			var col := mini(x * 3 / w, 2)
			var c: Color = tints[col].darkened(0.55 * float(y) / h)
			if x % 30 == 0 or y % 30 == 0:
				c = c.lightened(0.35)
			img.set_pixel(x, y, c)
	for col in 3:
		var cx := col * w / 3 + w / 6
		for bar in col + 1:
			var bx := cx - col * 9 + bar * 18 - 4
			img.fill_rect(Rect2i(bx, h / 2 - 30, 8, 60), Color.WHITE)
	_test_card = ImageTexture.create_from_image(img)
	return _test_card
