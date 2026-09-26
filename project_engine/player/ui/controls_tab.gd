extends VBoxContainer

## Controls tab of the F2 floating panel: every command with its bindings,
## grouped by when they apply. "+" waits for the button, stick flick or key
## you want (hold another button at the same time for a chord); a binding's
## own menu picks press / hold / double press or removes it. Taking an
## input another command had in the same context moves it here, and says
## so. Built in code, like the Config tab. Backed by InputBindings (saved on
## every change).

const LABEL_WIDTH := 340
const CAPTURE_SECONDS := 6.0
const CONFIRM_SECONDS := 3.0
const ACCENT := Color(0.3, 0.79, 0.94)
const WARN := Color(1.0, 0.45, 0.45)
## Sections in order, and the contexts whose commands they list.
const SECTIONS := [
	["play", "While watching"],
	["free", "With free movement"],
	["menus", "Pointing at a menu"],
]
## Laser-friendly minimum for the + and reset buttons.
const BUTTON_SIZE := Vector2(44, 36)
const _GESTURE_IDS := {"press": 0, "hold": 1, "double": 2}
const _REMOVE_ID := 10

var _router: InputRouter
var _bindings: InputBindings
var _list: VBoxContainer
var _status: Label
var _left_handed: Button
var _reset_all: Button
var _timer: Timer
var _capturing_for := ""


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	var hint := Label.new()
	hint.text = "Press + on a command, then the button, stick or key you want.\nHold another button at the same time for a combination."
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	header.add_child(hint)
	_left_handed = Button.new()
	_left_handed.text = "Left-handed"
	_left_handed.tooltip_text = "Every default with left and right swapped (replaces your changes)"
	_left_handed.pressed.connect(func(): _confirm(_left_handed, "Left-handed", func(): _bindings.apply_left_handed()))
	header.add_child(_left_handed)
	_reset_all = Button.new()
	_reset_all.text = "Reset all"
	_reset_all.tooltip_text = "Back to the default bindings"
	_reset_all.pressed.connect(func(): _confirm(_reset_all, "Reset all", func(): _bindings.reset_all()))
	header.add_child(_reset_all)
	add_child(header)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", ACCENT)
	add_child(_status)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	add_child(_list)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_capture_timeout)
	add_child(_timer)


func bind(router: InputRouter) -> void:
	_router = router
	_bindings = router.bindings
	_bindings.changed.connect(_rebuild)
	_router.captured.connect(_on_captured)
	_rebuild()


func _rebuild() -> void:
	if _bindings == null:
		return
	for c in _list.get_children():
		c.queue_free()
	var conflicted: Dictionary = {}
	for c in _bindings.conflicts():
		conflicted[c[0]] = c[1]
		conflicted[c[1]] = c[0]
	for section in SECTIONS:
		var title := Label.new()
		title.text = section[1]
		title.add_theme_color_override("font_color", ACCENT)
		_list.add_child(title)
		for command in InputBindings.COMMANDS:
			if InputBindings.command_context(command) == section[0]:
				_list.add_child(_command_row(command, conflicted))


func _command_row(command: String, conflicted: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = InputBindings.COMMANDS[command].label
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if conflicted.has(command):
		label.add_theme_color_override("font_color", WARN)
		label.tooltip_text = "Shares a button with \"%s\": only one of them fires" % InputBindings.COMMANDS[conflicted[command]].label
	row.add_child(label)

	var chips := HFlowContainer.new()
	chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chips.add_theme_constant_override("h_separation", 6)
	var list := _bindings.bindings_for(command)
	for i in list.size():
		chips.add_child(_chip(command, i, list[i]))
	if list.is_empty() and _capturing_for != command:
		var none := Label.new()
		none.text = "— none —"
		none.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		chips.add_child(none)
	row.add_child(chips)

	var add := Button.new()
	add.custom_minimum_size = BUTTON_SIZE
	if _capturing_for == command:
		add.text = "Press a button… (cancel)"
		add.add_theme_color_override("font_color", ACCENT)
	else:
		add.text = "+"
		add.tooltip_text = "Add a button, stick or key"
	add.pressed.connect(_on_add_pressed.bind(command))
	row.add_child(add)
	if not _bindings.is_default(command):
		var reset := Button.new()
		reset.custom_minimum_size = BUTTON_SIZE
		reset.text = "↺"
		reset.tooltip_text = "Back to this command's default"
		reset.pressed.connect(func(): _bindings.reset(command))
		row.add_child(reset)
	return row


## A binding as a button whose menu changes its gesture or removes it.
func _chip(command: String, index: int, binding: Dictionary) -> Control:
	var chip := MenuButton.new()
	chip.flat = false
	chip.tooltip_text = "Change how it's pressed, or remove it"
	for state in ["normal", "hover", "pressed", "focus"]:
		chip.add_theme_stylebox_override(state, _chip_style(state))
	var text := InputBindings.describe(binding)
	var ctx := InputBindings.binding_context(command, binding)
	if ctx != InputBindings.command_context(command):
		text += " (%s)" % InputBindings.CONTEXT_LABELS[ctx].to_lower()
	chip.text = text
	var popup := chip.get_popup()
	if InputBindings.command_kind(command) == "button" and not String(binding.input).contains("stick_"):
		for g in InputBindings.GESTURES:
			popup.add_radio_check_item({"press": "Press", "hold": "Hold", "double": "Double press"}[g], _GESTURE_IDS[g])
			popup.set_item_checked(popup.get_item_index(_GESTURE_IDS[g]), String(binding.get("gesture", "press")) == g)
		popup.add_separator()
	popup.add_item("Remove", _REMOVE_ID)
	popup.id_pressed.connect(_on_chip_menu.bind(command, index))
	return chip


static func _chip_style(state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = {"normal": Color(0.17, 0.19, 0.24), "hover": Color(0.22, 0.26, 0.33),
			"pressed": Color(0.26, 0.31, 0.4), "focus": Color(0.17, 0.19, 0.24)}[state]
	if state == "focus":
		sb.draw_center = false
		sb.border_color = ACCENT
		sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _on_chip_menu(id: int, command: String, index: int) -> void:
	var list := _bindings.bindings_for(command)
	if index >= list.size():
		return
	if id == _REMOVE_ID:
		list.remove_at(index)
		_bindings.set_bindings(command, list)
		_say("Removed from %s." % InputBindings.COMMANDS[command].label)
		return
	var gesture: String = _GESTURE_IDS.find_key(id)
	var binding: Dictionary = list[index].duplicate()
	if gesture == "press":
		binding.erase("gesture")
	else:
		binding["gesture"] = gesture
	list.remove_at(index)
	_bindings.set_bindings(command, list)
	_report(command, binding, _bindings.assign(command, binding))


func _on_add_pressed(command: String) -> void:
	if _capturing_for == command:
		_stop_capture("Cancelled.")
		return
	_capturing_for = command
	_router.begin_capture()
	_timer.start(CAPTURE_SECONDS)
	_say("%s: press the button, push the stick or press the key you want." % InputBindings.COMMANDS[command].label)
	_rebuild()


func _on_captured(input: String, modifier: String) -> void:
	if _capturing_for == "":
		return
	var command := _capturing_for
	_capturing_for = ""
	_timer.stop()
	if InputBindings.command_kind(command) == "axis":
		if InputBindings.physical(input) == input or input.begins_with("key:"):
			_say("%s needs a stick: press + again and push the stick you want." % InputBindings.COMMANDS[command].label)
			_rebuild()
			return
		input = InputBindings.physical(input)
	var binding := {"input": input}
	if modifier != "":
		binding["modifier"] = modifier
	_report(command, binding, _bindings.assign(command, binding))


func _report(command: String, binding: Dictionary, taken: Array) -> void:
	var text := "%s: %s" % [InputBindings.COMMANDS[command].label, InputBindings.describe(binding)]
	if not taken.is_empty():
		text += " (was %s)" % ", ".join(taken.map(func(c): return "\"%s\"" % InputBindings.COMMANDS[c].label))
	_say(text)


func _on_capture_timeout() -> void:
	_stop_capture("Nothing pressed: cancelled.")


func _stop_capture(message: String) -> void:
	_capturing_for = ""
	_timer.stop()
	if _router != null:
		_router.cancel_capture()
	_say(message)
	_rebuild()


func _say(text: String) -> void:
	_status.text = text


## Destructive buttons need a second press within CONFIRM_SECONDS.
func _confirm(button: Button, label: String, action: Callable) -> void:
	if button.has_meta("armed"):
		button.remove_meta("armed")
		button.text = label
		action.call()
		_say("%s: done." % label)
		return
	button.set_meta("armed", true)
	button.text = "Really?"
	await get_tree().create_timer(CONFIRM_SECONDS).timeout
	if is_instance_valid(button) and button.has_meta("armed"):
		button.remove_meta("armed")
		button.text = label
