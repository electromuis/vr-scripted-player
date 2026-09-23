@tool
class_name VJScreen
extends Node3D

## Video screen prefab for the VJ authoring project. Runs an artist shader
## over a video texture inside a SubViewport at reduced resolution, then
## samples the result on a 3D quad. Mirrors the runtime Screen used by the
## player so what the artist sees in the template project matches what the
## audience sees.
##
## The player runtime injects the video texture at play time via
## `set_source_texture()`. In the editor, the shader runs with a null source
## texture — parameters like `video_uv_bounds` and the glow controls are still
## authorable and previewable against a blank canvas.

const _SOURCE_TEX_UNIFORM := "screen_tex"
const _BASE_RENDER_RES := Vector2i(1920, 1080)

## Fraction of the base 1920×1080 render target used for the artist shader.
## Lower = faster (fewer fragments) but softer. Surfaced to the exporter as
## `config.render_scale`.
@export_range(0.05, 2.0, 0.05) var render_scale: float = 1.0 :
	set(value):
		render_scale = clampf(value, 0.05, 2.0)
		_apply_render_scale()

@onready var mesh: MeshInstance3D = $Mesh
@onready var render_viewport: SubViewport = $RenderViewport
@onready var canvas: ColorRect = $RenderViewport/Canvas

var _display_material: StandardMaterial3D
var _source_texture: Texture2D


func _ready() -> void:
	render_viewport.transparent_bg = true
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	render_viewport.disable_3d = true

	_display_material = StandardMaterial3D.new()
	_display_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_display_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_display_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	_display_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_display_material.albedo_texture = render_viewport.get_texture()
	mesh.material_override = _display_material

	_apply_render_scale()
	_wire_source_texture()


func set_shader_material(mat: ShaderMaterial) -> void:
	canvas.material = mat
	_wire_source_texture()


func get_shader_material() -> ShaderMaterial:
	# Robust against being called before `_ready` (e.g. by the exporter, which
	# instantiates the scene without adding it to the tree so @onready doesn't
	# run). Fall back to a direct node lookup.
	var c: ColorRect = canvas
	if c == null:
		c = get_node_or_null("RenderViewport/Canvas") as ColorRect
	if c == null:
		return null
	return c.material as ShaderMaterial


func set_source_texture(tex: Texture2D) -> void:
	_source_texture = tex
	_wire_source_texture()


func set_render_scale(scale: float) -> void:
	render_scale = scale


func _apply_render_scale() -> void:
	if render_viewport == null:
		return
	render_viewport.size = Vector2i(Vector2(_BASE_RENDER_RES) * render_scale)


func _wire_source_texture() -> void:
	if _source_texture == null or canvas == null:
		return
	var mat := get_shader_material()
	if mat != null:
		mat.set_shader_parameter(_SOURCE_TEX_UNIFORM, _source_texture)
