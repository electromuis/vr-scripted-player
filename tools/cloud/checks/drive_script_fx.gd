extends SceneTree

## Headless: a script's camera block overrides the preset's effect, its
## strength track animates, and the Config limits cap it.

func _initialize() -> void:
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	for i in 20:
		await process_frame
	main.stage.layers.camera_fx.shader = "builtin:hue_cycle"
	await process_frame
	print("preset only: ", main.stage.camera_fx._key, " strength ", main.stage.camera_fx.applied_strength())
	var r := ScriptFormat.load_from_string(JSON.stringify({"format_version": 2,
		"media": {"video": "none.mp4", "duration": 30.0},
		"shaders": {"k": "builtin:kaleidoscope"},
		"camera": {"effects": [{"shader": "k", "params": {"segments": 3}}]},
		"tracks": [{"type": "shader_param", "target": "$camera.effect0", "param": "strength",
			"keyframes": [{"t": 0, "value": 0.0}, {"t": 10, "value": 1.0}]}]}))
	main.runner.load_timeline(r.data)
	main.runner.seek(5.0)
	for i in 5:
		await process_frame
	print("script: ", main.stage.camera_fx._key, " strength ", main.stage.camera_fx.applied_strength(), " params ", main.stage.camera_fx._params)
	main._player_settings.camera_fx_max = 0.25
	await process_frame
	print("capped: ", main.stage.camera_fx.applied_strength())
	main._player_settings.camera_fx = false
	await process_frame
	print("off: ", main.stage.camera_fx.applied_strength())
	main._player_settings.camera_fx = true
	main._player_settings.camera_fx_max = 1.0
	quit()
