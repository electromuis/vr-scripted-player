extends RefCounted

## Camera effects without a GPU: shader sources and params, settings and
## presets, the script format's camera block and the runner's tracks, and
## that the scripts compile at all (the compositor pass itself is checked
## by rendering; see VR Studio — Plan.md).

const TMP_DIR := "user://test_camera_fx_tmp"


static func test_scripts_compile(tc: TestCase) -> void:
	for path in ["res://player/visualizer/camera_fx_effect.gd", "res://player/visualizer/camera_fx.gd",
			"res://player/visualizer/camera_fx_shaders.gd", "res://player/settings/camera_fx_settings.gd"]:
		var script: GDScript = load(path)
		tc.assert_true(script != null and script.can_instantiate(), "%s compiles" % path)


static func test_builtins_have_sliders(tc: TestCase) -> void:
	for key in CameraFxShaders.BUILTINS:
		var code := CameraFxShaders.code_for(key)
		tc.assert_true(CameraFxShaders.is_camera_code(code), "%s is marked @camera" % key)
		tc.assert_true(code.contains("vec3 camera_fx(vec2 uv)"), "%s defines camera_fx" % key)
		tc.assert_false(CameraFxShaders.params_of(code).is_empty(), "%s has sliders" % key)


static func test_build_source_turns_uniforms_into_buffer_reads(tc: TestCase) -> void:
	var code := """// @camera
uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.5; // how much
uniform int steps : hint_range(1, 8) = 3;
uniform bool flip = true;
vec3 camera_fx(vec2 uv) { return view_color(uv) * amount; }
"""
	var src := CameraFxShaders.build_source(code)
	tc.assert_has(src, "#define amount data.v[0]")
	tc.assert_has(src, "#define steps int(data.v[1])")
	tc.assert_has(src, "#define flip (data.v[2] > 0.5)")
	tc.assert_false(src.contains("uniform float amount"), "the uniform line is gone")
	tc.assert_has(src, "vec3 camera_fx(vec2 uv)")
	tc.assert_has(src, "void main()")
	var specs := CameraFxShaders.params_of(code)
	tc.assert_eq(CameraFxShaders.param_values(specs, {"steps": 5}), PackedFloat32Array([0.5, 5.0, 1.0]))


static func test_errors_point_at_the_effects_own_line(tc: TestCase) -> void:
	var code := "// @camera\nuniform float a : hint_range(0.0, 1.0) = 0.5;\nvec3 camera_fx(vec2 uv) {\n\treturn view_color(uv) * b;\n}\n"
	var prefix_lines := CameraFxShaders.build_source(code).split("\n").find("// @camera")
	var raw := "Failed parse:\nERROR: 0:%d: 'b' : undeclared identifier\nERROR: 1 compilation errors." % (prefix_lines + 4)
	tc.assert_eq(CameraFxShaders.explain_error(code, raw), "line 4: 'b' : undeclared identifier")


static func test_camera_files_are_not_layers(tc: TestCase) -> void:
	_wipe()
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	_write(TMP_DIR.path_join("trip.glsl"), "// @camera\nvec3 camera_fx(vec2 uv) { return view_color(uv); }\n")
	_write(TMP_DIR.path_join("plasma.glsl"), "void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\n")
	var dirs: Array[String] = [ProjectSettings.globalize_path(TMP_DIR)]
	var cams := CameraFxShaders.list_options(dirs).map(func(o): return o.label)
	var layers := VisualizerShaders.list_options(dirs).map(func(o): return o.label)
	tc.assert_true(cams.has("trip") and not cams.has("plasma"), "camera list: %s" % [cams])
	tc.assert_true(layers.has("plasma") and not layers.has("trip"), "layer list: %s" % [layers])
	_wipe()


static func test_settings_round_trip_and_presets(tc: TestCase) -> void:
	var fx := CameraFxSettings.new()
	tc.assert_eq(fx.to_dict(), {}, "no effect saves nothing")
	fx.shader = "builtin:kaleidoscope"
	fx.strength = 0.4
	fx.set_param("segments", 8.0)
	var again := CameraFxSettings.new()
	again.from_dict(fx.to_dict())
	tc.assert_eq(again.to_dict(), {"shader": "builtin:kaleidoscope", "strength": 0.4, "params": {"segments": 8.0}})
	fx.shader = "builtin:hue_cycle"
	tc.assert_eq(fx.params, {}, "a new shader starts from its defaults")

	_wipe()
	var store := PresetStore.new(TMP_DIR)
	var layers := LayerStack.new()
	layers.camera_fx.from_dict({"shader": "builtin:liquid_warp", "strength": 0.7})
	store.save_preset(2, "Trip", ScreenSettings.new().to_dict(), [], layers.camera_fx.to_dict())
	var loaded := LayerStack.new()
	store.apply(2, ScreenSettings.new(), loaded)
	tc.assert_eq(loaded.camera_fx.shader, "builtin:liquid_warp")
	tc.assert_eq(loaded.camera_fx.strength, 0.7)
	store.apply(PresetStore.SCRIPT_PRESET_INDEX, ScreenSettings.new(), loaded)
	tc.assert_eq(loaded.camera_fx.shader, "", "Script (defaults) has none")
	_wipe()


static func test_player_limits_save(tc: TestCase) -> void:
	var path := "user://test_camera_fx_settings.json"
	var s := PlayerSettings.new(path)
	s.camera_fx = false
	s.camera_fx_max = 0.5
	var again := PlayerSettings.new(path)
	again.load_from_disk()
	tc.assert_false(again.camera_fx)
	tc.assert_eq(again.camera_fx_max, 0.5)
	DirAccess.remove_absolute(path)


static func test_script_camera_block(tc: TestCase) -> void:
	var base := {"format_version": 2, "media": {"video": "v.mp4", "duration": 20.0},
			"shaders": {"trip": "builtin:kaleidoscope", "warp": "shaders/warp.glsl"},
			"camera": {"effects": [
				{"shader": "warp", "enabled": false},
				{"shader": "trip", "params": {"segments": 4}, "strength": 0.5}]},
			"tracks": [{"type": "shader_param", "target": "$camera.effect0", "param": "strength",
				"keyframes": [{"t": 0, "value": 0.0}, {"t": 10, "value": 1.0}]},
				{"type": "shader_param", "target": "$camera.effect0", "param": "spin",
				"keyframes": [{"t": 0, "value": 0.5}]}]}
	var r := ScriptFormat.load_from_string(JSON.stringify(base))
	tc.assert_ok(r)
	var bad := base.duplicate(true)
	bad.camera.effects[0].enabled = "no"
	tc.assert_err(ScriptFormat.load_from_string(JSON.stringify(bad)), "enabled")

	var runner := ScriptRunner.new()
	runner._registry = ObjectRegistry.new()
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	runner.load_timeline(r.data)
	runner.seek(5.0)
	var e := runner.camera_effect()
	tc.assert_eq(e.key, "builtin:kaleidoscope", "the first enabled effect")
	tc.assert_true(absf(float(e.strength) - 0.5) < 1e-6, "strength keyed halfway: %s" % e.strength)
	tc.assert_eq(e.params, {"segments": 4.0, "spin": 0.5})
	runner.free()


static func test_no_camera_block(tc: TestCase) -> void:
	var runner := ScriptRunner.new()
	tc.assert_eq(runner.camera_effect(), {}, "no timeline")
	runner.free()


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func _wipe() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(TMP_DIR)
