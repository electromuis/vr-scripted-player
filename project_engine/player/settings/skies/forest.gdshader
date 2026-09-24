// Forest clearing: morning sky, hazy mountains, two rings of conifer
// silhouettes and a dark forest floor.
shader_type sky;

#include "res://player/settings/skies/sky_noise.gdshaderinc"

// Silhouette edge softness, in radians of elevation (~0.1°).
const float EDGE = 0.002;

// Height (radians of elevation) of a ring of `count` conifers at azimuth
// `az`. Each tree is a triangle; neighbours are checked so they overlap.
float tree_line(float az, float count, float base, float tall, float seed) {
	float x = (az / TAU + 0.5) * count;
	float h = 0.0;
	for (int k = -1; k <= 1; k++) {
		float cell = mod(floor(x) + float(k), count);
		float r = hash13(vec3(cell, seed, 1.0));
		float centre = floor(x) + float(k) + 0.5 + (hash13(vec3(cell, seed, 2.0)) - 0.5) * 0.5;
		float height = base + tall * (0.4 + 0.6 * r);
		float width = 0.35 + 0.35 * hash13(vec3(cell, seed, 3.0));
		float profile = 1.0 - abs(x - centre) / width;
		// Branch tiers: a small sawtooth notch down the sides.
		profile -= 0.06 * fract(profile * 6.0);
		h = max(h, height * profile);
	}
	return h;
}

void sky() {
	vec3 d = EYEDIR;
	float elev = asin(clamp(d.y, -1.0, 1.0));
	float az = atan(d.x, -d.z);
	vec2 ring = vec2(cos(az), sin(az));  // seamless around the full circle

	vec3 sun = normalize(vec3(-0.5, 0.25, -0.8));
	float s = max(dot(d, sun), 0.0);
	vec3 zenith = vec3(0.32, 0.52, 0.80);
	vec3 horizon = vec3(0.86, 0.86, 0.80);
	vec3 col = mix(horizon, zenith, pow(clamp(d.y, 0.0, 1.0), 0.6));
	col += vec3(1.0, 0.85, 0.6) * (pow(s, 600.0) * 5.0 + pow(s, 6.0) * 0.3);

	// Soft high clouds.
	if (d.y > 0.0) {
		float c = fbm(vec3(d.xz / (d.y + 0.2) * 1.5, 2.0));
		col = mix(col, vec3(0.95), smoothstep(0.55, 0.8, c) * smoothstep(0.05, 0.3, d.y) * 0.6);
	}

	float mountains = 0.05 + 0.09 * fbm(vec3(ring * 2.5, 4.0));
	col = mix(col, mix(horizon, vec3(0.42, 0.52, 0.60), 0.6), smoothstep(mountains + EDGE, mountains - EDGE, elev));

	float back = tree_line(az, 200.0, 0.05, 0.08, 11.0) - 0.004;
	col = mix(col, vec3(0.12, 0.22, 0.2), smoothstep(back + EDGE, back - EDGE, elev));

	float front = tree_line(az, 90.0, 0.09, 0.16, 23.0) - 0.008;
	col = mix(col, vec3(0.015, 0.05, 0.03), smoothstep(front + EDGE, front - EDGE, elev));

	if (elev < 0.0) {
		float g = fbm(vec3(d.xz / (-d.y + 0.05) * 3.0, 6.0));
		vec3 ground = mix(vec3(0.05, 0.09, 0.04), vec3(0.12, 0.16, 0.07), g);
		col = mix(col, ground, smoothstep(0.0, 0.03, -elev));
	}
	COLOR = col;
}
