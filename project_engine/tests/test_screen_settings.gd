extends RefCounted

## ScreenSettings.mount_transform: tilt orbits the screen around the viewer.


static func test_tilt_keeps_distance_to_viewer(t: TestCase) -> void:
	var s := ScreenSettings.new()
	var eye := Vector3(0, 2, 8)
	var screen := Vector3(0, 2, -10)  # straight ahead of the eye
	s.tilt = 30.0
	var moved := s.mount_transform(eye) * screen
	t.assert_true(is_equal_approx(moved.distance_to(eye), screen.distance_to(eye)),
			"orbit keeps the screen's distance from the viewer")
	t.assert_true(moved.y > screen.y, "positive tilt raises the screen")
	var expected_y := eye.y + 18.0 * sin(deg_to_rad(30.0))
	t.assert_true(is_equal_approx(moved.y, expected_y), "raised along the arc (%s)" % moved)


static func test_tilted_screen_faces_viewer(t: TestCase) -> void:
	var s := ScreenSettings.new()
	var eye := Vector3(0, 2, 8)
	s.tilt = 40.0
	var xf := s.mount_transform(eye)
	var pos := xf * Vector3(0, 2, -10)
	var normal := (xf.basis * Vector3.BACK).normalized()  # quad front is +Z
	t.assert_true(normal.dot((eye - pos).normalized()) > 0.999, "screen front points at the eye")


static func test_zero_tilt_is_plain_offset(t: TestCase) -> void:
	var s := ScreenSettings.new()
	s.height = 0.5
	s.distance = 2.0
	var p := s.mount_transform(Vector3(0, 2, 8)) * Vector3(0, 2, -10)
	t.assert_true(p.is_equal_approx(Vector3(0, 2.5, -12)), "height/distance only (%s)" % p)


static func test_size_scales_about_pivot(t: TestCase) -> void:
	var s := ScreenSettings.new()
	s.size = 2.0
	var pivot := Vector3(0, 2, 0)
	var xf := s.mount_transform(Vector3(0, 2, 8), 0.0, pivot)
	t.assert_true((xf * pivot).is_equal_approx(pivot), "centre stays put (%s)" % (xf * pivot))
	t.assert_true((xf * Vector3(1, 3, 0)).is_equal_approx(Vector3(2, 4, 0)), "corners grow outward")


static func test_opacity_round_trip_and_clamp(t: TestCase) -> void:
	var s := ScreenSettings.new()
	t.assert_eq(s.opacity, 1.0, "opaque by default")
	s.opacity = 1.5
	t.assert_eq(s.opacity, 1.0, "clamped")
	s.opacity = 0.4
	var copy := ScreenSettings.new()
	copy.from_dict(s.to_dict())
	t.assert_eq(copy.opacity, 0.4)
	copy.from_dict({})
	t.assert_eq(copy.opacity, 1.0, "old presets stay opaque")


static func test_resolution_round_trip_and_clamp(t: TestCase) -> void:
	var s := ScreenSettings.new()
	t.assert_eq(s.resolution, 1.0, "full resolution by default")
	s.resolution = 5.0
	t.assert_eq(s.resolution, ScreenSettings.RESOLUTION_MAX, "clamped high")
	s.resolution = 0.0
	t.assert_eq(s.resolution, ScreenSettings.RESOLUTION_MIN, "clamped low")
	s.resolution = 0.5
	var copy := ScreenSettings.new()
	copy.from_dict(s.to_dict())
	t.assert_eq(copy.resolution, 0.5)
	copy.from_dict({})
	t.assert_eq(copy.resolution, 1.0, "old presets keep full resolution")


static func test_effects_and_vertical_curve_round_trip(t: TestCase) -> void:
	var s := ScreenSettings.new()
	s.vertical_curvature = 0.4
	s.add_effect(VisualizerShaders.KEY_BLACK)
	s.add_effect()
	s.set_effect_shader(1, VisualizerShaders.OVAL_MASK)
	s.set_effect_param(1, "size", 0.7)
	var copy := ScreenSettings.new()
	copy.from_dict(s.to_dict())
	t.assert_eq(copy.vertical_curvature, 0.4)
	t.assert_eq(copy.effects.size(), 2)
	t.assert_eq(copy.effects[0].shader, VisualizerShaders.KEY_BLACK)
	t.assert_eq(copy.effects[1].params.get("size"), 0.7)
	copy.set_effect_param(1, "size", 0.2)
	t.assert_eq(s.effects[1].params.get("size"), 0.7, "copies don't share params")


static func test_effect_edits_signal(t: TestCase) -> void:
	var s := ScreenSettings.new()
	var counts := {"structure": 0, "changed": 0}
	s.structure_changed.connect(func(): counts.structure += 1)
	s.changed.connect(func(): counts.changed += 1)
	s.add_effect(VisualizerShaders.OVAL_MASK)
	s.set_effect_param(0, "blur", 0.5)
	t.assert_eq(counts.structure, 1, "a param change isn't structural")
	t.assert_eq(counts.changed, 2)
	s.set_effect_shader(0, VisualizerShaders.KEY_BLACK)
	t.assert_true(s.effects[0].params.is_empty(), "re-picking resets params")
	s.remove_effect(0)
	t.assert_eq(counts.structure, 3)
	t.assert_true(s.effects.is_empty())


static func test_legacy_mask_becomes_oval_effect(t: TestCase) -> void:
	var s := ScreenSettings.new()
	s.from_dict({"mask": {"enabled": true, "outside": false, "feather": 0.3, "level": 1}})
	t.assert_eq(s.effects.size(), 1)
	t.assert_eq(s.effects[0].shader, VisualizerShaders.OVAL_MASK)
	t.assert_eq(s.effects[0].params.blur, 0.3)
	t.assert_eq(s.effects[0].params.outside, false)
	t.assert_eq(s.effects[0].params.level, 1.0)
	s.from_dict({"mask": {"enabled": false}})
	t.assert_true(s.effects.is_empty(), "disabled mask = no effect")
