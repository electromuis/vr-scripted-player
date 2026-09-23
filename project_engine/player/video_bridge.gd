class_name VideoBridge
extends Node

## Owns a gde_gozen VideoPlayback (FFmpeg-based decoder). Exposes a small,
## decoder-agnostic API so main.gd doesn't touch gozen internals.
##
## Design: VideoPlayback is a Control that renders its video with a
## `shader_type canvas_item` YUV→RGB shader. That won't run on a 3D mesh
## directly, so we host the VideoPlayback inside a SubViewport and expose
## its ViewportTexture. Consumers (spawned Screen prefabs) sample that
## texture through their own artist shader; the bridge itself no longer
## owns any 3D geometry.

signal video_loaded(duration_seconds: float, framerate: float)

const PLAYBACK_SCRIPT_PATH := "res://addons/gde_gozen/video_playback.gd"

var _viewport: SubViewport
var _vp: Node  # VideoPlayback (Control) — null if the gozen addon didn't load
var _loaded: bool = false


func _ready() -> void:
	var script = load(PLAYBACK_SCRIPT_PATH)
	if script == null:
		push_warning("VideoBridge: gde_gozen not loadable; video playback disabled.")
		return

	_viewport = SubViewport.new()
	_viewport.name = "VideoViewport"
	_viewport.size = Vector2i(1280, 720)  # resized to actual video resolution on load
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.transparent_bg = false
	_viewport.disable_3d = true
	add_child(_viewport)

	_vp = script.new()
	_vp.name = "VideoPlayback"
	_vp.enable_audio = true
	_vp.enable_auto_play = false
	_vp.anchor_right = 1.0
	_vp.anchor_bottom = 1.0
	_viewport.add_child(_vp)
	_vp.video_loaded.connect(_on_video_loaded)


## Returns the ViewportTexture that carries the decoded video. Safe to
## call before a video has loaded — the texture just reads black until
## VideoPlayback starts rendering.
func get_output_texture() -> Texture2D:
	return _viewport.get_texture() if _viewport != null else null


func load_video(os_path: String) -> void:
	if _vp == null:
		return
	_loaded = false
	_vp.set_video_path(os_path)


func play() -> void:
	if _vp != null and _loaded:
		_vp.play()


func pause() -> void:
	if _vp != null and _loaded:
		_vp.pause()


func seek_seconds(t: float) -> void:
	if _vp == null or not _loaded:
		return
	var fps: float = _vp.get_video_framerate()
	if fps <= 0.0:
		return
	_vp.seek_frame(int(round(t * fps)))


func is_playing() -> bool:
	return _vp != null and _loaded and _vp.is_playing


func duration_seconds() -> float:
	return _vp.get_video_length_float() if (_vp != null and _loaded) else 0.0


func playhead_seconds() -> float:
	return _vp.get_current_playback_position_float() if (_vp != null and _loaded) else 0.0


func _on_video_loaded() -> void:
	_loaded = true
	# Match the SubViewport size to the video's native resolution so we
	# don't scale up or down.
	var w: int = _vp.video.get_resolution().x
	var h: int = _vp.video.get_resolution().y
	if w > 0 and h > 0:
		_viewport.size = Vector2i(w, h)
	video_loaded.emit(duration_seconds(), _vp.get_video_framerate())
