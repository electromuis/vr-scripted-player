extends SceneTree

## Studio M2 end to end, on a copy of moving_screen: picking with a posed
## right controller and the real router inputs (trigger selects, grip
## grabs), a move with auto-key off (the placement) and on (keys), an
## animated object moved as a whole, snapping, two-hand scale, push / pull,
## "key it", undo / redo, seat / go to it / back, then save and play the
## result in the player. Headless (HEADLESS=1) it prints; rendered it also
## saves studio_m2_*.png to OUT_DIR (the selection, the snap grid, the seat
## marker, the wrist palette, the desktop status) and drags with the mouse.

var studio: Node
var tools: StudioEditTools
var out := OS.get_environment("OUT_DIR")
var rendered := DisplayServer.get_name() != "headless"
var clock := 100.0


func frames(n: int) -> void:
	for i in n:
		await process_frame


func v(p) -> String:
	p = Interpolation.to_vec3(p) if typeof(p) == TYPE_ARRAY else p
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


## A controller button through the router, as the headset would send it.
func press(input: String, hold := false) -> void:
	clock += 1.0
	studio.stage.router.feed_button(input, true, clock)
	if not hold:
		studio.stage.router.feed_button(input, false, clock + 0.05)
	await frames(2)


func let_go(input: String) -> void:
	clock += 0.1
	studio.stage.router.feed_button(input, false, clock)
	await frames(2)


## Point the right (or left) controller from `from` at `at`.
func aim(hand: String, from: Vector3, at: Vector3) -> Transform3D:
	var xf := Transform3D(Basis.looking_at(at - from, Vector3.UP), from)
	var ctl: XRController3D = studio.stage.xr_rig.right_controller if hand == "R" else studio.stage.xr_rig.left_controller
	ctl.global_transform = xf
	return xf


func spawn_of(id: String) -> Dictionary:
	return studio.model.tracks()[studio.model.spawn_index(id)].get("transform", {})


func keys_of(id: String, ch: String) -> Array:
	var ti: int = studio.model.find_track("transform", id, ch)
	return studio.model.tracks()[ti].get("keyframes", []) if ti >= 0 else []


var card: ImageTexture


func shot(name: String, cam_pos: Vector3, look_at: Vector3) -> void:
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
	var cam: Camera3D = studio.stage.desktop_camera
	cam.global_position = cam_pos
	cam.look_at(look_at)
	await frames(20)
	root.get_texture().get_image().save_png(out.path_join("studio_m2_%s.png" % name))


func copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


func _initialize() -> void:
	var repo := OS.get_environment("REPO")
	var piece_dir := OS.get_environment("WORK").path_join("studio_m2_piece")
	copy_dir(repo.path_join("scripts/moving_screen"), piece_dir)
	var piece := piece_dir.path_join("video.json")

	studio = load("res://studio/studio.tscn").instantiate()
	root.add_child(studio)
	await frames(10)
	tools = studio.tools
	var reg: ObjectRegistry = studio.runner.registry()
	if not reg.object_spawned.is_connected(studio.stage._on_object_spawned):
		reg.object_spawned.connect(studio.stage._on_object_spawned)
	print("open: ", studio.open_piece(piece))
	studio.runner.set_video_duration(30.0)
	studio.stage.seek_to(5.0)
	await frames(5)
	print("objects at 5 s: ", reg.all_ids())
	var eye := Vector3(0, 2, 8)
	var cube: Node3D = reg.get_node_by_id("cube_1")
	var screen: Node3D = reg.get_node_by_id("main_screen")
	print("cube at ", v(cube.global_position), ", screen at ", v(screen.global_position))

	# Picking with the real inputs: aim the right controller, pull the trigger.
	aim("R", eye, cube.global_position)
	await press("R.trigger")
	print("trigger at the cube: selected '", tools.selected, "'")
	aim("R", eye, screen.global_position)
	await press("R.trigger")
	print("trigger at the screen: selected '", tools.selected, "'")
	aim("R", eye, eye + Vector3(0, 5, -1))
	await press("R.trigger")
	print("trigger at the sky: selected '", tools.selected, "'")
	await shot("0_nothing", Vector3(4, 3, 7), Vector3(-0.5, 1.5, 0))

	# Auto-key off: grab the cube with the grip, carry it 1 m right.
	var hand := aim("R", eye, cube.global_position)
	await press("R.grip", true)
	print("grip: grabbing '", tools.grabbed_id(), "', held by the runner ", studio.runner.held.has("cube_1"))
	aim("R", eye + Vector3(1, 0, 0), cube.global_position + Vector3(1, 0, 0))
	tools.move_hand("R", studio.stage.xr_rig.right_controller.global_transform)
	await frames(2)
	print("carried: cube at ", v(cube.global_position))
	await shot("1_grabbing", Vector3(3, 3, 6), Vector3(-1, 1, 0))
	await let_go("R.grip")
	cube = reg.get_node_by_id("cube_1")
	print("let go: '", studio.message, "' spawn ", v(spawn_of("cube_1").position), " cube at ", v(cube.global_position), " dirty ", studio.model.is_dirty())
	await key(KEY_Z, true)
	cube = reg.get_node_by_id("cube_1")
	print("ctrl+z: spawn ", v(spawn_of("cube_1").position), " cube at ", v(cube.global_position))
	await key(KEY_Z, true, true)
	cube = reg.get_node_by_id("cube_1")
	print("ctrl+shift+z: spawn ", v(spawn_of("cube_1").position))

	# Snapping: a move of 0.137 m lands on the 10 cm grid.
	await key(KEY_G, false, true)
	print("shift+g: snap ", tools.snap, " '", studio.message, "'")
	tools.grab("cube_1", "T", Transform3D(Basis(), cube.global_position + Vector3(0, 0, 1)))
	tools.move_hand("T", Transform3D(Basis(), cube.global_position + Vector3(0.137, 0.052, 1)))
	await frames(2)
	await shot("2_snap_grid", Vector3(0.5, 2.6, 2.2), cube.global_position)
	tools.release()
	print("snapped move: spawn ", v(spawn_of("cube_1").position))
	await key(KEY_G, false, true)

	# Two hands: twice as far apart = twice the size.
	cube = reg.get_node_by_id("cube_1")
	var c := cube.global_position
	tools.grab("cube_1", "R", Transform3D(Basis(), c + Vector3(-0.3, 0, 0.5)))
	tools.add_hand("L", Transform3D(Basis(), c + Vector3(0.3, 0, 0.5)))
	tools.move_hand("R", Transform3D(Basis(), c + Vector3(-0.6, 0, 0.5)))
	tools.move_hand("L", Transform3D(Basis(), c + Vector3(0.6, 0, 0.5)))
	tools.release_hand("L")
	tools.release_hand("R")
	print("two hands apart x2: '", studio.message, "' spawn scale ", v(spawn_of("cube_1").scale))

	# Push: grab from 3 m, push 1 m further.
	cube = reg.get_node_by_id("cube_1")
	var from := cube.global_position + Vector3(0, 0, 3)
	tools.grab("cube_1", "R", Transform3D(Basis.looking_at(cube.global_position - from, Vector3.UP), from))
	tools.push(1.0)
	tools.release()
	cube = reg.get_node_by_id("cube_1")
	print("pushed 1 m: now ", snappedf((cube.global_position - from).length(), 0.01), " m from the hand")

	# Auto-key on at 10 s: lift the (animated) screen 0.5 m -> a key.
	studio.stage.seek_to(10.0)
	await frames(2)
	screen = reg.get_node_by_id("main_screen")
	var pos_keys_before := keys_of("main_screen", "position").size()
	var rot_keys_before := keys_of("main_screen", "rotation_deg").size()
	await key(KEY_I, false, true)
	print("shift+i: auto-key ", tools.auto_key)
	var sp := screen.global_position
	tools.grab("main_screen", "R", Transform3D(Basis(), sp + Vector3(0, 0, 2)))
	tools.move_hand("R", Transform3D(Basis(), sp + Vector3(0, 0.5, 2)))
	tools.release()
	var k10: Array = keys_of("main_screen", "position").filter(func(k): return absf(float(k.t) - 10.0) < 0.001)
	print("auto-key lift: '", studio.message, "' position keys ", pos_keys_before, " -> ", keys_of("main_screen", "position").size(),
			", key at 10 s ", v(k10[0].value) if not k10.is_empty() else "none", ", rotation keys ", rot_keys_before, " -> ", keys_of("main_screen", "rotation_deg").size())
	await frames(2)
	print("screen at 10 s now ", v(reg.get_node_by_id("main_screen").position), " (was ", v(sp), ")")
	await shot("3_selected_screen", Vector3(3.5, 3.2, 5.5), sp)
	await key(KEY_I, false, true)

	# Auto-key off on the animated screen: its whole path moves 1 m right.
	var first_before: Array = keys_of("main_screen", "position")[0].value
	var last_before: Array = keys_of("main_screen", "position").back().value
	screen = reg.get_node_by_id("main_screen")
	sp = screen.global_position
	tools.grab("main_screen", "R", Transform3D(Basis(), sp + Vector3(0, 0, 2)))
	tools.move_hand("R", Transform3D(Basis(), sp + Vector3(1, 0, 2)))
	tools.release()
	print("path moved: first key ", v(first_before), " -> ", v(keys_of("main_screen", "position")[0].value),
			", last ", v(last_before), " -> ", v(keys_of("main_screen", "position").back().value),
			", spawn unchanged ", v(spawn_of("main_screen").position))

	# "Key it" with A: all three channels of the selected cube at 10 s.
	tools.select("cube_1")
	await press("R.ax")
	print("A (key it): '", studio.message, "' cube keys ", ["position", "rotation_deg", "scale"].map(func(ch): return keys_of("cube_1", ch).size()))

	# Getting around.
	var cam: Camera3D = studio.stage.desktop_camera
	cam.global_position = Vector3(5, 3, 5)
	await key(KEY_F)
	print("F (go to it): camera ", v(cam.global_position), " '", studio.message, "'")
	await key(KEY_0)
	print("0 (seat): camera ", v(cam.global_position), " '", studio.message, "'")
	await key(KEY_F, false, true)
	print("shift+f (back): camera ", v(cam.global_position), " '", studio.message, "'")

	if rendered:
		# The desktop status with auto-key and snap shown, then the wrist.
		tools.auto_key = true
		tools.snap = true
		await shot("4_status", Vector3(4, 3, 7), Vector3(-0.5, 1.5, 0))
		var wrist: Node3D = studio.stage.xr_rig.wrist_panel
		wrist.visible = true
		await frames(25)
		wrist.get_node("Viewport").get_texture().get_image().save_png(out.path_join("studio_m2_5_wrist.png"))
		wrist.visible = false
		tools.auto_key = false
		tools.snap = false
		# A mouse drag on the desktop: the cube 1 m left.
		cube = reg.get_node_by_id("cube_1")
		cam.global_position = cube.global_position + Vector3(0, 0.5, -4)
		cam.look_at(cube.global_position)
		await frames(3)
		var at := cam.unproject_position(cube.global_position)
		var world_left := cube.global_position + Vector3(-1, 0, 0)
		var to := cam.unproject_position(world_left)
		var before := cube.global_position
		Input.warp_mouse(at)
		await frames(2)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = at
		studio._unhandled_input(ev)
		Input.warp_mouse(to)
		await frames(2)
		var mv := InputEventMouseMotion.new()
		mv.position = to
		studio._unhandled_input(mv)
		ev = ev.duplicate()
		ev.pressed = false
		studio._unhandled_input(ev)
		await frames(2)
		print("mouse drag: '", studio.message, "' cube ", v(before), " -> ", v(reg.get_node_by_id("cube_1").global_position))

	await key(KEY_S, true)
	print("save: '", studio.message, "' valid ", ScriptFormat.load_from_file(piece).ok)
	var saved_cube := spawn_of("cube_1")
	var saved_key10: Array = keys_of("main_screen", "position").filter(func(k): return absf(float(k.t) - 10.0) < 0.001)
	studio.queue_free()
	await frames(3)

	var main: Node = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	await frames(10)
	var preg: ObjectRegistry = main.runner.registry()
	if not preg.object_spawned.is_connected(main.stage._on_object_spawned):
		preg.object_spawned.connect(main.stage._on_object_spawned)
	main.open_file(piece, false)
	main.runner.set_video_duration(30.0)
	main.runner.seek(10.0)
	await frames(3)
	var pcube: Node3D = preg.get_node_by_id("cube_1")
	print("player at 10 s: cube scale ", v(pcube.scale), " (saved ", v(saved_cube.scale), "), screen ", v(preg.get_node_by_id("main_screen").position),
			" (key ", v(saved_key10[0].value) if not saved_key10.is_empty() else "none", ")")
	print("STUDIO M2 DONE")
	quit()
