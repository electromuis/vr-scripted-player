class_name StudioWristPalette
extends PanelContainer

## Studio's left-wrist palette in Edit mode: the status (mode, piece,
## unsaved, time, last action) over a grid of big buttons for what the
## controllers don't have a button for. Press them with the right laser.
## Each button asks Studio to run a command (`action`, the same ids as the
## router's Studio commands); toggles show their state (auto-key red,
## snapping blue) via show_toggles().

signal action(id: StringName)

const ACCENT := Color(0.3, 0.79, 0.94)
const RECORD := Color(1.0, 0.36, 0.36)
## [command id, label, toggle?]
const BUTTONS := [
	[&"studio_toggle_mode", "Play / Edit", false],
	[&"studio_play_pause", "Play ❚❚", false],
	[&"studio_key_selection", "◆ Key it", false],
	[&"studio_toggle_autokey", "Auto-key", true],
	[&"studio_toggle_snap", "Snap", true],
	[&"studio_undo", "↶ Undo", false],
	[&"studio_redo", "↷ Redo", false],
	[&"studio_save", "Save", false],
	[&"studio_seat", "Seat", false],
	[&"studio_goto_selection", "Go to it", false],
	[&"studio_jump_back", "Back", false],
	[&"studio_deselect", "Deselect", false],
]

var status: StudioStatus
var _buttons: Dictionary = {}  # id -> Button


func _ready() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.06, 0.09, 0.92)
	bg.set_corner_radius_all(12)
	bg.set_content_margin_all(14)
	add_theme_stylebox_override("panel", bg)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 14)
	add_child(rows)
	status = StudioStatus.new()
	status.compact = true
	rows.add_child(status)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.add_child(grid)
	for b in BUTTONS:
		var button := Button.new()
		button.text = b[1]
		button.custom_minimum_size = Vector2(0, 96)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 30)
		button.toggle_mode = b[2]
		button.focus_mode = Control.FOCUS_NONE
		for state in ["normal", "hover", "pressed", "hover_pressed"]:
			button.add_theme_stylebox_override(state, _style(state, b[0]))
		button.pressed.connect(func(): action.emit(b[0]))
		grid.add_child(button)
		_buttons[b[0]] = button


## Auto-key and snapping as they are in Studio (not what a click toggled).
func show_toggles(auto_key: bool, snap: bool) -> void:
	if _buttons.is_empty():
		return
	_buttons[&"studio_toggle_autokey"].set_pressed_no_signal(auto_key)
	_buttons[&"studio_toggle_snap"].set_pressed_no_signal(snap)


func _style(state: String, id: StringName) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(8)
	var on := state in ["pressed", "hover_pressed"]
	var tint := RECORD if id == &"studio_toggle_autokey" else ACCENT
	sb.bg_color = Color(0.17, 0.2, 0.27) if not on else Color(tint, 0.28)
	if state == "hover" or state == "hover_pressed":
		sb.bg_color = sb.bg_color.lightened(0.12)
	if on:
		sb.border_color = tint
		sb.set_border_width_all(3)
	return sb
