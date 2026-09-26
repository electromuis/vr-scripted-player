extends SceneTree

## Headless: rebinds a command through the Controls tab and checks it
## fires, refuses a button for a stick command, saves and resets.

func _initialize() -> void:
	DirAccess.remove_absolute("user://input_bindings.json")
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	for i in 90:
		await process_frame
	var content: Node = main.floating_panel.content()
	var tab: Node = content.controls_tab if content != null else null
	print("tab bound: ", tab != null and tab._router != null)
	var rows := 0
	for c in tab._list.get_children():
		if c is HBoxContainer:
			rows += 1
	# The player's commands only (Studio's share the table but not the tab).
	var player_commands := InputBindings.COMMANDS.keys().filter(func(c): return InputBindings.command_app(c) == "player")
	print("command rows: ", rows, " of ", player_commands.size())
	var router: InputRouter = main.stage.router
	var fired: Array = []
	router.command.connect(func(id): fired.append(String(id)))
	# Rebind play/pause to Y (left B/Y button), as the + button would.
	tab._on_add_pressed("play_pause")
	var t := InputRouter._now() + 0.5
	router.feed_button("L.by", true, t)
	router.feed_button("L.by", false, t + 0.05)
	await process_frame
	print("status: ", tab._status.text)
	print("play_pause now: ", router.bindings.bindings_for("play_pause").map(func(b): return InputBindings.describe(b)))
	router.feed_button("L.by", true, t + 1.0)
	router.feed_button("L.by", false, t + 1.05)
	print("Y fires: ", fired)
	# Axis command needs a stick: a button is refused.
	tab._on_add_pressed("move")
	router.feed_button("R.ax", true, InputRouter._now() + 0.5)
	router.feed_button("R.ax", false, InputRouter._now() + 0.6)
	print("axis refusal: ", tab._status.text)
	print("saved: ", FileAccess.file_exists("user://input_bindings.json"))
	router.bindings.reset_all()
	await process_frame
	print("after reset default: ", router.bindings.is_default("play_pause"))
	print("DONE")
	quit()
