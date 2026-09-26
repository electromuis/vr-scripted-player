// Club lasers: a fan of beams from the bottom that opens and closes once a
// bar and sweeps side to side over two. On every beat a chase lights up
// every fourth beam (which ones follows the beat of the bar), all beams
// flash on the downbeat, and the colour changes each bar. Black
// background: put Key black after it to lay it over the video.
// Without a beat grid the fan drifts and the beams pulse with the bass.
shader_type canvas_item;
#include "res://player/visualizer/shadertoy_prelude.gdshaderinc"

uniform int beams : hint_range(3, 24) = 12;
uniform float spread : hint_range(0.2, 2.5, 0.05) = 1.6;
uniform float width : hint_range(0.5, 4.0, 0.05) = 1.6;
uniform float haze : hint_range(0.0, 1.0, 0.05) = 0.4;
uniform bool mirror = true;

vec3 laser_palette(float t) {
	return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

float hash11(float x) {
	return fract(sin(x * 91.3458) * 47453.5453);
}

// Light from `n` beams leaving `origin` at `base` ± `fan` / 2 radians.
vec3 fan_light(vec2 p, vec2 origin, float base, float fan, int n, float kick, int beat_no, int per_bar, float bar, float dir) {
	vec3 col = vec3(0.0);
	vec2 q = p - origin;
	for (int i = 0; i < 24; i++) {
		if (i >= n) {
			break;
		}
		float k = n > 1 ? float(i) / float(n - 1) - 0.5 : 0.0;
		float ang = base + k * fan;
		vec2 dirv = vec2(sin(ang), cos(ang) * dir);
		float along = dot(q, dirv);
		if (along <= 0.0) {
			continue;
		}
		float across = abs(q.x * dirv.y - q.y * dirv.x);
		// Beams widen a little with distance, like real ones in haze.
		float w = 0.0025 * width * (1.0 + along * 0.8);
		float beam = w / (across + w);
		beam = beam * beam * 1.5;
		float mist = haze * 0.02 / (across + 0.02) * 0.15;
		// Chase: every per_bar-th beam from this beat's lights up.
		bool chased = int(mod(float(i), float(per_bar))) == beat_no;
		float level = chased ? 0.45 + 1.6 * kick : 0.45;
		if (beat_no == 0) {
			level += 0.8 * kick;
		}
		// A little per-beam flicker so the fan doesn't look drawn.
		level *= 0.85 + 0.15 * hash11(float(i) + floor(bar * 16.0));
		vec3 tint = laser_palette(floor(bar) * 0.27 + float(i) * 0.015);
		col += tint * (beam + mist) * level * exp(-along * 0.9);
	}
	return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	bool grid = beat_bpm > 0.0;
	float beat = grid ? beat_time : iTime * 1.5;
	float phase = fract(beat);
	float kick = grid ? exp(-phase * 6.0) : audio_bass;
	float bar = grid ? bar_time : beat / 4.0;
	int beat_no = grid ? beat_in_bar : int(mod(floor(beat), 4.0));
	int per_bar = grid ? beats_per_bar : 4;

	// Open and close once a bar; sweep across and back over two.
	float open = 0.3 + 0.7 * (0.5 - 0.5 * cos(fract(bar) * 6.28318));
	float sweep = 0.45 * sin(bar * 3.14159);
	vec3 col = fan_light(p, vec2(0.0, -0.55), sweep, spread * open, beams, kick, beat_no, per_bar, bar, 1.0);
	if (mirror) {
		// A second fan from the top on alternate bars' beats 3 and 4.
		float on = mod(floor(bar), 2.0) >= 1.0 && beat_no >= per_bar / 2 ? 1.0 : 0.25;
		col += on * fan_light(p, vec2(0.0, 0.55), -sweep, spread * (1.3 - open), beams, kick, (beat_no + 2) % per_bar, per_bar, bar + 0.5, -1.0);
	}
	// Emitter glow.
	col += laser_palette(floor(bar) * 0.27) * 0.01 / (length(p - vec2(0.0, -0.55)) + 0.01) * (0.4 + kick);
	col = 1.0 - exp(-col * 1.4);
	fragColor = vec4(col, 1.0);
}

#include "res://player/visualizer/shadertoy_main.gdshaderinc"
