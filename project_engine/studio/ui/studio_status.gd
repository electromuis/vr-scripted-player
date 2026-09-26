class_name StudioStatus
extends PanelContainer

## Studio's status in Edit mode: the mode, the piece and whether it has
## unsaved changes, the playhead, and the last thing that happened (undo,
## save, an error). The desktop window shows it in a corner, with the
## keyboard shortcuts; the headset on the left wrist (compact: no hints).

const ACCENT := Color(0.3, 0.79, 0.94)
const RECORD := Color(1.0, 0.36, 0.36)
const DIM := Color(0.72, 0.75, 0.8)
const HINTS := "Tab  Play / Edit     Space  play / pause     ← →  1 s     Shift+← →  10 s     Home  start\nCtrl+Z  undo     Ctrl+Shift+Z  redo     Ctrl+S  save     R  reset view     F1  VR\nClick  select     Drag  move (wheel: nearer / further)     I  key it     Shift+I  auto-key     Shift+G  snap     F  go to it     0  seat     Shift+F  back     Esc  deselect"

## Wrist layout: bigger text, no keyboard hints.
@export var compact: bool = false

var _mode: Label
var _title: Label
var _dirty: Label
var _time: Label
var _message: Label
var _hints: Label
var _auto_key: Label
var _snap: Label


func _ready() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.06, 0.09, 0.88)
	bg.border_color = Color(0.3, 0.79, 0.94, 0.6)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(10)
	bg.set_content_margin_all(18 if compact else 12)
	add_theme_stylebox_override("panel", bg)
	var size := 34 if compact else 18
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12 if compact else 4)
	add_child(rows)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	rows.add_child(top)
	_mode = _label(top, size, Color.BLACK)
	var chip := StyleBoxFlat.new()
	chip.bg_color = ACCENT
	chip.set_corner_radius_all(6)
	chip.content_margin_left = 10
	chip.content_margin_right = 10
	_mode.add_theme_stylebox_override("normal", chip)
	if compact:
		# The wrist is narrow: the title gets its own line (or two).
		top.add_child(_spacer())
		_dirty = _label(top, size, RECORD)
		_title = _label(rows, size, Color.WHITE)
		_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_title.max_lines_visible = 2
	else:
		_title = _label(top, size, Color.WHITE)
		_title.clip_text = true
		_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_dirty = _label(top, size, RECORD)

	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 10)
	rows.add_child(toggles)
	_auto_key = _chip(toggles, size, "● AUTO-KEY", RECORD)
	_snap = _chip(toggles, size, "SNAP", ACCENT)
	_time = _label(rows, int(size * 1.5), Color.WHITE)
	_message = _label(rows, size, DIM)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not compact:
		_hints = _label(rows, 14, DIM)
		_hints.text = HINTS


## A small outlined tag, shown while its toggle is on.
func _chip(parent: Control, font_size: int, text: String, color: Color) -> Label:
	var l := _label(parent, int(font_size * 0.8), color)
	l.text = text
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, 0.15)
	sb.border_color = color
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	l.add_theme_stylebox_override("normal", sb)
	l.visible = false
	return l


static func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _label(parent: Control, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


## Everything at once; cheap enough to call every frame.
func show_state(mode: String, title: String, dirty: bool, t: float, duration: float, playing: bool, message: String,
		auto_key: bool = false, snap: bool = false) -> void:
	if _mode == null:
		return
	_auto_key.visible = auto_key and mode == "EDIT"
	_snap.visible = snap and mode == "EDIT"
	_auto_key.get_parent().visible = _auto_key.visible or _snap.visible
	_mode.text = mode
	_title.text = title
	_dirty.text = "● unsaved" if dirty else ""
	_time.text = "%s  %s / %s" % ["▶" if playing else "❚❚", timecode(t), timecode(duration)]
	_message.text = message
	_message.visible = message != ""


static func timecode(t: float) -> String:
	t = maxf(t, 0.0)
	return "%d:%05.2f" % [floori(t / 60.0), fmod(t, 60.0)]
