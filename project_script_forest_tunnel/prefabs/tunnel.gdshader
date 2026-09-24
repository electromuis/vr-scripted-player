// Light tunnel: glowing rings that rush past plus streaks running along the
// tube. Drawn from inside a long open cylinder (UV.x = around, UV.y = along).
//
// Motion comes from `scroll` (in rings), which the script keyframes — not
// from TIME — so the tunnel is deterministic when scrubbing, and ramping
// the keyframe slope speeds it up without jumps.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color_a : source_color = vec3(0.1, 0.55, 1.0);
uniform vec3 color_b : source_color = vec3(1.0, 0.25, 0.85);
uniform float scroll = 0.0;
uniform float ring_count = 100.0;
uniform float ring_width : hint_range(0.01, 0.5) = 0.08;
uniform float streaks = 18.0;
uniform float intensity : hint_range(0.0, 4.0) = 1.4;
// Fraction of brightness kept at 100 m (depth falloff).
uniform float far_fade : hint_range(0.0, 1.0) = 0.15;

void fragment() {
	float along = UV.y * ring_count + scroll;
	float ring = 1.0 - smoothstep(0.0, ring_width, abs(fract(along) - 0.5));
	float streak = pow(abs(sin(UV.x * PI * streaks + along * 0.05)), 60.0);
	float hue = 0.5 + 0.5 * sin(along * 0.12 + UV.x * TAU);
	vec3 col = mix(color_a, color_b, hue);
	float depth = pow(far_fade, length(VERTEX) / 100.0);
	ALBEDO = col * (0.06 + ring + 0.6 * streak) * intensity * depth;
}
