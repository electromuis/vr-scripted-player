// Neon ring tunnel that lunges forward one ring on every beat and coasts
// between beats. Each bar gets its own colours, the ring quarter for the
// current beat of the bar lights up (1-2-3-4 going round), the downbeat
// flashes, and the tunnel twists one way over a bar and back over the next.
// Without a beat grid it drifts forward and pulses with the bass.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/shadertoy_prelude.gdshaderinc"

uniform float glow : hint_range(0.2, 3.0, 0.05) = 1.0;
uniform float twist : hint_range(0.0, 2.0, 0.05) = 0.8;
uniform float lunge : hint_range(0.0, 2.0, 0.05) = 1.0;
uniform bool flash_downbeat = true;

vec3 tunnel_palette(float t) {
	return 0.55 + 0.45 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
	vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
	bool grid = beat_bpm > 0.0;
	float beat = grid ? beat_time : iTime * 2.0;
	float phase = fract(beat);
	float kick = grid ? exp(-phase * 5.0) : audio_bass;
	float bar = grid ? bar_time : beat / 4.0;
	int beat_no = grid ? beat_in_bar : int(mod(floor(beat), 4.0));
	int per_bar = grid ? beats_per_bar : 4;

	// Forward: a fast push right on the beat, easing out before the next.
	float travel = floor(beat) + mix(phase, 1.0 - pow(1.0 - phase, 4.0), clamp(lunge, 0.0, 1.0));
	travel *= max(lunge, 0.5);

	// Twist: out over one bar, back over the next (continuous).
	float swing = abs(fract(bar * 0.5) * 2.0 - 1.0) * 2.0 - 1.0;
	float r = length(uv);
	float a = atan(uv.y, uv.x) + twist * swing + 0.4 * kick * twist;
	float z = 0.9 / max(r, 1e-3);
	float zr = z + travel;
	float ring = floor(zr);
	float d = abs(fract(zr) - 0.5);

	// Ring line: thin core plus a soft halo, faded into the distance.
	float w = fwidth(zr) + 1e-4;
	float core = smoothstep(w * 2.0, 0.0, d - 0.015);
	float halo = 0.008 / (d + 0.008);
	float fade = exp(-z * 0.12) * smoothstep(0.0, 0.05, r);

	// Which quarter (beat of the bar) this pixel's arc belongs to.
	float turn = fract(a / 6.28318 + 0.25);
	int quarter = int(floor(turn * float(per_bar)));
	float lit = quarter == beat_no ? 1.0 + 2.5 * kick : 0.4;
	if (flash_downbeat && beat_no == 0) {
		lit += 1.2 * kick;
	}

	vec3 col = tunnel_palette(ring * 0.09 + floor(bar) * 0.21) * (core * 1.6 + halo * 0.45) * lit * glow * fade;

	// Radial spokes between the rings, pulsing with the beat.
	float spokes = pow(abs(cos(a * float(per_bar) * 2.0)), 40.0) * 0.25 * kick * fade;
	col += tunnel_palette(floor(bar) * 0.21 + 0.5) * spokes;

	// The downbeat flashes the far end of the tunnel.
	if (flash_downbeat && beat_no == 0) {
		col += tunnel_palette(floor(bar) * 0.21 + 0.5) * kick * 1.5 * exp(-r * 9.0);
	}
	col = 1.0 - exp(-col * 1.6);
	fragColor = vec4(col, 1.0);
}

#include "res://addons/vj_editor/visualizer/shadertoy_main.gdshaderinc"
