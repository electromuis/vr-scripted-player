extends Node3D

const SEEK_STEP_SECONDS := 10.0
const VOLUME_STEP := 0.1
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
@onready var screen_mount: Node3D = $Stage/ScreenMount
@onready var floor_mesh: MeshInstance3D = $Stage/Floor
@onready var world_env: WorldEnvironment = $WorldEnvironment

var _video: VideoBridge
var _cli_script_path: String = ""
var _cli_live_sync_port: int = 0
var _cli_start_in_vr: bool = false
## --desktop: don't auto-enter VR even when a headset is detected.
var _cli_force_desktop: bool = false
## --paused: open the --script file without starting playback.
var _cli_paused: bool = false
## Where to seek once the video reports its length (seek() clamps to the
## timeline duration, which is unknown until then): --start, or a live-sync
## seek that arrived while the video was opening.
var _pending_start: float = 0.0
var _cli_whirligig_port: int = WhirligigServer.DEFAULT_PORT
var _cli_whirligig_bind: String = "127.0.0.1"
var _whirligig: WhirligigServer
var _router: InputRouter
var _camera_fx: CameraFx
var _camera_fx_running := false
var _camera_fx_error := ""
var _live_sync: LiveSyncClient
var _preset_store: PresetStore
var _screen_settings: ScreenSettings
var _layers: LayerStack
var _layer_nodes: Array[Visualizer] = []  # parallel to _layers.layers
var _layer_links: Array[Callable] = []  # each layer's `changed` handler, to disconnect on rebuild
var _main_screen: Node3D  # what locked layers follow
## Parent of the layer nodes, under the ScreenMount: it carries the main
## screen's own (script-animated) motion, so layers move with the screen
## and their settings place them relative to it.
var _layer_anchor: Node3D
var _audio: AudioAnalyzer
var _player_settings: PlayerSettings
var _skyboxes := SkyboxLibrary.new()
var _camera_tab: Node  # set once the floating panel content binds
## Where "reset view" puts the viewer: the desktop camera's start pose.
var _home_pos: Vector3
var _home_yaw_deg: float
## A vr_cut/vr_teleport moved the viewer; the next script load returns home
## so position stays stable across videos.
var _script_moved_view: bool = false
var _video_path: String = ""  # OS path or URL of the current video, "" if none
## File name projection detection reads: the file's own, or a DLNA item's
## title-derived name when the URL doesn't carry one.
var _video_name: String = ""
var _dlna: DlnaClient
## OS thumbnails, shared with the Files tab: shown on the screen while a
## local video opens.
var _thumbs: OsThumbnails
## What next/previous step through (see Playlist); null until something
## is opened.
var _playlist: Playlist
var _projection_override: String = "auto"  # per video; reset on each load
## Last curvature pushed from the Camera tab, so other sliders firing
## ScreenSettings.changed don't re-flatten a script-curved screen.
var _last_curvature: float = -1.0
## The look (active preset, screen values, layers) from before a script
## switched to the locked Script preset; restored for the next plain video.
## Empty while not playing a script.
var _look_before_script: Dictionary = {}


func _ready() -> void:
	_parse_cli_args()
	# The runner animates the screens first; then _process moves the layer
	# anchor after them, before the layers (children) read it.
	runner.process_priority = -1
	_home_pos = desktop_camera.global_position
	_home_yaw_deg = rad_to_deg(desktop_camera.global_rotation.y)

	xr_mode.entered_vr.connect(_on_entered_vr)
	xr_mode.exited_vr.connect(_on_exited_vr)
	xr_mode.vr_init_failed.connect(_on_vr_init_failed)

	runner.script_loaded.connect(_on_script_loaded)
	runner.script_load_failed.connect(_on_script_load_failed)
	runner.seeked.connect(_on_runner_seeked)
	runner.play_state_changed.connect(_on_runner_play_state_changed)
	runner.reached_end.connect(_on_runner_reached_end)
	runner.event_fired.connect(_on_event_fired)

	vr_button.pressed.connect(_on_vr_button)
	_init_input()
	xr_rig.movement.scroll_step.connect(xr_rig.scroll_pointed_panel)
	get_window().files_dropped.connect(_on_files_dropped)
	_update_mode_label()
	_init_media_controls()
	_init_video()
	_init_screen_settings()
	_init_camera_fx()
	_init_player_settings()
	_init_fps_label()
	_init_whirligig()
	_init_live_sync()
	_init_dlna()
	_thumbs = OsThumbnails.new()
	_thumbs.name = "OsThumbnails"
	add_child(_thumbs)
	_thumbs.thumbnail_ready.connect(func(path: String, tex: Texture2D):
		if path == _video_path and _video != null:
			_video.set_loading_thumbnail(tex))
	floating_panel.set_mouse_camera(desktop_camera)
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
	if _cli_start_in_vr or (not _cli_force_desktop and xr_mode.headset_detected()):
		xr_mode.try_enter_vr()


func _process(_delta: float) -> void:
	_update_layer_anchor()
	_update_camera_fx()
	# `pulse` reactive objects follow the bass.
	runner.audio_bass = _audio.bass if _audio != null else 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and _router.handle_key(event):
		get_viewport().set_input_as_handled()


## Controller buttons, sticks and keys all arrive as commands (InputRouter,
## with the user's bindings from the Controls tab).
func _init_input() -> void:
	_router = InputRouter.new(InputBindings.new())
	_router.name = "InputRouter"
	# Before XRMovement reads its axes in the same frame.
	_router.process_priority = -10
	add_child(_router)
	xr_rig.router = _router
	_router.command.connect(_on_command)
	_router.command_released.connect(_on_command_released)


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
			floating_panel.begin_drag(xr_rig.left_controller if _router.last_input.begins_with("L.") else xr_rig.right_controller)
		&"reset_view": reset_view()
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


## Put the viewer back at the home pose. In VR this moves the headset (not
## just the rig origin) there, cancelling where the user stands/faces in
## their playspace.
func reset_view() -> void:
	if xr_mode.is_in_vr():
		xr_rig.recenter(_home_pos, _home_yaw_deg)
	else:
		desktop_camera.set_view(_home_pos, Vector3(0.0, _home_yaw_deg, 0.0))


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
		reset_view()


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
	var ray := xr_rig.right_aim_ray()
	return XRRig.ray_hits_quad(ray[0], ray[1], mesh.global_transform, (mesh.mesh as QuadMesh).size)


## Leave VR first so the OpenXR session is torn down before the tree goes.
func quit_app() -> void:
	runner.pause()
	xr_mode.exit_vr()
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
			_pending_start = float(args[i + 1])
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
	if xr_mode.is_in_vr():
		xr_mode.exit_vr()
	else:
		xr_mode.try_enter_vr()


func _on_entered_vr() -> void:
	# Put the headset where the desktop camera was so the VR view picks up
	# where the desktop view left off — Whirligig / VRChat-style continuity.
	# Y stays at 0 (floor); tracking determines actual eye height.
	var d := desktop_camera.global_position
	var yaw := rad_to_deg(desktop_camera.global_rotation.y)
	xr_rig.set_view(Vector3(d.x, 0.0, d.z), Vector3(0.0, yaw, 0.0))
	desktop_camera.current = false
	xr_rig.set_visuals_enabled(true)
	xr_rig.xr_camera.current = true
	_update_mode_label()
	vr_button.text = "Exit VR"
	# The runtime's own recenter (e.g. holding the Oculus/SteamVR button)
	# should land on our home pose too.
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.has_signal("pose_recentered") and not xr.pose_recentered.is_connected(reset_view):
		xr.pose_recentered.connect(reset_view)
	# Head pose isn't tracked for the first few frames; recenter once it is
	# so the head (not the playspace origin) lands on the desktop pose.
	await get_tree().create_timer(0.3).timeout
	if xr_mode.is_in_vr():
		xr_rig.recenter(d, yaw)


func _on_exited_vr() -> void:
	xr_rig.set_visuals_enabled(false)
	desktop_camera.current = true
	# Pick up where the headset was looking, mirroring _on_entered_vr.
	var head := xr_rig.xr_camera.global_transform
	desktop_camera.set_view(Vector3(head.origin.x, _home_pos.y, head.origin.z),
			Vector3(0.0, rad_to_deg(head.basis.get_euler().y), 0.0))
	# A panel left open in VR sits wherever the headset put it; bring it in
	# front of the desktop view.
	if floating_panel.visible:
		floating_panel.show_in_front_of(desktop_camera)
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
	if xr_mode.is_in_vr():
		mode_label.text = "VR"
	else:
		mode_label.text = "Desktop (right-click look · ←/→ seek · ↑/↓ volume · R reset view · H play bar · F11 fullscreen · F2 menu · F12 VR)"


func _init_media_controls() -> void:
	var mc := MEDIA_CONTROLS_SCENE.instantiate()
	mc.name = "MediaControls"
	$UI.add_child(mc)
	mc.bind(runner)
	mc.previous_requested.connect(play_previous)
	mc.next_requested.connect(play_next)


func _init_screen_settings() -> void:
	_layer_anchor = Node3D.new()
	_layer_anchor.name = "LayerAnchor"
	screen_mount.add_child(_layer_anchor)
	_preset_store = PresetStore.new()
	_screen_settings = ScreenSettings.new()
	_layers = LayerStack.new()
	_layers.layers_changed.connect(_rebuild_layers)
	# The startup preset (preset 1, the auto-created default, unless the
	# Presets tab picked another) seeds the sliders and the mount transforms.
	if not _preset_store.apply(_preset_store.startup_index(), _screen_settings, _layers):
		_preset_store.apply(_preset_store.default_preset_index(), _screen_settings, _layers)
	_screen_settings.changed.connect(_apply_screen_settings)
	_screen_settings.changed.connect(_on_curvature_maybe_changed)
	_screen_settings.changed.connect(_apply_screen_display)
	_apply_screen_settings()
	_apply_screen_display()
	_rebuild_layers()


func _apply_screen_settings() -> void:
	if _screen_settings == null or screen_mount == null:
		return
	# Tilt orbits the screen around the viewer's home eye position — where
	# reset view puts them — in the mount's parent (Stage) space.
	var stage := screen_mount.get_parent() as Node3D
	var eye := stage.to_local(_home_pos) if stage != null else _home_pos
	_screen_settings.apply_to_mount(screen_mount, eye, _home_yaw_deg, _screen_pivot())
	_place_layers()


## Centre of the default screen in mount space; size scales about it.
static func _screen_pivot() -> Vector3:
	return Vector3(DefaultScreen.POSITION[0], DefaultScreen.POSITION[1], DefaultScreen.POSITION[2])


## Opacity, vertical curvature and effects apply to every screen under
## the mount (main and split-off). Horizontal curvature is separate
## (_apply_curvature) since scripts set it too.
func _apply_screen_display() -> void:
	if _screen_settings == null or screen_mount == null:
		return
	for screen in _screens_under(screen_mount):
		_apply_display_to(screen)


## Screens under `node`, groups included; not the ones inside shader
## layers, which follow their layer's settings.
func _screens_under(node: Node) -> Array[Screen]:
	var out: Array[Screen] = []
	for child in node.get_children():
		if child is Visualizer:
			continue
		if child is Screen:
			out.append(child)
		out.append_array(_screens_under(child))
	return out


## The Camera tab's display values, except the ones a script set on this
## screen (its look stays as authored; resolution is always the viewer's).
func _apply_display_to(screen: Node) -> void:
	if not screen is Screen or _screen_settings == null:
		return
	screen.set_resolution_scale(_screen_settings.resolution)
	if not screen.is_scripted("opacity"):
		screen.set_opacity(_screen_settings.opacity)
	if not screen.is_scripted("vertical_curvature"):
		screen.set_vertical_curvature(_screen_settings.vertical_curvature)
	if not screen.is_scripted("effects"):
		screen.set_effects(_screen_settings.effects)


## One Visualizer node per LayerStack entry, rebuilt whenever the list
## changes (count or a preset); edits within a layer just re-apply it.
func _rebuild_layers() -> void:
	for i in _layer_links.size():
		var old: LayerSettings = _layer_links[i].get_bound_arguments()[0]
		if old.changed.is_connected(_layer_links[i]):
			old.changed.disconnect(_layer_links[i])
	_layer_links.clear()
	for node in _layer_nodes:
		node.queue_free()
	_layer_nodes.clear()
	for i in _layers.count():
		var node := Visualizer.new()
		node.name = "Layer%d" % (i + 1)
		_layer_anchor.add_child(node)
		if _audio != null:
			node.bind_audio(_audio)
		_apply_video_to_layer(node)
		if _main_screen != null:
			node.set_follow_target(_main_screen)
		_layer_nodes.append(node)
		var link := _apply_layer.bind(_layers.layers[i], node)
		_layers.layers[i].changed.connect(link)
		_layer_links.append(link)
		_apply_layer(_layers.layers[i], node)
	_update_audio_active()


## Draw order is by depth (see Visualizer); the stack position only breaks
## ties between equal placements.
func _apply_layer(settings: LayerSettings, node: Visualizer) -> void:
	var i := _layers.layers.find(settings)
	_place_layer(settings, node)
	node.set_order(i)
	node.set_locked(settings.lock_to_screen, settings.size, settings.distance)
	node.set_curvature(settings.curvature)
	node.set_vertical_curvature(settings.vertical_curvature)
	node.set_opacity(settings.opacity)
	node.set_resolution_scale(settings.resolution)
	node.set_shader(settings.shader)
	node.set_params(settings.params)
	node.set_effects(settings.effects)
	_update_audio_active()


## Size, distance and height are relative to the screen (the layer's
## parent). Tilt orbits the viewer's eye as seen from the screen, so a
## tilted layer keeps its distance from the viewer like the screen's own
## tilt does; that eye moves whenever the screen does (_place_layers).
func _place_layer(settings: LayerSettings, node: Visualizer) -> void:
	var eye := _layer_anchor.global_transform.affine_inverse() * _home_pos
	var yaw := _home_yaw_deg - rad_to_deg(_layer_anchor.global_rotation.y)
	settings.apply_to_mount(node, eye, yaw, _screen_pivot())


func _place_layers() -> void:
	if _layers == null:
		return
	for i in mini(_layers.count(), _layer_nodes.size()):
		_place_layer(_layers.layers[i], _layer_nodes[i])


## The main screen's motion away from where the default screen sits, which
## the layers inherit. Identity until a script moves (or respawns) it.
func _update_layer_anchor() -> void:
	if _layer_anchor == null:
		return
	var t := Transform3D.IDENTITY
	# In mount space, so a main_screen inside a script's group counts the
	# group's motion too.
	if is_instance_valid(_main_screen) and screen_mount.is_ancestor_of(_main_screen):
		t = screen_mount.global_transform.affine_inverse() * _main_screen.global_transform * _default_screen_transform().affine_inverse()
	if not t.is_equal_approx(_layer_anchor.transform):
		_layer_anchor.transform = t
		_place_layers()


static func _default_screen_transform() -> Transform3D:
	return Transform3D(Basis.from_scale(Vector3.ONE * DefaultScreen.SCALE), _screen_pivot())


## Full-view camera effects (CameraFx) on the world's compositor, so both
## the desktop view and the headset get them. The menus are left alone.
func _init_camera_fx() -> void:
	_camera_fx = CameraFx.new()
	_camera_fx.name = "CameraFx"
	add_child(_camera_fx)
	_camera_fx.attach(world_env)
	_camera_fx.audio = _audio
	_camera_fx.mask_panels = [floating_panel.panel_quad(), xr_rig.wrist_panel]


## A playing script's camera effect wins; otherwise the preset's. Called
## every frame (script tracks animate it).
func _update_camera_fx() -> void:
	if _camera_fx == null:
		return
	var from_script := runner.camera_effect()
	if not from_script.is_empty():
		_camera_fx.show_effect(from_script.key, from_script.params, from_script.strength)
	else:
		var fx := _layers.camera_fx
		_camera_fx.show_effect(fx.shader, fx.params, fx.strength)
	if _camera_fx.is_running() != _camera_fx_running:
		_camera_fx_running = _camera_fx.is_running()
		_update_audio_active()
	if _camera_fx.error_text() != _camera_fx_error:
		_camera_fx_error = _camera_fx.error_text()
		if _camera_tab != null:
			_camera_tab.set_camera_fx_error(_camera_fx_error)


## The analyzer is shared: run it while any layer has a shader (or a
## camera effect is on).
func _update_audio_active() -> void:
	if _audio == null:
		return
	var running := runner.wants_audio() or (_camera_fx != null and _camera_fx.is_running())
	for node in _layer_nodes + _script_layers():
		running = running or node.is_running()
	_audio.set_active(running)


## The shader layers the current script spawned.
func _script_layers() -> Array[Visualizer]:
	var out: Array[Visualizer] = []
	var registry := runner.registry()
	for id in registry.all_ids():
		var node = registry.get_node_by_id(id)
		if is_instance_valid(node) and node is Visualizer:
			out.append(node)
	return out


func _on_curvature_maybe_changed() -> void:
	if _screen_settings.curvature != _last_curvature:
		_apply_curvature()


## Push the Camera tab's curvature to the main screen's display shader.
## `only_if_curved` is for a fresh spawn: a flat (0) preference leaves any
## curvature the script's own config set, so a script's curved screen isn't
## flattened by a default preset. Moving the slider always applies.
func _apply_curvature(only_if_curved: bool = false) -> void:
	if _screen_settings == null:
		return
	if only_if_curved and _screen_settings.curvature <= 0.0:
		return
	_last_curvature = _screen_settings.curvature
	var screen := runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	if screen != null and screen.has_method("set_curvature"):
		screen.set_curvature(_screen_settings.curvature)


func _init_player_settings() -> void:
	_player_settings = PlayerSettings.new()
	_player_settings.load_from_disk()
	_player_settings.changed.connect(_apply_player_settings)
	_apply_player_settings()


func _apply_player_settings() -> void:
	_camera_fx.enabled = _player_settings.camera_fx
	_camera_fx.max_strength = _player_settings.camera_fx_max
	var locked := _player_settings.locomotion == PlayerSettings.Locomotion.LOCKED
	# Free movement's bindings (walk, turn) take the sticks from the media
	# remote's; with it locked, Space plays / pauses instead of flying up.
	_router.set_context("locked", locked)
	_router.set_context("free", not locked)
	desktop_camera.movement_enabled = not locked
	floor_mesh.visible = _player_settings.show_floor
	_apply_window_settings()
	_skyboxes.apply(world_env.environment, _player_settings.skybox)
	if _video != null:
		_video.set_volume(_player_settings.volume)
		if _audio != null:
			_audio.set_input_gain(_video.audio_gain())
	if _live_sync != null:
		_live_sync.set_enabled(_player_settings.live_sync)


## Desktop window preferences: fullscreen and the bottom play bar.
func _apply_window_settings() -> void:
	var mc := get_node_or_null("UI/MediaControls") as Control
	if mc != null:
		mc.visible = _player_settings.show_play_bar
	if DisplayServer.get_name() == "headless":
		return
	var want := DisplayServer.WINDOW_MODE_FULLSCREEN if _player_settings.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	var mode := DisplayServer.window_get_mode()
	var is_full := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if is_full != _player_settings.fullscreen:
		DisplayServer.window_set_mode(want)


## Effective projection key for the current video.
func _current_projection() -> String:
	if _projection_override != "auto":
		return _projection_override
	return VideoProjection.detect(_video_name)


func _on_projection_selected(key: String) -> void:
	_projection_override = key
	_apply_projection()


## Push projection + aspect to the main screen (and the layers that read
## the video) and mirror it in the panel.
func _apply_projection() -> void:
	if _video != null:
		_video.set_overlay_stereo(VideoProjection.stereo_of(_current_projection()))
	var screen := runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	if screen != null and screen.has_method("set_projection"):
		screen.set_projection(_current_projection())
		if _video != null and screen.has_method("set_content_aspect"):
			var size := _video.frame_size()
			if size.y > 0:
				screen.set_content_aspect(float(size.x) / float(size.y))
	for node in _layer_nodes + _script_layers():
		_apply_video_to_layer(node)
	if _camera_tab != null:
		_camera_tab.set_projection_state(_projection_override, VideoProjection.detect(_video_name))


## The video's frame and layout, for layer shaders tagged `@iChannelN video`.
func _apply_video_to_layer(node: Visualizer) -> void:
	if _video == null:
		return
	node.bind_video(_video.get_output_texture())
	var size := _video.frame_size()
	node.set_video_layout(_current_projection(), float(size.x) / size.y if size.y > 0 else 0.0)


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
	_live_sync.seek_requested.connect(_seek_to)
	_live_sync.play_requested.connect(runner.play)
	_live_sync.pause_requested.connect(runner.pause)
	_live_sync.connect_to_editor(_cli_live_sync_port)


## The editor pressed Preview. Already showing that script: reload it in
## place now (the file watcher would too, a moment later), so the edit and
## the seek land together without reopening the video.
func _on_live_open(path: String, t: float, playing: bool) -> void:
	if runner.timeline != null and LiveSyncClient.same_path(runner.timeline.script_path, path):
		runner.reload()
		_seek_to(t)
	else:
		_playlist = Playlist.from_folder(path, _player_settings.browser_sort)
		open_file(path)
		_seek_to(t)
	if playing:
		runner.play()
	else:
		runner.pause()


## Seek now, and again once the video has opened if it is still opening.
func _seek_to(t: float) -> void:
	runner.seek(t)
	if (_video != null and _video.is_loading()) or runner.effective_duration() <= 0.0:
		_pending_start = t


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
		content.bind_camera(_screen_settings, _preset_store, _layers)
		_camera_tab = content.camera_tab
		_camera_tab.projection_selected.connect(_on_projection_selected)
		_camera_tab.reset_view_requested.connect(reset_view)
		_apply_projection()
	# Config first: the Files tab needs PlayerSettings (its remembered folder)
	# before bind_files opens its first folder.
	if content.has_method("bind_config"):
		content.bind_config(_player_settings)
	if content.has_method("bind_controls"):
		content.bind_controls(_router)
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
		content = xr_rig.wrist_content()
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


func _init_video() -> void:
	if not ClassDB.class_exists("GoZenVideo"):
		_set_status("GoZenVideo class not found — is addons/gde_gozen loaded?")
		return
	_video = VIDEO_BRIDGE_SCRIPT.new()
	_video.name = "VideoBridge"
	add_child(_video)
	_video.video_loaded.connect(_on_video_loaded)
	_video.video_load_failed.connect(_on_video_load_failed)
	# Freeze the timeline while the picture catches up (opening, seeking), so
	# script events and the scrub bar stay in step with the video.
	_video.busy_changed.connect(func(busy: bool): runner.hold = busy)
	if _player_settings != null:
		_video.set_volume(_player_settings.volume)
	# Live analysis of the video's sound for the visualizer plane.
	_audio = AudioAnalyzer.new()
	_audio.name = "AudioAnalyzer"
	add_child(_audio)
	if not _audio.attach(_video.audio_bus_name()):
		push_warning("AudioAnalyzer: video audio bus not found; the visualizer won't react to sound.")
	_audio.set_input_gain(_video.audio_gain())
	_audio.set_active(false)
	# Push the video texture into any spawned object that accepts one
	# (e.g. the Screen prefab). Fires both for runner spawns and any
	# externally-registered nodes.
	runner.registry().object_spawned.connect(_on_object_spawned)


func _on_object_spawned(id: String, node: Node3D) -> void:
	if node == null:
		return
	if screen_mount != null and node.get_parent() == screen_mount.get_parent() and _belongs_in_mount(node):
		# Screens (main_screen and any split-off ones), and the groups and
		# shader layers a script places with them, live under the mount:
		# the runner's per-frame transform tracks write into the mount's
		# local space, and user preferences (size/distance/height on the
		# mount) layer on top without ever fighting animation. Objects
		# spawned inside another one stay there.
		node.reparent(screen_mount, false)
	if id == DefaultScreen.SCREEN_ID and screen_mount != null and screen_mount.is_ancestor_of(node):
		_apply_curvature(true)
	if node is Screen:
		_apply_display_to(node)
	if node is Visualizer:
		if _audio != null:
			node.bind_audio(_audio)
		_apply_video_to_layer(node)
	# A layer's shader and a `pulse` arrive right after this signal.
	_update_audio_active.call_deferred()
	if id == DefaultScreen.SCREEN_ID:
		_main_screen = node
		for layer in _layer_nodes:
			layer.set_follow_target(node)
	if _video != null and node.has_method("set_source_texture"):
		node.call("set_source_texture", _video.get_output_texture())
	if id == DefaultScreen.SCREEN_ID:
		_apply_projection()


static func _belongs_in_mount(node: Node) -> bool:
	return node.has_method("set_source_texture") or node is Visualizer or node.get_meta("vj_group", false)


func _on_script_loaded(data: TimelineData) -> void:
	if not DefaultScreen.is_idle(data):
		_set_status("Loaded: %s" % data.meta.get("title", data.script_path.get_file()))
	if _script_moved_view:
		_script_moved_view = false
		reset_view()
	_projection_override = "auto"
	_apply_look_for(data)
	# Spawn what the timeline starts with (the screen) now: the clock is
	# held until the video opens, and waiting for its first tick left no
	# screen in the meantime.
	runner.tick(0.0)
	_load_video_for(data)
	_apply_projection()


## Scripts play with the locked Script preset (software defaults, no
## effects or layers) so they look as authored, whatever preset the viewer
## uses for plain videos; that look comes back when a plain video loads.
## Runs before the new timeline's screens spawn, so a script's own curvature
## isn't flattened (see _apply_curvature).
func _apply_look_for(data: TimelineData) -> void:
	var is_script := not data.synthetic
	if is_script and _look_before_script.is_empty():
		_look_before_script = {
			"preset": _preset_store.active_index,
			"screen": _screen_settings.to_dict(),
			"layers": _layers.to_array(),
		}
		_preset_store.apply(PresetStore.SCRIPT_PRESET_INDEX, _screen_settings, _layers)
	elif not is_script and not _look_before_script.is_empty():
		_screen_settings.from_dict(_look_before_script["screen"])
		_layers.from_array(_look_before_script["layers"])
		_preset_store.set_active(int(_look_before_script["preset"]))
		_look_before_script = {}


func _load_video_for(data: TimelineData) -> void:
	var rel: String = data.media.get("video", "")
	var resource_path := data.resolve(rel) if rel != "" else ""
	var os_path := ""
	if DefaultScreen.is_url(resource_path):
		os_path = resource_path
	elif resource_path != "" and FileAccess.file_exists(resource_path):
		# get_path_absolute() resolves both res:// and cwd-relative paths
		# (e.g. `--script ../scripts/x.json`) to a clean absolute OS path —
		# timecode clients match funscripts by this path.
		var f := FileAccess.open(resource_path, FileAccess.READ)
		os_path = f.get_path_absolute().simplify_path() if f != null else ProjectSettings.globalize_path(resource_path)
	elif resource_path != "":
		_set_status("Video not found: %s" % resource_path)
	_video_path = os_path
	_video_name = String(data.meta.get("video_name", os_path))
	if _whirligig != null:
		_whirligig.set_media_path(os_path)
	if _video == null or os_path == "":
		return
	_video.load_video(os_path)
	_show_loading_thumbnail(os_path, String(data.meta.get("thumbnail_url", "")))


## The opening video's thumbnail on the screen: the DLNA server's image for
## a network item, else the OS's for a local file (may arrive later, via
## _thumbs.thumbnail_ready).
func _show_loading_thumbnail(os_path: String, thumbnail_url: String) -> void:
	if thumbnail_url != "" and _dlna != null:
		var tex := BrowserView.texture_from_bytes(await _dlna.fetch_bytes(thumbnail_url))
		if os_path == _video_path:
			_video.set_loading_thumbnail(tex)
	elif not DefaultScreen.is_url(os_path) and _thumbs != null:
		_video.set_loading_thumbnail(_thumbs.request(os_path))


func _on_video_loaded(duration: float, framerate: float) -> void:
	_set_status("Video loaded: %.2fs @ %.2f fps" % [duration, framerate])
	runner.set_video_duration(duration)
	_apply_projection()  # aspect is known now
	if _pending_start > 0.0:
		runner.seek(_pending_start)
		_pending_start = 0.0
	if runner.playing:
		_video.play()


## The bridge already retried. Stop the clock and withdraw the media from
## timecode clients, so devices don't start on a video that isn't playing.
func _on_video_load_failed() -> void:
	_set_status("Could not open video: %s" % _video_path)
	runner.pause()
	if _whirligig != null:
		_whirligig.set_media_path("")


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


func _on_event_fired(ev: Dictionary) -> void:
	match String(ev.get("action", "")):
		"vr_cut", "vr_teleport":
			_apply_camera_cut(ev)


func _apply_camera_cut(ev: Dictionary) -> void:
	if not _player_settings.allow_script_camera:
		return
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
	_script_moved_view = true
	if xr_mode.is_in_vr():
		xr_rig.recenter(pos, rot_deg.y)
	else:
		desktop_camera.set_view(pos, rot_deg)


func _on_script_load_failed(err: String) -> void:
	_set_status("ERROR: %s" % err)


func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg
	print(msg)
