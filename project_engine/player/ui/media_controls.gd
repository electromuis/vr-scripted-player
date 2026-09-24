extends PanelContainer

## Bottom-bar media controls for desktop mode: previous/play/next, scrub
## bar, time readout. Previous/next just ask main.gd, which owns the playlist. Poll runner state each frame; only push seek() when the user
## interacts with the slider (drag_started/drag_ended prevents feedback loops).

signal previous_requested
signal next_requested

@onready var prev_button: Button = %PrevButton
@onready var play_button: Button = %PlayButton
@onready var next_button: Button = %NextButton
@onready var scrub: HSlider = %Scrub
@onready var time_label: Label = %TimeLabel

var runner: ScriptRunner
var _scrubbing: bool = false


func bind(r: ScriptRunner) -> void:
	runner = r
	if runner == null:
		return
	runner.script_loaded.connect(_on_script_loaded)
	runner.script_reloaded.connect(_on_script_loaded)


func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	prev_button.pressed.connect(previous_requested.emit)
	next_button.pressed.connect(next_requested.emit)
	scrub.drag_started.connect(func(): _scrubbing = true)
	scrub.drag_ended.connect(_on_scrub_drag_ended)
	scrub.value_changed.connect(_on_scrub_value_changed)
	_refresh_labels()


func _process(_delta: float) -> void:
	if runner == null or runner.timeline == null:
		return
	# Effective duration can change after script_loaded if the video reports
	# its length. Keep the scrub range in sync.
	var eff := runner.effective_duration()
	if abs(scrub.max_value - eff) > 0.01 and eff > 0.0:
		scrub.max_value = maxf(eff, 0.1)
	if not _scrubbing:
		scrub.set_value_no_signal(runner.playhead)
	_refresh_labels()
	play_button.text = "⏸" if runner.playing else "▶"


func _on_script_loaded(data: TimelineData) -> void:
	scrub.min_value = 0.0
	scrub.max_value = maxf(data.duration(), 0.1)
	scrub.step = 0.01
	scrub.set_value_no_signal(runner.playhead)
	_refresh_labels()


func _on_play_pressed() -> void:
	if runner == null:
		return
	if runner.playing:
		runner.pause()
	else:
		runner.play()


func _on_scrub_value_changed(v: float) -> void:
	# During a drag, only seek if we're actively scrubbing (drag_started fired).
	# Godot fires value_changed on every step; seeking each tick during a drag
	# is what makes the "reproject on scrub" feel snappy.
	if runner == null:
		return
	if _scrubbing:
		runner.seek(v)


func _on_scrub_drag_ended(value_changed: bool) -> void:
	if runner != null and value_changed:
		runner.seek(scrub.value)
	_scrubbing = false


func _refresh_labels() -> void:
	if runner == null or runner.timeline == null:
		time_label.text = "--:-- / --:--"
		return
	time_label.text = "%s / %s" % [_format_time(runner.playhead), _format_time(runner.effective_duration())]


static func _format_time(t: float) -> String:
	var total := int(t)
	return "%02d:%02d" % [total / 60, total % 60]
