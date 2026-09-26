class_name InputRouter
extends Node

## Turns raw controller buttons, sticks and keys into commands, using
## InputBindings. Emits `command` when a binding fires (and
## `command_released` for "held" commands, like dragging the menu); axis
## commands (walking, turning, scrolling) are read with `axis()`.
##
## Gestures, per input:
##   press  — fires on press, unless the same input also has a hold or
##            double binding here; then it fires on release (hold) or once
##            the double-press window has passed (double)
##   hold   — fires after HOLD_SECONDS held
##   double — fires on the second press within DOUBLE_SECONDS
## A binding with a modifier fires only while that input is held, and
## beats one without.
##
## Stick flicks work like the old media remote: one push past
## FLICK_ON is one step (the dominant axis wins), and the stick has to come
## back under FLICK_OFF before the next.
##
## Everything takes an explicit time `t` (seconds) so tests can drive it;
## _process polls the XR controllers with the real clock. Keys arrive from
## `handle_key`, which the app calls from _unhandled_input.
##
## Rebinding: `begin_capture()` makes the next press (button, flick or key)
## come out of `captured` instead of firing anything, with the other input
## held at that moment (if any) as its modifier. Presses in the first
## CAPTURE_GRACE seconds are swallowed.

signal command(id: StringName)
signal command_released(id: StringName)
signal captured(input: String, modifier: String)

const HOLD_SECONDS := 0.5
const DOUBLE_SECONDS := 0.35
const FLICK_ON := 0.7
const FLICK_OFF := 0.3
const DEAD_ZONE := 0.15
## Analog trigger / grip: pressed above ON, released below OFF.
const ANALOG_ON := 0.6
const ANALOG_OFF := 0.35
## After begin_capture, presses this soon are ignored: in VR the trigger
## pull that clicked "+" can reach the router a moment after the click.
const CAPTURE_GRACE := 0.2

## OpenXR action (Godot's default action map) -> our control name.
const XR_BUTTONS := {"ax_button": "ax", "by_button": "by", "menu_button": "menu", "primary_click": "stick_click"}

var bindings: InputBindings
## The input behind the command being emitted ("R.grip", "key:F2", …), for
## handlers that care which hand did it.
var last_input: String = ""
## Controllers polled in _process (either may be null).
var left: XRController3D
var right: XRController3D

var _active: Dictionary = {"play": true}
var _held: Dictionary = {}         # input -> press time
var _state: Dictionary = {}        # input -> {cands, hold_fired, deferred, wait_until, released_cmds}
var _sticks: Dictionary = {}       # "L.stick" -> Vector2
var _flick_armed: Dictionary = {}  # "L.stick" -> bool
var _capturing := false
var _capture_since := 0.0
var _key_codes: Dictionary = {}    # held "key:…" input -> its keycode, to match the release


func _init(p_bindings: InputBindings = null) -> void:
	bindings = p_bindings if p_bindings != null else InputBindings.new()


func set_context(context: String, active: bool) -> void:
	if active:
		_active[context] = true
	else:
		_active.erase(context)


func is_context_active(context: String) -> bool:
	return _active.has(context)


func begin_capture(t: float = _now()) -> void:
	_capturing = true
	_capture_since = t


func cancel_capture() -> void:
	_capturing = false


func is_capturing() -> bool:
	return _capturing


## The context that owns `physical_input` right now, or "".
func owner_of(physical_input: String) -> String:
	for ctx in InputBindings.CONTEXTS:
		if _active.has(ctx) and bindings.context_uses(ctx, physical_input):
			return ctx
	return ""


## An axis command's stick, if its context owns that stick now. Dead zone
## applied; ZERO otherwise.
func axis(id: String) -> Vector2:
	for b in bindings.bindings_for(id):
		var stick := String(b.get("input", ""))
		var ctx := InputBindings.binding_context(id, b)
		if owner_of(InputBindings.physical(stick)) != ctx:
			continue
		if b.has("modifier") and not _held.has(String(b.modifier)):
			continue
		var v: Vector2 = _sticks.get(stick, Vector2.ZERO)
		if v.length() >= DEAD_ZONE:
			return v
	return Vector2.ZERO


# ---------- raw input ----------

func feed_button(input: String, pressed: bool, t: float) -> void:
	if pressed == _held.has(input):
		return
	if pressed:
		_held[input] = t
		if _capturing and t < _capture_since + CAPTURE_GRACE:
			_state[input] = {"cands": [], "captured": true}  # swallowed
			return
		if _capturing:
			_capturing = false
			var modifier := ""
			for other in _held:
				if other != input and not other.begins_with("key:"):
					modifier = other
			captured.emit(input, modifier)
			_state[input] = {"cands": [], "captured": true}
			return
		_on_press(input, t)
	else:
		_held.erase(input)
		_on_release(input, t)


## A stick's position; fires flicks.
func feed_stick(stick: String, value: Vector2, t: float) -> void:
	_sticks[stick] = value
	var armed: bool = _flick_armed.get(stick, true)
	if armed and value.length() > FLICK_ON:
		_flick_armed[stick] = false
		var dir: String
		if absf(value.x) >= absf(value.y):
			dir = "right" if value.x > 0.0 else "left"
		else:
			dir = "up" if value.y > 0.0 else "down"
		var flick := "%s_%s" % [stick, dir]
		feed_button(flick, true, t)
		feed_button(flick, false, t)
	elif not armed and value.length() < FLICK_OFF:
		_flick_armed[stick] = true


## A key event from _unhandled_input. Returns whether it did something (so
## the caller can mark it handled).
func handle_key(event: InputEventKey, t: float = _now()) -> bool:
	if event.echo:
		return false
	if not event.pressed:
		# The release's modifiers may differ from the press's (Ctrl let go
		# first): match the key itself.
		for held in _key_codes.keys():
			if _key_codes[held] == event.keycode:
				_key_codes.erase(held)
				feed_button(held, false, t)
		return false
	var input := "key:" + OS.get_keycode_string(event.get_keycode_with_modifiers())
	var was_capturing := _capturing
	var owner := owner_of(input)
	_key_codes[input] = event.keycode
	feed_button(input, true, t)
	return was_capturing or owner != ""


## Timers: holds and double-press windows. Called every frame.
func update(t: float) -> void:
	for input in _state.keys():
		var st: Dictionary = _state[input]
		if st.get("captured", false):
			continue
		if _held.has(input) and not st.hold_fired and t - float(_held[input]) >= HOLD_SECONDS:
			var holds: Array = st.cands.filter(func(c): return _gesture(c) == "hold")
			if not holds.is_empty():
				st.hold_fired = true
				_fire(holds)
		if st.get("wait_until", -1.0) >= 0.0 and t >= st.wait_until:
			st.wait_until = -1.0
			_fire(st.cands.filter(func(c): return _gesture(c) == "press"))


func _on_press(input: String, t: float) -> void:
	var prev: Dictionary = _state.get(input, {})
	# Second press inside the window: the double.
	if prev.get("wait_until", -1.0) >= t:
		prev.wait_until = -1.0
		prev.hold_fired = true  # nothing else for this press
		_fire(prev.cands.filter(func(c): return _gesture(c) == "double"))
		return
	var cands := _candidates(input)
	var st := {"cands": cands, "hold_fired": false, "wait_until": -1.0, "released_cmds": []}
	_state[input] = st
	var has_hold := cands.any(func(c): return _gesture(c) == "hold")
	var has_double := cands.any(func(c): return _gesture(c) == "double")
	for c in cands:
		if InputBindings.command_kind(c[0]) == "held":
			last_input = input
			command.emit(StringName(c[0]))
			st.released_cmds.append(c[0])
	if not has_hold and not has_double:
		_fire(cands.filter(func(c): return _gesture(c) == "press" and InputBindings.command_kind(c[0]) == "button"))


func _on_release(input: String, t: float) -> void:
	var st: Dictionary = _state.get(input, {})
	if st.is_empty() or st.get("captured", false):
		_state.erase(input)
		return
	for id in st.released_cmds:
		last_input = input
		command_released.emit(StringName(id))
	st.released_cmds = []
	if st.hold_fired:
		return
	var presses: Array = st.cands.filter(func(c): return _gesture(c) == "press" and InputBindings.command_kind(c[0]) == "button")
	var has_hold: bool = st.cands.any(func(c): return _gesture(c) == "hold")
	var has_double: bool = st.cands.any(func(c): return _gesture(c) == "double")
	if has_double:
		st.wait_until = t + DOUBLE_SECONDS
	elif has_hold:
		_fire(presses)  # let go before the hold: it was a press


## The bindings `input` can fire now: in the context that owns it, those
## whose modifier is held (preferred) or that have none.
func _candidates(input: String) -> Array:
	var ctx := owner_of(InputBindings.physical(input))
	if ctx == "":
		return []
	var on_input: Array = bindings.bindings_on(ctx, InputBindings.physical(input)).filter(
			func(c): return String(c[1].get("input", "")) == input)
	var chorded: Array = on_input.filter(func(c): return c[1].has("modifier") and _held.has(String(c[1].modifier)))
	if not chorded.is_empty():
		return chorded
	return on_input.filter(func(c): return not c[1].has("modifier"))


func _fire(cands: Array) -> void:
	for c in cands:
		last_input = String(c[1].get("input", ""))
		command.emit(StringName(c[0]))


static func _gesture(c: Array) -> String:
	return String(c[1].get("gesture", "press"))


# ---------- XR polling ----------

func _process(_delta: float) -> void:
	var t := _now()
	for pair in [["L", left], ["R", right]]:
		var hand: String = pair[0]
		var ctl: XRController3D = pair[1]
		if ctl == null or not ctl.get_is_active():
			continue
		for action in XR_BUTTONS:
			feed_button("%s.%s" % [hand, XR_BUTTONS[action]], ctl.is_button_pressed(action), t)
		for analog in ["trigger", "grip"]:
			var v := maxf(ctl.get_float(analog), 1.0 if ctl.is_button_pressed(analog + "_click") else 0.0)
			var name := "%s.%s" % [hand, analog]
			if v > ANALOG_ON:
				feed_button(name, true, t)
			elif v < ANALOG_OFF:
				feed_button(name, false, t)
		feed_stick(hand + ".stick", ctl.get_vector2("primary"), t)
	update(t)


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
