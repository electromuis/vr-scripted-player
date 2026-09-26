class_name VideoBridge
extends Node

## Owns a gde_gozen VideoPlayback (FFmpeg-based decoder). Exposes a small,
## decoder-agnostic API so the Stage doesn't touch gozen internals.
##
## Design: VideoPlayback is a Control that renders its video with a
## `shader_type canvas_item` YUV→RGB shader. That won't run on a 3D mesh
## directly, so we host the VideoPlayback inside a SubViewport and expose
## its ViewportTexture. Consumers (spawned Screen prefabs) sample that
## texture through their own artist shader; the bridge itself no longer
## owns any 3D geometry.
##
## Opening a video runs off the main thread too. VideoPlayback.set_video_path
## starts the open on a worker but then waits for it on the very next frame,
## so the app still stalled for the whole open (hundreds of ms locally, far
## more over DLNA). Instead the bridge opens the GoZenVideo and its audio on
## its own worker, polls for completion, and hands both to update_video().
## Opening another video meanwhile doesn't wait: the stale result is dropped.
## A failed open is retried once (network streams fail now and then) before
## video_load_failed is reported.
##
## Seeking runs off the main thread. FFmpeg's seek (find the keyframe,
## decode up to the target) can take a second or more — longer over the
## network — and done inline it froze the whole app, headset included, on
## every scrub step. A seek now runs as a WorkerThreadPool task while the
## decoder is paused; requests arriving meanwhile collapse into one follow-up
## seek to the latest position. `busy_changed` reports seeks and loads so
## the Stage can hold the timeline clock, and a "Seeking..." / "Loading..."
## card is drawn into the video frame itself (once per eye for stereo
## layouts, see set_overlay_stereo) when one takes long enough to notice.
## While a video opens, set_loading_thumbnail can put its thumbnail in the
## frame (under the "Loading..." card) instead of the old video's frame.

signal video_loaded(duration_seconds: float, framerate: float)
signal video_load_failed
## True while the frame on screen isn't the one playback should show: a
## video is opening or a seek is in flight.
signal busy_changed(busy: bool)

const PLAYBACK_SCRIPT_PATH := "res://addons/gde_gozen/video_playback.gd"
## Quick seeks finish without flashing the overlay.
const OVERLAY_DELAY_MSEC := 150
## Tries at opening a video (and its audio) before giving up.
const OPEN_ATTEMPTS := 2

var _viewport: SubViewport
var _placeholder: Control  # shown on the screen until a video has loaded
var _placeholder_title: Label
var _placeholder_hint: Label
var _overlay: Control  # "Seeking..." card over the video, see _show_overlay
var _thumb: ColorRect  # the loading video's thumbnail on black, see set_loading_thumbnail
var _thumb_image: TextureRect
var _overlay_stereo: int = VideoProjection.Stereo.MONO
var _vp: Node  # VideoPlayback (Control) — null if the gozen addon didn't load
var _loaded: bool = false
var _loading: bool = false  # a video was asked for and isn't ready yet
var _load_path: String = ""  # the video asked for most recently
var _load_task: int = -1
var _open_path: String = ""  # what _load_task is opening
var _open_attempt: int = 0  # which try _load_task is, from 1
var _opened: Array = []  # [GoZenVideo or null, AudioStream or null], set by the worker
## Worker tasks whose result no longer matters (a seek on a replaced video);
## still reaped, since every task must be waited on.
var _stale_tasks: Array[int] = []
var _volume: float = 1.0
## Whether playback should run once any seek completes (the decoder itself
## is paused while seeking).
var _want_playing: bool = false
var _seek_task: int = -1
var _seek_frame: int = 0
var _seek_error: int = OK  # written by the worker, read after it completes
var _pending_frame: int = -1  # latest request made during a seek; -1 = none
var _busy_reported: bool = false  # last busy_changed value
var _busy_since_msec: int = 0
var _overlay_text: String = ""  # what the overlay's labels say, "" = none


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
	_placeholder = _build_placeholder()
	_viewport.add_child(_placeholder)
	_placeholder_title = _placeholder.get_child(0).get_child(0)
	_placeholder_hint = _placeholder.get_child(0).get_child(1)
	_thumb = ColorRect.new()
	_thumb.name = "LoadingThumbnail"
	_thumb.color = Color.BLACK
	_thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.visible = false
	_viewport.add_child(_thumb)
	_thumb_image = TextureRect.new()
	_thumb_image.set_anchors_preset(Control.PRESET_FULL_RECT)
	_thumb_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_thumb_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb.add_child(_thumb_image)
	_overlay = Control.new()
	_overlay.name = "BusyOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	_viewport.add_child(_overlay)
	set_volume(_volume)


func _exit_tree() -> void:
	_wait_for_seek()
	for t in _stale_tasks + ([_load_task] if _load_task != -1 else []):
		WorkerThreadPool.wait_for_task_completion(t)


## Neutral "no video" card so the screen is visible against a dark skybox
## before anything is opened (the decoder output alone reads black).
static func _build_placeholder() -> Control:
	var bg := PanelContainer.new()
	bg.name = "Placeholder"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.18, 0.22)
	style.border_color = Color(0.35, 0.55, 0.9)
	style.set_border_width_all(12)
	bg.add_theme_stylebox_override("panel", style)
	var rows := VBoxContainer.new()
	rows.alignment = BoxContainer.ALIGNMENT_CENTER
	rows.add_theme_constant_override("separation", 24)
	bg.add_child(rows)
	for line in [["No video", 96, Color(0.85, 0.9, 1.0)],
			["Open the menu to pick a file", 44, Color(0.6, 0.66, 0.75)]]:
		var label := Label.new()
		label.text = line[0]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", line[1])
		label.add_theme_color_override("font_color", line[2])
		rows.add_child(label)
	return bg


## Returns the ViewportTexture that carries the decoded video. Safe to
## call before a video has loaded — the texture shows the placeholder card
## until VideoPlayback starts rendering.
func get_output_texture() -> Texture2D:
	return _viewport.get_texture() if _viewport != null else null


func load_video(os_path: String) -> void:
	if _vp == null:
		return
	if _seek_task != -1:
		# The worker holds its own reference to the old decoder; let it finish.
		_stale_tasks.append(_seek_task)
		_seek_task = -1
	_pending_frame = -1
	_loaded = false
	_loading = true
	_load_path = os_path
	_thumb.visible = false  # the caller sets this video's, if it has one
	_vp.close()  # stop the old video and its sound now
	if _load_task == -1:
		_start_open()
	# else: _finish_open sees the newer path and opens that instead.
	if _placeholder.visible:
		_set_placeholder_text("Loading...", os_path.get_file().uri_decode())
		_update_busy()
	else:
		_update_busy("Loading...")


## Show `tex` (the thumbnail of the video now opening) in the frame until
## it has loaded. Ignored once the video is ready or has failed, so a
## thumbnail that arrives late is harmless.
func set_loading_thumbnail(tex: Texture2D) -> void:
	if _vp == null or tex == null or not _loading:
		return
	_thumb_image.texture = tex
	_thumb.visible = true
	# The placeholder card is covered now; say "Loading..." on the overlay.
	_placeholder.visible = false
	_update_busy("Loading...")


## How the frame is split between the eyes (VideoProjection.Stereo), so the
## overlay card sits in the middle of each eye's view instead of on the seam.
func set_overlay_stereo(stereo: int) -> void:
	if stereo == _overlay_stereo:
		return
	_overlay_stereo = stereo
	var text := _overlay_text
	_show_overlay("")
	_show_overlay(text)


func play() -> void:
	_want_playing = true
	if _vp != null and _loaded and _seek_task == -1:
		_vp.play()


func pause() -> void:
	_want_playing = false
	if _vp != null and _loaded and _seek_task == -1:
		_vp.pause()


## Asynchronous: the frame (and audio) jump once the decoder gets there.
func seek_seconds(t: float) -> void:
	if _vp == null or not _loaded:
		return
	var fps: float = _vp.get_video_framerate()
	if fps <= 0.0:
		return
	var frame := clampi(roundi(t * fps), 0, maxi(_vp.get_video_frame_count() - 1, 0))
	if _seek_task != -1:
		_pending_frame = frame
		return
	_start_seek(frame)


func is_busy() -> bool:
	return _loading or _seek_task != -1


func _start_seek(frame: int) -> void:
	if _vp.is_playing:
		_vp.pause()
	_seek_frame = frame
	_seek_task = WorkerThreadPool.add_task(_seek_worker.bind(_vp.video, frame))
	_update_busy("Seeking...")


## Worker thread: only touches the decoder, which the main thread leaves
## alone while _seek_task is set (VideoPlayback is paused).
func _seek_worker(video: Object, frame: int) -> void:
	_seek_error = video.seek_frame(frame)


func _start_open(retry: bool = false) -> void:
	_open_attempt = _open_attempt + 1 if retry else 1
	_open_path = _load_path
	_opened = []
	_load_task = WorkerThreadPool.add_task(_open_worker.bind(_open_path))


## Worker thread: the slow part of a load (probing the file / stream).
func _open_worker(path: String) -> void:
	var video := GoZenVideo.new()
	# open() doesn't always report failure (e.g. a missing file); is_open() does.
	if video.open(path) or not video.is_open():
		video = null
	var audio: AudioStream = null
	if video != null:
		# A stream that dropped the audio probe would otherwise play silent;
		# a local file without sound isn't worth a second probe.
		var tries := OPEN_ATTEMPTS if DefaultScreen.is_url(path) else 1
		for i in tries:
			var stream := AudioStreamFFmpeg.new()
			if stream.open(path, -1) == OK:
				audio = stream
				break
	_opened = [video, audio]


func _finish_open() -> void:
	if _open_path != _load_path:
		_start_open()  # superseded while opening
		return
	var video: Object = _opened[0]
	var audio: AudioStream = _opened[1]
	_opened = []
	if video == null and _open_attempt < OPEN_ATTEMPTS:
		push_warning("VideoBridge: could not open %s, retrying." % _load_path)
		_start_open(true)
		return
	if video == null:
		_loading = false
		_thumb.visible = false
		_set_placeholder_text("Could not open video", _load_path.get_file().uri_decode())
		_placeholder.visible = true
		_update_busy()
		video_load_failed.emit()
		return
	# No audio track: say so, or update_video retries the open on this thread.
	_vp.enable_audio = audio != null
	_vp.update_video(video, audio)  # → video_loaded → _on_video_loaded


func _process(_delta: float) -> void:
	if _vp == null:
		return
	for t in _stale_tasks.duplicate():
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
			_stale_tasks.erase(t)
	if _load_task != -1 and WorkerThreadPool.is_task_completed(_load_task):
		WorkerThreadPool.wait_for_task_completion(_load_task)
		_load_task = -1
		_finish_open()
	if _overlay_text != "" and not _overlay.visible \
			and Time.get_ticks_msec() - _busy_since_msec >= OVERLAY_DELAY_MSEC:
		_overlay.visible = true
	if _seek_task == -1 or not WorkerThreadPool.is_task_completed(_seek_task):
		return
	WorkerThreadPool.wait_for_task_completion(_seek_task)
	_seek_task = -1
	_vp.current_frame = _seek_frame
	if _seek_error:
		push_warning("VideoBridge: seek to frame %d failed." % _seek_frame)
	else:
		_vp._set_frame_image()
	if _pending_frame >= 0:
		var next := _pending_frame
		_pending_frame = -1
		_start_seek(next)
		return
	_update_busy()
	if _want_playing:
		_vp.play()  # also moves the audio to current_frame


func _wait_for_seek() -> void:
	if _seek_task != -1:
		WorkerThreadPool.wait_for_task_completion(_seek_task)
		_seek_task = -1


## Call after changing _loading / _seek_task. `text` is the overlay card's;
## "" shows none (the placeholder card says it instead).
func _update_busy(text: String = "") -> void:
	var busy := is_busy()
	if busy != _busy_reported:
		_busy_reported = busy
		_busy_since_msec = Time.get_ticks_msec()
		busy_changed.emit(busy)
	_show_overlay(text if busy else "")


## Rebuilds the overlay: a dimmed frame with `text` centred in each eye's
## part of it, or nothing for "". It becomes visible from _process once
## the wait has lasted OVERLAY_DELAY_MSEC.
func _show_overlay(text: String) -> void:
	if text == _overlay_text:
		return
	_overlay_text = text
	_overlay.visible = false
	for c in _overlay.get_children():
		_overlay.remove_child(c)
		c.queue_free()
	if text == "":
		return
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(dim)
	var eyes: Array[Rect2] = [Rect2(0, 0, 1, 1)]
	match _overlay_stereo:
		VideoProjection.Stereo.SBS:
			eyes = [Rect2(0, 0, 0.5, 1), Rect2(0.5, 0, 0.5, 1)]
		VideoProjection.Stereo.TB:
			eyes = [Rect2(0, 0, 1, 0.5), Rect2(0, 0.5, 1, 0.5)]
	var eye_h := _viewport.size.y * eyes[0].size.y
	for r in eyes:
		var label := Label.new()
		label.text = text
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.anchor_left = r.position.x
		label.anchor_top = r.position.y
		label.anchor_right = r.end.x
		label.anchor_bottom = r.end.y
		label.add_theme_font_size_override("font_size", maxi(24, int(eye_h / 12.0)))
		label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", maxi(4, int(eye_h / 120.0)))
		_overlay.add_child(label)


func _set_placeholder_text(title: String, hint: String) -> void:
	_placeholder_title.text = title
	_placeholder_hint.text = hint


## Linear 0..1 volume, applied to gozen's AudioStreamPlayer.
func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	if _vp != null and _vp.audio_player != null:
		_vp.audio_player.volume_db = linear_to_db(_volume) if _volume > 0.0 else -80.0


## Name of the AudioServer bus the video's sound plays on ("" if none),
## for analysis effects.
func audio_bus_name() -> String:
	return String(_vp.audio_player.bus) if _vp != null and _vp.audio_player != null else ""


## Linear gain set_volume applied to the audio before it reaches the bus.
func audio_gain() -> float:
	return db_to_linear(_vp.audio_player.volume_db) if _vp != null and _vp.audio_player != null else 1.0


## Native video resolution (the output texture's size), or ZERO before load.
func frame_size() -> Vector2i:
	return _viewport.size if (_viewport != null and _loaded) else Vector2i.ZERO


func is_playing() -> bool:
	return _vp != null and _loaded and _vp.is_playing


## A video was asked for and hasn't loaded (or failed) yet.
func is_loading() -> bool:
	return _loading


func duration_seconds() -> float:
	return _vp.get_video_length_float() if (_vp != null and _loaded) else 0.0


func playhead_seconds() -> float:
	return _vp.get_current_playback_position_float() if (_vp != null and _loaded) else 0.0


func _on_video_loaded() -> void:
	_loaded = true
	_loading = false
	_placeholder.visible = false
	_thumb.visible = false
	# Match the SubViewport size to the video's native resolution so we
	# don't scale up or down.
	var w: int = _vp.video.get_resolution().x
	var h: int = _vp.video.get_resolution().y
	if w > 0 and h > 0:
		_viewport.size = Vector2i(w, h)
	_update_busy()
	video_loaded.emit(duration_seconds(), _vp.get_video_framerate())
