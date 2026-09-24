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
##   Effect chain (set_effects): one SubViewport pass per effect shader,
##   each reading the previous output as `input_tex`; for stereo
##   projections, one chain per eye behind an eye_crop pass
##          |
##          v
##   Mesh / Sphere (screen_display / screen_sphere shaders: projection + stereo eye split)
##
## Without an artist shader (the player's default screen for plain videos)
## the RenderViewport is skipped and the display (or the first effect)
## samples the video texture directly. Effect passes run at the
## RenderViewport's size, except after a Padding effect
## (VisualizerShaders.PADDING): that pass and the ones after it grow by its
## margin, and so does the flat quad (_pad_scale), so the picture keeps its
## size and later effects can spread past its edge. Each pass is told where
## the unpadded picture sits in it (`picture_rect`), and past a Rounded
## corners effect how round its corners are (`picture_corners`).
##
## An effect that declares `prepass_tex` (VisualizerShaders.has_prepass) gets
## a prepass: the same shader with `prepass` on, at `prepass_scale` of the
## pass's size, whose output it reads as `prepass_tex`. Heavy, soft work
## (a glow's halo) goes there, so only the sharp parts run at full size.
##
## Projection: flat keys draw on the quad; 180°/360° keys draw on a
## camera-centred sphere that only takes this node's rotation (so tilt and
## yaw still orient the video, but mount size/distance can't shrink the
## sphere around the viewer).

const _SOURCE_TEX_UNIFORM := "screen_tex"
const _BASE_RENDER_RES := Vector2i(1920, 1080)
const _DISPLAY_SHADER := preload("res://player/prefabs/screen_display.gdshader")
const _SPHERE_SHADER := preload("res://player/prefabs/screen_sphere.gdshader")
const _EYE_CROP_SHADER := preload("res://player/prefabs/eye_crop.gdshader")
const _QUAD_ASPECT := 16.0 / 9.0
const _SPHERE_RADIUS := 50.0

@onready var mesh: MeshInstance3D = $Mesh
@onready var render_viewport: SubViewport = $RenderViewport
@onready var canvas: ColorRect = $RenderViewport/Canvas

var _display_material: ShaderMaterial  # flat quad (alpha-blended)
var _sphere_material: ShaderMaterial   # immersive sphere (opaque)
var _source_texture: Texture2D  # last-received source; re-applied whenever the material or texture changes
var _sphere: MeshInstance3D
var _projection: String = "flat"
var _fit_aspect: bool = false
var _frame_aspect: float = 0.0
## set_effects state: per effect, its key, loaded shader (null = none
## picked or missing, skipped) and uniform values.
var _effect_keys: Array[String] = []
var _effect_shaders: Array[Shader] = []
var _effect_params: Array[Dictionary] = []
## Built passes: [{material, viewport, effect, prepass}] per eye chain
## (effect -1 = eye crop, which starts each stereo chain; prepass: an
## effect's prepass, just before the effect's own pass).
var _passes: Array[Dictionary] = []
var _base_scale: Vector3 = Vector3.ONE  # the quad's scale before padding
var _pad_scale: Vector2 = Vector2.ONE  # the quad's growth from Padding effects
var _chain_holder: Node
var _requested_size: Vector2i  # set_render_size's, before _resolution_scale
var _resolution_scale: float = 1.0
## configure() keys a script set ("effects", "opacity", ...): the viewer's
## screen settings leave those alone (see is_scripted).
var _scripted: Dictionary = {}


func _ready() -> void:
	render_viewport.transparent_bg = true
	render_viewport.disable_3d = true
	_requested_size = render_viewport.size

	_display_material = ShaderMaterial.new()
	_display_material.shader = _DISPLAY_SHADER
	mesh.material_override = _display_material
	_sphere_material = ShaderMaterial.new()
	_sphere_material.shader = _SPHERE_SHADER

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = _SPHERE_RADIUS
	sphere_mesh.height = _SPHERE_RADIUS * 2.0
	sphere_mesh.radial_segments = 64
	sphere_mesh.rings = 32
	_sphere = MeshInstance3D.new()
	_sphere.name = "Sphere"
	_sphere.mesh = sphere_mesh
	_sphere.material_override = _sphere_material
	_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sphere.top_level = true
	_sphere.visible = false
	_sphere.extra_cull_margin = 16384.0
	add_child(_sphere)
	_chain_holder = Node.new()
	_chain_holder.name = "Effects"
	add_child(_chain_holder)

	_wire_source_texture()
	_apply_projection()


func _process(_delta: float) -> void:
	if not _sphere.visible:
		return
	# Keep the sphere centred on whoever is looking so it always encloses
	# the camera, and follow only this node's rotation.
	var cam := get_viewport().get_camera_3d()
	var origin := cam.global_position if cam != null else global_position
	_sphere.global_transform = Transform3D(global_basis.orthonormalized(), origin)


func set_shader_material(mat: ShaderMaterial) -> void:
	canvas.material = mat
	_wire_source_texture()


func get_shader_material() -> ShaderMaterial:
	return canvas.material as ShaderMaterial


## Wire the source video texture into the artist shader (or straight into
## the display pass when there is none).
## Safe to call in any order relative to set_shader_material() and _ready().
func set_source_texture(tex: Texture2D) -> void:
	_source_texture = tex
	_wire_source_texture()


func set_render_scale(scale: float) -> void:
	var s := clampf(scale, 0.05, 2.0)
	set_render_size(Vector2i(Vector2(_BASE_RENDER_RES) * s))


## Pixel size of the artist pass and the effect passes, before the
## resolution scale.
func set_render_size(size: Vector2i) -> void:
	_requested_size = size
	_apply_render_size()


## Multiplier on the render size (ScreenSettings.resolution): the user's
## quality / speed trade-off, on top of whatever a script or shader asked for.
func set_resolution_scale(scale: float) -> void:
	scale = clampf(scale, ScreenSettings.RESOLUTION_MIN, ScreenSettings.RESOLUTION_MAX)
	if scale == _resolution_scale:
		return
	_resolution_scale = scale
	_apply_render_size()


func _apply_render_size() -> void:
	var size := Vector2i((Vector2(_requested_size) * _resolution_scale).round())
	size = size.clamp(Vector2i.ONE * 16, Vector2i.ONE * 4096)
	if size == render_viewport.size:
		return
	render_viewport.size = size
	_apply_effect_params()  # resizes the passes


## Effect shaders run in order over the output: [{shader: key, params:
## {uniform: value}}] (ScreenSettings.effects). Changing only params
## updates the running passes; a different list of shaders rebuilds them.
func set_effects(effects: Array) -> void:
	var keys: Array[String] = []
	var params: Array[Dictionary] = []
	for e in effects:
		keys.append(String(e.get("shader", "")))
		var p = e.get("params", {})
		# Copies: set_effect_param writes into them.
		params.append(p.duplicate() if typeof(p) == TYPE_DICTIONARY else {})
	_effect_params = params
	if keys == _effect_keys:
		_apply_effect_params()
		return
	_effect_keys = keys
	_effect_shaders.clear()
	for k in keys:
		_effect_shaders.append(VisualizerShaders.load_shader(k))
	_wire_source_texture()


## One uniform of effect `index` (a `shader_param` track on `<id>.effect<N>`).
func set_effect_param(index: int, param: String, value: Variant) -> void:
	if index < 0 or index >= _effect_params.size():
		return
	_effect_params[index][param] = value
	_apply_effect_params()


## Projection key from VideoProjection.KEYS (not "auto").
func set_projection(key: String) -> void:
	_projection = key
	_apply_projection()


func get_projection() -> String:
	return _projection


## Full video frame aspect (width / height). With fit_aspect enabled the
## quad letterboxes/pillarboxes to one eye's aspect inside its 16:9 box.
func set_content_aspect(frame_aspect: float) -> void:
	_frame_aspect = frame_aspect
	_apply_aspect()


## Flat-quad bend: 0 = flat, 1 = half-cylinder. Ignored for 180°/360°.
func set_curvature(amount: float) -> void:
	_set_display_param("curvature", clampf(amount, 0.0, 1.0))


## Top-to-bottom bend: 0 = flat, 1 = half-cylinder. Ignored for 180°/360°.
func set_vertical_curvature(amount: float) -> void:
	_set_display_param("vertical_curvature", clampf(amount, 0.0, 1.0))


## 0..1 fade of the flat quad (the 180°/360° sphere stays opaque).
func set_opacity(amount: float) -> void:
	_set_display_param("opacity", clampf(amount, 0.0, 1.0))


## Target for `shader_param` tracks (`<id>.<slot>`). Slot "display" drives
## the display pass (`curvature`, `vertical_curvature` and `opacity`),
## "effect<N>" the Nth effect (from 0); any other slot is the artist shader.
func set_material_param(slot: String, param: String, value: Variant) -> void:
	if slot == "display":
		match param:
			"curvature": set_curvature(float(value))
			"vertical_curvature": set_vertical_curvature(float(value))
			"opacity": set_opacity(float(value))
		return
	if slot.begins_with("effect") and slot.substr(6).is_valid_int():
		set_effect_param(int(slot.substr(6)), param, value)
		return
	var mat := get_shader_material()
	if mat != null:
		mat.set_shader_parameter(param, value)


## Called by the runner with the object's `config` block.
## Recognised keys: render_scale (float), fit_aspect (bool), curvature,
## vertical_curvature, opacity (floats), effects ([{shader: path, params}],
## see set_effects). Shader is supplied via `mat`, with its shader_params
## already baked in by the runner.
func configure(cfg: Dictionary, mat: ShaderMaterial) -> void:
	if mat != null:
		set_shader_material(mat)
	if cfg.has("render_scale"):
		set_render_scale(float(cfg["render_scale"]))
	if cfg.has("fit_aspect"):
		_fit_aspect = bool(cfg["fit_aspect"])
		_apply_aspect()
	if cfg.has("curvature"):
		set_curvature(float(cfg["curvature"]))
	if cfg.has("vertical_curvature"):
		set_vertical_curvature(float(cfg["vertical_curvature"]))
		_scripted["vertical_curvature"] = true
	if cfg.has("opacity"):
		set_opacity(float(cfg["opacity"]))
		_scripted["opacity"] = true
	if typeof(cfg.get("effects")) == TYPE_ARRAY:
		set_effects(cfg["effects"])
		_scripted["effects"] = true


## Whether the script's config set `key` (see configure).
func is_scripted(key: String) -> bool:
	return _scripted.has(key)


func _wire_source_texture() -> void:
	if canvas == null or _display_material == null:
		return
	var mat := get_shader_material()
	var out: Texture2D
	if mat == null:
		# Passthrough: no artist pass, so don't pay for the intermediate
		# viewport at all.
		render_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		out = _source_texture
	else:
		render_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		out = render_viewport.get_texture()
		if _source_texture != null:
			mat.set_shader_parameter(_SOURCE_TEX_UNIFORM, _source_texture)
	_build_chains(out)


## (Re)build the effect passes after `src` and point the display at the
## result. Stereo frames get a chain per eye, each starting with a crop to
## that eye, so effects see one eye's picture (an oval stays an oval).
func _build_chains(src: Texture2D) -> void:
	if _chain_holder == null:
		return
	for c in _chain_holder.get_children():
		_chain_holder.remove_child(c)
		c.queue_free()
	_passes.clear()
	var active: Array[int] = []
	for i in _effect_shaders.size():
		if _effect_shaders[i] != null:
			active.append(i)
	if active.is_empty() or src == null:
		_set_display_param("frame_tex", src)
		_set_display_param("eyes_split", false)
		_apply_effect_params()  # no padding left
		return
	var stereo := VideoProjection.stereo_of(_projection)
	var eyes: Array[Rect2] = [Rect2(0, 0, 1, 1)]
	if stereo == 1:
		eyes = [Rect2(0, 0, 0.5, 1), Rect2(0.5, 0, 0.5, 1)]
	elif stereo == 2:
		eyes = [Rect2(0, 0, 1, 0.5), Rect2(0, 0.5, 1, 0.5)]
	var outs: Array[Texture2D] = []
	for rect in eyes:
		var tex := src
		if eyes.size() > 1:
			tex = _add_pass(_EYE_CROP_SHADER, tex, -1)
			_passes[-1].material.set_shader_parameter("rect",
					Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
		for i in active:
			tex = _add_pass(_effect_shaders[i], tex, i)
		outs.append(tex)
	_set_display_param("frame_tex", outs[0])
	_set_display_param("frame_tex_right", outs[-1])
	_set_display_param("eyes_split", outs.size() > 1)
	_apply_effect_params()


func _add_pass(shader: Shader, input: Texture2D, effect: int) -> Texture2D:
	var pre: Texture2D = null
	if effect >= 0 and VisualizerShaders.has_prepass(shader):
		pre = _new_pass(shader, input, effect, true)
	var out := _new_pass(shader, input, effect, false)
	if pre != null:
		_passes[-1].material.set_shader_parameter("prepass_tex", pre)
	return out


func _new_pass(shader: Shader, input: Texture2D, effect: int, prepass: bool) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = render_viewport.size  # padding resizes it in _apply_effect_params
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("input_tex", input)
	if prepass:
		mat.set_shader_parameter("prepass", true)
	rect.material = mat
	vp.add_child(rect)
	_chain_holder.add_child(vp)
	_passes.append({"material": mat, "viewport": vp, "effect": effect, "prepass": prepass})
	return vp.get_texture()


## Push effect params and each pass's shape: display_aspect, and past a
## Padding effect the grown pass size and quad (walked per eye chain, in
## units of the unpadded picture's height).
func _apply_effect_params() -> void:
	var base := _display_aspect()
	var flat := _projection_shape() == VideoProjection.Shape.FLAT
	var w := base
	var h := 1.0
	var px := Vector2(render_viewport.size) if render_viewport != null else Vector2.ONE
	var corners := Vector2.ZERO
	for p in _passes:
		var i: int = p.effect
		if i < 0:
			w = base
			h = 1.0
			corners = Vector2.ZERO
			px = Vector2(render_viewport.size)
			(p.viewport as SubViewport).size = pass_size(px)
			continue
		var mat: ShaderMaterial = p.material
		var params: Dictionary = _effect_params[i] if i < _effect_params.size() else {}
		for k in params:
			mat.set_shader_parameter(k, params[k])
		var key: String = _effect_keys[i] if i < _effect_keys.size() else ""
		if flat and key == VisualizerShaders.PADDING:
			var grown := pad(w, h, px, float(params.get("amount", _param_default(key, "amount"))))
			w = grown.w
			h = grown.h
			px = grown.px
		mat.set_shader_parameter("display_aspect", w / h)
		mat.set_shader_parameter("picture_rect", picture_rect(base, w, h))
		mat.set_shader_parameter("picture_corners", corners)
		if key == VisualizerShaders.ROUNDED_CORNERS and not p.prepass:
			corners = Vector2(float(params.get("radius_x", _param_default(key, "radius_x"))),
					float(params.get("radius_y", _param_default(key, "radius_y"))))
		var size := px
		if p.prepass:
			size *= clampf(float(params.get("prepass_scale", _param_default(key, "prepass_scale", 1.0))), 0.05, 1.0)
		(p.viewport as SubViewport).size = pass_size(size)
	if _passes.is_empty():
		w = base
		h = 1.0
	_pad_scale = Vector2(w / base, h)
	if mesh != null:
		mesh.scale = _base_scale * Vector3(_pad_scale.x, _pad_scale.y, 1.0)


## One Padding step: picture `w` × `h` (in unpadded heights) rendered at
## `px` pixels, with `amount` × h added on each side. -> {w, h, px}
static func pad(w: float, h: float, px: Vector2, amount: float) -> Dictionary:
	var m := maxf(amount, 0.0) * h
	return {"w": w + 2.0 * m, "h": h + 2.0 * m,
			"px": px * Vector2((w + 2.0 * m) / w, (h + 2.0 * m) / h)}


## Where the unpadded picture (`base` wide, 1 high) sits in a pass `w` × `h`
## (Padding centres it), as UV x, y, width, height: `picture_rect`.
static func picture_rect(base: float, w: float, h: float) -> Vector4:
	return Vector4(0.5 - 0.5 * base / w, 0.5 - 0.5 / h, base / w, 1.0 / h)


## A pass's viewport size for `px` pixels, shrunk to fit 4096.
static func pass_size(px: Vector2) -> Vector2i:
	if px.x > 4096.0 or px.y > 4096.0:
		px *= 4096.0 / maxf(px.x, px.y)
	return Vector2i(px.round()).max(Vector2i.ONE * 16)


## The default of effect `key`'s uniform `param`, from its hints.
static func _param_default(key: String, param: String, fallback: float = 0.0) -> float:
	for spec in VisualizerShaders.hints_for(key).params:
		if spec.name == param:
			return float(spec.default)
	return fallback


func _projection_shape() -> int:
	return VideoProjection.shape_of(_projection)


## Width / height of the flat quad's picture, without padding.
func _display_aspect() -> float:
	return _QUAD_ASPECT * _base_scale.x / maxf(_base_scale.y, 0.001)


func _apply_projection() -> void:
	if _display_material == null:
		return
	var shape := VideoProjection.shape_of(_projection)
	_set_display_param("shape", shape)
	_set_display_param("stereo", VideoProjection.stereo_of(_projection))
	var immersive := shape != VideoProjection.Shape.FLAT
	mesh.visible = not immersive
	_sphere.visible = immersive
	_apply_aspect()
	if not _passes.is_empty():
		_wire_source_texture()  # eye chains follow the stereo layout


func _set_display_param(param: String, value: Variant) -> void:
	_display_material.set_shader_parameter(param, value)
	_sphere_material.set_shader_parameter(param, value)


func _apply_aspect() -> void:
	if mesh == null:
		return
	if not _fit_aspect or _frame_aspect <= 0.0:
		_base_scale = Vector3.ONE
	else:
		var a := VideoProjection.eye_aspect(_projection, _frame_aspect)
		if a >= _QUAD_ASPECT:
			_base_scale = Vector3(1.0, _QUAD_ASPECT / a, 1.0)
		else:
			_base_scale = Vector3(a / _QUAD_ASPECT, 1.0, 1.0)
	_apply_effect_params()  # sets mesh.scale, padding included
