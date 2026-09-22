extends Node3D

const DEFAULT_SCRIPT := "res://examples/moving_screen/script.json"
const MEDIA_CONTROLS_SCENE := preload("res://player/ui/media_controls.tscn")

@onready var runner: ScriptRunner = $ScriptRunner
@onready var status_label: Label = $UI/TopBar/StatusLabel
@onready var vr_button: Button = $UI/TopBar/VRButton
@onready var mode_label: Label = $UI/TopBar/ModeLabel
@onready var xr_mode: XRMode = $XRMode
@onready var desktop_camera: Camera3D = $DesktopCamera
@onready var video_quad: MeshInstance3D = $Stage/VideoQuad

var _mpv  # MPVPlayer, dynamically instantiated (GDExtension class)
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

	vr_button.pressed.connect(_on_vr_button)
	_update_mode_label()
	_init_media_controls()

	_init_mpv()

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
	desktop_camera.current = false
	_update_mode_label()
	vr_button.text = "Exit VR"


func _on_exited_vr() -> void:
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


func _init_mpv() -> void:
	if not ClassDB.class_exists("MPVPlayer"):
		_set_status("MPVPlayer class not found — is bin/godot_mpv.gdextension loaded?")
		return
	_mpv = ClassDB.instantiate("MPVPlayer")
	add_child(_mpv)
	if not _mpv.initialize():
		_set_status("MPV failed to initialize.")
		_mpv = null
		return
	# Take direct control of the material: the scene's surface_material_override
	# would otherwise mask whatever apply_to_mesh_3d() sets.
	_mpv.texture_updated.connect(_on_mpv_texture_updated)


func _on_mpv_texture_updated(tex_arg = null) -> void:
	if _mpv == null:
		return
	var tex = tex_arg if tex_arg != null else _mpv.get_texture()
	if tex == null:
		return
	if video_quad.material_override == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mat.albedo_texture = tex
		video_quad.material_override = mat
		# Drop the placeholder surface override so it can't win priority.
		video_quad.set_surface_override_material(0, null)
		_set_status("Video texture bound (%dx%d)" % [_mpv.get_width(), _mpv.get_height()])
	else:
		(video_quad.material_override as StandardMaterial3D).albedo_texture = tex


func _on_script_loaded(data: TimelineData) -> void:
	_set_status("Loaded: %s" % data.meta.get("title", data.script_path.get_file()))
	# The video screen is always addressable as "main_screen" so transform/
	# shader_param tracks in the script can target it without having to spawn it.
	# Marked external so live-reload reconciliation never despawns it.
	runner.registry().register("main_screen", video_quad, true)
	_play_video_for(data)


func _play_video_for(data: TimelineData) -> void:
	if _mpv == null:
		return
	var rel: String = data.media.get("video", "")
	if rel == "":
		return
	var resource_path := data.resolve(rel)
	if not FileAccess.file_exists(resource_path):
		_set_status("Video not found: %s" % resource_path)
		return
	# mpv expects an OS filesystem path, not a res:// URI.
	var os_path := ProjectSettings.globalize_path(resource_path)
	_mpv.load_file(os_path)
	_mpv.play()
	_set_status("Playing: %s" % resource_path.get_file())


func _on_script_load_failed(err: String) -> void:
	_set_status("ERROR: %s" % err)


func _set_status(msg: String) -> void:
	if status_label:
		status_label.text = msg
	print(msg)
