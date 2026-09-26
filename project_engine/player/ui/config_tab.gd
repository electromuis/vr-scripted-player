extends VBoxContainer

## Config tab of the F2 floating panel: app-wide viewer preferences backed
## by PlayerSettings (saved on every change). Controls are built in code —
## it's a flat list of labelled rows.

const LABEL_WIDTH := 190

var _settings: PlayerSettings
var _refreshing: bool = false
var _skybox_keys: Array[String] = []

var _locomotion: OptionButton
var _script_camera: CheckButton
var _skybox: OptionButton
var _floor: CheckButton
var _fps: CheckButton
var _volume: HSlider
var _volume_value: Label
var _end_action: OptionButton
var _live_sync: CheckButton
var _fullscreen: CheckButton
var _play_bar: CheckButton
var _camera_fx: CheckButton
var _camera_fx_max: HSlider
var _camera_fx_max_value: Label


func _ready() -> void:
	add_theme_constant_override("separation", 12)

	_locomotion = OptionButton.new()
	_locomotion.add_item("Locked — sticks seek / volume", PlayerSettings.Locomotion.LOCKED)
	_locomotion.add_item("Free — walk and snap-turn", PlayerSettings.Locomotion.FREE)
	_locomotion.item_selected.connect(func(idx: int):
		_apply_ui(func(): _settings.locomotion = _locomotion.get_item_id(idx)))
	_row("Movement", _locomotion)

	_script_camera = CheckButton.new()
	_script_camera.text = "Scripts may move the viewer"
	_script_camera.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.allow_script_camera = on))
	_row("Script camera", _script_camera)

	_skybox = OptionButton.new()
	_skybox.item_selected.connect(func(idx: int):
		_apply_ui(func(): _settings.skybox = _skybox_keys[idx]))
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.tooltip_text = "Look for new panoramas in the skyboxes folders"
	rescan.pressed.connect(_refresh_skybox_list)
	_row("Skybox", _skybox, rescan)

	_floor = CheckButton.new()
	_floor.text = "Show floor"
	_floor.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.show_floor = on))
	_row("Floor", _floor)

	_fps = CheckButton.new()
	_fps.text = "Show frames per second"
	_fps.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.show_fps = on))
	_row("FPS", _fps)

	_fullscreen = CheckButton.new()
	_fullscreen.text = "Fill the screen (F11)"
	_fullscreen.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.fullscreen = on))
	_row("Fullscreen", _fullscreen)

	_play_bar = CheckButton.new()
	_play_bar.text = "Show the desktop play bar (H)"
	_play_bar.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.show_play_bar = on))
	_row("Play bar", _play_bar)

	_camera_fx = CheckButton.new()
	_camera_fx.text = "Allow full-view effects"
	_camera_fx.tooltip_text = "Camera effects (kaleidoscopes, colour cycling, warps) from presets and scripts"
	_camera_fx.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.camera_fx = on))
	_row("Camera effects", _camera_fx)
	_camera_fx_max = HSlider.new()
	_camera_fx_max.min_value = 0.0
	_camera_fx_max.max_value = 1.0
	_camera_fx_max.step = 0.05
	_camera_fx_max.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_camera_fx_max.tooltip_text = "Scripts and presets never go stronger than this"
	_camera_fx_max_value = Label.new()
	_camera_fx_max_value.custom_minimum_size = Vector2(60, 0)
	_camera_fx_max_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_camera_fx_max.value_changed.connect(func(v: float):
		_camera_fx_max_value.text = "%d%%" % roundi(v * 100.0)
		_apply_ui(func(): _settings.camera_fx_max = v))
	_row("Effects at most", _camera_fx_max, _camera_fx_max_value)

	_volume = HSlider.new()
	_volume.min_value = 0.0
	_volume.max_value = 1.0
	_volume.step = 0.01
	_volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_volume_value = Label.new()
	_volume_value.custom_minimum_size = Vector2(60, 0)
	_volume_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_volume.value_changed.connect(func(v: float):
		_volume_value.text = "%d%%" % roundi(v * 100.0)
		_apply_ui(func(): _settings.volume = v))
	_row("Volume", _volume, _volume_value)

	_end_action = OptionButton.new()
	for key in PlayerSettings.END_ACTIONS:
		_end_action.add_item(PlayerSettings.END_ACTION_LABELS[key])
	_end_action.tooltip_text = "Next follows the order of the Files / Network list the video was picked from"
	_end_action.item_selected.connect(func(idx: int):
		_apply_ui(func(): _settings.end_action = PlayerSettings.END_ACTIONS[idx]))
	_row("At video end", _end_action)

	_live_sync = CheckButton.new()
	_live_sync.text = "Follow the authoring editor"
	_live_sync.tooltip_text = "When the player was started from the editor's Preview button: scrubbing and playing there drive this player, and pausing here moves the editor's playhead"
	_live_sync.toggled.connect(func(on: bool):
		_apply_ui(func(): _settings.live_sync = on))
	_row("Editor sync", _live_sync)

	var hint := Label.new()
	hint.text = "Panoramas: put .jpg/.png/.hdr files in %s" % " or ".join(SkyboxLibrary.search_dirs())
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(hint)


func bind(settings: PlayerSettings) -> void:
	_settings = settings
	if _settings != null:
		_settings.changed.connect(_refresh)
	_refresh_skybox_list()
	_refresh()


func _refresh_skybox_list() -> void:
	_skybox.clear()
	_skybox_keys.clear()
	for opt in SkyboxLibrary.list_options():
		_skybox.add_item(String(opt.label))
		_skybox_keys.append(String(opt.key))
	# A previously chosen panorama that's since been moved still shows up,
	# so the dropdown never silently lies about the current setting.
	if _settings != null and not _skybox_keys.has(_settings.skybox):
		_skybox.add_item(_settings.skybox.get_file() + " (missing)")
		_skybox_keys.append(_settings.skybox)
	_refresh()


func _refresh() -> void:
	if _settings == null or _locomotion == null:
		return
	_refreshing = true
	_locomotion.select(_locomotion.get_item_index(_settings.locomotion))
	_script_camera.button_pressed = _settings.allow_script_camera
	_skybox.select(_skybox_keys.find(_settings.skybox))
	_floor.button_pressed = _settings.show_floor
	_fps.button_pressed = _settings.show_fps
	_volume.value = _settings.volume
	_volume_value.text = "%d%%" % roundi(_settings.volume * 100.0)
	_end_action.select(PlayerSettings.END_ACTIONS.find(_settings.end_action))
	_live_sync.button_pressed = _settings.live_sync
	_fullscreen.button_pressed = _settings.fullscreen
	_play_bar.button_pressed = _settings.show_play_bar
	_camera_fx.button_pressed = _settings.camera_fx
	_camera_fx_max.value = _settings.camera_fx_max
	_camera_fx_max_value.text = "%d%%" % roundi(_settings.camera_fx_max * 100.0)
	_refreshing = false


## Apply a UI change to settings unless we're mirroring settings into the UI.
func _apply_ui(apply: Callable) -> void:
	if not _refreshing and _settings != null:
		apply.call()


func _row(label_text: String, control: Control, trailing: Control = null) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	if trailing != null:
		row.add_child(trailing)
	add_child(row)
