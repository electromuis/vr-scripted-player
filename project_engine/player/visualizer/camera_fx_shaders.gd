class_name CameraFxShaders
extends RefCounted

## Camera effects: full-view shaders over everything the viewer sees (see
## CameraFx). They're GLSL, run as a compute pass per eye after the scene
## is drawn, so the video and see-through layers are in the picture.
##
## An effect defines one function, from the view's uv (0..1, top-left) to a
## colour:
##
##     // @camera
##     uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.5;
##     vec3 camera_fx(vec2 uv) {
##         return view_color(uv + vec2(sin(uv.y * 30.0 + iTime) * 0.01 * amount, 0.0));
##     }
##
## Provided: view_color(uv) (what was rendered, linear colour), iTime,
## iResolution (the eye's pixel size), eye (0 left / mono, 1 right),
## strength (0..1; the result is also blended by it, so an effect needn't
## use it), audio_level / audio_bass / audio_mid / audio_high (0..1) and
## audio_spectrum(x) (x 0..1 over 0–11 kHz, like a layer's iChannel0 row 0).
## `uniform float|int|bool` lines with a hint_range (bools without) become
## sliders, as for layers, up to MAX_PARAMS. The `// @camera` line is what
## marks a .glsl / .frag / .txt file in the shaders folders as a camera
## effect rather than a Shadertoy layer.
##
## Comfort: warp both eyes the same way (compute from uv, never from `eye`
## unless it's to cancel a difference), and keep big brightness flashes
## under 3 per second.

const MAX_PARAMS := 32
const CAMERA_HINT := "@camera"
const EXTENSIONS := ["glsl", "frag", "txt"]

const BUILTIN_PREFIX := "builtin:"
## key -> [label, code]
const BUILTINS := {
	"builtin:kaleidoscope": ["Kaleidoscope", _KALEIDOSCOPE],
	"builtin:hue_cycle": ["Hue cycle", _HUE_CYCLE],
	"builtin:liquid_warp": ["Liquid warp", _LIQUID_WARP],
	"builtin:chromatic_pulse": ["Chromatic pulse", _CHROMATIC],
	"builtin:posterize_glow": ["Posterize glow", _POSTERIZE],
	"builtin:breathing": ["Breathing", _BREATHING],
}

const _KALEIDOSCOPE := """// @camera
uniform float segments : hint_range(2.0, 16.0, 1.0) = 6.0;
uniform float spin : hint_range(0.0, 1.0, 0.01) = 0.15;
uniform float zoom : hint_range(0.5, 2.0, 0.01) = 1.0;
uniform float bass_kick : hint_range(0.0, 1.0, 0.01) = 0.3;
vec3 camera_fx(vec2 uv) {
	vec2 aspect = vec2(iResolution.x / iResolution.y, 1.0);
	vec2 p = (uv - 0.5) * aspect;
	float r = length(p) / zoom;
	float a = atan(p.y, p.x) + iTime * spin + audio_bass * bass_kick;
	float wedge = 6.28318530718 / segments;
	a = mod(a, wedge);
	a = min(a, wedge - a);  // mirror inside each wedge: seamless edges
	vec2 q = vec2(cos(a), sin(a)) * r / aspect + 0.5;
	return view_color(clamp(q, 0.0, 1.0));
}
"""

const _HUE_CYCLE := """// @camera
uniform float speed : hint_range(0.0, 1.0, 0.01) = 0.08;
uniform float saturation : hint_range(0.0, 3.0, 0.01) = 1.4;
uniform float bass_shift : hint_range(0.0, 1.0, 0.01) = 0.2;
vec3 hue_rotate(vec3 c, float turns) {
	float a = turns * 6.28318530718;
	vec3 k = vec3(0.57735);
	return c * cos(a) + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - cos(a));
}
vec3 camera_fx(vec2 uv) {
	vec3 c = hue_rotate(view_color(uv), iTime * speed + audio_bass * bass_shift);
	float grey = dot(c, vec3(0.2126, 0.7152, 0.0722));
	return max(mix(vec3(grey), c, saturation), 0.0);
}
"""

const _LIQUID_WARP := """// @camera
uniform float amount : hint_range(0.0, 0.1, 0.001) = 0.025;
uniform float scale : hint_range(1.0, 30.0, 0.1) = 8.0;
uniform float speed : hint_range(0.0, 3.0, 0.01) = 0.6;
uniform float bass_boost : hint_range(0.0, 2.0, 0.01) = 0.8;
vec3 camera_fx(vec2 uv) {
	float t = iTime * speed;
	float a = amount * (1.0 + audio_bass * bass_boost);
	vec2 d = vec2(sin(uv.y * scale + t) + sin(uv.y * scale * 0.37 - t * 1.3),
			cos(uv.x * scale * 0.9 - t * 0.8) + sin(uv.x * scale * 0.21 + t * 1.7));
	return view_color(clamp(uv + d * a * 0.5, 0.0, 1.0));
}
"""

const _CHROMATIC := """// @camera
uniform float split : hint_range(0.0, 0.05, 0.001) = 0.015;
uniform float bass_boost : hint_range(0.0, 8.0, 0.1) = 3.0;
vec3 camera_fx(vec2 uv) {
	vec2 dir = uv - 0.5;
	vec2 o = dir * split * (1.0 + audio_bass * bass_boost);
	return vec3(view_color(clamp(uv + o, 0.0, 1.0)).r,
			view_color(uv).g,
			view_color(clamp(uv - o, 0.0, 1.0)).b);
}
"""

const _POSTERIZE := """// @camera
uniform float levels : hint_range(2.0, 12.0, 1.0) = 4.0;
uniform float edge_glow : hint_range(0.0, 4.0, 0.01) = 1.5;
uniform float glow_hue : hint_range(0.0, 1.0, 0.01) = 0.55;
float luma(vec2 uv) { return dot(view_color(uv), vec3(0.2126, 0.7152, 0.0722)); }
vec3 camera_fx(vec2 uv) {
	vec2 px = 1.0 / iResolution.xy;
	float gx = luma(uv + vec2(px.x, 0.0)) - luma(uv - vec2(px.x, 0.0));
	float gy = luma(uv + vec2(0.0, px.y)) - luma(uv - vec2(0.0, px.y));
	float edge = clamp(length(vec2(gx, gy)) * 4.0, 0.0, 1.0);
	vec3 c = floor(clamp(view_color(uv), 0.0, 1.0) * levels + 0.5) / levels;
	vec3 glow = 0.5 + 0.5 * cos(6.28318530718 * (glow_hue + vec3(0.0, 0.33, 0.67) + iTime * 0.05));
	return c + glow * edge * edge_glow * (0.6 + audio_level);
}
"""

const _BREATHING := """// @camera
uniform float depth : hint_range(0.0, 0.2, 0.001) = 0.06;
uniform float rate : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float bass_boost : hint_range(0.0, 2.0, 0.01) = 0.5;
vec3 camera_fx(vec2 uv) {
	float breath = 0.5 + 0.5 * sin(iTime * rate * 6.28318530718);
	float z = 1.0 - depth * (breath + audio_bass * bass_boost);
	return view_color(clamp((uv - 0.5) * z + 0.5, 0.0, 1.0));
}
"""

## The compute shader around an effect. Bindings: the eye's colour image
## (written), a copy of it (sampled: view_color), the audio texture, and a
## buffer with the effect's params followed by the masks.
const _HEAD := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D view_tex;
layout(set = 0, binding = 2) uniform sampler2D audio_tex;
layout(set = 0, binding = 3, std430) restrict readonly buffer Data { float v[]; } data;
layout(push_constant, std430) uniform Push {
	vec2 size;
	float time;
	float fx_strength;
	vec4 audio;
	int fx_eye;
	int mask_count;
	int mask_offset;
	int pad;
} pc;
#define iTime pc.time
#define iResolution vec3(pc.size, 1.0)
#define strength pc.fx_strength
#define eye pc.fx_eye
#define audio_level pc.audio.x
#define audio_bass pc.audio.y
#define audio_mid pc.audio.z
#define audio_high pc.audio.w
vec3 view_color(vec2 uv) { return textureLod(view_tex, uv, 0.0).rgb; }
float audio_spectrum(float x) { return textureLod(audio_tex, vec2(clamp(x, 0.0, 1.0), 0.25), 0.0).r; }
"""

const _TAIL := """
// Masks: quads (4 uv corners each, in order) left untouched, like menus.
bool in_mask(vec2 p) {
	for (int m = 0; m < pc.mask_count; m++) {
		int o = pc.mask_offset + m * 8;
		bool inside = true;
		float sgn = 0.0;
		for (int i = 0; i < 4; i++) {
			vec2 a = vec2(data.v[o + i * 2], data.v[o + i * 2 + 1]);
			int j = (i + 1) % 4;
			vec2 b = vec2(data.v[o + j * 2], data.v[o + j * 2 + 1]);
			float c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
			if (sgn == 0.0) {
				sgn = sign(c);
			} else if (sign(c) != sgn && c != 0.0) {
				inside = false;
			}
		}
		if (inside) {
			return true;
		}
	}
	return false;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(pc.size.x) || px.y >= int(pc.size.y)) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / pc.size;
	if (in_mask(uv)) {
		return;
	}
	vec4 base = imageLoad(color_image, px);
	vec3 fx = camera_fx(uv);
	imageStore(color_image, px, vec4(mix(base.rgb, fx, clamp(pc.fx_strength, 0.0, 1.0)), base.a));
}
"""

## Copies the eye's image into the sampled copy (a compute pass, so it
## works whatever the colour buffer's copy flags).
const COPY_SOURCE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_image;
layout(push_constant, std430) uniform Push { vec2 size; vec2 pad; } pc;
void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (px.x >= int(pc.size.x) || px.y >= int(pc.size.y)) {
		return;
	}
	imageStore(dst_image, px, imageLoad(src_image, px));
}
"""


## [{key, label}] for a dropdown: built-ins first, then `// @camera` files
## in the shaders folders. Doesn't include a "none" entry.
static func list_options(dirs: Array[String] = VisualizerShaders.search_dirs()) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in BUILTINS:
		out.append({"key": key, "label": BUILTINS[key][0]})
	for dir in dirs:
		var d := DirAccess.open(dir)
		if d == null:
			continue
		var files := Array(d.get_files())
		files.sort()
		for f in files:
			var path := dir.path_join(f)
			if String(f).get_extension().to_lower() in EXTENSIONS and is_camera_code(FileAccess.get_file_as_string(path)):
				out.append({"key": path, "label": String(f).get_basename()})
	return out


static func is_camera_code(code: String) -> bool:
	return code.contains(CAMERA_HINT)


## The effect's source for `key` ("" if unreadable).
static func code_for(key: String) -> String:
	if BUILTINS.has(key):
		return BUILTINS[key][1]
	if key == "" or not FileAccess.file_exists(key):
		return ""
	return FileAccess.get_file_as_string(key)


## The effect's sliders: VisualizerShaders.parse_hints params, capped.
static func params_of(code: String) -> Array:
	return VisualizerShaders.parse_hints(code).params.slice(0, MAX_PARAMS)


## The full compute shader for an effect: the hinted uniforms become reads
## from the data buffer (data.v[i], in params_of order), everything else is
## the effect's own code between the provided head and the pass's main().
static func build_source(code: String) -> String:
	return _prefix(code) + _body(code) + "\n" + _TAIL


## Everything before the effect's own code (its first line is the line
## after this).
static func _prefix(code: String) -> String:
	var params := params_of(code)
	var defines := ""
	for i in params.size():
		var p: Dictionary = params[i]
		match String(p.type):
			"bool": defines += "#define %s (data.v[%d] > 0.5)\n" % [p.name, i]
			"int": defines += "#define %s int(data.v[%d])\n" % [p.name, i]
			_: defines += "#define %s data.v[%d]\n" % [p.name, i]
	return _HEAD + defines + "\n"


## The effect's code with its hinted uniform lines blanked (the lines stay,
## so error line numbers still match the file).
static func _body(code: String) -> String:
	var params := params_of(code)
	var uniform_re := RegEx.create_from_string("(?m)^\\s*uniform\\s+(float|int|bool)\\s+(\\w+)[^;]*;[^\\n]*$")
	var body := code
	for m in uniform_re.search_all(code):
		if params.any(func(p): return p.name == m.get_string(2)):
			body = body.replace(m.get_string(0), "")
	return body


## The compiler's first error as "line N: message", N counted in the
## effect's own file ("" if `raw` has none).
static func explain_error(code: String, raw: String) -> String:
	var offset := _prefix(code).count("\n")
	var re := RegEx.create_from_string("ERROR:\\s*\\d+:(\\d+):\\s*(.*)")
	for line in raw.split("\n"):
		var m := re.search(line)
		if m != null:
			var n := int(m.get_string(1)) - offset
			var msg := m.get_string(2).strip_edges()
			return ("line %d: %s" % [n, msg]) if n > 0 else msg
	return raw.strip_edges().get_slice("\n", 0)


## The params' values in buffer order (`specs` from params_of):
## `values[name]`, else the default.
static func param_values(specs: Array, values: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for p in specs:
		var v = values.get(p.name, p.default)
		if p.type == "bool":
			out.append(1.0 if bool(v) else 0.0)
		else:
			out.append(float(v))
	return out
