extends PanelContainer

## 2D control tree hosted inside a SubViewport on the wrist quad. Compact
## layout: previous/play/next + time + menu, scrub, volume. Bound to a ScriptRunner.
## Same interaction model as the floating panel — pointer events arrive
## through the parent XRToolsViewport2DIn3D from the right controller's
## XRToolsFunctionPointer.

signal menu_requested  ## Menu button — main.gd toggles the floating panel.
signal previous_requested  ## main.gd steps the playlist.
signal next_requested

@onready var prev_button: Button = %WristPrev
@onready var play_button: Button = %WristPlay
@onready var next_button: Button = %WristNext
@onready var menu_button: Button = %WristMenu
@onready var time_label: Label = %WristTime
@onready var scrub_slider: HSlider = %WristScrub
@onready var volume_slider: HSlider = %WristVolume

var _runner: ScriptRunner
var _settings: PlayerSettings
var _scrubbing: bool = false
var _fps: FpsLabel


func bind(runner: ScriptRunner, settings: PlayerSettings = null) -> void:
	_settings = settings
	_fps.bind(settings)
	if _settings != null:
		_settings.changed.connect(_refresh_volume)
		_refresh_volume()
	_runner = runner
	if _runner == null:
		return
	_runner.script_loaded.connect(_on_script_loaded)
	_runner.script_reloaded.connect(_on_script_loaded)
	if _runner.timeline != null:
		_on_script_loaded(_runner.timeline)


func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	menu_button.pressed.connect(menu_requested.emit)
	prev_button.pressed.connect(previous_requested.emit)
	next_button.pressed.connect(next_requested.emit)
	scrub_slider.drag_started.connect(func(): _scrubbing = true)
	scrub_slider.drag_ended.connect(_on_scrub_drag_ended)
	scrub_slider.value_changed.connect(_on_scrub_value_changed)
	volume_slider.value_changed.connect(_on_volume_changed)
	_fps = FpsLabel.new()
	_fps.name = "WristFps"
	menu_button.add_sibling(_fps)
	menu_button.get_parent().move_child(_fps, menu_button.get_index())


func _process(_delta: float) -> void:
	if _runner == null or _runner.timeline == null:
		time_label.text = "--:-- / --:--"
		play_button.text = "▶"
		return
	var eff := _runner.effective_duration()
	if absf(scrub_slider.max_value - eff) > 0.01 and eff > 0.0:
		scrub_slider.max_value = maxf(eff, 0.1)
	if not _scrubbing:
		scrub_slider.set_value_no_signal(_runner.playhead)
	time_label.text = "%s / %s" % [
		_format_time(_runner.playhead),
		_format_time(_runner.effective_duration()),
	]
	play_button.text = "⏸" if _runner.playing else "▶"


func _on_script_loaded(data: TimelineData) -> void:
	scrub_slider.min_value = 0.0
	scrub_slider.max_value = maxf(data.duration(), 0.1)
	scrub_slider.step = 0.01
	scrub_slider.set_value_no_signal(_runner.playhead)


func _on_play_pressed() -> void:
	if _runner == null:
		return
	if _runner.playing:
		_runner.pause()
	else:
		_runner.play()


func _on_scrub_value_changed(v: float) -> void:
	if _runner != null and _scrubbing:
		_runner.seek(v)


func _on_scrub_drag_ended(value_changed: bool) -> void:
	if _runner != null and value_changed:
		_runner.seek(scrub_slider.value)
	_scrubbing = false


func _on_volume_changed(v: float) -> void:
	# Slider range is whatever the scene defines; settings store 0..1.
	if _settings != null:
		_settings.volume = inverse_lerp(volume_slider.min_value, volume_slider.max_value, v)


func _refresh_volume() -> void:
	volume_slider.set_value_no_signal(
		lerpf(volume_slider.min_value, volume_slider.max_value, _settings.volume))


static func _format_time(t: float) -> String:
	var total := int(t)
	return "%02d:%02d" % [total / 60, total % 60]
