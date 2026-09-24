// A halo around the picture, made from the picture itself and brightened,
// and a brightening just inside its edge. Put a Padding effect before it:
// the halo draws in the transparent margin around the picture.
//
// Sizes are fractions of the picture, per axis. At `intensity` 0 there's no
// halo at all, so screens can sit edge to edge. It follows the picture's
// outline, rounded by a Rounded corners effect before it.
//
// Halo: `radius` is how far it reaches, `power` how fast it fades there.
//
// Looks — the halo's colour is a blend of these (weights, normalised):
//   mirror — the strip `mirror_width` in from the edge, reflected outward
//            back and forth (width 1: the whole picture)
//   repeat — the strip `repeat_width` in from the edge, copied outward over
//            and over (shifted, not flipped)
//            Both strips: `_near` is the weight at the border, `_far` at
//            the halo's reach; `_depth` is how fast they run through the
//            strip going out (< 1 slower, stretched)
//   smear  — the nearest edge colour pushed straight out
//   rays   — streaks from the edge toward the picture's centre,
//            `ray_length` long
//
// Colour: `bloom` lets bright parts of the picture dominate, `saturation`
// is eased in over the halo's first stretch.
//
// Softness: `blur` is how blurred the looks are at the halo's reach (less
// at the border; `border_blur` scales that), over `samples` taps.
// `soften` blurs the finished halo to merge its layers.
//
// Picture edge: `inner_strength` / `inner_width` brighten a band just
// inside it, `edge_blur` is how far in the picture fades into the halo's
// colour. The picture itself is never blurred.
//
// The halo is soft, so it's worked out in the prepass at `prepass_scale` of
// the pass's size; the full-size pass keeps the picture sharp and lays it
// over the (upscaled, softened) halo.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/effect_prelude.gdshaderinc"

group_uniforms halo;
uniform float intensity : hint_range(0.0, 4.0, 0.01) = 1.6;
uniform vec3 tint : source_color = vec3(1.0);
uniform float radius : hint_range(0.01, 2.0, 0.01) = 0.64;
uniform float power : hint_range(0.5, 6.0, 0.1) = 2.0;
group_uniforms mirror;
uniform float mirror_near : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float mirror_far : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float mirror_width : hint_range(0.01, 1.0, 0.01) = 1.0;
uniform float mirror_depth : hint_range(0.1, 2.0, 0.01) = 1.0;
group_uniforms repeat;
uniform float repeat_near : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float repeat_far : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float repeat_width : hint_range(0.01, 1.0, 0.01) = 0.1;
uniform float repeat_depth : hint_range(0.1, 2.0, 0.01) = 1.0;
group_uniforms smear_and_rays;
uniform float smear : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float rays : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float ray_length : hint_range(0.05, 1.0, 0.01) = 0.3;
group_uniforms colour;
uniform float bloom : hint_range(0.0, 3.0, 0.05) = 0.0;
uniform float saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
group_uniforms softness;
uniform float blur : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float border_blur : hint_range(0.5, 4.0, 0.05) = 1.0;
uniform float soften : hint_range(0.0, 0.3, 0.005) = 0.0;
uniform int samples : hint_range(8, 96) = 24;
group_uniforms picture_edge;
uniform float inner_strength : hint_range(0.0, 2.0, 0.01) = 0.3;
uniform float inner_width : hint_range(0.001, 0.8, 0.001) = 0.12;
uniform float edge_blur : hint_range(0.0, 0.2, 0.001) = 0.05;
group_uniforms;
uniform float prepass_scale : hint_range(0.1, 1.0, 0.05) = 0.35;
uniform sampler2D prepass_tex : filter_linear, repeat_disable;
uniform bool prepass = false;

const float GOLDEN_ANGLE = 2.39996323;
const int RAY_SAMPLES = 32;
const int SOFTEN_SAMPLES = 24;
// The blur at the border, as a fraction of `blur` (it reaches all of it at `radius`).
const float EDGE_SPREAD = 0.1;
// Saturation reaches its full amount this far into the halo (a fraction of `radius`).
const float SATURATION_RAMP = 0.3;

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Picture coordinates mirrored back into 0..1 at its edges.
vec2 fold(vec2 q) {
	return 1.0 - abs(mod(q, 2.0) - 1.0);
}

// The picture around p (mirrored back in where p is outside it),
// Gaussian-blurred over a disc `spread` across.
vec3 disc(vec2 p, float spread, vec2 vmin, vec2 size, vec2 texel) {
	vec3 sum = vec3(0.0);
	float sum_w = 0.0;
	for (int i = 0; i < samples; i++) {
		float d = sqrt((float(i) + 0.5) / float(samples));
		float ang = float(i) * GOLDEN_ANGLE;
		vec2 sp = clamp(fold(p + vec2(cos(ang), sin(ang)) * d * spread), texel, 1.0 - texel);
		vec3 col = texture(input_tex, vmin + sp * size).rgb;
		float w = exp(-3.0 * d * d);
		if (bloom > 0.0) {
			w *= pow(luma(col) + 0.02, bloom);
		}
		sum += col * w;
		sum_w += w;
	}
	return sum / max(sum_w, 0.00001);
}

// How far in from the edge a strip look samples at `x` out: the strip
// `width` deep, run through `depth` times as fast as going out, reflected
// back and forth (mirror) or copied over and over (tiled).
float strip(float x, float width, float depth, bool tiled) {
	x *= depth;
	return tiled ? width - mod(x, width) : width - abs(mod(x, 2.0 * width) - width);
}

// Streaks from edge point `ep` toward the picture's centre.
vec3 ray(vec2 ep, float t, vec2 vmin, vec2 size, vec2 texel) {
	vec2 reach = (vec2(0.5) - ep) * 2.0 * ray_length * (0.3 + 0.7 * t);
	vec3 sum = vec3(0.0);
	float sum_w = 0.0;
	for (int i = 0; i < RAY_SAMPLES; i++) {
		float s = (float(i) + 0.5) / float(RAY_SAMPLES);
		vec2 sp = clamp(ep + reach * s, texel, 1.0 - texel);
		float w = exp(-3.0 * s * s);
		sum += texture(input_tex, vmin + sp * size).rgb * w;
		sum_w += w;
	}
	return sum / sum_w;
}

// The halo's colour `x` out from outline point `ep`, whose outward
// direction is `n` (t: 0 at the border, 1 at `radius`).
vec3 halo_colour(vec2 ep, vec2 n, float x, float t, float spread, vec2 vmin, vec2 size, vec2 texel) {
	float wm = mix(mirror_near, mirror_far, t);
	float wr = mix(repeat_near, repeat_far, t);
	vec3 sum = vec3(0.0);
	float total = 0.0;
	if (wm > 0.0) {
		sum += wm * disc(ep - n * strip(x, mirror_width, mirror_depth, false), spread, vmin, size, texel);
		total += wm;
	}
	if (wr > 0.0) {
		sum += wr * disc(ep - n * strip(x, repeat_width, repeat_depth, true), spread, vmin, size, texel);
		total += wr;
	}
	if (smear > 0.0) {
		sum += smear * disc(ep, spread, vmin, size, texel);
		total += smear;
	}
	if (rays > 0.0) {
		sum += rays * ray(ep, t, vmin, size, texel);
		total += rays;
	}
	if (total <= 0.0) {
		sum = disc(ep, spread, vmin, size, texel);
		total = 1.0;
	}
	vec3 c = sum / total;
	float s = mix(1.0, saturation, smoothstep(0.0, SATURATION_RAMP, t));
	return max(mix(vec3(luma(c)), c, s), vec3(0.0));
}

// The prepass halo at `uv`, Gaussian-blurred over a disc `soften` across.
// Colour is averaged by coverage, so empty texels don't darken it; where a
// tap lands on the picture it counts as covered (the picture's opaque there).
vec4 halo_at(vec2 uv, vec2 vmin, vec2 size) {
	if (soften <= 0.0) {
		return texture(prepass_tex, uv);
	}
	vec3 rgb = vec3(0.0);
	float rgb_w = 0.0;
	float a = 0.0;
	float sum_w = 0.0;
	for (int i = 0; i < SOFTEN_SAMPLES; i++) {
		float d = sqrt((float(i) + 0.5) / float(SOFTEN_SAMPLES));
		float ang = float(i) * GOLDEN_ANGLE;
		vec2 tap = uv + vec2(cos(ang), sin(ang)) * d * soften * size;
		vec4 c = texture(prepass_tex, tap);
		vec2 edge;
		vec2 normal;
		bool on_picture = picture_outline((tap - vmin) / size, edge, normal) <= 0.0;
		float w = exp(-3.0 * d * d);
		rgb += c.rgb * c.a * w;
		rgb_w += c.a * w;
		a += (on_picture ? 1.0 : c.a) * w;
		sum_w += w;
	}
	return vec4(rgb / max(rgb_w, 0.00001), a / sum_w);
}

void fragment() {
	vec2 vmin = picture_rect.xy;
	vec2 size = max(picture_rect.zw, vec2(0.0001));
	// Keeps edge samples off the transparent texels around the picture.
	vec2 texel = 0.5 / (vec2(textureSize(input_tex, 0)) * size);
	vec2 p = (UV - vmin) / size;  // picture coordinates, 0..1 inside
	vec2 ep;  // nearest point on the picture's outline
	vec2 n;   // outward there
	float sd = picture_outline(p, ep, n);
	float dist = sd > 0.0 ? length(p - ep) : 0.0;  // how far outside
	float e = max(-sd, 0.0);  // how far inside

	if (prepass) {
		// The halo outside; inside, near the border, the colour the picture
		// fades into there (the halo's at the nearest border point), which
		// also backs the picture's own soft edge (a Rounded corners feather).
		vec4 out_c = vec4(0.0);
		float border_spread = blur * EDGE_SPREAD * border_blur;
		if (intensity > 0.0) {
			if (sd > 0.0) {
				float t = clamp(dist / max(radius, 0.0001), 0.0, 1.0);
				vec3 halo = halo_colour(ep, n, dist, t, mix(border_spread, blur, t), vmin, size, texel);
				float falloff = pow(1.0 - smoothstep(0.0, 1.0, t), power);
				// Coverage fades with intensity, so a screen at 0 has no dark rim.
				out_c = vec4(halo * tint * intensity, falloff * clamp(intensity, 0.0, 1.0));
			} else if (e < edge_blur * 1.5 + 0.02) {
				out_c = vec4(halo_colour(ep, n, 0.0, 0.0, border_spread, vmin, size, texel) * tint * intensity, 1.0);
			}
		}
		COLOR = out_c;
	} else if (sd > 0.0) {
		COLOR = halo_at(UV, vmin, size);
	} else {
		vec4 c = texture(input_tex, UV);
		float edge = 1.0 - smoothstep(0.0, max(inner_width, 0.0001), e);
		vec3 rgb = c.rgb + c.rgb * tint * edge * inner_strength;
		// Fades into the colour the halo starts with, so there's no step at
		// the border (none at intensity 0: no halo).
		float k = edge_blur > 0.0 ? (1.0 - smoothstep(0.0, edge_blur, e)) * clamp(intensity, 0.0, 1.0) : 0.0;
		if (k > 0.0 || c.a < 1.0) {
			vec4 h = halo_at(UV, vmin, size);
			rgb = mix(rgb, h.rgb, k);
			// Where the picture is see-through (its soft edge), the halo
			// shows behind it.
			float a = c.a + h.a * (1.0 - c.a);
			rgb = a > 0.0 ? (rgb * c.a + h.rgb * h.a * (1.0 - c.a)) / a : vec3(0.0);
			c.a = a;
		}
		COLOR = vec4(rgb, c.a);
	}
}
