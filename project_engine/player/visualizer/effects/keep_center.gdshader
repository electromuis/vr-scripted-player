// Keeps the middle of a scaled-up picture near its original size and
// stretches the rest out to the edges instead. Set `zoom` to how much the
// screen or layer was scaled up (its Size): the middle `center` of the
// picture (a fraction of its width and height) is shrunk by that much, so
// it looks as it did at size 1, and the outer part fills the remaining
// room. `softness` blends the two zones instead of meeting at a crease.
// `horizontal` / `vertical` pick the axes it works along. After a Padding
// it warps the picture, not the margin.
shader_type canvas_item;
#include "res://player/visualizer/effect_prelude.gdshaderinc"

uniform float zoom : hint_range(1.0, 6.0, 0.01) = 2.0;
uniform float center : hint_range(0.0, 0.95, 0.01) = 0.5;
uniform float softness : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform bool horizontal = true;
uniform bool vertical = true;

// Output distance from the middle (0 middle, 1 edge) -> picture distance.
// The slope is `zoom` in the middle (shrinking it) and a smaller one
// outside (stretching the rest), switching around the middle zone's edge
// with a smoothstep; this is the integral of that slope. It maps 1 to 1,
// so the picture's edges stay where they are.
float warp(float x) {
	float c = clamp(center, 0.0, 0.95);
	float k = max(zoom, 1.0);
	float xc = c / k;  // where the middle zone ends on screen
	float outer = (1.0 - c) / max(1.0 - xc, 0.0001);
	float h = clamp(softness, 0.0, 1.0) * min(xc, 1.0 - xc);
	float past;  // integral of the switch from 0 (middle slope) to 1 (outer slope)
	if (h < 0.00001) {
		past = max(x - xc, 0.0);
	} else {
		float w = 2.0 * h;
		float t = clamp((x - (xc - h)) / w, 0.0, 1.0);
		past = w * (t * t * t - 0.5 * t * t * t * t) + max(x - (xc + h), 0.0);
	}
	return k * x + (outer - k) * past;
}

void fragment() {
	vec2 size = max(picture_rect.zw, vec2(0.0001));
	vec2 p = (UV - picture_rect.xy) / size - 0.5;  // -0.5..0.5 inside the picture
	vec2 uv = UV;
	if (all(lessThanEqual(abs(p), vec2(0.5)))) {
		vec2 d = abs(p) * 2.0;
		vec2 s = vec2(horizontal ? warp(d.x) : d.x, vertical ? warp(d.y) : d.y);
		uv = picture_rect.xy + (sign(p) * s * 0.5 + 0.5) * size;
	}
	COLOR = texture(input_tex, uv);
}
