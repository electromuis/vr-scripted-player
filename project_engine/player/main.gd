extends Node3D

const DEFAULT_SCRIPT := "res://examples/moving_screen/script.json"
const MEDIA_CONTROLS_SCENE := preload("res://player/ui/media_controls.tscn")
const VIDEO_BRIDGE_SCRIPT := preload("res://player/video_bridge.gd")

@onready var runner: ScriptRunner = $ScriptRunner
@onready var status_label: Label = $UI/TopBar/StatusLabel
@onready var vr_button: Button = $UI/TopBar/VRButton
@onready var mode_label: Label = $UI/TopBar/ModeLabel
@onready var xr_mode: XRMode = $XRMode
@onready var xr_rig: XRRig = $XRRig
@onready var desktop_camera: Camera3D = $DesktopCamera
@onready var fade_overlay: FadeOverlay = $UI/FadeOverlay
@onready var floating_panel: FloatingPanel = $FloatingPanel

var _video: VideoBridge
var _cli_script_path: String = ""
var _cli_live_sync_port: int = 0
var _cli_start_in_vr: bool = false


func _ready() -> void:
	_parse_cli_args()

	xr_mode.entered_vr.connect(_on_entered_vr)
	xr_mode.exited_vr.connect(_on_exited_vr)
	xr_mode.vr_init_failed.connect(_on_vr_init_failed)

	runner.script_loaded.connect(_on_script_loaded)
	runner.script_load_failed.connect(_on_script_load_failed)
	runner.seeked.connect(_on_runner_seeked)
	runner.play_state_changed.connect(_on_runner_play_state_changed)
	runner.event_fired.connect(_on_event_fired)

	vr_button.pressed.connect(_on_vr_button)
	xr_rig.menu_button_pressed.connect(floating_panel.toggle)
	_update_mode_label()
	_init_media_controls()
	_init_video()
	floating_panel.set_mouse_camera(desktop_camera)
	# Wrist HUD binds after the runner is ready so it can poll play state.
	_bind_wrist_hud()

	var script_to_load := _cli_script_path if _cli_script_path != "" else DEFAULT_SCRIPT
	_set_status("Loading %s..." % script_to_load)
	var loaded := runner.load_script(script_to_load)
	if loaded:
		runner.play()

	if _cli_start_in_vr:
		xr_mode.try_enter_vr()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_vr"):
		_on_vr_button()
	elif event.is_action_pressed("toggle_panel"):
		floating_panel.toggle()


func _parse_cli_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var a: String = args[i]
		if a == "--script" and i + 1 < args.size():
			_cli_script_path = args[i + 1]
		elif a == "--live-sync" and i + 1 < args.size():
			_cli_live_sync_port = int(args[i + 1])
		elif a == "--vr":
			_cli_start_in_vr = true


func _on_vr_button() -> void:
	if xr_mode.is_in_vr():
		xr_mode.exit_vr()
	else:
		xr_mode.try_enter_vr()


func _on_entered_vr() -> void:
	# Snap the rig to the desktop camera's XZ + yaw so the VR view picks up
	# where the desktop view left off — Whirligig / VRChat-style continuity.
	# Y stays at 0 (floor); the XRCamera3D's local Y=1.6 plus SteamVR height
	# calibration determines actual eye height.
	var d := desktop_camera.global_position
	var e := desktop_camera.global_rotation
	xr_rig.set_view(Vector3(d.x, 0.0, d.z), Vector3(0.0, rad_to_deg(e.y), 0.0))
	desktop_camera.current = false
	xr_rig.set_visuals_enabled(true)
	xr_rig.xr_camera.current = true
	_update_mode_label()
	vr_button.text = "Exit VR"


func _on_exited_vr() -> void:
	xr_rig.set_visuals_enabled(false)
	desktop_camera.current = true
	_update_mode_label()
	vr_button.text = "Enter VR"


func _on_vr_init_failed(reason: String) -> void:
	_set_status("VR: %s" % reason)


func _update_mode_label() -> void:
	mode_label.text = "VR" if xr_mode.is_in_vr() else "Desktop (WASD + right-click look, F12 to toggle VR)"


func _init_media_controls() -> void:
	var mc := MEDIA_CONTROLS_SCENE.instantiate()
	$UI.add_child(mc)
	mc.bind(runner)


func _bind_wrist_hud() -> void:
	# XRToolsViewport2DIn3D defers scene instantiation until after
	# `RenderingServer.frame_post_draw` + `process_frame` (see
	# addons/godot-xr-tools/objects/viewport_2d_in_3d.gd:150). One frame
	# isn't enough — poll for up to ~1s so we're robust to boot jitter.
	var content: Node = null
	for _i in 60:
		content = xr_rig.wrist_content()
		if content != null:
			break
		await get_tree().process_frame
	if content == null:
		push_warning("Wrist HUD content never appeared — bind skipped.")
		return
	if content.has_method("bind"):
		content.bind(runner)


func _init_video() -> void:
	if not ClassDB.class_exists("GoZenVideo"):
		_set_status("GoZenVideo class not found — is addons/gde_gozen loaded?")
		return
	_video = VIDEO_BRIDGE_SCRIPT.new()
	_video.name = "VideoBridge"
	add_child(_video)
	_video.video_loaded.connect(_on_video_loaded)
	# Push the video texture into any spawned object that accepts one
	# (e.g. the Screen prefab). Fires both for runner spawns and any
	# externally-registered nodes.
	runner.registry().object_spawned.connect(_on_object_spawned)


func _on_object_spawned(_id: String, node: Node3D) -> void:
	if _video == null or node == null:
		return
	if node.has_method("set_source_texture"):
		node.call("set_source_texture", _video.get_output_texture())


func _on_script_loaded(data: TimelineData) -> void:
	_set_status("Loaded: %s" % data.meta.get("title", data.script_path.get_file()))
	_load_video_for(data)


func _load_video_for(data: TimelineData) -> void:
	if _video == null:
		return
	var rel: String = data.media.get("video", "")
	if rel == "":
		return
	var resource_path := data.resolve(rel)
	if not FileAccess.file_exists(resource_path):
		_set_status("Video not found: %s" % resource_path)
		return
	var os_path := ProjectSettings.globalize_path(resource_path)
	_video.load_video(os_path)


func _on_video_loaded(duration: float, framerate: float) -> void:
	_set_status("Video loaded: %.2fs @ %.2f fps" % [duration, framerate])
	runner.set_video_duration(duration)
	if runner.playing:
		_video.play()


func _on_runner_seeked(t: float) -> void:
	if _video != null:
		_video.seek_seconds(t)


func _on_runner_play_state_changed(is_playing: bool) -> void:
	if _video == null:
		return
	if is_playing:
		_video.play()
	else:
		_video.pause()


func _on_event_fired(ev: Dictionary) -> void:
	match String(ev.get("action", "")):
		"vr_cut", "vr_teleport":
			_apply_camera_cut(ev)


func _apply_camera_cut(ev: Dictionary) -> void:
	var to_dict = ev.get("to", {})
	if typeof(to_dict) != TYPE_DICTIONARY:
		return
	var pos := Interpolation.to_vec3(to_dict.get("position", [0, 0, 0]))
	var rot_arr = to_dict.get("rotation_deg", [0, 0, 0])
	var rot := Interpolation.to_vec3(rot_arr) if typeof(rot_arr) == TYPE_ARRAY else Vector3.ZERO
	var tr = ev.get("transition")
	if typeof(tr) == TYPE_DICTIONARY and String(tr.get("type", "")) == "fade_to_black":
		var dur := float(tr.get("duration", 0.5))
		# In VR, fade the in-headset quad so the transition is visible in the
		# headset; also fade the CanvasLayer overlay so the desktop mirror
		# matches. Desktop-only: just the overlay.
		if xr_mode.is_in_vr():
			xr_rig.fade_through(dur, func(): _snap_camera(pos, rot))
			fade_overlay.fade_through(dur, func(): pass)
		else:
			fade_overlay.fade_through(dur, func(): _snap_camera(pos, rot))
	else:
		_snap_camera(pos, rot)


func _snap_camera(pos: Vector3, rot_deg: Vector3) -> void:
	if xr_mode.is_in_vr():
		xr_rig.set_view(pos, rot_deg)
	else:
		desktop_camera.set_view(pos, rot_deg)


func _on_script_load_failed(err: String) -> void:
	_set_status("ERROR: %s" % err)


func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg
	print(msg)
