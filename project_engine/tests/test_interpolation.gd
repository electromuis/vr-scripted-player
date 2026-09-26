extends RefCounted


static func test_scalar_linear(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 0.0}, {"t": 10.0, "value": 10.0}]
	tc.assert_eq(Interpolation.evaluate(kfs, 0.0), 0.0)
	tc.assert_eq(Interpolation.evaluate(kfs, 5.0), 5.0)
	tc.assert_eq(Interpolation.evaluate(kfs, 10.0), 10.0)


static func test_scalar_clamps_out_of_range(tc: TestCase) -> void:
	var kfs := [{"t": 1.0, "value": 4.0}, {"t": 3.0, "value": 8.0}]
	tc.assert_eq(Interpolation.evaluate(kfs, 0.0), 4.0)
	tc.assert_eq(Interpolation.evaluate(kfs, 99.0), 8.0)


static func test_vec3_linear(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": [0, 0, 0]}, {"t": 2.0, "value": [2, 4, 6]}]
	var mid = Interpolation.evaluate(kfs, 1.0)
	tc.assert_eq(mid[0], 1.0)
	tc.assert_eq(mid[1], 2.0)
	tc.assert_eq(mid[2], 3.0)


static func test_step_holds_previous(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 5.0, "interp": "step"}, {"t": 10.0, "value": 20.0}]
	tc.assert_eq(Interpolation.evaluate(kfs, 4.99), 5.0)
	tc.assert_eq(Interpolation.evaluate(kfs, 9.99), 5.0)
	tc.assert_eq(Interpolation.evaluate(kfs, 10.0), 20.0)


static func test_ease_smoothstep(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 0.0, "interp": "ease"}, {"t": 2.0, "value": 10.0}]
	# smoothstep(0.5) = 0.5, so midpoint is still 5.0
	tc.assert_eq(Interpolation.evaluate(kfs, 1.0), 5.0)
	_assert_near(tc, Interpolation.evaluate(kfs, 0.5), 1.5625, 1e-9, "smoothstep(0.25) * 10")


## The player's cubic follows Godot's cubic value tracks: uneven key
## spacing, both ends, scalars and vectors.
static func test_cubic_matches_godot(tc: TestCase) -> void:
	var times := [0.0, 1.0, 1.5, 4.0, 5.0]
	var values := [0.0, 3.0, -1.0, 2.0, 2.5]
	var anim := Animation.new()
	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_interpolation_type(track, Animation.INTERPOLATION_CUBIC)
	var vtrack := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_interpolation_type(vtrack, Animation.INTERPOLATION_CUBIC)
	var kfs: Array = []
	var vkfs: Array = []
	for i in times.size():
		var v3 := Vector3(values[i], -values[i] * 2.0, float(i))
		anim.track_insert_key(track, times[i], values[i])
		anim.track_insert_key(vtrack, times[i], v3)
		kfs.append({"t": times[i], "value": values[i], "interp": "cubic"})
		vkfs.append({"t": times[i], "value": [v3.x, v3.y, v3.z], "interp": "cubic"})
	anim.length = 5.0
	for n in 101:
		var t := n * 0.05
		_assert_near(tc, Interpolation.evaluate(kfs, t), anim.value_track_interpolate(track, t), 1e-4, "t=%s" % t)
		var want: Vector3 = anim.value_track_interpolate(vtrack, t)
		var got := Interpolation.to_vec3(Interpolation.evaluate(vkfs, t))
		tc.assert_true(got.distance_to(want) < 1e-4, "vec t=%s: %s != %s" % [t, got, want])


## The player's bezier follows Godot's bezier tracks, handles and all
## (including one reaching past its neighbour's value).
static func test_bezier_matches_godot(tc: TestCase) -> void:
	var keys := [
		[0.0, 0.0, Vector2.ZERO, Vector2(0.4, 2.0)],
		[1.2, 1.0, Vector2(-0.3, -0.5), Vector2(0.5, 0.1)],
		[2.0, -2.0, Vector2(-0.2, 3.0), Vector2(0.9, -1.0)],
		[4.0, 0.5, Vector2(-1.5, 0.0), Vector2.ZERO],
	]
	var anim := Animation.new()
	var track := anim.add_track(Animation.TYPE_BEZIER)
	var kfs: Array = []
	for k in keys:
		anim.bezier_track_insert_key(track, k[0], k[1], k[2], k[3])
		kfs.append({"t": k[0], "value": k[1], "interp": "bezier",
				"in": [k[2].x, k[2].y], "out": [k[3].x, k[3].y]})
	anim.length = 4.0
	for n in 81:
		var t := n * 0.05
		_assert_near(tc, Interpolation.evaluate(kfs, t), anim.bezier_track_interpolate(track, t), 1e-5, "t=%s" % t)


static func test_bezier_arrays_per_element(tc: TestCase) -> void:
	var kfs := [
		{"t": 0.0, "value": [0.0, 10.0], "interp": "bezier", "out": [[0.5, 1.0], [0.5, 0.0]]},
		{"t": 2.0, "value": [4.0, 10.0], "in": [[-0.5, 0.0], [-0.5, 0.0]]},
	]
	var mid: Array = Interpolation.evaluate(kfs, 1.0)
	_assert_near(tc, mid[0], Interpolation.bezier_segment(0.0, Vector2(0.5, 1.0), 4.0, Vector2(-0.5, 0.0), 1.0, 2.0), 1e-9, "x")
	_assert_near(tc, mid[1], 10.0, 1e-9, "flat element stays put")


static func test_bezier_without_handles_is_linear(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 0.0, "interp": "bezier"}, {"t": 4.0, "value": 8.0}]
	for t in [0.5, 1.0, 2.0, 3.7]:
		_assert_near(tc, Interpolation.evaluate(kfs, t), t * 2.0, 1e-3, "t=%s" % t)


static func _assert_near(tc: TestCase, got, want, eps: float, msg: String) -> void:
	tc.assert_true(absf(float(got) - float(want)) <= eps, "%s: %s != %s" % [msg, got, want])


static func test_single_keyframe(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 7.5}]
	tc.assert_eq(Interpolation.evaluate(kfs, 0.0), 7.5)
	tc.assert_eq(Interpolation.evaluate(kfs, 100.0), 7.5)


static func test_to_vec3(tc: TestCase) -> void:
	var v := Interpolation.to_vec3([1, 2, 3])
	tc.assert_eq(v.x, 1.0)
	tc.assert_eq(v.y, 2.0)
	tc.assert_eq(v.z, 3.0)
