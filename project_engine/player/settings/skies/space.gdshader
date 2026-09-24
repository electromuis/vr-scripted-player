// Deep space: two star layers, a faint galactic band and coloured nebulae.
shader_type sky;

#include "res://player/settings/skies/sky_noise.gdshaderinc"

// One star per lit grid cell on the direction sphere; `density` is the
// fraction of cells that get a star.
vec3 stars(vec3 d, float scale, float density) {
	vec3 p = d * scale;
	vec3 cell = floor(p);
	float h = hash13(cell);
	if (h < 1.0 - density) {
		return vec3(0.0);
	}
	vec3 jitter = vec3(hash13(cell + 1.3), hash13(cell + 2.7), hash13(cell + 5.1)) - 0.5;
	float dist = length(p - (cell + 0.5 + jitter * 0.6));
	float brightness = smoothstep(0.35, 0.0, dist) * (h - (1.0 - density)) / density;
	vec3 tint = mix(vec3(1.0, 0.85, 0.7), vec3(0.7, 0.8, 1.0), hash13(cell + 9.1));
	return tint * brightness * 2.5;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col = vec3(0.004, 0.005, 0.012);

	float n1 = fbm(d * 2.5);
	float n2 = fbm(d * 3.5 + 7.0);
	col += vec3(0.30, 0.07, 0.38) * pow(n1, 4.0) * 1.2;
	col += vec3(0.04, 0.16, 0.34) * pow(n2, 4.0) * 1.2;

	float band = exp(-pow(dot(d, normalize(vec3(0.3, 0.8, 0.5))), 2.0) * 14.0);
	col += vec3(0.14, 0.12, 0.11) * band * fbm(d * 8.0);

	col += stars(d, 110.0, 0.04);
	col += stars(d, 260.0, 0.03) * 0.6;
	COLOR = col;
}
