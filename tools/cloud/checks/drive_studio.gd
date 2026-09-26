extends SceneTree

## Studio end to end: opens a copy of forest_tunnel, saves it unchanged
## (must be byte-identical), toggles Play / Edit with keys, edits and
## undoes / redoes with keys, saves the edit, and then plays the saved file
## in the player to see the edit there. Headless (HEADLESS=1) it prints;
## rendered it also saves studio_*.png to OUT_DIR.

var studio: Node
var out := OS.get_environment("OUT_DIR")
var rendered := DisplayServer.get_name() != "headless"


func frames(n: int) -> void:
	for i in n:
		await process_frame


func v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]


func key(code: Key, ctrl := false, shift := false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.ctrl_pressed = ctrl
		ev.shift_pressed = shift
		ev.pressed = pressed
		studio.stage.router.handle_key(ev)
	await frames(2)


var card: ImageTexture


## A test card on every screen (there's no video here), seen
## from the seat with a wide lens so the whole screen rig is in view.
func shot(name: String) -> void:
	if not rendered:
		return
	if card == null:
		var img := Image.create(640, 360, false, Image.FORMAT_RGB8)
		for y in 360:
			for x in 640:
				var c := Color.from_hsv(float(x) / 640.0, 0.8, 0.35 + 0.65 * float(y) / 360.0)
				if (x / 40 + y / 40) % 2 == 0 and y > 250:
					c = Color(0.95, 0.95, 0.95)
				img.set_pixel(x, y, c)
		card = ImageTexture.create_from_image(img)
	var reg: ObjectRegistry = studio.runner.registry()
	for id in reg.all_ids():
		var n = reg.get_node_by_id(id)
		if n is Screen:
			n.set_source_texture(card)
	studio.stage.desktop_camera.set_view(Vector3(0, 2.5, 8), Vector3(8, 0, 0))
	studio.stage.desktop_camera.fov = 100.0
	await frames(30)
	root.get_texture().get_image().save_png(out.path_join("studio_%s.png" % name))


func copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
	for d in DirAccess.get_directories_at(from):
		copy_dir(from.path_join(d), to.path_join(d))


func status() -> String:
	return "mode %s, edit context %s, status shown %s, dirty %s, '%s'" % [
		"EDIT" if studio.mode == 1 else "PLAY", studio.stage.router.is_context_active("studio_edit"),
		studio.status_view.visible, studio.model.is_dirty(), studio.message]


func _initialize() -> void:
	var repo := OS.get_environment("REPO")
	var piece_dir := OS.get_environment("WORK").path_join("studio_piece")
	copy_dir(repo.path_join("scripts/forest_tunnel"), piece_dir)
	var piece := piece_dir.path_join("video.json")
	var original := FileAccess.get_file_as_bytes(piece)

	studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await frames(10)
	# No video decoder here: hook the stage's spawn handler up by hand (it
	# waits for the video) and give the timeline the video's length.
	var reg: ObjectRegistry = studio.runner.registry()
	if not reg.object_spawned.is_connected(studio.stage._on_object_spawned):
		reg.object_spawned.connect(studio.stage._on_object_spawned)
	print("open: ", studio.open_piece(piece))
	studio.runner.set_video_duration(170.0)
	studio.stage.seek_to(20.0)
	await frames(5)
	print("opened: ", status(), " playhead ", studio.runner.playhead)
	print("objects at 20 s: ", reg.all_ids())

	# Saved unchanged: the same bytes.
	await key(KEY_S, true)
	print("save unchanged: ", status(), " byte-identical ", FileAccess.get_file_as_bytes(piece) == original)
	await shot("1_edit_mode")
	if rendered:
		# The wrist status, as the headset shows it in Edit mode.
		var wrist: Node3D = studio.stage.xr_rig.wrist_panel
		wrist.visible = true
		await frames(20)
		wrist.get_node("Viewport").get_texture().get_image().save_png(out.path_join("studio_1b_wrist.png"))
		wrist.visible = false

	# Play mode: no UI, no edit commands.
	await key(KEY_TAB)
	print("tab: ", status())
	await key(KEY_Z, true)
	print("ctrl+z in play mode: ", status())
	await shot("2_play_mode")
	await key(KEY_TAB)
	print("tab: ", status())

	# An edit: key the screen rig 1.5 m higher and 1 m left at 20 s.
	var rig: Node3D = reg.get_node_by_id("screen_master")
	var screen_node: Node3D = reg.get_node_by_id("main_screen")
	var before := rig.position
	var screen_before := screen_node
	studio.model.set_key("transform", "screen_master", "position", 20.0, [before.x - 1.0, before.y + 1.5, before.z])
	await frames(2)
	print("edit: rig ", v(before), " -> ", v(rig.position), " main_screen respawned ", reg.get_node_by_id("main_screen") != screen_before, " ", status())
	await shot("3_after_edit")
	await key(KEY_Z, true)
	print("ctrl+z: rig ", v(rig.position), " ", status())
	await shot("4_after_undo")
	await key(KEY_Z, true, true)
	print("ctrl+shift+z: rig ", v(rig.position), " ", status())
	await key(KEY_Z, true)
	await key(KEY_Z, true)
	print("undo past the start: ", status())
	await key(KEY_Y, true)
	print("ctrl+y: rig ", v(rig.position), " ", status())

	# A structural edit: switch the main screen's glow off in its spawn config.
	var effects: Array = studio.model.tracks()[studio.model.spawn_index("main_screen")].get("config", {}).get("effects", []).duplicate(true)
	print("main_screen effects: ", effects.map(func(e): return e.get("shader")))
	for e in effects:
		if e.get("shader") == "glow":
			e["enabled"] = false
	screen_before = reg.get_node_by_id("main_screen")
	var forest_before := reg.get_node_by_id("forest")
	studio.model.set_config("main_screen", "effects", effects)
	await frames(2)
	var screen_now: Node = reg.get_node_by_id("main_screen")
	print("glow off: main_screen respawned ", screen_now != screen_before, ", forest kept ", reg.get_node_by_id("forest") == forest_before,
		", backdrop inside it ", screen_now != null and screen_now.find_child("*", true, false) != null and reg.get_node_by_id("backdrop") != null,
		", rig still ", v(rig.position), " ", status())
	await shot("5_glow_off")
	await key(KEY_Z, true)
	print("ctrl+z: main_screen respawned again ", reg.get_node_by_id("main_screen") != screen_now, " ", status())

	# Stepping and seeking with keys.
	await key(KEY_RIGHT)
	print("right: playhead ", snappedf(studio.runner.playhead, 0.01))
	await key(KEY_LEFT, false, true)
	print("shift+left: playhead ", snappedf(studio.runner.playhead, 0.01))
	await key(KEY_HOME)
	print("home: playhead ", snappedf(studio.runner.playhead, 0.01))
	studio.stage.seek_to(20.0)

	# Save the edit; the player then plays it.
	await key(KEY_S, true)
	print("save edit: ", status(), " changed on disk ", FileAccess.get_file_as_bytes(piece) != original)
	var check := ScriptFormat.load_from_file(piece)
	print("saved file valid: ", check.ok, " format_version ", check.data.format_version if check.ok else -1)
	studio.queue_free()
	await frames(3)

	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	await frames(10)
	var preg: ObjectRegistry = main.runner.registry()
	if not preg.object_spawned.is_connected(main.stage._on_object_spawned):
		preg.object_spawned.connect(main.stage._on_object_spawned)
	main.open_file(piece, false)
	main.runner.set_video_duration(170.0)
	main.runner.seek(20.0)
	await frames(3)
	print("player at 20 s: rig ", v(preg.get_node_by_id("screen_master").position))
	print("STUDIO DONE")
	quit()
