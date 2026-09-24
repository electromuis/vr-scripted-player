extends RefCounted

## Visualizer plane: settings/preset round trip, shader discovery and the
## Shadertoy wrapper, and the analyzer's texture layout.

const TEST_DIR := "user://test_visualizer_tmp"


static func _wipe() -> void:
	var dir := DirAccess.open(TEST_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(TEST_DIR)


static func _fresh_dir() -> String:
	_wipe()
	DirAccess.make_dir_recursive_absolute(TEST_DIR)
	return ProjectSettings.globalize_path(TEST_DIR)


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


static func test_layer_round_trip(t: TestCase) -> void:
	var s := LayerSettings.new()
	s.distance = 1.5
	s.shader = "res://x.gdshader"
	s.set_param("speed", 2.0)
	s.add_effect(VisualizerShaders.KEY_BLACK)
	var copy := LayerSettings.new()
	copy.from_dict(s.to_dict())
	t.assert_eq(copy.shader, "res://x.gdshader")
	t.assert_eq(copy.distance, 1.5)
	t.assert_eq(copy.params.get("speed"), 2.0)
	t.assert_false(copy.lock_to_screen)
	t.assert_eq(copy.effects.size(), 1)
	copy.shader = "res://y.gdshader"
	t.assert_true(copy.params.is_empty(), "a new shader starts from its defaults")
	copy.from_dict({})
	t.assert_eq(copy.shader, "", "missing shader = blank")


static func test_stack_count(t: TestCase) -> void:
	var stack := LayerStack.new()
	var fired := [0]
	stack.layers_changed.connect(func(): fired[0] += 1)
	t.assert_eq(stack.count(), 0, "starts empty")
	stack.set_count(3)
	var first := stack.layers[0]
	stack.set_count(2)
	t.assert_eq(stack.count(), 2)
	t.assert_true(stack.layers[0] == first, "shrinking keeps the rest")
	stack.set_count(99)
	t.assert_eq(stack.count(), LayerStack.MAX_LAYERS)
	stack.set_count(LayerStack.MAX_LAYERS)
	t.assert_eq(fired[0], 3, "no signal without a change")


static func test_preset_stores_layers(t: TestCase) -> void:
	_wipe()
	var store := PresetStore.new(TEST_DIR)
	var stack := LayerStack.new()
	stack.set_count(2)
	stack.layers[0].shader = "res://a.gdshader"
	stack.layers[1].height = 0.4
	store.save_preset(2, "Layers", ScreenSettings.new().to_dict(), stack.to_array())
	var loaded := LayerStack.new()
	t.assert_true(store.apply(2, ScreenSettings.new(), loaded))
	t.assert_eq(loaded.count(), 2)
	t.assert_eq(loaded.layers[0].shader, "res://a.gdshader")
	t.assert_eq(loaded.layers[1].height, 0.4)
	store.save_preset(3, "None", ScreenSettings.new().to_dict())
	t.assert_false(store.load_preset(3).has("layers"), "no empty list written")
	t.assert_true(store.apply(3, ScreenSettings.new(), loaded))
	t.assert_eq(loaded.count(), 0)
	_wipe()


static func test_legacy_presets_become_layers(t: TestCase) -> void:
	var old := PresetStore.layers_of({"visualizer": {"shader": "res://v.gdshader", "size": 2.0}})
	t.assert_eq(old.size(), 1)
	var l := LayerSettings.new()
	l.from_dict(old[0])
	t.assert_eq(l.shader, "res://v.gdshader")
	t.assert_eq(l.size, 2.0)
	t.assert_eq(l.distance, 0.0, "a foreground keeps its place")
	t.assert_eq(l.effects.size(), 1, "the old plane was keyed")
	t.assert_eq(l.effects[0].shader, VisualizerShaders.KEY_BLACK)
	var two := PresetStore.layers_of({
		"background": {"shader": "res://b.gdshader", "key_black": false,
				"mask": {"enabled": true}},
		"foreground": {"shader": "res://f.gdshader", "key_black": true},
		"visualizer": {"shader": "res://ignored.gdshader"},
	})
	t.assert_eq(two.size(), 2)
	var b := LayerSettings.new()
	b.from_dict(two[0])
	t.assert_eq(b.distance, LayerSettings.LEGACY_BEHIND, "background pushed behind the video")
	t.assert_eq(b.effects.size(), 1)
	t.assert_eq(b.effects[0].shader, VisualizerShaders.OVAL_MASK)
	var f := LayerSettings.new()
	f.from_dict(two[1])
	t.assert_eq(f.effects[0].shader, VisualizerShaders.KEY_BLACK)
	t.assert_eq(PresetStore.layers_of({"foreground": {"shader": ""}}).size(), 0, "off layers dropped")


static func test_parse_hints(t: TestCase) -> void:
	var h := VisualizerShaders.parse_hints("""shader_type canvas_item;
// @resolution 1024x1024
uniform float speed : hint_range(0.0, 4.0, 0.5) = 1.0;
uniform int count : hint_range(1, 32) = 1.0 * 8;
uniform bool mirror = true;
uniform float plain = 0.3;
uniform vec3 tint : source_color = vec3(1.0);
uniform sampler2D iChannel0;
""")
	t.assert_eq(h.resolution, Vector2i(1024, 1024))
	t.assert_eq(h.params.size(), 3, "range floats/ints and bools only")
	t.assert_eq(h.params[0].name, "speed")
	t.assert_eq(h.params[0].max, 4.0)
	t.assert_eq(h.params[0].step, 0.5)
	t.assert_eq(h.params[0].default, 1.0)
	t.assert_eq(h.params[1].type, "int")
	t.assert_eq(h.params[1].step, 1.0, "ints step by 1")
	t.assert_eq(h.params[1].default, 8.0, "defaults are evaluated")
	t.assert_eq(h.params[2].default, true)
	t.assert_eq(VisualizerShaders.parse_hints("").resolution, Vector2i.ZERO, "no hint")


static func test_parse_hints_channels_and_height_only(t: TestCase) -> void:
	var h := VisualizerShaders.parse_hints("""
// @iChannel1 video
// @iChannel2 webcam
// @resolution 270
""")
	t.assert_eq(h.channels, {0: "audio", 1: "video"}, "unknown sources skipped, audio default kept")
	t.assert_eq(h.resolution, Vector2i(0, 270), "height only")
	t.assert_eq(VisualizerShaders.parse_hints("// @iChannel0 video").channels, {0: "video"})
	t.assert_eq(VisualizerShaders.parse_hints("").channels, {0: "audio"})


static func test_builtin_effects(t: TestCase) -> void:
	for b in VisualizerShaders.BUILTIN_EFFECTS:
		var shader := VisualizerShaders.load_shader(b.key)
		t.assert_true(shader != null, "built-in %s" % b.label)
		t.assert_true(VisualizerShaders.is_effect_code(shader.code), "%s is an effect" % b.label)
	var names: Array = VisualizerShaders.hints_for(VisualizerShaders.OVAL_MASK).params.map(func(p): return p.name)
	t.assert_eq(names, ["outside", "size", "ratio", "blur", "level"])
	names = VisualizerShaders.hints_for(VisualizerShaders.EDGE_BLUR).params.map(func(p): return p.name)
	t.assert_eq(names, ["inward", "radius"])


static func test_list_options_builtins_then_user_files(t: TestCase) -> void:
	var dir := _fresh_dir()
	_write(dir.path_join("b_ring.glsl"), "void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }")
	_write(dir.path_join("a_native.gdshader"), "shader_type canvas_item;")
	_write(dir.path_join("notes.md"), "not a shader")
	_write(dir.path_join("c_fx.gdshader"), "shader_type canvas_item;\nuniform sampler2D input_tex;")
	var dirs: Array[String] = [dir, dir.path_join("missing")]
	var opts := VisualizerShaders.list_options(dirs)
	var n := VisualizerShaders.BUILTINS.size()
	t.assert_eq(opts.size(), n + 2, "built-ins + two shaders, .md and the effect skipped")
	t.assert_eq(String(opts[0].key), String(VisualizerShaders.BUILTINS[0].key))
	t.assert_eq(String(opts[n].label), "a_native")
	t.assert_eq(String(opts[n + 1].key), dir.path_join("b_ring.glsl"))
	var fx := VisualizerShaders.list_options(dirs, true)
	var m := VisualizerShaders.BUILTIN_EFFECTS.size()
	t.assert_eq(fx.size(), m + 1, "built-in effects + the user's")
	t.assert_eq(String(fx[m].label), "c_fx")
	_wipe()


static func test_load_shadertoy_file_wraps_code(t: TestCase) -> void:
	var dir := _fresh_dir()
	var path := dir.path_join("x.glsl")
	_write(path, "void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }")
	var shader := VisualizerShaders.load_shader(path)
	t.assert_true(shader != null, "loaded")
	t.assert_true(shader.code.begins_with("shader_type canvas_item;"), "shader type first")
	t.assert_has(shader.code, VisualizerShaders.PRELUDE)
	t.assert_has(shader.code, "void mainImage")
	t.assert_true(shader.code.find(VisualizerShaders.MAIN) > shader.code.find("void mainImage"),
			"fragment() comes after mainImage")
	t.assert_true(VisualizerShaders.load_shader(dir.path_join("nope.glsl")) == null, "missing file")
	t.assert_true(VisualizerShaders.load_shader("") == null, "off")
	_wipe()


static func test_builtins_load(t: TestCase) -> void:
	for b in VisualizerShaders.BUILTINS:
		t.assert_true(VisualizerShaders.load_shader(b.key) != null, "built-in %s" % b.label)


static func test_analyzer_texture_layout(t: TestCase) -> void:
	var a := AudioAnalyzer.new()
	var img := a.texture.get_image()
	t.assert_eq(img.get_size(), Vector2i(AudioAnalyzer.BINS, 2))
	t.assert_eq(img.get_pixel(0, 0).r, 0.0, "silent spectrum")
	t.assert_true(absf(img.get_pixel(100, 1).r - 0.5) < 0.01, "silent waveform sits at 0.5")
	t.assert_false(a.attach("no such bus"), "unknown bus")
	a.free()


static func test_padding_step(t: TestCase) -> void:
	var a := 16.0 / 9.0
	var g := Screen.pad(a, 1.0, Vector2(320, 180), 0.5)
	t.assert_eq(g.h, 2.0, "half a height each side")
	t.assert_eq(g.w, a + 1.0)
	t.assert_eq(Screen.pass_size(g.px), Vector2i(500, 360), "pixels grow with it")
	var g2 := Screen.pad(g.w, g.h, g.px, 0.25)
	t.assert_eq(g2.h, 3.0, "a second padding is relative to the padded picture")
	t.assert_eq(Screen.pass_size(Vector2(8192, 2048)), Vector2i(4096, 1024), "capped at 4096")
	t.assert_eq(Screen.pad(a, 1.0, Vector2(320, 180), -1.0).h, 1.0, "negative is none")
	t.assert_eq(VisualizerShaders.hints_for(VisualizerShaders.PADDING).params.map(func(p): return p.name), ["amount"])
