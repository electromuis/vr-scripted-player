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


static func test_cubic_smoothstep_midpoint(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 0.0, "interp": "cubic"}, {"t": 2.0, "value": 10.0}]
	# smoothstep(0.5) = 0.5, so midpoint is still 5.0
	tc.assert_eq(Interpolation.evaluate(kfs, 1.0), 5.0)


static func test_single_keyframe(tc: TestCase) -> void:
	var kfs := [{"t": 0.0, "value": 7.5}]
	tc.assert_eq(Interpolation.evaluate(kfs, 0.0), 7.5)
	tc.assert_eq(Interpolation.evaluate(kfs, 100.0), 7.5)


static func test_to_vec3(tc: TestCase) -> void:
	var v := Interpolation.to_vec3([1, 2, 3])
	tc.assert_eq(v.x, 1.0)
	tc.assert_eq(v.y, 2.0)
	tc.assert_eq(v.z, 3.0)
