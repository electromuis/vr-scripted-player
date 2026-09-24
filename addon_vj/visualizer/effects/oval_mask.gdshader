// Sets the alpha on one side of an oval, centred on the screen, to `level`:
// 0 cuts that part away, 1 makes it solid (undoing an earlier Key black
// there, black included). `size` is the oval's height as a fraction of the
// screen's, `ratio` its width / height (1.78 fits a 16:9 screen) and `blur`
// the width of the soft edge, in the same units as size.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/effect_prelude.gdshaderinc"

uniform bool outside = true;
uniform float size : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float ratio : hint_range(0.25, 4.0, 0.01) = 1.78;
uniform float blur : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float level : hint_range(0.0, 1.0, 0.01) = 0.0;

void fragment() {
	vec4 c = texture(input_tex, UV);
	vec2 p = (UV - 0.5) * vec2(display_aspect, 1.0);
	float d = length(p / vec2(max(ratio, 0.01), 1.0));
	float r = size * 0.5;
	float f = max(blur, 0.0001) * 0.5;
	float inside = 1.0 - smoothstep(r - f, r + f, d);
	float m = outside ? 1.0 - inside : inside;
	// Premultiplied colour and alpha, each pulled toward the level.
	float a = mix(c.a, level, m);
	vec3 premul = c.rgb * c.a * mix(1.0, level, m);
	COLOR = vec4(a > 0.0 ? premul / a : vec3(0.0), a);
}
