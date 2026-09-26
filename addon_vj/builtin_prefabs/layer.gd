@tool
class_name VJLayer
extends "res://addons/vj_editor/builtin_prefabs/screen.gd"

## Shader layer prefab: a sound-reactive (Shadertoy-style) shader on its
## own quad, with effects after it: the player's shader layers, placed and
## animated like any other object. Exports as the player's `layer` prefab
## (vj_prefab "layer"). Put it inside a screen or group to have it move
## with that.
##
## `shader_material` holds the layer shader, a canvas_item .gdshader such as
## addons/vj_editor/visualizer/shaders/ (the player's built-ins: Light ring,
## Spectrum bars, Video blur, and the beat-synced Beat tunnel, Laser fan and
## Kaleido pulse) or your own written the same way. Its hinted
## uniforms export as `config.params`; animate
## `<layer>:shader_material:shader_parameter/<p>` for a `<id>.layer` track.
## `render_scale` exports as `config.resolution`, a multiplier on the
## shader's `// @resolution` hint (960×540 without one), like the Camera
## tab's layer resolution.
##
## The editor has no audio, so sound-reactive shaders sit at silence here
## (and beat-synced ones have no beat grid, so they use their fallback);
## a channel tagged `// @iChannelN video` gets the preview still. The
## player is the accurate view.

const DEFAULT_RESOLUTION := Vector2i(960, 540)
const _INPUTS := ["iChannel0", "iChannel1", "iChannel2", "iChannel3", "iChannelResolution",
		"iResolution", "video_stereo", "audio_level", "audio_bass", "audio_mid", "audio_high",
		"beat_bpm", "beat_time", "beat_phase", "bar_time", "bar_phase", "beat_in_bar", "beats_per_bar",
		"beat_confidence"]

var _hints := {"resolution": Vector2i.ZERO, "channels": {}}


func _apply_material() -> void:
	_hints = parse_hints(shader_material.shader.code if shader_material != null and shader_material.shader != null else "")
	super._apply_material()
	var mesh := get_node_or_null("Mesh") as MeshInstance3D
	if mesh != null:
		mesh.visible = _render_material != null and _render_material.shader != null


func _render_size() -> Vector2i:
	var res: Vector2i = _hints.resolution
	if res == Vector2i.ZERO:
		res = DEFAULT_RESOLUTION
	if res.x == 0:
		res.x = roundi(res.y * _QUAD_ASPECT)  # the preview still stands in for a 16:9 video
	return Vector2i((Vector2(res) * render_scale).round()).max(Vector2i.ONE * 16)


func _input_uniforms() -> Array:
	return _INPUTS


func _bind_inputs(mat: ShaderMaterial) -> void:
	var size := _render_size()
	mat.set_shader_parameter("iResolution", Vector3(size.x, size.y, 1.0))
	var sizes := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	for i in 4:
		var tex: Texture2D = null
		if _hints.channels.get(i, "") == "video":
			tex = _source_texture if _source_texture != null else _preview_texture()
			sizes[i] = Vector3(tex.get_width(), tex.get_height(), 1.0)
		mat.set_shader_parameter("iChannel%d" % i, tex)
	mat.set_shader_parameter("iChannelResolution", sizes)


## The quad takes the render size's shape inside its 16:9 box, as in the
## player (Visualizer fits its screen to the shader's resolution).
func _base_scale() -> Vector2:
	var size := _render_size()
	var a := float(size.x) / size.y
	if a >= _QUAD_ASPECT:
		return Vector2(1.0, _QUAD_ASPECT / a)
	return Vector2(a / _QUAD_ASPECT, 1.0)


## The `// @resolution` and `// @iChannelN video` hints (see the player's
## VisualizerShaders.parse_hints).
static func parse_hints(code: String) -> Dictionary:
	var out := {"resolution": Vector2i.ZERO, "channels": {}}
	var m := RegEx.create_from_string("@resolution\\s+(\\d+)(?:\\s*[xX×]\\s*(\\d+))?").search(code)
	if m != null:
		if m.get_string(2) == "":
			out.resolution = Vector2i(0, int(m.get_string(1)))
		else:
			out.resolution = Vector2i(int(m.get_string(1)), int(m.get_string(2)))
	for c in RegEx.create_from_string("@iChannel([0-3])\\s+(\\w+)").search_all(code):
		out.channels[int(c.get_string(1))] = c.get_string(2).to_lower()
	return out
