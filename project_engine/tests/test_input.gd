extends RefCounted

## InputBindings + InputRouter: the default bindings behave like the player
## always has, gestures and contexts resolve as documented, and user
## changes save and load. Uses a throwaway file, never the user's own.

const PATH := "user://test_input_bindings.json"


static func _bindings() -> InputBindings:
	DirAccess.remove_absolute(PATH)
	return InputBindings.new(PATH)


## A router with the given contexts on, and a log of what it fired.
static func _router(b: InputBindings, contexts: Array = ["play", "locked"]) -> Array:
	var r := InputRouter.new(b)
	for ctx in contexts:
		r.set_context(ctx, true)
	var log: Array = []
	r.command.connect(func(id): log.append(String(id)))
	r.command_released.connect(func(id): log.append("-" + String(id)))
	return [r, log]


static func _tap(r: InputRouter, input: String, t: float) -> void:
	r.feed_button(input, true, t)
	r.feed_button(input, false, t + 0.05)


static func _key(r: InputRouter, keycode: Key, pressed: bool = true) -> bool:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = pressed
	return r.handle_key(ev, 0.0)


static func test_defaults_match_the_player(tc: TestCase) -> void:
	var pair := _router(_bindings())
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	_tap(r, "R.ax", 0.0)
	_tap(r, "R.by", 1.0)
	_tap(r, "L.menu", 2.0)
	_tap(r, "R.stick_click", 3.0)
	_tap(r, "R.trigger", 4.0)
	tc.assert_eq(log, ["play_pause", "next_video", "toggle_menu", "screen_click", "screen_trigger"])
	r.free()


static func test_locked_sticks_are_a_media_remote(tc: TestCase) -> void:
	var pair := _router(_bindings())
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	r.feed_stick("L.stick", Vector2(-0.9, 0.1), 0.0)
	r.feed_stick("L.stick", Vector2(-0.95, 0.0), 0.1)  # still out: no repeat
	r.feed_stick("L.stick", Vector2.ZERO, 0.2)
	r.feed_stick("L.stick", Vector2(0.2, 0.9), 0.3)    # dominant axis: up
	r.feed_stick("R.stick", Vector2(0.9, 0.0), 0.4)
	tc.assert_eq(log, ["seek_back", "volume_up", "seek_forward"])
	tc.assert_eq(r.axis("move"), Vector2.ZERO, "no walking while locked")
	r.free()


static func test_free_movement_owns_the_sticks(tc: TestCase) -> void:
	var pair := _router(_bindings(), ["play", "free"])
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	r.feed_stick("L.stick", Vector2(0.0, 0.9), 0.0)
	r.feed_stick("R.stick", Vector2(0.9, 0.0), 0.0)
	tc.assert_eq(log, [], "no seek or volume")
	tc.assert_eq(r.axis("move"), Vector2(0.0, 0.9))
	tc.assert_eq(r.axis("turn"), Vector2(0.9, 0.0))
	r.feed_stick("L.stick", Vector2(0.05, 0.0), 0.1)
	tc.assert_eq(r.axis("move"), Vector2.ZERO, "dead zone")
	r.free()


static func test_menus_take_the_right_stick_and_trigger(tc: TestCase) -> void:
	var pair := _router(_bindings(), ["play", "locked", "menus"])
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	r.feed_stick("R.stick", Vector2(0.0, 0.9), 0.0)
	_tap(r, "R.trigger", 0.1)
	tc.assert_eq(log, [], "right stick scrolls, trigger clicks the menu")
	tc.assert_eq(r.axis("scroll_menu"), Vector2(0.0, 0.9))
	r.feed_stick("L.stick", Vector2(0.9, 0.0), 0.2)
	tc.assert_eq(log, ["seek_forward"], "left stick still seeks")
	r.set_context("menus", false)
	_tap(r, "R.trigger", 1.0)
	tc.assert_eq(log, ["seek_forward", "screen_trigger"])
	r.free()


static func test_held_command_presses_and_releases(tc: TestCase) -> void:
	var pair := _router(_bindings())
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	r.feed_button("R.grip", true, 0.0)
	r.update(2.0)
	r.feed_button("R.grip", false, 2.1)
	tc.assert_eq(log, ["drag_menu", "-drag_menu"])
	r.free()


static func test_hold_and_press_on_one_button(tc: TestCase) -> void:
	var b := _bindings()
	b.assign("reset_view", {"input": "L.menu", "gesture": "hold"})
	var pair := _router(b)
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	# Short: the press, on release.
	r.feed_button("L.menu", true, 0.0)
	r.update(0.2)
	tc.assert_eq(log, [], "waits to see if it's a hold")
	r.feed_button("L.menu", false, 0.3)
	tc.assert_eq(log, ["toggle_menu"])
	# Long: only the hold.
	r.feed_button("L.menu", true, 1.0)
	r.update(1.6)
	r.feed_button("L.menu", false, 2.0)
	tc.assert_eq(log, ["toggle_menu", "reset_view"])
	r.free()


static func test_double_and_press_on_one_button(tc: TestCase) -> void:
	var b := _bindings()
	b.assign("previous_video", {"input": "R.by", "gesture": "double"})
	var pair := _router(b)
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	_tap(r, "R.by", 0.0)
	r.update(0.2)
	tc.assert_eq(log, [], "waits for a second press")
	r.update(0.5)
	tc.assert_eq(log, ["next_video"], "single press after the window")
	_tap(r, "R.by", 1.0)
	_tap(r, "R.by", 1.2)
	r.update(2.0)
	tc.assert_eq(log, ["next_video", "previous_video"], "double: only the double")
	r.free()


static func test_chord_beats_the_plain_binding(tc: TestCase) -> void:
	var b := _bindings()
	b.assign("reset_view", {"input": "R.ax", "modifier": "L.trigger"})
	var pair := _router(b)
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	_tap(r, "R.ax", 0.0)
	r.feed_button("L.trigger", true, 1.0)
	_tap(r, "R.ax", 1.1)
	r.feed_button("L.trigger", false, 1.3)
	tc.assert_eq(log, ["play_pause", "reset_view"])
	r.free()


static func test_keys(tc: TestCase) -> void:
	var pair := _router(_bindings())
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	tc.assert_true(_key(r, KEY_SPACE), "Space handled while locked")
	_key(r, KEY_SPACE, false)
	_key(r, KEY_F1)
	_key(r, KEY_F1, false)
	_key(r, KEY_LEFT)
	_key(r, KEY_LEFT, false)
	tc.assert_eq(log, ["play_pause", "toggle_vr", "seek_back"])
	r.set_context("locked", false)
	r.set_context("free", true)
	tc.assert_false(_key(r, KEY_SPACE), "Space is the fly-up key with free movement")
	tc.assert_eq(log.size(), 3)
	r.free()


static func test_capture(tc: TestCase) -> void:
	var pair := _router(_bindings())
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	var got: Array = []
	r.captured.connect(func(input, modifier): got.append([input, modifier]))
	r.begin_capture(0.0)
	_tap(r, "R.trigger", 0.05)  # the click on "+" itself: swallowed
	_tap(r, "R.by", 0.5)
	r.feed_button("L.trigger", true, 1.0)
	r.begin_capture(0.9)
	_tap(r, "R.ax", 1.2)
	r.feed_button("L.trigger", false, 1.3)
	r.begin_capture(1.5)
	r.feed_stick("L.stick", Vector2(-0.9, 0.0), 2.0)
	tc.assert_eq(got, [["R.by", ""], ["R.ax", "L.trigger"], ["L.stick_left", ""]])
	tc.assert_eq(log, [], "captured presses fire nothing")
	r.free()


static func test_assign_takes_from_others_and_conflicts(tc: TestCase) -> void:
	var b := _bindings()
	var taken := b.assign("reset_view", {"input": "R.ax"})
	tc.assert_eq(taken, ["play_pause"])
	tc.assert_false(b.bindings_for("play_pause").any(func(x): return x.input == "R.ax"))
	tc.assert_eq(b.conflicts(), [])
	# Same input, different context: no conflict.
	b.assign("scroll_menu", {"input": "L.stick"})
	tc.assert_true(b.bindings_for("move").any(func(x): return x.input == "L.stick"), "walk keeps L.stick (other context)")
	b.set_bindings("toggle_vr", [{"input": "R.by"}])
	tc.assert_eq(b.conflicts().size(), 1, "next_video and toggle_vr share Right B")


static func test_save_load_and_reset(tc: TestCase) -> void:
	var b := _bindings()
	b.assign("toggle_vr", {"input": "L.by", "gesture": "hold"})
	# A newer version's command survives a save from this one.
	var raw = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	raw.bindings["future_thing"] = [{"input": "L.ax"}]
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(raw))
	f.close()
	var again := InputBindings.new(PATH)
	tc.assert_eq(again.bindings_for("toggle_vr").back(), {"input": "L.by", "gesture": "hold"})
	tc.assert_true(again.is_default("play_pause"))
	again.reset("volume_up")  # saves
	raw = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	tc.assert_true(raw.bindings.has("future_thing"), "unknown commands kept")
	again.reset_all()
	tc.assert_true(again.is_default("toggle_vr"))
	DirAccess.remove_absolute(PATH)


static func test_left_handed(tc: TestCase) -> void:
	var b := _bindings()
	b.apply_left_handed()
	tc.assert_eq(b.bindings_for("play_pause")[0], {"input": "L.ax"})
	tc.assert_eq(b.bindings_for("move"), [{"input": "R.stick"}])
	tc.assert_eq(b.bindings_for("reset_view"), [{"input": "key:R"}, {"input": "key:Home"}], "keys unchanged")
	var pair := _router(b)
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	_tap(r, "L.ax", 0.0)
	tc.assert_eq(log, ["play_pause"])
	r.free()
	DirAccess.remove_absolute(PATH)


static func test_describe(tc: TestCase) -> void:
	tc.assert_eq(InputBindings.describe({"input": "R.ax"}), "A")
	tc.assert_eq(InputBindings.describe({"input": "L.by", "gesture": "hold"}), "Hold Y")
	tc.assert_eq(InputBindings.describe({"input": "L.stick_left"}), "Left stick ←")
	tc.assert_eq(InputBindings.describe({"input": "R.stick_up", "modifier": "L.trigger"}), "Left trigger + Right stick ↑")
	tc.assert_eq(InputBindings.describe({"input": "key:Ctrl+Z", "gesture": "double"}), "Double Ctrl+Z key")
	tc.assert_eq(InputBindings.describe({"input": "L.menu"}), "Left ≡")


static func test_studio_commands(tc: TestCase) -> void:
	var b := _bindings()
	tc.assert_eq(b.conflicts(), [], "no clashes in the defaults, Studio's included")
	var pair := _router(b, ["studio"])
	var r: InputRouter = pair[0]
	var log: Array = pair[1]
	r.set_context("play", false)  # as Studio does: the player's are on by default
	# Play mode: only Studio's own commands, never the player's.
	_tap(r, "L.menu", 1.0)
	_tap(r, "R.ax", 2.0)
	_tap(r, "R.by", 3.0)
	_key(r, KEY_TAB)
	_key(r, KEY_TAB, false)
	tc.assert_eq(log, ["studio_toggle_mode", "studio_play_pause", "studio_toggle_mode"], "B does nothing outside Edit")
	# Edit mode on top: B undoes (press) and redoes (hold); the stick
	# scrubs only with the left trigger held.
	log.clear()
	r.set_context("studio_edit", true)
	_tap(r, "R.by", 4.0)
	r.update(4.5)
	r.feed_button("R.by", true, 5.0)
	r.update(5.6)
	r.feed_button("R.by", false, 5.7)
	tc.assert_eq(log, ["studio_undo", "studio_redo"])
	r.feed_stick("L.stick", Vector2(0.8, 0), 6.0)
	tc.assert_eq(r.axis("studio_scrub"), Vector2.ZERO, "no trigger: no scrub")
	r.feed_button("L.trigger", true, 6.1)
	tc.assert_eq(r.axis("studio_scrub"), Vector2(0.8, 0))
	var ctrl_z := InputEventKey.new()
	ctrl_z.keycode = KEY_Z
	ctrl_z.ctrl_pressed = true
	ctrl_z.pressed = true
	log.clear()
	tc.assert_true(r.handle_key(ctrl_z, 7.0))
	tc.assert_eq(log, ["studio_undo"])
	tc.assert_eq(InputBindings.command_app("studio_undo"), "studio")
	tc.assert_eq(InputBindings.command_app("play_pause"), "player")
