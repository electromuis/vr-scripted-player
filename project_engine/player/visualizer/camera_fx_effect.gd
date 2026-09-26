class_name CameraFxEffect
extends CompositorEffect

## The compositor pass behind CameraFx: after everything is drawn (video and
## see-through layers included), per eye, copy the image and run the
## current effect's compute shader over it. Needs the Forward+ or Mobile
## renderer (RenderingDevice); on Compatibility it never runs.
##
## Main-thread side (CameraFx) sets `code`, `values`, `strength`, `audio`,
## `audio_texture` and `masks`; everything else happens on the render
## thread, including compiling a changed `code`. A compile error lands in
## `error` (read on the main thread).

const MAX_MASKS := 4
const _DATA_FLOATS := CameraFxShaders.MAX_PARAMS + MAX_MASKS * 8
const _CONTEXT := &"camera_fx"
const _COPY := &"view_copy"

## Effect source (see CameraFxShaders); "" = off.
var code: String = ""
var values: PackedFloat32Array = PackedFloat32Array()
var strength: float = 0.0
## level, bass, mid, high
var audio: Vector4 = Vector4.ZERO
var audio_texture: RID
## Quads to leave untouched, 4 world-space corners each (menus).
var masks: Array[PackedVector3Array] = []
var error: String = ""

var _rd: RenderingDevice
var _compiled_code: String = ""
var _shader: RID
var _pipeline: RID
var _copy_shader: RID
var _copy_pipeline: RID
var _sampler: RID
var _buffer: RID
var _blank_audio: RID
var _time_start := Time.get_ticks_msec()
var _mask_count := 0  # masks in the data buffer for the current view


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_setup)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd != null:
		for rid in [_pipeline, _shader, _copy_pipeline, _copy_shader, _sampler, _buffer, _blank_audio]:
			if rid.is_valid():
				_rd.free_rid(rid)


func _setup() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var copy_src := RDShaderSource.new()
	copy_src.source_compute = CameraFxShaders.COPY_SOURCE
	var copy_spirv := _rd.shader_compile_spirv_from_source(copy_src)
	if copy_spirv.compile_error_compute != "":
		push_error("CameraFx copy shader: " + copy_spirv.compile_error_compute)
		return
	_copy_shader = _rd.shader_create_from_spirv(copy_spirv)
	_copy_pipeline = _rd.compute_pipeline_create(_copy_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var zeros := PackedFloat32Array()
	zeros.resize(_DATA_FLOATS)
	_buffer = _rd.storage_buffer_create(_DATA_FLOATS * 4, zeros.to_byte_array())
	# Stands in for the audio texture when there's none (silence).
	var tf := RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.width = 1
	tf.height = 1
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_blank_audio = _rd.texture_create(tf, RDTextureView.new(), [PackedByteArray([0, 0, 0, 255])])


## Compiles `code` if it changed. Render thread.
func _update_pipeline() -> bool:
	if code == _compiled_code:
		return _pipeline.is_valid()
	_compiled_code = code
	for rid in [_pipeline, _shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_pipeline = RID()
	_shader = RID()
	if code == "":
		error = ""
		return false
	var src := RDShaderSource.new()
	src.source_compute = CameraFxShaders.build_source(code)
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv.compile_error_compute != "":
		error = CameraFxShaders.explain_error(code, spirv.compile_error_compute)
		push_warning("Camera effect didn't compile: " + error)
		return false
	error = ""
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	return true


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or strength <= 0.0:
		return
	if not _update_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data() as RenderSceneDataRD
	if buffers == null or scene == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var views := buffers.get_view_count()
	if not buffers.has_texture(_CONTEXT, _COPY):
		buffers.create_texture(_CONTEXT, _COPY, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
				RenderingDevice.TEXTURE_SAMPLES_1, size, views, 1, true, false)
	var groups := Vector3i(ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	var audio_rid := audio_texture if audio_texture.is_valid() else _blank_audio
	var time := (Time.get_ticks_msec() - _time_start) / 1000.0
	for view in views:
		var color := buffers.get_color_layer(view)
		var copy := buffers.get_texture_slice(_CONTEXT, _COPY, view, 0, 1, 1)
		_rd.buffer_update(_buffer, 0, _DATA_FLOATS * 4, _data_for(scene, view).to_byte_array())

		var copy_push := PackedFloat32Array([size.x, size.y, 0.0, 0.0]).to_byte_array()
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _copy_pipeline)
		_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_copy_shader, 0, [
				_image_uniform(0, color), _image_uniform(1, copy)]), 0)
		_rd.compute_list_set_push_constant(list, copy_push, copy_push.size())
		_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
		_rd.compute_list_add_barrier(list)

		var push := PackedFloat32Array([size.x, size.y, time, clampf(strength, 0.0, 1.0),
				audio.x, audio.y, audio.z, audio.w]).to_byte_array()
		push.append_array(PackedInt32Array([view, _mask_count, CameraFxShaders.MAX_PARAMS, 0]).to_byte_array())
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(_shader, 0, [
				_image_uniform(0, color),
				_sampler_uniform(1, copy),
				_sampler_uniform(2, audio_rid),
				_buffer_uniform(3, _buffer)]), 0)
		_rd.compute_list_set_push_constant(list, push, push.size())
		_rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
		_rd.compute_list_end()



## Params, then each mask's corners projected to this eye's uv (0..1,
## top-left). Masks behind the eye are skipped.
func _data_for(scene: RenderSceneDataRD, view: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(_DATA_FLOATS)
	for i in mini(values.size(), CameraFxShaders.MAX_PARAMS):
		data[i] = values[i]
	_mask_count = 0
	var eye_xf := scene.get_cam_transform() * Transform3D(Basis(), scene.get_view_eye_offset(view))
	var to_view := eye_xf.affine_inverse()
	var proj := scene.get_view_projection(view)
	for quad in masks:
		if _mask_count >= MAX_MASKS or quad.size() != 4:
			continue
		var ok := true
		var corners: Array[Vector2] = []
		for p in quad:
			var v := to_view * p
			if v.z >= -0.01:
				ok = false  # a corner behind the eye: skip rather than guess
				break
			var clip := proj * Vector4(v.x, v.y, v.z, 1.0)
			var ndc := Vector2(clip.x, clip.y) / clip.w
			corners.append(Vector2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5))
		if not ok:
			continue
		var o := CameraFxShaders.MAX_PARAMS + _mask_count * 8
		for i in 4:
			data[o + i * 2] = corners[i].x
			data[o + i * 2 + 1] = corners[i].y
		_mask_count += 1
	return data


static func _image_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _sampler_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(rid)
	return u


static func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u
