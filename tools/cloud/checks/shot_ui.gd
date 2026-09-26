extends SceneTree

## Rendered: the Camera tab's camera effect section, a broken user effect's
## error, and the Config tab. -> ui_*.png

func _panel_shot(content: Node, name: String) -> void:
	for i in 25:
		await process_frame
	content.get_viewport().get_texture().get_image().save_png(OS.get_environment("OUT_DIR").path_join(name))


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("user://shaders")
	var f := FileAccess.open("user://shaders/my_trip.glsl", FileAccess.WRITE)
	f.store_string("// @camera\nuniform float wobble : hint_range(0.0, 1.0, 0.01) = 0.3;\nvec3 camera_fx(vec2 uv) {\n\treturn view_color(uv) * wobbel;\n}\n")
	f.close()
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	for i in 30:
		await process_frame
	var content: Node = main.floating_panel.content()
	main.floating_panel.toggle()
	var fx: CameraFxSettings = main._layers.camera_fx
	fx.shader = "builtin:kaleidoscope"
	var scroll: ScrollContainer = content.camera_tab.get_parent()
	for i in 10:
		await process_frame
	scroll.scroll_vertical = 100000
	await _panel_shot(content, "ui_camera_fx.png")
	fx.shader = ProjectSettings.globalize_path("user://shaders/my_trip.glsl")
	for i in 20:
		await process_frame
	scroll.scroll_vertical = 100000
	await _panel_shot(content, "ui_camera_fx_error.png")
	var tabs: TabContainer = content.config_tab.get_parent().get_parent() if content.config_tab.get_parent() is ScrollContainer else content.config_tab.get_parent().get_parent()
	var cfg_margin: Node = content.config_tab.get_parent()
	while not (cfg_margin.get_parent() is TabContainer):
		cfg_margin = cfg_margin.get_parent()
	cfg_margin.get_parent().current_tab = cfg_margin.get_index()
	await _panel_shot(content, "ui_config.png")
	print("UI SHOTS DONE")
	quit()
