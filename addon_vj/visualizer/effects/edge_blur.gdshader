// Softens the edges of whatever is already cut out by alpha (by Key black,
// an Oval mask, or a shader's own transparency): alpha is blurred over
// `radius`, the width of the soft edge as a fraction of the screen's height.
// With `inward` the fade stays inside the original shape (the edge goes to
// 0, `radius` in is fully back); without, it's centred on the edge and also
// spreads out, taking the nearby visible colour. Solid areas are untouched.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/effect_prelude.gdshaderinc"

uniform bool inward = true;
uniform float radius : hint_range(0.0, 0.5, 0.005) = 0.05;

const int SAMPLES = 96;
const float GOLDEN_ANGLE = 2.39996323;

void fragment() {
	vec4 c = texture(input_tex, UV);
	float r = inward ? radius : radius * 0.5;
	if (r <= 0.0) {
		COLOR = c;
	} else {
		// Gaussian-weighted disc of samples on a golden-angle spiral, in
		// screen-height units so the edge is the same width both ways.
		vec2 scale = vec2(r / display_aspect, r);
		float sum_a = 0.0;
		vec3 sum_rgb = vec3(0.0);
		float sum_w = 0.0;
		for (int i = 0; i < SAMPLES; i++) {
			float t = (float(i) + 0.5) / float(SAMPLES);
			float d = sqrt(t);
			float ang = float(i) * GOLDEN_ANGLE;
			vec4 s = texture(input_tex, UV + vec2(cos(ang), sin(ang)) * d * scale);
			float w = exp(-4.0 * d * d);
			sum_a += s.a * w;
			sum_rgb += s.rgb * s.a * w;
			sum_w += w;
		}
		float blurred = sum_a / sum_w;
		if (inward) {
			// A straight edge blurs to 0.5 on the edge itself; remap so that's
			// 0 and never add alpha where there was none.
			COLOR = vec4(c.rgb, min(c.a, clamp(blurred * 2.0 - 1.0, 0.0, 1.0)));
		} else {
			// Outside the original shape there's no colour of its own, so use
			// the alpha-weighted average of what's nearby.
			vec3 near = sum_a > 0.0 ? sum_rgb / sum_a : vec3(0.0);
			COLOR = vec4(mix(near, c.rgb, c.a), blurred);
		}
	}
}
