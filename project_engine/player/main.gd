extends Node3D

## The player app: the shell around the Stage (player/stage/), which does
## the rendering. This owns what only the player needs: command-line
## options, opening files and URLs, the playlist, DLNA, the Whirligig
## timecode server, live sync with the editor, the menus and the desktop
## window, and what the player's commands do.

const SEEK_STEP_SECONDS := 10.0
const VOLUME_STEP := 0.1
const MEDIA_CONTROLS_SCENE := preload("res://player/ui/media_controls.tscn")

@onready var stage: Stage = $Stage
@onready var runner: ScriptRunner = $Stage/ScriptRunner
@onready var status_label: Label = $UI/TopBar/StatusLabel
@onready var vr_button: Button = $UI/TopBar/VRButton
@onready var mode_label: Label = $UI/TopBar/ModeLabel
@onready var floating_panel: FloatingPanel = $FloatingPanel

var _cli_script_path: String = ""
var _cli_live_sync_port: int = 0
var _cli_start_in_vr: bool = false
## --desktop: don't auto-enter VR even when a headset is detected.
var _cli_force_desktop: bool = false
## --paused: open the --script file without starting playback.
var _cli_paused: bool = false
var _cli_whirligig_port: int = WhirligigServer.DEFAULT_PORT
var _cli_whirligig_bind: String = "127.0.0.1"
var _whirligig: WhirligigServer
var _live_sync: LiveSyncClient
var _player_settings: PlayerSettings
var _camera_tab: Node  # set once the floating panel content binds
var _dlna: DlnaClient
## OS thumbnails, shared with the Files tab: shown on the screen while a
## local video opens.
var _thumbs: OsThumbnails
## What next/previous step through (see Playlist); null until something
## is opened.
var _playlist: Playlist


func _ready() -> void:
	_parse_cli_args()
	stage.status.connect(_set_status)
	stage.media_path_changed.connect(func(path: String):
		if _whirligig != null:
			_whirligig.set_media_path(path))
	stage.video_opening.connect(_show_loading_thumbnail)
	stage.projection_changed.connect(func(override: String, detected: String):
		if _camera_tab != null:
			_camera_tab.set_projection_state(override, detected))
	stage.camera_fx_error_changed.connect(func(text: String):
		if _camera_tab != null:
			_camera_tab.set_camera_fx_error(text))
	stage.xr_mode.entered_vr.connect(_on_entered_vr)
	stage.xr_mode.exited_vr.connect(_on_exited_vr)
	stage.xr_mode.vr_init_failed.connect(_on_vr_init_failed)
	runner.reached_end.connect(_on_runner_reached_end)

	vr_button.pressed.connect(_on_vr_button)
	get_window().files_dropped.connect(_on_files_dropped)
	_update_mode_label()
	_player_settings = PlayerSettings.new()
	_player_settings.load_from_disk()
	stage.setup(_player_settings, InputBindings.new())
	stage.router.command.connect(_on_command)
	stage.router.command_released.connect(_on_command_released)
	stage.add_masked_panel(floating_panel.panel_quad())
	_init_media_controls()
	_player_settings.changed.connect(_apply_player_settings)
	_apply_player_settings()
	_init_fps_label()
	_init_whirligig()
	_init_live_sync()
	_init_dlna()
	_thumbs = OsThumbnails.new()
	_thumbs.name = "OsThumbnails"
	add_child(_thumbs)
	_thumbs.thumbnail_ready.connect(func(path: String, tex: Texture2D):
		if path == stage.video_path and stage.video != null:
			stage.video.set_loading_thumbnail(tex))
	floating_panel.set_mouse_camera(stage.desktop_camera)
	# Wrist HUD + floating-panel content bind after the runner is ready so they
	# can poll play state / receive shared settings.
	_bind_wrist_hud()
	_bind_panel_content()

	if _cli_script_path != "":
		_playlist = Playlist.from_folder(_cli_script_path, _player_settings.browser_sort)
		open_file(_cli_script_path, not _cli_paused)
	else:
		# Show the screen (with its placeholder card) right away; seek spawns
		# it without starting playback.
		runner.load_timeline(DefaultScreen.idle_timeline())
		runner.seek(0.0)
		_set_status("Open a video or script: F2 → Files, or drop a file on this window.")

	# --vr forces an attempt (and reports failure); otherwise go straight to
	# VR only when a headset is already up, staying silently on desktop if not.
	if _cli_start_in_vr or (not _cli_force_desktop and stage.xr_mode.headset_detected()):
		stage.xr_mode.try_enter_vr()


func _on_command(id: StringName) -> void:
	match id:
		&"play_pause": _toggle_play()
		&"screen_trigger": _on_right_trigger()
		&"screen_click": _on_right_stick_clicked()
		&"seek_back": _seek_by(-SEEK_STEP_SECONDS)
		&"seek_forward": _seek_by(SEEK_STEP_SECONDS)
		&"volume_up": _change_volume(VOLUME_STEP)
		&"volume_down": _change_volume(-VOLUME_STEP)
		&"next_video": play_next()
		&"previous_video": play_previous()
		&"toggle_menu": floating_panel.toggle()
		&"drag_menu":
			var rig := stage.xr_rig
			floating_panel.begin_drag(rig.left_controller if stage.router.last_input.begins_with("L.") else rig.right_controller)
		&"reset_view": stage.reset_view()
		&"toggle_vr": _on_vr_button()
		&"fullscreen": _player_settings.fullscreen = not _player_settings.fullscreen
		&"toggle_play_bar": _player_settings.show_play_bar = not _player_settings.show_play_bar


func _on_command_released(id: StringName) -> void:
	if id == &"drag_menu":
		floating_panel.end_drag()


## Open a script (.json) or a video. A video with a same-name .json next to
## it plays through that script; otherwise it plays on the default screen.
## With `autoplay` false it opens paused.
func open_file(path: String, autoplay: bool = true) -> void:
	if DefaultScreen.is_url(path):
		open_url(path)
		return
	if DefaultScreen.is_video(path):
		var sidecar := DefaultScreen.sidecar_script(path)
		if sidecar != "":
			path = sidecar
		else:
			_set_status("Opening %s..." % path.get_file())
			runner.load_timeline(DefaultScreen.timeline_for_video(path))
			if autoplay:
				runner.play()
			return
	if path.get_extension().to_lower() != "json":
		_set_status("Unsupported file: %s" % path.get_file())
		return
	_set_status("Loading %s..." % path)
	if not runner.load_script(path):
		return
	# load_script starts playing by itself (the runner's autostart).
	if autoplay:
		runner.play()
	else:
		runner.pause()


## Play a network video (http/https) on the default screen. `file_name`
## stands in for the URL's own file name, `thumbnail_url` is shown while it
## opens (see DefaultScreen.timeline_for_video).
func open_url(url: String, file_name: String = "", thumbnail_url: String = "") -> void:
	var data := DefaultScreen.timeline_for_video(url, file_name, thumbnail_url)
	_set_status("Opening %s..." % data.title())
	runner.load_timeline(data)
	runner.play()


func _on_files_dropped(files: PackedStringArray) -> void:
	if not files.is_empty():
		_playlist = Playlist.from_folder(files[0], _player_settings.browser_sort)
		open_file(files[0])


func play_next() -> void:
	_step_playlist(1)


func play_previous() -> void:
	_step_playlist(-1)


func _step_playlist(dir: int) -> void:
	if _playlist == null or _playlist.is_empty():
		_set_status("Nothing to skip to: open a video from Files or Network first.")
		return
	var item := _playlist.step(dir)
	if item.is_empty():
		_set_status("Already at the %s video in this folder." % ("last" if dir > 0 else "first"))
		return
	var path := String(item["path"])
	if DefaultScreen.is_url(path):
		open_url(path, String(item["name"]), String(item.get("thumb", "")))
	else:
		open_file(path)


func _toggle_play() -> void:
	if runner.timeline == null or DefaultScreen.is_idle(runner.timeline):
		return
	if runner.playing:
		runner.pause()
	else:
		runner.play()


## `screen_click` (right stick click by default): play/pause while aiming at
## the screen, reset view otherwise.
func _on_right_stick_clicked() -> void:
	if _aiming_at_screen():
		_toggle_play()
	else:
		stage.reset_view()


## `screen_trigger` (right trigger, not on a panel): play/pause while aiming
## at the screen.
func _on_right_trigger() -> void:
	if _aiming_at_screen():
		_toggle_play()


## Whether the right controller points at the main screen's flat quad.
## 180°/360° videos surround the viewer, so there is no screen to aim at and
## the click keeps its reset-view meaning.
func _aiming_at_screen() -> bool:
	var screen: Node = runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	if screen == null:
		return false
	var mesh := screen.get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null or not mesh.is_visible_in_tree() or not (mesh.mesh is QuadMesh):
		return false
	var ray := stage.xr_rig.right_aim_ray()
	return XRRig.ray_hits_quad(ray[0], ray[1], mesh.global_transform, (mesh.mesh as QuadMesh).size)


## Leave VR first so the OpenXR session is torn down before the tree goes.
func quit_app() -> void:
	runner.pause()
	stage.xr_mode.exit_vr()
	get_tree().quit()


func _seek_by(seconds: float) -> void:
	if runner.timeline != null:
		runner.seek(runner.playhead + seconds)


func _change_volume(delta: float) -> void:
	_player_settings.volume += delta
	_set_status("Volume %d%%" % roundi(_player_settings.volume * 100.0))


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
		elif a == "--desktop":
			_cli_force_desktop = true
		elif a == "--paused":
			_cli_paused = true
		elif a == "--start" and i + 1 < args.size():
			stage.pending_start = float(args[i + 1])
		elif a == "--whirligig-port" and i + 1 < args.size():
			# 0 disables the timecode server.
			_cli_whirligig_port = int(args[i + 1])
		elif a == "--whirligig-lan":
			_cli_whirligig_bind = "*"
	# "Open with" / drag onto the .exe passes the file as a plain (non-user)
	# argument; pick it up unless --script already chose something.
	if _cli_script_path == "":
		for a in OS.get_cmdline_args():
			if (DefaultScreen.is_video(a) or a.get_extension().to_lower() == "json") \
					and FileAccess.file_exists(a):
				_cli_script_path = a


func _on_vr_button() -> void:
	if stage.xr_mode.is_in_vr():
		stage.xr_mode.exit_vr()
	else:
		stage.xr_mode.try_enter_vr()


## The stage has moved the view into the headset (it connected first).
func _on_entered_vr() -> void:
	_update_mode_label()
	vr_button.text = "Exit VR"


func _on_exited_vr() -> void:
	# A panel left open in VR sits wherever the headset put it; bring it in
	# front of the desktop view (the stage has just moved that there).
	if floating_panel.visible:
		floating_panel.show_in_front_of(stage.desktop_camera)
	_update_mode_label()
	vr_button.text = "Enter VR"


func _on_vr_init_failed(reason: String) -> void:
	_set_status("VR: %s" % reason)


## Frames-per-second readout at the start of the top bar (Config → FPS),
## ahead of the long mode and status texts.
func _init_fps_label() -> void:
	var fps := FpsLabel.new()
	fps.name = "FpsLabel"
	$UI/TopBar.add_child(fps)
	$UI/TopBar.move_child(fps, 0)
	fps.bind(_player_settings)


func _update_mode_label() -> void:
	if stage.xr_mode.is_in_vr():
		mode_label.text = "VR"
	else:
		mode_label.text = "Desktop (right-click look · ←/→ seek · ↑/↓ volume · R reset view · H play bar · F11 fullscreen · F2 menu · F12 VR)"


## The play bar sits in its own layer above the stage's fade overlay.
func _init_media_controls() -> void:
	var mc := MEDIA_CONTROLS_SCENE.instantiate()
	mc.name = "MediaControls"
	$PlayBar.add_child(mc)
	mc.bind(runner)
	mc.previous_requested.connect(play_previous)
	mc.next_requested.connect(play_next)


## The player's own part of the settings; the stage applies what it shows
## (volume, skybox, floor, camera effect limits).
func _apply_player_settings() -> void:
	var locked := _player_settings.locomotion == PlayerSettings.Locomotion.LOCKED
	# Free movement's bindings (walk, turn) take the sticks from the media
	# remote's; with it locked, Space plays / pauses instead of flying up.
	stage.router.set_context("locked", locked)
	stage.router.set_context("free", not locked)
	stage.desktop_camera.movement_enabled = not locked
	_apply_window_settings()
	if _live_sync != null:
		_live_sync.set_enabled(_player_settings.live_sync)


## Desktop window preferences: fullscreen and the bottom play bar.
func _apply_window_settings() -> void:
	var mc := get_node_or_null("PlayBar/MediaControls") as Control
	if mc != null:
		mc.visible = _player_settings.show_play_bar
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if _player_settings.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	var mode := DisplayServer.window_get_mode()
	var is_full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if is_full != _player_settings.fullscreen:
		DisplayServer.window_set_mode(want)


func _init_whirligig() -> void:
	if _cli_whirligig_port <= 0:
		return
	_whirligig = WhirligigServer.new()
	_whirligig.name = "WhirligigServer"
	add_child(_whirligig)
	_whirligig.bind(runner)
	_whirligig.start(_cli_whirligig_port, _cli_whirligig_bind)


## --live-sync <port>: follow the authoring editor's playhead and Preview
## presses (see LiveSyncClient), while Config → Editor sync is on.
func _init_live_sync() -> void:
	if _cli_live_sync_port <= 0:
		return
	_live_sync = LiveSyncClient.new()
	_live_sync.name = "LiveSyncClient"
	add_child(_live_sync)
	_live_sync.bind(runner)
	_live_sync.set_script_path(_cli_script_path)
	_live_sync.set_enabled(_player_settings.live_sync)
	_live_sync.open_requested.connect(_on_live_open)
	_live_sync.seek_requested.connect(stage.seek_to)
	_live_sync.play_requested.connect(runner.play)
	_live_sync.pause_requested.connect(runner.pause)
	_live_sync.connect_to_editor(_cli_live_sync_port)


## The editor pressed Preview. Already showing that script: reload it in
## place now (the file watcher would too, a moment later), so the edit and
## the seek land together without reopening the video.
func _on_live_open(path: String, t: float, playing: bool) -> void:
	if runner.timeline != null and LiveSyncClient.same_path(runner.timeline.script_path, path):
		runner.reload()
		stage.seek_to(t)
	else:
		_playlist = Playlist.from_folder(path, _player_settings.browser_sort)
		open_file(path)
		stage.seek_to(t)
	if playing:
		runner.play()
	else:
		runner.pause()


func _init_dlna() -> void:
	_dlna = DlnaClient.new()
	_dlna.name = "DlnaClient"
	add_child(_dlna)


func _bind_panel_content() -> void:
	# XRToolsViewport2DIn3D defers scene instantiation across a couple of
	# frames; poll for up to ~1s (same pattern as _bind_wrist_hud).
	var content: Node = null
	for _i in 60:
		content = floating_panel.content()
		if content != null:
			break
		await get_tree().process_frame
	if content == null:
		push_warning("Floating panel content never appeared — bind skipped.")
		return
	if content.has_method("bind_camera"):
		content.bind_camera(stage.screen_settings, stage.preset_store, stage.layers)
		_camera_tab = content.camera_tab
		_camera_tab.projection_selected.connect(stage.set_projection_override)
		_camera_tab.reset_view_requested.connect(stage.reset_view)
		if stage.beats != null:
			_camera_tab.bind_beats(stage.beats)
		stage.apply_projection()
	# Config first: the Files tab needs PlayerSettings (its remembered folder)
	# before bind_files opens its first folder.
	if content.has_method("bind_config"):
		content.bind_config(_player_settings)
	if content.has_method("bind_controls"):
		content.bind_controls(stage.router)
	if content.has_method("bind_files"):
		content.bind_files(runner, func(path: String, playlist: Playlist = null):
			_close_panel_after_pick()
			_playlist = playlist
			open_file(path), _thumbs)
	if content.has_signal("close_requested"):
		content.close_requested.connect(func(): floating_panel.hide_panel.call_deferred())
		content.quit_requested.connect(quit_app)
	if content.has_method("bind_network"):
		content.bind_network(_dlna, func(url: String, file_name: String = "", playlist: Playlist = null):
			_close_panel_after_pick()
			_playlist = playlist
			var thumb := ""
			if playlist != null and playlist.index >= 0 and playlist.index < playlist.items.size():
				thumb = String(playlist.items[playlist.index].get("thumb", ""))
			open_url(url, file_name, thumb))


## Picking a video in the panel closes it so playback isn't hidden behind the
## menu. Deferred: we're inside the panel's own input dispatch here.
func _close_panel_after_pick() -> void:
	floating_panel.hide_panel.call_deferred()


func _bind_wrist_hud() -> void:
	# XRToolsViewport2DIn3D defers scene instantiation until after
	# `RenderingServer.frame_post_draw` + `process_frame` (see
	# addons/godot-xr-tools/objects/viewport_2d_in_3d.gd:150). One frame
	# isn't enough — poll for up to ~1s so we're robust to boot jitter.
	var content: Node = null
	for _i in 60:
		content = stage.xr_rig.wrist_content()
		if content != null:
			break
		await get_tree().process_frame
	if content == null:
		push_warning("Wrist HUD content never appeared — bind skipped.")
		return
	if content.has_method("bind"):
		content.bind(runner, _player_settings)
	if content.has_signal("menu_requested"):
		content.menu_requested.connect(func(): floating_panel.toggle.call_deferred())
	if content.has_signal("next_requested"):
		# Deferred: opening a video from inside the HUD's own input dispatch.
		content.previous_requested.connect(func(): play_previous.call_deferred())
		content.next_requested.connect(func(): play_next.call_deferred())


## The opening video's thumbnail on the screen: the DLNA server's image for
## a network item, else the OS's for a local file (may arrive later, via
## _thumbs.thumbnail_ready).
func _show_loading_thumbnail(os_path: String, thumbnail_url: String) -> void:
	if thumbnail_url != "" and _dlna != null:
		var tex := BrowserView.texture_from_bytes(await _dlna.fetch_bytes(thumbnail_url))
		if os_path == stage.video_path:
			stage.video.set_loading_thumbnail(tex)
	elif not DefaultScreen.is_url(os_path) and _thumbs != null:
		stage.video.set_loading_thumbnail(_thumbs.request(os_path))


## Config → At video end. "next" stops at the playlist's last video.
func _on_runner_reached_end() -> void:
	if DefaultScreen.is_idle(runner.timeline):
		return
	match _player_settings.end_action:
		"loop":
			runner.seek(0.0)
		"next":
			# Deferred: we're inside the runner's tick.
			play_next.call_deferred()


func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg
	print(msg)
