extends RefCounted

## Media-player behavior: projection detection, default-screen injection,
## player settings persistence, and head-accurate recentering.


static func test_projection_detect(t: TestCase) -> void:
	t.assert_eq(VideoProjection.detect("C:/v/movie.mp4"), "flat")
	t.assert_eq(VideoProjection.detect("C:/v/Movie_3D_SBS.mkv"), "flat_sbs")
	t.assert_eq(VideoProjection.detect("clip.OU.mp4"), "flat_tb")
	t.assert_eq(VideoProjection.detect("scene_180_LR.mp4"), "180_sbs")
	t.assert_eq(VideoProjection.detect("scene_180.mp4"), "180_sbs", "180 defaults to SBS")
	t.assert_eq(VideoProjection.detect("scene-180x180_3dh.mp4"), "180_sbs")
	t.assert_eq(VideoProjection.detect("scene_180_TB.mp4"), "180_tb")
	t.assert_eq(VideoProjection.detect("tour_360.mp4"), "360_mono", "360 defaults to mono")
	t.assert_eq(VideoProjection.detect("tour_360_TB.mp4"), "360_tb")
	t.assert_eq(VideoProjection.detect("tour 360 sbs.mp4"), "360_sbs")
	# Digits inside other tokens must not trigger.
	t.assert_eq(VideoProjection.detect("track1800.mp4"), "flat")
	t.assert_eq(VideoProjection.detect(""), "flat")


static func test_projection_helpers(t: TestCase) -> void:
	t.assert_eq(VideoProjection.shape_of("flat_sbs"), VideoProjection.Shape.FLAT)
	t.assert_eq(VideoProjection.shape_of("180_tb"), VideoProjection.Shape.DOME_180)
	t.assert_eq(VideoProjection.shape_of("360_mono"), VideoProjection.Shape.SPHERE_360)
	t.assert_eq(VideoProjection.stereo_of("180_sbs"), VideoProjection.Stereo.SBS)
	t.assert_eq(VideoProjection.stereo_of("360_tb"), VideoProjection.Stereo.TB)
	t.assert_eq(VideoProjection.stereo_of("flat"), VideoProjection.Stereo.MONO)
	t.assert_true(is_equal_approx(VideoProjection.eye_aspect("flat_sbs", 32.0 / 9.0), 16.0 / 9.0))
	t.assert_true(is_equal_approx(VideoProjection.eye_aspect("flat_tb", 16.0 / 18.0), 16.0 / 9.0))
	for key in VideoProjection.KEYS:
		t.assert_true(VideoProjection.LABELS.has(key), "label for %s" % key)


static func test_default_screen_injected_when_missing(t: TestCase) -> void:
	var data := DefaultScreen.timeline_for_video("C:/v/movie.mp4")
	t.assert_true(data.synthetic)
	t.assert_eq(data.resolve(String(data.media.video)), "C:/v/movie.mp4")
	DefaultScreen.inject(data)
	var spawns := data.events_sorted().filter(func(e): return e.get("action") == "spawn")
	t.assert_eq(spawns.size(), 1)
	t.assert_eq(String(spawns[0].id), DefaultScreen.SCREEN_ID)
	t.assert_eq(data.resolve_prefab(String(spawns[0].prefab)), DefaultScreen.PREFAB_PATH)
	# Idempotent: a second inject (e.g. live reload) doesn't add another.
	DefaultScreen.inject(data)
	t.assert_eq(data.events_sorted().size(), 1)


static func test_default_screen_respects_script(t: TestCase) -> void:
	var own := TimelineData.new()
	own.tracks = [{"type": "event", "t": 2.0, "action": "spawn", "id": "main_screen", "prefab": "screen"}]
	DefaultScreen.inject(own)
	t.assert_eq(own.tracks.size(), 1, "script's own main_screen wins")

	var opted_out := TimelineData.new()
	opted_out.meta = {"default_screen": false}
	DefaultScreen.inject(opted_out)
	t.assert_eq(opted_out.tracks.size(), 0, "meta.default_screen=false opts out")


static func test_video_detection(t: TestCase) -> void:
	t.assert_true(DefaultScreen.is_video("a/b/C.MP4"))
	t.assert_true(DefaultScreen.is_video("x.mkv"))
	t.assert_false(DefaultScreen.is_video("x.json"))
	t.assert_false(DefaultScreen.is_video("x.funscript"))


static func test_player_settings_roundtrip(t: TestCase) -> void:
	var path := "user://test_player_settings.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var s := PlayerSettings.new(path)
	s.load_from_disk()  # missing file → defaults
	t.assert_eq(s.locomotion, PlayerSettings.Locomotion.LOCKED, "locked by default")
	t.assert_eq(s.skybox, "black", "black by default")
	t.assert_false(s.show_floor, "no floor by default")
	t.assert_false(s.browser_tiles, "list view by default")
	s.browser_tiles = true
	s.locomotion = PlayerSettings.Locomotion.FREE
	s.skybox = "dusk"
	s.volume = 1.7  # clamps
	var s2 := PlayerSettings.new(path)
	s2.load_from_disk()
	t.assert_eq(s2.locomotion, PlayerSettings.Locomotion.FREE)
	t.assert_eq(s2.skybox, "dusk")
	t.assert_eq(s2.volume, 1.0)
	t.assert_true(s2.browser_tiles)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func test_skybox_options_start_with_builtins(t: TestCase) -> void:
	var opts := SkyboxLibrary.list_options()
	t.assert_true(opts.size() >= PlayerSettings.SKYBOX_BUILTINS.size())
	t.assert_eq(String(opts[0].key), "black")


static func test_every_builtin_skybox_applies(t: TestCase) -> void:
	var lib := SkyboxLibrary.new()
	for key in PlayerSettings.SKYBOX_BUILTINS:
		t.assert_true(PlayerSettings.SKYBOX_LABELS.has(key), "label for %s" % key)
		var env := Environment.new()
		env.background_mode = Environment.BG_CANVAS  # neither colour nor sky
		lib.apply(env, key)
		t.assert_true(env.background_mode == Environment.BG_COLOR or env.background_mode == Environment.BG_SKY, "%s sets a background" % key)
		if key in ["forest", "clouds", "space"]:
			t.assert_true(env.sky != null and env.sky.sky_material is ShaderMaterial, "%s uses its sky shader" % key)


static func test_ray_hits_quad(t: TestCase) -> void:
	# 32x18 quad scaled 0.25 (8 x 4.5 m) at z = -8, 2 m up, facing +Z.
	var quad := Transform3D(Basis().scaled(Vector3.ONE * 0.25), Vector3(0.0, 2.0, -8.0))
	var size := Vector2(32, 18)
	var eye := Vector3(0.0, 1.6, 0.0)
	t.assert_true(XRRig.ray_hits_quad(eye, Vector3(0, 0, -1), quad, size), "straight ahead hits")
	t.assert_true(XRRig.ray_hits_quad(eye, (Vector3(3.9, 2.0, -8.0) - eye).normalized(), quad, size), "near the right edge hits")
	t.assert_false(XRRig.ray_hits_quad(eye, (Vector3(4.2, 2.0, -8.0) - eye).normalized(), quad, size), "past the edge misses")
	t.assert_false(XRRig.ray_hits_quad(eye, Vector3(0, 0, 1), quad, size), "pointing away misses")
	t.assert_false(XRRig.ray_hits_quad(eye, Vector3(1, 0, 0), quad, size), "parallel misses")


static func test_recenter_puts_head_on_target(t: TestCase) -> void:
	# User stands 0.5 m right / 0.3 m back in their playspace, turned 70°.
	var head_local := Transform3D(Basis(Vector3.UP, deg_to_rad(70.0)), Vector3(0.5, 1.6, 0.3))
	var target := Vector3(2.0, 1.8, 8.0)
	var origin := XRRig.recentered_origin(head_local, target, 15.0)
	var head_world := origin * head_local
	t.assert_true(is_equal_approx(head_world.origin.x, target.x), "head x %f" % head_world.origin.x)
	t.assert_true(is_equal_approx(head_world.origin.z, target.z), "head z %f" % head_world.origin.z)
	t.assert_true(is_equal_approx(head_world.origin.y, 1.6), "eye height from tracking")
	t.assert_true(is_equal_approx(origin.origin.y, 0.0), "origin stays on floor")
	var fwd := -head_world.basis.z
	t.assert_true(is_equal_approx(rad_to_deg(atan2(-fwd.x, -fwd.z)), 15.0), "head yaw")
