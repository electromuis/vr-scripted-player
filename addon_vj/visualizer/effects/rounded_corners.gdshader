// Rounds the picture's corners by cutting them away in alpha. `radius_x` /
// `radius_y` are each corner's width / height, in fractions of the
// picture's height, capped at half the picture. The corners ease into the
// sides (see CORNER_EXPONENT), so they stay smooth however unequal the
// radii. `feather` is the width of the soft edge, in the same units; for a
// wide, blurry edge put an Edge blur after it. Effects after it (a Glow)
// follow the rounded outline. After a Padding the corners are the
// picture's, not the margin's.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/effect_prelude.gdshaderinc"

uniform float radius_x : hint_range(0.0, 2.0, 0.005) = 0.1;
uniform float radius_y : hint_range(0.0, 2.0, 0.005) = 0.1;
uniform float feather : hint_range(0.0, 0.3, 0.001) = 0.003;

void fragment() {
	vec4 c = texture(input_tex, UV);
	vec2 size = max(picture_rect.zw, vec2(0.0001));
	// The picture's half-size and this point's offset from its centre, in
	// picture heights.
	vec2 half_ext = vec2(display_aspect * size.x / size.y, 1.0) * 0.5;
	vec2 pos = ((UV - picture_rect.xy) / size - 0.5) * half_ext * 2.0;
	vec2 edge;
	vec2 normal;
	float d = outline(pos, half_ext, vec2(radius_x, radius_y), edge, normal);
	float mask = clamp(0.5 - d / max(feather, 0.0005), 0.0, 1.0);
	COLOR = vec4(c.rgb, c.a * mask);
}
