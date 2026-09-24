// Spectrum bars along the bottom with the waveform drawn across the middle.
shader_type canvas_item;
#include "res://player/visualizer/shadertoy_prelude.gdshaderinc"

const float BARS = 64.0;

vec3 bar_color(float x) {
	return 0.5 + 0.5 * cos(6.2831 * (x + vec3(0.0, 0.33, 0.67)));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = fragCoord / iResolution.xy;
	float bar = floor(uv.x * BARS);
	float cell = fract(uv.x * BARS);
	// Squared spacing so the bass isn't squeezed into the first few bars.
	float f = pow((bar + 0.5) / BARS, 2.0);
	float level = texture(iChannel0, vec2(f, 0.25)).x;
	vec3 col = vec3(0.0);
	float gap = step(0.15, cell) * step(cell, 0.85);
	if (uv.y < level) {
		col = bar_color(bar / BARS) * gap * (0.4 + 0.6 * uv.y / max(level, 0.001));
	}
	float wave = texture(iChannel0, vec2(uv.x, 0.75)).x;
	col += vec3(0.8) * smoothstep(0.012, 0.0, abs(uv.y - wave));
	fragColor = vec4(col, 1.0);
}

#include "res://player/visualizer/shadertoy_main.gdshaderinc"
