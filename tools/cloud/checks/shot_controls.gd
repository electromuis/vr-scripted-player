extends SceneTree

## Rendered: the Controls tab (top, and scrolled to the bottom), with a
## sample rebind and a row waiting for a button. -> controls_tab*.png

func _initialize() -> void:
	DirAccess.remove_absolute("user://input_bindings.json")
	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	for i in 60:
		await process_frame
	var content: Node = main.floating_panel.content()
	var margin: Node = content.controls_tab.get_parent().get_parent()
	var tabs: TabContainer = margin.get_parent()
	print("tabs: ", tabs.get_path(), " controls idx ", margin.get_index())
	var router: InputRouter = main._router
	router.bindings.assign("previous_video", {"input": "R.by", "gesture": "double"})
	router.bindings.assign("reset_view", {"input": "L.menu", "gesture": "hold"})
	content.controls_tab._on_add_pressed("toggle_vr")
	for i in 5:
		await process_frame
	main.floating_panel.toggle()
	tabs.current_tab = margin.get_index()
	for i in 30:
		await process_frame
	print("current tab ", tabs.current_tab)
	if OS.get_environment("SCROLL") != "":
		var scroll: ScrollContainer = content.controls_tab.get_parent()
		scroll.scroll_vertical = 100000
		for i in 10:
			await process_frame
	var sub: SubViewport = content.get_viewport()
	var img := sub.get_texture().get_image()
	img.save_png(OS.get_environment("OUT_DIR").path_join("controls_tab_bottom.png" if OS.get_environment("SCROLL") != "" else "controls_tab.png"))
	print("saved ", img.get_size())
	router.bindings.reset_all()
	quit()
