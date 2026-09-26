class_name InputBindings
extends RefCounted

## What every controller button, stick and key does: named commands, the
## contexts they apply in, and the bindings that trigger them. InputRouter
## turns raw input into commands with this; the Controls tab edits it.
##
## A binding is a Dictionary:
##   input     — "L.trigger", "R.ax" (A; X on the left), "R.by" (B / Y),
##               "L.grip", "L.stick_click", "L.menu", a stick flick
##               "L.stick_left" / _right / _up / _down, a whole stick
##               "L.stick" (axis commands), or a key "key:Space",
##               "key:Ctrl+Z" (OS.get_keycode_string of the key with its
##               modifiers)
##   gesture   — "press" (default), "hold" (about half a second) or
##               "double" (two presses in quick succession)
##   modifier  — optional: an input that must be held too ("L.trigger" for
##               a chord like left trigger + left stick)
##   context   — optional: overrides the command's own context
##
## Contexts decide which bindings apply. When several are active, the
## first in CONTEXTS owns an input (a stick counts as one input, flicks and
## all): while the laser is on a menu, the right stick scrolls it instead
## of seeking; with free movement, the left stick walks instead of seeking.
##
## Only the user's changes are saved (`user://input_bindings.json`); every
## other command keeps its default, so new defaults reach existing users.
## Changes for commands this version doesn't know are kept in the file.

signal changed

const PATH := "user://input_bindings.json"
const FORMAT_VERSION := 1
const KIND := "input_bindings"

## Highest priority first. Studio's contexts are only ever active in
## Studio, the player's only in the player: "studio" always, "studio_edit"
## on top of it in Edit mode.
const CONTEXTS := ["menus", "studio_edit", "studio", "free", "locked", "play"]
const CONTEXT_LABELS := {
	"menus": "Pointing at a menu",
	"studio_edit": "Studio: editing",
	"studio": "Studio",
	"free": "Free movement",
	"locked": "Movement locked",
	"play": "Watching",
}
## Inputs a context uses without a command, so nothing below it gets them:
## on a menu the right trigger is the laser's click (XR Tools handles it).
const RESERVED := {"menus": ["R.trigger"]}

const GESTURES := ["press", "hold", "double"]

## id -> label, context, kind ("button"; "held": pressed and released, like
## a drag; "axis": a whole stick), app ("player", the default, or "studio").
const COMMANDS := {
	"play_pause": {"label": "Play / pause", "context": "play"},
	"screen_trigger": {"label": "Play / pause when aiming at the screen", "context": "play"},
	"screen_click": {"label": "Play / pause when aiming at the screen, else reset view", "context": "play"},
	"seek_back": {"label": "Seek back 10 s", "context": "play"},
	"seek_forward": {"label": "Seek forward 10 s", "context": "play"},
	"volume_up": {"label": "Volume up", "context": "play"},
	"volume_down": {"label": "Volume down", "context": "play"},
	"next_video": {"label": "Next video", "context": "play"},
	"previous_video": {"label": "Previous video", "context": "play"},
	"toggle_menu": {"label": "Open / close the menu", "context": "play"},
	"drag_menu": {"label": "Move the menu (hold)", "context": "play", "kind": "held"},
	"reset_view": {"label": "Reset view", "context": "play"},
	"toggle_vr": {"label": "Enter / leave VR", "context": "play"},
	"fullscreen": {"label": "Fullscreen (desktop)", "context": "play"},
	"toggle_play_bar": {"label": "Show / hide the play bar (desktop)", "context": "play"},
	"move": {"label": "Walk", "context": "free", "kind": "axis"},
	"turn": {"label": "Snap turn", "context": "free", "kind": "axis"},
	"scroll_menu": {"label": "Scroll the menu", "context": "menus", "kind": "axis"},
	# Studio
	"studio_toggle_mode": {"label": "Switch Play / Edit", "context": "studio", "app": "studio"},
	"studio_play_pause": {"label": "Play / pause", "context": "studio", "app": "studio"},
	"studio_step_back": {"label": "Step back 1 s", "context": "studio", "app": "studio"},
	"studio_step_forward": {"label": "Step forward 1 s", "context": "studio", "app": "studio"},
	"studio_seek_back": {"label": "Seek back 10 s", "context": "studio", "app": "studio"},
	"studio_seek_forward": {"label": "Seek forward 10 s", "context": "studio", "app": "studio"},
	"studio_go_start": {"label": "Go to the start", "context": "studio", "app": "studio"},
	"studio_save": {"label": "Save", "context": "studio", "app": "studio"},
	"studio_toggle_vr": {"label": "Enter / leave VR", "context": "studio", "app": "studio"},
	"studio_reset_view": {"label": "Reset view (home seat)", "context": "studio", "app": "studio"},
	"studio_undo": {"label": "Undo", "context": "studio_edit", "app": "studio"},
	"studio_redo": {"label": "Redo", "context": "studio_edit", "app": "studio"},
	"studio_scrub": {"label": "Scrub (further = faster)", "context": "studio_edit", "kind": "axis", "app": "studio"},
}

## Today's player, button for button.
const DEFAULTS := {
	"play_pause": [{"input": "R.ax"}, {"input": "key:K"}, {"input": "key:Space", "context": "locked"}],
	"screen_trigger": [{"input": "R.trigger"}],
	"screen_click": [{"input": "R.stick_click"}],
	"seek_back": [{"input": "L.stick_left"}, {"input": "R.stick_left"}, {"input": "key:Left"}],
	"seek_forward": [{"input": "L.stick_right"}, {"input": "R.stick_right"}, {"input": "key:Right"}],
	"volume_up": [{"input": "L.stick_up"}, {"input": "R.stick_up"}, {"input": "key:Up"}],
	"volume_down": [{"input": "L.stick_down"}, {"input": "R.stick_down"}, {"input": "key:Down"}],
	"next_video": [{"input": "R.by"}],
	"previous_video": [],
	"toggle_menu": [{"input": "L.menu"}, {"input": "R.menu"}, {"input": "key:F2"}],
	"drag_menu": [{"input": "R.grip"}],
	"reset_view": [{"input": "key:R"}, {"input": "key:Home"}],
	"toggle_vr": [{"input": "key:F1"}],
	"fullscreen": [{"input": "key:F11"}],
	"toggle_play_bar": [{"input": "key:H"}],
	"move": [{"input": "L.stick"}],
	"turn": [{"input": "R.stick"}],
	"scroll_menu": [{"input": "R.stick"}],
	"studio_toggle_mode": [{"input": "L.menu"}, {"input": "key:Tab"}],
	"studio_play_pause": [{"input": "R.ax"}, {"input": "key:Space"}, {"input": "key:K"}],
	"studio_step_back": [{"input": "key:Left"}],
	"studio_step_forward": [{"input": "key:Right"}],
	"studio_seek_back": [{"input": "R.stick_left"}, {"input": "key:Shift+Left"}],
	"studio_seek_forward": [{"input": "R.stick_right"}, {"input": "key:Shift+Right"}],
	"studio_go_start": [{"input": "key:Home"}],
	"studio_save": [{"input": "key:Ctrl+S"}],
	"studio_toggle_vr": [{"input": "key:F1"}],
	"studio_reset_view": [{"input": "R.stick_click"}, {"input": "key:R"}],
	"studio_undo": [{"input": "R.by"}, {"input": "key:Ctrl+Z"}],
	"studio_redo": [{"input": "R.by", "gesture": "hold"}, {"input": "key:Ctrl+Shift+Z"}, {"input": "key:Ctrl+Y"}],
	"studio_scrub": [{"input": "L.stick", "modifier": "L.trigger"}],
}

const _BUTTON_NAMES := {
	"trigger": "trigger", "grip": "grip", "stick_click": "stick click", "menu": "≡",
	"stick": "stick", "stick_left": "stick ←", "stick_right": "stick →", "stick_up": "stick ↑", "stick_down": "stick ↓",
}
const _FACE_BUTTONS := {"L.ax": "X", "L.by": "Y", "R.ax": "A", "R.by": "B"}

var _path: String
## command id -> Array of bindings, only where they differ from DEFAULTS.
var _overrides: Dictionary = {}
## context -> physical input -> Array of [command id, binding]. Rebuilt on change.
var _index: Dictionary = {}


func _init(path: String = PATH) -> void:
	_path = path
	load_file()


# ---------- reading ----------

func bindings_for(command: String) -> Array:
	var list: Array = _overrides.get(command, DEFAULTS.get(command, []))
	return list.duplicate(true)


func is_default(command: String) -> bool:
	return not _overrides.has(command)


static func command_context(command: String) -> String:
	return String(COMMANDS.get(command, {}).get("context", "play"))


static func command_kind(command: String) -> String:
	return String(COMMANDS.get(command, {}).get("kind", "button"))


## "player" or "studio": the app a command belongs to.
static func command_app(command: String) -> String:
	return String(COMMANDS.get(command, {}).get("app", "player"))


## The context a binding of `command` applies in.
static func binding_context(command: String, binding: Dictionary) -> String:
	return String(binding.get("context", command_context(command)))


## What a stick flick, a stick and its click have in common: the stick.
## Everything else is its own physical input.
static func physical(input: String) -> String:
	if input.begins_with("key:"):
		return input
	var parts := input.split(".")
	if parts.size() == 2 and parts[1].begins_with("stick") and parts[1] != "stick_click":
		return parts[0] + ".stick"
	return input


## Every [command, binding] on `physical_input` in `context`.
func bindings_on(context: String, physical_input: String) -> Array:
	return _index.get(context, {}).get(physical_input, [])


## Whether `context` uses `physical_input` at all (so it owns it).
func context_uses(context: String, physical_input: String) -> bool:
	return not bindings_on(context, physical_input).is_empty() or physical_input in RESERVED.get(context, [])


## Same input, gesture, modifier and context on two commands: the second
## never fires. Returns [[command a, command b, binding], ...].
func conflicts() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for command in COMMANDS:
		for b in bindings_for(command):
			var key := _binding_key(command, b)
			if seen.has(key) and seen[key] != command:
				out.append([seen[key], command, b])
			else:
				seen[key] = command
	return out


func _binding_key(command: String, b: Dictionary) -> String:
	return "%s|%s|%s|%s" % [binding_context(command, b), b.get("input", ""), b.get("gesture", "press"), b.get("modifier", "")]


# ---------- changing ----------

func set_bindings(command: String, list: Array) -> void:
	if not COMMANDS.has(command):
		return
	if JSON.stringify(list) == JSON.stringify(DEFAULTS.get(command, [])):
		_overrides.erase(command)
	else:
		_overrides[command] = list.duplicate(true)
	_changed()


## Adds `binding` to `command`, taking it away from any other command that
## had the same input, gesture and modifier in the same context. Returns
## the commands it was taken from.
func assign(command: String, binding: Dictionary) -> Array:
	var key := _binding_key(command, binding)
	var taken: Array = []
	for other in COMMANDS:
		if other == command:
			continue
		var kept: Array = bindings_for(other).filter(func(b): return _binding_key(other, b) != key)
		if kept.size() != bindings_for(other).size():
			taken.append(other)
			_set_quiet(other, kept)
	var list := bindings_for(command).filter(func(b): return _binding_key(command, b) != key)
	list.append(binding)
	_set_quiet(command, list)
	_changed()
	return taken


func reset(command: String) -> void:
	_overrides.erase(command)
	_changed()


func reset_all() -> void:
	_overrides.clear()
	_changed()


## Every command's defaults with left and right swapped.
func apply_left_handed() -> void:
	_overrides.clear()
	for command in COMMANDS:
		var mirrored: Array = DEFAULTS[command].map(func(b): return mirror(b))
		if JSON.stringify(mirrored) != JSON.stringify(DEFAULTS[command]):
			_overrides[command] = mirrored
	_changed()


static func mirror(binding: Dictionary) -> Dictionary:
	var out := binding.duplicate()
	for k in ["input", "modifier"]:
		if out.has(k):
			out[k] = _mirror_input(String(out[k]))
	return out


static func _mirror_input(input: String) -> String:
	if input.begins_with("L."):
		return "R." + input.substr(2)
	if input.begins_with("R."):
		return "L." + input.substr(2)
	return input


func _set_quiet(command: String, list: Array) -> void:
	if JSON.stringify(list) == JSON.stringify(DEFAULTS.get(command, [])):
		_overrides.erase(command)
	else:
		_overrides[command] = list


func _changed() -> void:
	_rebuild_index()
	save_file()
	changed.emit()


func _rebuild_index() -> void:
	_index.clear()
	for command in COMMANDS:
		for b in bindings_for(command):
			var ctx := binding_context(command, b)
			var phys := physical(String(b.get("input", "")))
			if not _index.has(ctx):
				_index[ctx] = {}
			if not _index[ctx].has(phys):
				_index[ctx][phys] = []
			_index[ctx][phys].append([command, b])


# ---------- labels ----------

static func describe(binding: Dictionary) -> String:
	var text := describe_input(String(binding.get("input", "")))
	match String(binding.get("gesture", "press")):
		"hold": text = "Hold " + text
		"double": text = "Double " + text
	if binding.has("modifier"):
		text = describe_input(String(binding.modifier)) + " + " + text
	return text


static func describe_input(input: String) -> String:
	if input.begins_with("key:"):
		return input.substr(4) + " key"
	if _FACE_BUTTONS.has(input):
		return _FACE_BUTTONS[input]
	var parts := input.split(".")
	if parts.size() != 2:
		return input
	return "%s %s" % ["Left" if parts[0] == "L" else "Right", _BUTTON_NAMES.get(parts[1], parts[1])]


# ---------- file ----------

func load_file() -> void:
	_overrides.clear()
	if FileAccess.file_exists(_path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(_path))
		if typeof(data) == TYPE_DICTIONARY and data.get("kind") == KIND and typeof(data.get("bindings")) == TYPE_DICTIONARY:
			# Kept even for unknown commands (a newer version's), so saving
			# from this version doesn't drop them.
			for command in data.bindings:
				if typeof(data.bindings[command]) == TYPE_ARRAY:
					_overrides[command] = data.bindings[command].filter(func(b): return typeof(b) == TYPE_DICTIONARY and b.has("input"))
	_rebuild_index()


func save_file() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("InputBindings: could not write %s" % _path)
		return
	f.store_string(JSON.stringify({"format_version": FORMAT_VERSION, "kind": KIND, "bindings": _overrides}, "  "))
	f.close()
