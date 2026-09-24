// Above the clouds: blue sky with scattered clouds overhead and a bright
// cloud sea below the horizon.
shader_type sky;

#include "res://player/settings/skies/sky_noise.gdshaderinc"

void sky() {
	vec3 d = EYEDIR;
	vec3 sun = normalize(vec3(0.4, 0.35, -0.8));
	float s = max(dot(d, sun), 0.0);
	vec3 zenith = vec3(0.16, 0.36, 0.78);
	vec3 horizon = vec3(0.72, 0.83, 0.95);

	vec3 col = mix(horizon, zenith, pow(clamp(d.y, 0.0, 1.0), 0.5));
	col += vec3(1.0, 0.9, 0.7) * (pow(s, 800.0) * 6.0 + pow(s, 10.0) * 0.25);

	if (d.y > 0.0) {
		// Cloud layer overhead, projected onto a plane; fades out toward
		// the horizon where the projection would stretch and shimmer.
		vec2 uv = d.xz / (d.y + 0.12) * 1.2;
		float c = fbm(vec3(uv, 0.5));
		float cover = smoothstep(0.5, 0.75, c) * smoothstep(0.0, 0.2, d.y);
		vec3 cloud = mix(vec3(0.74, 0.78, 0.86), vec3(1.0), smoothstep(0.55, 0.85, c));
		col = mix(col, cloud, cover * 0.9);
	} else {
		vec2 uv = d.xz / (-d.y + 0.06) * 0.8;
		float c = fbm(vec3(uv, 3.1));
		vec3 sea = mix(vec3(0.70, 0.75, 0.84), vec3(1.0, 0.98, 0.95), smoothstep(0.35, 0.75, c));
		col = mix(horizon, sea, smoothstep(0.0, 0.1, -d.y));
	}
	COLOR = col;
}
