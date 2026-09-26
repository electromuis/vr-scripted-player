extends SceneTree

## Headless: what the Stage does with a script. It loads a script (the look
## switches to the Script preset), plays cuts with and without a fade, moves
## the main screen with a user layer following it, resets the view, then
## opens a plain video (the look comes back). Prints the numbers to compare
## between versions. Run with HEADLESS=1.

var main: Node


## The stage's parts, wherever this version keeps them.
func part(name: String) -> Variant:
	var stage = main.get("stage")
	if stage != null:
		return stage.get(name)
	return main.get("_" + name) if main.get("_" + name) != null else main.get(name)


## Stage (new) or main (old): whoever handles spawns and cuts.
func core() -> Node:
	var stage = main.get("stage")
	return stage if stage != null else main


func v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]


func cam() -> String:
	var c: Camera3D = part("desktop_camera")
	return "%s yaw %.1f" % [v(c.global_position), rad_to_deg(c.global_rotation.y)]


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	main = load("res://player/main.tscn").instantiate()
	root.add_child(main)
	await frames(20)
	var layers: LayerStack = part("layers")
	var screen_settings: ScreenSettings = part("screen_settings")
	var presets: PresetStore = part("preset_store")
	print("boot: camera ", cam(), " preset ", presets.active_index, " layers ", layers.count())
	layers.set_count(1)
	layers.layers[0].shader = "res://player/visualizer/shaders/spectrum_bars.gdshader"
	screen_settings.opacity = 0.8
	await frames(2)
	print("look: layers ", layers.count(), " opacity ", screen_settings.opacity)

	var r := ScriptFormat.load_from_string(JSON.stringify({"format_version": 2,
		"meta": {"title": "Stage check"},
		"media": {"video": "none.mp4", "duration": 30.0},
		"prefabs": {"screen": "res://player/prefabs/screen.tscn"},
		"tracks": [
			{"type": "event", "t": 0.0, "action": "spawn", "id": "main_screen", "prefab": "screen",
				"transform": {"position": [0, 2, 0], "rotation_deg": [0, 0, 0], "scale": [0.15, 0.15, 0.15]},
				"config": {"curvature": 0.4}},
			{"type": "transform", "target": "main_screen", "channel": "position",
				"keyframes": [{"t": 0, "value": [0, 2, 0]}, {"t": 10, "value": [3, 2, -1]}]},
			{"type": "event", "t": 1.0, "action": "vr_cut", "to": {"position": [3, 2, 4], "rotation_deg": [0, 30, 0]}},
			{"type": "event", "t": 3.0, "action": "vr_cut", "to": {"position": [-2, 1.5, 6], "rotation_deg": [0, -20, 0]},
				"transition": {"type": "fade_to_black", "duration": 0.4}},
		]}))
	# The container has no video decoder, so the stage never hooks up its
	# spawn handler (it waits for the video); connect it here.
	var reg: ObjectRegistry = main.runner.registry()
	if not reg.object_spawned.is_connected(Callable(core(), "_on_object_spawned")):
		reg.object_spawned.connect(Callable(core(), "_on_object_spawned"))
	main.runner.load_timeline(r.data)
	await frames(2)
	print("script: preset ", presets.active_index, " layers ", layers.count(), " opacity ", screen_settings.opacity)
	var screen: Node3D = main.runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	print("screen: parent ", screen.get_parent().name, " curvature ", snappedf(float(screen.get("_display_material").get_shader_parameter("curvature")), 0.01))
	# Play across the cuts (seeking doesn't fire events).
	main.runner.seek(0.7)
	main.runner.play()
	await create_timer(0.6).timeout
	print("after cut 1: camera ", cam())
	main.runner.seek(2.9)
	await create_timer(0.15).timeout
	var fade: ColorRect = part("fade_overlay")
	print("fading: overlay alpha > 0 ", fade.color.a > 0.0, " camera ", cam())
	await create_timer(0.8).timeout
	print("after cut 2: camera ", cam(), " overlay alpha ", snappedf(fade.color.a, 0.01))
	main.runner.pause()
	main.runner.seek(5.0)
	await frames(3)
	print("screen at 5 s: ", v(screen.global_position))
	# Seeking lands the viewer at the cut in effect there (no fade), home
	# before the first; walking off within a cut isn't undone by a seek.
	if core().has_method("_restore_cut"):
		main.runner.seek(2.0)
		await frames(2)
		print("seek back to 2 s: camera ", cam())
		main.runner.seek(0.5)
		await frames(2)
		print("seek back to 0.5 s: camera ", cam())
		main.runner.seek(4.0)
		await frames(2)
		print("seek forward to 4 s: camera ", cam(), " overlay alpha ", snappedf(fade.color.a, 0.01))
		(part("desktop_camera") as Camera3D).global_position = Vector3(-2, 1.5, 7)
		main.runner.seek(6.0)
		await frames(2)
		print("seek within cut 2: camera ", cam())

	# A plain video: the look from before the script comes back, and the
	# view returns home (a cut moved it).
	main.runner.load_timeline(DefaultScreen.timeline_for_video("/nowhere/clip_180_sbs.mp4"))
	await frames(3)
	print("plain video: preset ", presets.active_index, " layers ", layers.count(), " opacity ", screen_settings.opacity, " camera ", cam())
	main.runner.seek(0.0)
	await frames(3)
	var main_screen: Node3D = main.runner.registry().get_node_by_id(DefaultScreen.SCREEN_ID)
	print("projection: ", main_screen.get("_projection") if main_screen.get("_projection") != null else "?")
	var layer_node: Node3D = null
	for n in main_screen.get_parent().find_children("Layer1", "", true, false):
		layer_node = n
	print("layer node: ", layer_node != null, " at ", v(layer_node.global_position) if layer_node != null else "-")
	# Moving the desktop camera, then reset view.
	(part("desktop_camera") as Camera3D).global_position = Vector3(5, 5, 5)
	main._on_command(&"reset_view")
	await frames(1)
	print("reset view: camera ", cam())
	layers.set_count(0)
	screen_settings.opacity = 1.0
	print("STAGE DONE")
	quit()
