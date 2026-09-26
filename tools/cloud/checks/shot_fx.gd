extends SceneTree

## Rendered: the main scene with a test card, then each built-in camera
## effect, then the kaleidoscope with the menu open. -> fx_*.png

func _initialize() -> void:
	var out := OS.get_environment("OUT_DIR")
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	for i in 30:
		await process_frame
	print("rendering: ", RenderingServer.get_current_rendering_method())
	main._player_settings.skybox = "dusk"
	# A colourful card on the screen in place of the (missing) video.
	var img := Image.create(960, 540, false, Image.FORMAT_RGB8)
	for y in 540:
		for x in 960:
			var c := Color.from_hsv(float(x) / 960.0, 0.85, 0.35 + 0.65 * float(y) / 540.0)
			if ((x / 60) + (y / 60)) % 2 == 0 and y > 380:
				c = Color(0.95, 0.95, 0.95) if (x / 60) % 2 == 0 else Color(0.08, 0.08, 0.1)
			var d := Vector2(x - 480, y - 200).length()
			if absf(d - 120.0) < 10.0 or absf(d - 60.0) < 6.0:
				c = Color(1, 1, 1)
			img.set_pixel(x, y, c)
	var card := ImageTexture.create_from_image(img)
	var screen = main.runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	screen.set_source_texture(card)
	main.stage.layers.set_count(1)
	var layer: LayerSettings = main.stage.layers.layers[0]
	layer.shader = "res://player/visualizer/shaders/spectrum_bars.gdshader"
	layer.size = 2.4
	layer.distance = 2.0
	for i in 40:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("fx_none.png"))
	var fx: CameraFxSettings = main.stage.layers.camera_fx
	for key in CameraFxShaders.BUILTINS:
		fx.shader = key
		fx.strength = 1.0
		for i in 25:
			await process_frame
		var name := String(key).trim_prefix("builtin:")
		root.get_texture().get_image().save_png(out.path_join("fx_%s.png" % name))
		print(name, " error='", main.stage.camera_fx.error_text().left(300), "'")
	# The menu stays readable under an effect.
	fx.shader = "builtin:kaleidoscope"
	main.floating_panel.toggle()
	for i in 40:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("fx_menu_open.png"))
	print("SHOTS DONE")
	quit()
