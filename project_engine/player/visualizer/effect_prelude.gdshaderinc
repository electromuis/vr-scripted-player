// Effect shader prelude (see VisualizerShaders). Include right after
// `shader_type canvas_item;`. An effect runs on a layer's (or the video
// screen's) output, after the layer's shader and any earlier effects:
//   input_tex       — that output; sample it at UV
//   display_aspect  — width / height of the screen it ends up on, for
//                     shapes that must stay round
//   picture_rect    — where the picture itself sits in this pass, as UV
//                     x, y, width, height: all of it, unless a Padding
//                     effect before this one added a margin around it
//   picture_corners — the picture's corner radii (x, y) in picture heights,
//                     from a Rounded corners effect before this one (0:
//                     square); picture_outline() gives the outline
// An effect that declares `uniform sampler2D prepass_tex` also gets a
// prepass: the same shader with `uniform bool prepass` on runs first, at
// `prepass_scale` (a float uniform, default 1) of this pass's size, and its
// output arrives as `prepass_tex`. Put heavy, soft work there.
// COLOR is written as-is with straight (not premultiplied) alpha, which the
// display pass uses as the screen's transparency.
// Uniforms with a hint_range (or bools) get controls in the Camera tab.

render_mode blend_disabled;

uniform sampler2D input_tex : filter_linear, repeat_disable;
uniform float display_aspect = 1.7777778;
uniform vec4 picture_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 picture_corners = vec2(0.0);

// Corners are superellipses (|x/rx|^n + |y/ry|^n = 1): above 2 they ease
// into the straight sides instead of bending sharply where they meet them,
// even with very unequal radii.
const float CORNER_EXPONENT = 4.0;

// Point `pos` (from the centre) against a rectangle of half-size `half_ext`
// with corner radii `r`, all in the same units: returns the signed distance
// to the outline (negative inside; approximate in the corners), and sets
// `edge` to the outline point it's nearest (radially, in the corners) and
// `normal` to the outward direction there (outside: from `edge` to `pos`).
float outline(vec2 pos, vec2 half_ext, vec2 r, out vec2 edge, out vec2 normal) {
	vec2 sg = vec2(pos.x < 0.0 ? -1.0 : 1.0, pos.y < 0.0 ? -1.0 : 1.0);
	vec2 a = abs(pos);
	r = clamp(r, vec2(0.0001), half_ext);
	vec2 inner = half_ext - r;
	vec2 v = a - inner;
	float sd;
	if (v.x > 0.0 && v.y > 0.0) {
		vec2 u = v / r;
		float f = pow(pow(u.x, CORNER_EXPONENT) + pow(u.y, CORNER_EXPONENT), 1.0 / CORNER_EXPONENT);
		vec2 grad = pow(u, vec2(CORNER_EXPONENT - 1.0)) / r * pow(f, 1.0 - CORNER_EXPONENT);
		sd = (f - 1.0) / max(length(grad), 0.000001);
		edge = inner + v / f;
		normal = sd > 0.0 ? normalize(v) : normalize(grad);
	} else if (a.x > half_ext.x || a.y > half_ext.y) {
		edge = min(a, half_ext);
		sd = length(a - edge);
		normal = normalize(a - edge);
	} else if (half_ext.x - a.x < half_ext.y - a.y) {
		edge = vec2(half_ext.x, a.y);
		sd = a.x - half_ext.x;
		normal = vec2(1.0, 0.0);
	} else {
		edge = vec2(a.x, half_ext.y);
		sd = a.y - half_ext.y;
		normal = vec2(0.0, 1.0);
	}
	edge *= sg;
	normal *= sg;
	return sd;
}

// outline() for the picture (`picture_corners` rounded), with p in picture
// coordinates (0..1 inside picture_rect) and distances in fractions of the
// picture, per axis.
float picture_outline(vec2 p, out vec2 edge, out vec2 normal) {
	vec2 size = max(picture_rect.zw, vec2(0.0001));
	float aspect = display_aspect * size.x / size.y;
	float sd = outline(p - 0.5, vec2(0.5), picture_corners / vec2(aspect, 1.0), edge, normal);
	edge += 0.5;
	return sd;
}
