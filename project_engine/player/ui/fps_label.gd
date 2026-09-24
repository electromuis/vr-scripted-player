class_name FpsLabel
extends Label

## Rendered frames per second, shown while PlayerSettings.show_fps is on.
## Updated a few times a second so it stays readable.

const INTERVAL := 0.25  # seconds

var _settings: PlayerSettings
var _elapsed: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func bind(settings: PlayerSettings) -> void:
	_settings = settings
	if _settings != null:
		_settings.changed.connect(_refresh)
	_refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_elapsed += delta
	if _elapsed < INTERVAL:
		return
	_elapsed = 0.0
	text = "%d FPS" % roundi(Engine.get_frames_per_second())


func _refresh() -> void:
	visible = _settings != null and _settings.show_fps
	if visible:
		text = "%d FPS" % roundi(Engine.get_frames_per_second())
