class_name Screen
extends Node3D

## Scripted VJ screen. Runs an artist-supplied shader over a video texture
## inside a SubViewport at reduced resolution, then samples the result on a
## 3D quad. Expensive per-fragment work (e.g. glow blurs) is done at a
## fraction of the visible pixel count; the display quad is a cheap
## unshaded blit with alpha.
##
## Data flow:
##   VideoBridge viewport texture
##          |
##          v  set_source_texture()  ->  shader uniform `screen_tex`
##   Canvas (ColorRect + artist ShaderMaterial) in RenderViewport
##          |
##          v  ViewportTexture
##   Mesh (MeshInstance3D, unshaded StandardMaterial3D, TRANSPARENCY_ALPHA)

const _SOURCE_TEX_UNIFORM := "screen_tex"
const _BASE_RENDER_RES := Vector2i(1920, 1080)

@onready var mesh: MeshInstance3D = $Mesh
@onready var render_viewport: SubViewport = $RenderViewport
@onready var canvas: ColorRect = $RenderViewport/Canvas

var _display_material: StandardMaterial3D
var _source_texture: Texture2D  # last-received source; re-applied whenever the material or texture changes


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

	_wire_source_texture()


func set_shader_material(mat: ShaderMaterial) -> void:
	canvas.material = mat
	_wire_source_texture()


func get_shader_material() -> ShaderMaterial:
	return canvas.material as ShaderMaterial


## Wire the source video texture into the artist shader.
## Safe to call in any order relative to set_shader_material() and _ready().
func set_source_texture(tex: Texture2D) -> void:
	_source_texture = tex
	_wire_source_texture()


func set_render_scale(scale: float) -> void:
	var s := clampf(scale, 0.05, 2.0)
	render_viewport.size = Vector2i(Vector2(_BASE_RENDER_RES) * s)


## Called by the runner with the object's `config` block.
## Recognised keys: render_scale (float). Shader is supplied via `mat`,
## with its shader_params already baked in by the runner.
func configure(cfg: Dictionary, mat: ShaderMaterial) -> void:
	if mat != null:
		set_shader_material(mat)
	if cfg.has("render_scale"):
		set_render_scale(float(cfg["render_scale"]))


func _wire_source_texture() -> void:
	if _source_texture == null or canvas == null:
		return
	var mat := get_shader_material()
	if mat != null:
		mat.set_shader_parameter(_SOURCE_TEX_UNIFORM, _source_texture)
