// Kaleidoscope that cuts to a new symmetry on every downbeat (6, 8, 10 then
// 12 mirrors over four bars), kicks inward on each beat and turns a notch
// per beat. Colours shift per bar and brighten on the beat.
// Without a beat grid it turns slowly and kicks with the bass.
shader_type canvas_item;
#include "res://player/visualizer/shadertoy_prelude.gdshaderinc"

uniform float zoom_kick : hint_range(0.0, 0.6, 0.01) = 0.22;
uniform float detail : hint_range(3.0, 9.0, 1.0) = 6.0;
uniform float turn : hint_range(0.0, 0.5, 0.01) = 0.08;
uniform float brightness : hint_range(0.2, 3.0, 0.05) = 1.0;

vec3 kaleido_palette(float t) {
	return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.1, 0.4, 0.7)));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	bool grid = beat_bpm > 0.0;
	float beat = grid ? beat_time : iTime * 1.2;
	float phase = fract(beat);
	float kick = grid ? exp(-phase * 4.0) : audio_bass;
	float bar = grid ? bar_time : beat / 4.0;
	float bar_no = floor(bar);

	// A notch of rotation per beat, arriving quickly.
	float ang = turn * (floor(beat) + 1.0 - pow(1.0 - phase, 3.0)) * 6.28318;
	float c = cos(ang);
	float s = sin(ang);
	p = mat2(vec2(c, s), vec2(-s, c)) * p;
	p *= 1.0 - zoom_kick * kick;

	// Mirror into one wedge.
	float segs = 6.0 + 2.0 * mod(bar_no, 4.0);
	float wedge = 6.28318 / segs;
	float r = length(p);
	float a = mod(atan(p.y, p.x), wedge);
	a = abs(a - wedge * 0.5);
	vec2 q = r * vec2(cos(a), sin(a));

	// Fold the wedge on itself a few times; the orbit paints the colour.
	vec2 shift = vec2(0.72 + 0.08 * sin(bar * 1.5708), 0.38 + 0.06 * cos(bar * 1.5708));
	vec3 col = vec3(0.0);
	float trap = 1e9;
	for (int i = 0; i < 9; i++) {
		if (float(i) >= detail) {
			break;
		}
		q = abs(q) / max(dot(q, q), 0.05) - shift;
		float d = length(q);
		trap = min(trap, abs(q.y) + 0.5 * abs(q.x - 0.3));
		col += kaleido_palette(d * 0.15 + bar_no * 0.19 + float(i) * 0.07) * exp(-d * 4.0) * 0.5;
	}
	col += kaleido_palette(bar_no * 0.19 + 0.5) * exp(-trap * 25.0) * (0.5 + 1.8 * kick);
	col = pow(col, vec3(1.6));
	col *= brightness * (0.6 + 0.8 * kick) * smoothstep(1.3, 0.15, r);
	col = 1.0 - exp(-col * 1.5);
	fragColor = vec4(col, 1.0);
}

#include "res://player/visualizer/shadertoy_main.gdshaderinc"
