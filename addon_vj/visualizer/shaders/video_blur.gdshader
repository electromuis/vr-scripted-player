// The playing video, heavily blurred: lock it slightly behind and larger
// than the screen for a glow around an edge-blurred video. Renders small
// (it's all blur anyway); `radius` is the blur's reach as a fraction of
// the picture's height, and each eye of a stereo video is blurred on its own.
// @iChannel1 video
// @resolution 270
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/shadertoy_prelude.gdshaderinc"

uniform float radius : hint_range(0.0, 0.5, 0.005) = 0.12;
uniform float brightness : hint_range(0.0, 3.0, 0.01) = 1.0;
uniform float saturation : hint_range(0.0, 2.0, 0.01) = 1.0;

const int SAMPLES = 128;
const float GOLDEN_ANGLE = 2.39996323;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	uv.y = 1.0 - uv.y;  // the video's top row is v = 0
	// This eye's part of the frame, to clamp samples to.
	vec2 lo = vec2(0.0);
	vec2 hi = vec2(1.0);
	if (video_stereo == 1) {
		lo.x = uv.x < 0.5 ? 0.0 : 0.5;
		hi.x = lo.x + 0.5;
	} else if (video_stereo == 2) {
		lo.y = uv.y < 0.5 ? 0.0 : 0.5;
		hi.y = lo.y + 0.5;
	}
	// Radius in the eye's height, round in pixels (the frame renders at
	// the video's shape).
	float r = radius * (hi.y - lo.y);
	vec2 scale = vec2(r * iResolution.y / iResolution.x, r);
	// Gaussian-weighted disc on a golden-angle spiral, turned per pixel so
	// the sparse taps average out instead of showing as a pattern.
	float spin = 6.2831853 * fract(52.9829189 * fract(dot(fragCoord, vec2(0.06711056, 0.00583715))));
	vec2 half_px = 0.5 / iResolution.xy;
	vec3 sum = vec3(0.0);
	float sum_w = 0.0;
	for (int i = 0; i < SAMPLES; i++) {
		float t = (float(i) + 0.5) / float(SAMPLES);
		float d = sqrt(t);
		float ang = float(i) * GOLDEN_ANGLE + spin;
		vec2 p = clamp(uv + vec2(cos(ang), sin(ang)) * d * scale, lo + half_px, hi - half_px);
		float w = exp(-3.0 * d * d);
		sum += texture(iChannel1, p).rgb * w;
		sum_w += w;
	}
	vec3 col = sum / sum_w;
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(luma), col, saturation) * brightness;
	fragColor = vec4(col, 1.0);
}

#include "res://addons/vj_editor/visualizer/shadertoy_main.gdshaderinc"
