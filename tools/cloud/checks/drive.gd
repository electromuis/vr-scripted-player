extends SceneTree

## Headless: boots the main scene, fires every input command and some keys,
## and switches free movement (checks contexts). Run with HEADLESS=1.

func _initialize() -> void:
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var router: InputRouter = main._router
	print("router ok: ", router != null, " contexts locked=", router.is_context_active("locked"), " free=", router.is_context_active("free"))
	for id in InputBindings.COMMANDS:
		if InputBindings.command_kind(id) != "axis":
			main._on_command(StringName(id))
			if InputBindings.command_kind(id) == "held":
				main._on_command_released(StringName(id))
		await process_frame
	var fired: Array = []
	router.command.connect(func(id): fired.append(String(id)))
	for k in [KEY_SPACE, KEY_K, KEY_LEFT, KEY_F2, KEY_F2, KEY_H, KEY_H]:
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.pressed = true
		root.push_input(ev)
		var up := ev.duplicate()
		up.pressed = false
		root.push_input(up)
		await process_frame
	print("keys fired: ", fired, " play_bar=", main._player_settings.show_play_bar)
	# Free movement switches the contexts.
	main._player_settings.locomotion = PlayerSettings.Locomotion.FREE
	await process_frame
	fired.clear()
	for k in [KEY_SPACE, KEY_K]:
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.pressed = true
		root.push_input(ev)
		var up := ev.duplicate()
		up.pressed = false
		root.push_input(up)
		await process_frame
	print("free keys fired: ", fired)
	print("after free: locked=", router.is_context_active("locked"), " free=", router.is_context_active("free"))
	print("DRIVE DONE")
	quit()
