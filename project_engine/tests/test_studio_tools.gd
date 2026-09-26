extends RefCounted

## Studio's M2 building blocks without a headset: grab maths, snapping,
## picking, batched edits and the runner leaving held objects alone.


static func _near(a: Vector3, b: Vector3, eps: float = 1e-4) -> bool:
	return a.distance_to(b) <= eps


static func test_one_hand_grab_keeps_the_offset(tc: TestCase) -> void:
	var hand := Transform3D(Basis(), Vector3(0, 1, 0))
	var obj := Transform3D(Basis(), Vector3(0, 1, -2))
	var off := GrabMath.grip_offset(hand, obj)
	tc.assert_true(_near(GrabMath.carried(hand, off).origin, obj.origin), "no jump on grab")
	# Move the hand 1 m right and turn it 90° left: the object swings round.
	var hand2 := Transform3D(Basis(Vector3.UP, deg_to_rad(90)), Vector3(1, 1, 0))
	var moved := GrabMath.carried(hand2, off)
	tc.assert_true(_near(moved.origin, Vector3(-1, 1, 0)), "swung to the left: %s" % moved.origin)


static func test_push_and_pull(tc: TestCase) -> void:
	var off := Transform3D(Basis(), Vector3(0, 0, -2))
	tc.assert_eq(GrabMath.pushed(off, 1.0).origin, Vector3(0, 0, -3))
	tc.assert_eq(GrabMath.pushed(off, -5.0).origin, Vector3(0, 0, -GrabMath.MIN_REACH), "never inside the hand")


static func test_two_hands_scale_and_turn(tc: TestCase) -> void:
	var obj := Transform3D(Basis(), Vector3(0, 1, -1))
	# Hands 1 m apart around the object, then 2 m apart: twice the size.
	var bigger := GrabMath.two_handed(Vector3(-0.5, 1, -1), Vector3(0.5, 1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1), obj)
	tc.assert_true(_near(bigger.basis.get_scale(), Vector3(2, 2, 2)), "scale %s" % bigger.basis.get_scale())
	tc.assert_true(_near(bigger.origin, obj.origin), "about the midpoint")
	# Turn the pair 90° about the vertical: the object turns with them.
	var turned := GrabMath.two_handed(Vector3(-0.5, 1, -1), Vector3(0.5, 1, -1), Vector3(0, 1, -0.5), Vector3(0, 1, -1.5), obj)
	tc.assert_true(_near(turned.basis * Vector3.RIGHT, Vector3(0, 0, -1)), "turned: %s" % (turned.basis * Vector3.RIGHT))


static func test_to_dict_round_trip(tc: TestCase) -> void:
	var d := {"position": [1.0, 2.0, 3.0], "rotation_deg": [10.0, 20.0, 30.0], "scale": [2.0, 1.0, 0.5]}
	var back := GrabMath.to_dict(GrabMath.from_dict(d))
	for k in d:
		tc.assert_true(_near(Interpolation.to_vec3(back[k]), Interpolation.to_vec3(d[k]), 1e-3), "%s: %s" % [k, back[k]])
	var parent := Transform3D(Basis(Vector3.UP, deg_to_rad(90)), Vector3(5, 0, 0))
	var child := parent * GrabMath.from_dict(d)
	tc.assert_true(_near(GrabMath.to_local(parent, child).origin, Vector3(1, 2, 3)), "back in the parent's space")


static func test_snapping(tc: TestCase) -> void:
	tc.assert_true(_near(StudioSnap.position(Vector3(0.14, 1.06, -2.349)), Vector3(0.1, 1.1, -2.3)))
	tc.assert_eq(StudioSnap.rotation_deg(Vector3(7.0, 44.0, -22.6)), Vector3(0, 45, -30))
	tc.assert_true(_near(StudioSnap.scale(Vector3(1.03, 0.51, 0.01)), Vector3(1.05, 0.5, 0.05)), "never snaps to zero")
	tc.assert_eq(StudioSnap.level(Vector3(12, 40, -8)), Vector3(0, 40, 0))
	tc.assert_eq(StudioSnap.face_yaw(Vector3(0, 0, 0), Vector3(0, 0, 5)), 0.0, "viewer in front (+Z)")
	tc.assert_eq(StudioSnap.face_yaw(Vector3(0, 0, 0), Vector3(5, 0, 0)), 90.0)


static func test_pick_nearest_and_inside(tc: TestCase) -> void:
	var near := _box_node(Vector3(0, 1, -2), Vector3(1, 1, 0.1))
	var far := _box_node(Vector3(0, 1, -5), Vector3(4, 4, 0.1))
	var around := _box_node(Vector3(0, 0, 0), Vector3(100, 100, 100))  # the forest you stand in
	var cands := [
		{"id": "far", "xf": far.transform, "bounds": StudioPicker.local_bounds(far)},
		{"id": "near", "xf": near.transform, "bounds": StudioPicker.local_bounds(near)},
		{"id": "around", "xf": around.transform, "bounds": StudioPicker.local_bounds(around)},
	]
	var eye := Vector3(0, 1, 0)
	tc.assert_eq(StudioPicker.pick(eye, Vector3(0, 0, -1), cands), "near")
	tc.assert_eq(StudioPicker.pick(eye, Vector3(0.3, 0.1, -1).normalized(), cands), "far", "past the small one")
	tc.assert_eq(StudioPicker.pick(eye, Vector3(0, 0, 1), cands), "around", "nothing else: the one you're in")
	for n in [near, far, around]:
		n.free()


static func test_pick_turns_with_the_object(tc: TestCase) -> void:
	# A thin wide panel turned 90°: seen edge-on it's missed where it would
	# have been hit unturned.
	var panel := _box_node(Vector3(0, 1, -3), Vector3(4, 1, 0.02))
	var bounds := StudioPicker.local_bounds(panel)
	var aim := (Vector3(1.5, 1, -3) - Vector3(0, 1, 0)).normalized()
	tc.assert_eq(StudioPicker.pick(Vector3(0, 1, 0), aim, [{"id": "p", "xf": panel.transform, "bounds": bounds}]), "p")
	panel.rotation.y = deg_to_rad(90)
	tc.assert_eq(StudioPicker.pick(Vector3(0, 1, 0), aim, [{"id": "p", "xf": panel.transform, "bounds": bounds}]), "", "turned away")
	panel.free()


static func test_nested_objects_pick_as_themselves(tc: TestCase) -> void:
	var group := Node3D.new()
	var child := _box_node(Vector3(0, 0, -2), Vector3(1, 1, 1))
	group.add_child(child)
	tc.assert_eq(StudioPicker.local_bounds(group, [child]).size, Vector3.ZERO, "the child's mesh isn't the group's")
	tc.assert_true(StudioPicker.local_bounds(group).size != Vector3.ZERO)
	group.free()


static func test_batch_is_one_undo_step(tc: TestCase) -> void:
	var m := _model()
	var fired: Array = []
	m.changed.connect(func(s): fired.append(s))
	var ok := m.batch("Move rig", func():
		m.set_key("transform", "rig", "position", 2.0, [0, 1, 0])
		m.set_key("transform", "rig", "scale", 2.0, [2, 2, 2]))
	tc.assert_true(ok)
	tc.assert_eq(fired.size(), 1, "one change notice")
	tc.assert_eq(m.undo_label(), "Move rig")
	tc.assert_true(m.find_track("transform", "rig", "position") >= 0 and m.find_track("transform", "rig", "scale") >= 0)
	m.undo()
	tc.assert_eq(m.find_track("transform", "rig", "position"), -1, "both undone together")
	tc.assert_eq(m.find_track("transform", "rig", "scale"), -1)
	tc.assert_false(m.batch("Nothing", func(): pass), "an empty batch isn't recorded")


static func test_runner_leaves_held_objects_alone(tc: TestCase) -> void:
	var runner := ScriptRunner.new()
	runner._registry = ObjectRegistry.new()
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	var node := Node3D.new()
	var data := TimelineData.new()
	data.media = {"video": "x.mp4", "duration": 10.0}
	data.tracks = [{"type": "transform", "target": "obj", "channel": "position",
			"keyframes": [{"t": 0.0, "value": [0, 0, 0]}, {"t": 10.0, "value": [10, 0, 0]}]}]
	runner.load_timeline(data)
	runner.registry().register("obj", node, true)  # external, like the main screen
	runner.held["obj"] = true
	node.position = Vector3(0, 5, 0)
	runner.seek(5.0)
	runner.tick(0.0)
	tc.assert_eq(node.position, Vector3(0, 5, 0), "held: the editor's position stays")
	runner.held.erase("obj")
	runner.tick(0.0)
	tc.assert_eq(node.position, Vector3(5, 0, 0), "released: the track applies again")
	node.free()
	runner.free()


static func _box_node(pos: Vector3, size: Vector3) -> Node3D:
	var root := Node3D.new()
	root.position = pos
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	root.add_child(mesh)
	return root


static func _model() -> EditModel:
	var path := "user://test_studio_tools.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"format_version": 2, "media": {"video": "v.mp4", "duration": 30.0},
			"prefabs": {"group": "res://player/prefabs/group.tscn"},
			"tracks": [{"type": "event", "t": 0.0, "action": "spawn", "id": "rig", "prefab": "group",
				"transform": {"position": [0, 0, 0]}}]}))
	f.close()
	return EditModel.open(path).model
