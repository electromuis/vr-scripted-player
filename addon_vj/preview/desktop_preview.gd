extends Node

## Desktop preview for running an authoring scene (F5), added by VJScene
## outside the editor. No VR — a quick look, not the real player:
##
##   - WASD move, Q/E down/up, Shift boost, hold right-click to look,
##     R back to the start pose. Drives the scene's VJViewer (or first
##     Camera3D), so the Viewer's cut keys still snap you back like in the player.
##   - Media bar: play/pause, scrub, time. Space/K play/pause, ←/→ seek ±10 s.
##   - Video: plays `video_relative_path` through gde_gozen when that addon is
##     in the project, and feeds it to every screen. Without it, screens keep
##     their preview still. The AnimationPlayer's "main" is the clock; the
##     animation follows the video when they drift apart.

const SceneExporterScript := preload("res://addons/vj_editor/exporter/scene_exporter.gd")
const VJViewerScript := preload("res://addons/vj_editor/builtin_prefabs/vj_viewer.gd")
const _PLAYBACK_SCRIPT := "res://addons/gde_gozen/video_playback.gd"
const _ANIMATION := "main"
const _SEEK_STEP := 10.0
const _MOVE_SPEED := 5.0
const _BOOST := 3.0
const _LOOK_SENSITIVITY := 0.003
const _MAX_DRIFT := 0.25

var _scene: Node3D
var _anim: AnimationPlayer
var _camera: Camera3D
var _home: Transform3D
var _yaw: float
var _pitch: float
var _looking := false

var _video: Node  # gde_gozen VideoPlayback, null without video
var _video_viewport: SubViewport
var _video_ready := false
var _video_length := 0.0

var _play_button: Button
var _scrub: HSlider
var _time_label: Label
var _status: Label
var _scrubbing := false


func _ready() -> void:
	_scene = get_parent() as Node3D
	for child in _scene.get_children():
		if child is AnimationPlayer:
			_anim = child
	_setup_camera()
	_build_ui()
	_setup_video()
	if _anim != null and _anim.has_animation(_ANIMATION):
		_anim.play(_ANIMATION)
	else:
		_set_status("No AnimationPlayer with a \"main\" animation.")


# ---------- camera ----------

func _setup_camera() -> void:
	for child in _scene.get_children():
		if child.get_script() == VJViewerScript:
			_camera = child
			break
	if _camera == null:
		for child in _scene.get_children():
			if child is Camera3D:
				_camera = child
				break
	if _camera == null:
		_camera = Camera3D.new()
		_camera.position = Vector3(0, 2, 8)
		_scene.add_child(_camera)
	_camera.current = true
	_home = _camera.transform
	_sync_look_angles()


func _sync_look_angles() -> void:
	var e := _camera.rotation
	_yaw = e.y
	_pitch = e.x


func _reset_view() -> void:
	_camera.transform = _home
	_sync_look_angles()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
		# The animation may have moved the camera (a cut) since the last look.
		if _looking:
			_sync_look_angles()
	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * _LOOK_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * _LOOK_SENSITIVITY, -PI * 0.49, PI * 0.49)
		_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE, KEY_K: _toggle_play()
			KEY_LEFT: _seek(_position() - _SEEK_STEP)
			KEY_RIGHT: _seek(_position() + _SEEK_STEP)
			KEY_R: _reset_view()
			_: return
		get_viewport().set_input_as_handled()


func _move_camera(delta: float) -> void:
	var input := Vector3(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if input == Vector3.ZERO:
		return
	var speed := _MOVE_SPEED * (_BOOST if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_camera.global_position += Basis(Vector3.UP, _yaw) * input.normalized() * speed * delta


# ---------- playback ----------

func _process(delta: float) -> void:
	_move_camera(delta)
	if _anim == null:
		return
	_follow_video()
	if not _scrubbing:
		_scrub.max_value = maxf(_duration(), 0.1)
		_scrub.set_value_no_signal(_position())
	_play_button.text = "⏸" if _anim.is_playing() else "▶"
	_time_label.text = "%s / %s" % [_format_time(_position()), _format_time(_duration())]


func _position() -> float:
	return _anim.current_animation_position if _anim != null and _anim.assigned_animation != "" else 0.0


func _duration() -> float:
	var length := _anim.get_animation(_ANIMATION).length if _anim != null and _anim.has_animation(_ANIMATION) else 0.0
	return maxf(length, _video_length)


func _toggle_play() -> void:
	if _anim == null:
		return
	if _anim.is_playing():
		_anim.pause()
		if _video_ready:
			_video.pause()
	else:
		if _position() >= _duration() - 0.01:
			_seek(0.0)
		_anim.play(_ANIMATION)
		if _video_ready:
			_video.play()


func _seek(t: float) -> void:
	if _anim == null:
		return
	t = clampf(t, 0.0, _duration())
	_anim.seek(t, true)
	if _video_ready:
		var fps: float = _video.get_video_framerate()
		if fps > 0.0:
			_video.seek_frame(int(round(t * fps)))


## The video decoder keeps its own clock; pull the animation onto it when
## they drift (e.g. after a hitch), so screens and effects stay in sync.
func _follow_video() -> void:
	if not _video_ready or not _anim.is_playing() or _scrubbing:
		return
	var video_t: float = _video.get_current_playback_position_float()
	if absf(video_t - _position()) > _MAX_DRIFT:
		_anim.seek(video_t, true)


# ---------- video ----------

func _setup_video() -> void:
	var rel := String(_scene.get("video_relative_path"))
	if rel.is_empty():
		return
	var out := SceneExporterScript.output_path_of(_scene)
	var path := rel if rel.is_absolute_path() else out.get_base_dir().path_join(rel).simplify_path()
	if not ClassDB.class_exists("GoZenVideo") or not ResourceLoader.exists(_PLAYBACK_SCRIPT):
		_set_status("No gde_gozen addon in this project — screens show the preview still.")
		return
	if not FileAccess.file_exists(path):
		_set_status("Video not found: %s" % path)
		return
	_video_viewport = SubViewport.new()
	_video_viewport.size = Vector2i(1280, 720)
	_video_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_video_viewport.disable_3d = true
	add_child(_video_viewport)
	_video = load(_PLAYBACK_SCRIPT).new()
	_video.enable_audio = true
	_video.enable_auto_play = false
	_video.anchor_right = 1.0
	_video.anchor_bottom = 1.0
	_video_viewport.add_child(_video)
	_video.video_loaded.connect(_on_video_loaded)
	_video.set_video_path(path)
	_set_status("Loading %s…" % path.get_file())


func _on_video_loaded() -> void:
	_video_ready = true
	var res: Vector2i = _video.video.get_resolution()
	if res.x > 0 and res.y > 0:
		_video_viewport.size = res
	_video_length = _video.get_video_length_float()
	_feed_video(_scene, _video_viewport.get_texture())
	_seek(_position())
	if _anim != null and _anim.is_playing():
		_video.play()
	_set_status("")


## Every screen and layer in the scene, groups included.
func _feed_video(node: Node, tex: Texture2D) -> void:
	for child in node.get_children():
		if child.has_method("set_source_texture"):
			child.set_source_texture(tex)
		if child.owner == _scene:
			_feed_video(child, tex)


# ---------- UI ----------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var help := Label.new()
	help.text = "WASD move · Q/E down/up · Shift fast · right-drag look · R reset view · Space play/pause · ←/→ seek"
	help.position = Vector2(12, 8)
	layer.add_child(help)
	_status = Label.new()
	_status.position = Vector2(12, 32)
	layer.add_child(_status)

	var bar := PanelContainer.new()
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_left = 12
	bar.offset_right = -12
	bar.offset_top = -52
	bar.offset_bottom = -12
	layer.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	bar.add_child(row)

	_play_button = Button.new()
	_play_button.custom_minimum_size = Vector2(40, 0)
	_play_button.focus_mode = Control.FOCUS_NONE
	_play_button.pressed.connect(_toggle_play)
	row.add_child(_play_button)

	_scrub = HSlider.new()
	_scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scrub.step = 0.01
	_scrub.focus_mode = Control.FOCUS_NONE
	_scrub.drag_started.connect(func(): _scrubbing = true)
	_scrub.drag_ended.connect(func(_changed: bool):
		_scrubbing = false
		_seek(_scrub.value))
	# Only user input lands here (_process updates it without signals).
	# While dragging, move just the animation; the video seeks on release.
	_scrub.value_changed.connect(func(v: float):
		if _scrubbing:
			_anim.seek(v, true)
		else:
			_seek(v))
	row.add_child(_scrub)

	_time_label = Label.new()
	row.add_child(_time_label)


func _set_status(msg: String) -> void:
	_status.text = msg
	if not msg.is_empty():
		print("VJ preview: %s" % msg)


static func _format_time(t: float) -> String:
	var total := int(t)
	return "%02d:%02d" % [total / 60, total % 60]
