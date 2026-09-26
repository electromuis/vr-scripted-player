extends Node3D

## Studio: the VR editor for VJ scripts (see "VR Studio — Plan.md"). It
## runs a piece on the player's own Stage (player/stage/), so what you see
## while editing is what the player shows, and edits it through an
## EditModel: every change is an undoable command on the script JSON,
## which the runner picks up in place (ScriptRunner.apply_edit).
##
## Two modes, one button: Play is the audience view with no UI; Edit shows
## the tools (for now the status on the wrist and in the desktop corner).
## Switching keeps the playhead.
##
## Command line (after `--`): --piece <script.json, or a video with a
## same-name .json next to it>, --start <seconds>, --vr, --desktop.

## Scrubbing speed at full stick, in seconds of timeline per second.
const SCRUB_SPEED := 20.0
const STEP_SECONDS := 1.0
const SEEK_SECONDS := 10.0
const WRIST_SCENE := preload("res://studio/ui/studio_status.tscn")

enum Mode { PLAY, EDIT }

@onready var stage: Stage = $Stage
@onready var runner: ScriptRunner = $Stage/ScriptRunner
@onready var status_view: StudioStatus = $UI/Status

## The piece being edited; null until one is open.
var model: EditModel
var mode: Mode = Mode.EDIT
## The last thing worth saying (undo, save, errors), shown in the status.
var message: String = ""

var _settings: PlayerSettings
var _cli_piece: String = ""
var _cli_start: float = 0.0
var _cli_vr: bool = false
var _cli_desktop: bool = false
var _wrist: StudioStatus


func _ready() -> void:
	_parse_cli_args()
	_use_studio_fly_keys()
	_settings = PlayerSettings.new()
	_settings.load_from_disk()
	stage.status.connect(func(msg: String): print(msg))
	stage.setup(_settings, InputBindings.new())
	# Studio's own commands; the player's never fire here.
	stage.router.set_context("play", false)
	stage.router.set_context("studio", true)
	stage.router.command.connect(_on_command)
	# Studio edits its own copy of the file: a save coming back through the
	# file watcher must not reload over newer edits.
	runner.set_live_reload(false)
	stage.xr_mode.entered_vr.connect(_apply_mode)
	stage.xr_rig.wrist_panel.scene = WRIST_SCENE
	set_mode(Mode.EDIT)

	if _cli_piece != "":
		open_piece(_cli_piece)
	else:
		runner.load_timeline(DefaultScreen.idle_timeline())
		runner.seek(0.0)
		_say("No piece open. Start Studio with -- --piece <script.json>.")

	if _cli_vr or (not _cli_desktop and stage.xr_mode.headset_detected()):
		stage.xr_mode.try_enter_vr()


func _process(delta: float) -> void:
	_scrub(delta)
	_show_status()


## Open a script (or a video with its sidecar script) for editing. Returns
## whether it opened; the current piece stays otherwise.
func open_piece(path: String) -> bool:
	if DefaultScreen.is_video(path):
		var sidecar := DefaultScreen.sidecar_script(path)
		if sidecar == "":
			_say("No script next to %s (Studio opens pieces: a .json)." % path.get_file())
			return false
		path = sidecar
	var r := EditModel.open(path)
	if not r.ok:
		_say("Can't open %s: %s" % [path.get_file(), r.error])
		return false
	if model != null:
		model.changed.disconnect(_on_model_changed)
	model = r.model
	model.changed.connect(_on_model_changed)
	runner.load_timeline(model.timeline())
	runner.pause()
	stage.seek_to(_cli_start)
	_cli_start = 0.0
	_say("Opened %s." % _piece_name())
	return true


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	_apply_mode()


func _apply_mode() -> void:
	var editing := mode == Mode.EDIT
	stage.router.set_context("studio_edit", editing)
	status_view.visible = editing
	# The wrist shows only in the headset (the stage turns it on with VR).
	stage.xr_rig.wrist_panel.visible = editing and stage.xr_mode.is_in_vr()
	stage.desktop_camera.movement_enabled = editing


func save() -> bool:
	if model == null:
		return false
	var r := model.save()
	_say("Saved %s." % model.path.get_file() if r.ok else String(r.error))
	return r.ok


func undo() -> void:
	if model == null:
		return
	var label := model.undo()
	_say("Undo: %s" % label if label != "" else "Nothing to undo.")


func redo() -> void:
	if model == null:
		return
	var label := model.redo()
	_say("Redo: %s" % label if label != "" else "Nothing to redo.")


func _on_model_changed(structural: bool) -> void:
	message = model.undo_label()  # undo / redo say their own afterwards
	var data := model.timeline()
	if data != null:
		runner.apply_edit(data, structural)


func _on_command(id: StringName) -> void:
	match id:
		&"studio_toggle_mode": set_mode(Mode.PLAY if mode == Mode.EDIT else Mode.EDIT)
		&"studio_play_pause": _toggle_play()
		&"studio_step_back": _seek_by(-STEP_SECONDS)
		&"studio_step_forward": _seek_by(STEP_SECONDS)
		&"studio_seek_back": _seek_by(-SEEK_SECONDS)
		&"studio_seek_forward": _seek_by(SEEK_SECONDS)
		&"studio_go_start": stage.seek_to(0.0)
		&"studio_save": save()
		&"studio_undo": undo()
		&"studio_redo": redo()
		&"studio_reset_view": stage.reset_view()
		&"studio_toggle_vr":
			if stage.xr_mode.is_in_vr():
				stage.xr_mode.exit_vr()
			else:
				stage.xr_mode.try_enter_vr()


func _toggle_play() -> void:
	if model == null:
		return
	if runner.playing:
		runner.pause()
	else:
		runner.play()


func _seek_by(seconds: float) -> void:
	if model != null:
		stage.seek_to(runner.playhead + seconds)


## Left trigger + left stick: further is faster (squared, so small pushes
## are fine-grained).
func _scrub(delta: float) -> void:
	if model == null:
		return
	var x := stage.router.axis("studio_scrub").x
	if x != 0.0:
		stage.seek_to(runner.playhead + x * absf(x) * SCRUB_SPEED * delta)


func _show_status() -> void:
	var args := [
		"EDIT" if mode == Mode.EDIT else "PLAY",
		_piece_name(),
		model != null and model.is_dirty(),
		runner.playhead,
		runner.effective_duration(),
		runner.playing,
		message,
	]
	if status_view.visible:
		status_view.callv("show_state", args)
	if _wrist == null or not is_instance_valid(_wrist):
		_wrist = stage.xr_rig.wrist_content() as StudioStatus
	if _wrist != null and stage.xr_rig.wrist_panel.visible:
		_wrist.callv("show_state", args)


func _piece_name() -> String:
	if model == null:
		return "No piece"
	var title := String(model.document().get("meta", {}).get("title", ""))
	return title if title != "" else model.path.get_file()


func _say(msg: String) -> void:
	message = msg
	print(msg)


## Desktop flight in Edit mode: WASD, E up, Q down (Space plays / pauses
## and Ctrl is for shortcuts here, unlike the player). Only this run's
## InputMap changes.
func _use_studio_fly_keys() -> void:
	for pair in [["move_up", KEY_E], ["move_down", KEY_Q]]:
		if not InputMap.has_action(pair[0]):
			continue
		InputMap.action_erase_events(pair[0])
		var ev := InputEventKey.new()
		ev.physical_keycode = pair[1]
		InputMap.action_add_event(pair[0], ev)


func _parse_cli_args() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var a: String = args[i]
		if a == "--piece" and i + 1 < args.size():
			_cli_piece = args[i + 1]
		elif a == "--start" and i + 1 < args.size():
			_cli_start = float(args[i + 1])
		elif a == "--vr":
			_cli_vr = true
		elif a == "--desktop":
			_cli_desktop = true
	# "Open with" / dropping a file on the .exe.
	if _cli_piece == "":
		for a in OS.get_cmdline_args():
			if (DefaultScreen.is_video(a) or a.get_extension().to_lower() == "json") and FileAccess.file_exists(a):
				_cli_piece = a
