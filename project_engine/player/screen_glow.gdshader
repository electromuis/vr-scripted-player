shader_type canvas_item;

render_mode blend_mix;

uniform sampler2D screen_tex : source_color, filter_linear;

uniform vec4 video_uv_bounds = vec4(0.25, 0.25, 0.75, 0.75);

// Sub-rect of the source video shown on this screen (UV space). Split
// screens use thirds: offset (0,0)/(1/3,0)/(2/3,0), scale (1/3,1).
uniform vec2 uv_offset = vec2(0.0);
uniform vec2 uv_scale = vec2(1.0);

uniform float glow_intensity : hint_range(0.0, 4.0) = 1.6;
uniform float glow_radius : hint_range(0.01, 1.0) = 0.32;
uniform float glow_power : hint_range(0.5, 6.0) = 2.0;

uniform vec3 glow_tint : source_color = vec3(1.0);

uniform float edge_blur : hint_range(0.0, 0.5) = 0.15;
uniform int glow_samples : hint_range(4, 32) = 12;

uniform float inner_glow_strength : hint_range(0.0, 2.0) = 0.3;
uniform float inner_glow_width : hint_range(0.001, 0.4) = 0.06;


void fragment() {

	vec2 uv = UV;

	vec2 vmin = video_uv_bounds.xy;
	vec2 vmax = video_uv_bounds.zw;

	vec2 video_size = vmax - vmin;

	vec2 vuv = clamp(
		(uv - vmin) / video_size,
		vec2(0.0),
		vec2(1.0)
	);

	vec2 outside = max(
		max(vmin - uv, uv - vmax),
		vec2(0.0)
	);

	float dist = length(outside);
	float inside = 1.0 - step(0.00001, dist);

	vec3 video = texture(screen_tex, uv_offset + vuv * uv_scale).rgb;

	vec2 inner = min(
		uv - vmin,
		vmax - uv
	);

	float inner_edge = min(inner.x, inner.y);

	float inner_amount = 1.0 - smoothstep(
		0.0,
		max(inner_glow_width, 0.0001),
		inner_edge
	);

	vec3 inside_color =
		video +
		video * glow_tint *
		inner_amount *
		inner_glow_strength;

	float radius = max(glow_radius, 0.0001);
	float t = clamp(dist / radius, 0.0, 1.0);

	vec2 edge_uv = clamp(uv, vmin, vmax);
	edge_uv = clamp(
		(edge_uv - vmin) / video_size,
		vec2(0.0),
		vec2(1.0)
	);

	float blur = edge_blur * t;
	vec3 glow = vec3(0.0);
	float angle_step = 6.283185 / float(glow_samples);

	for (int i = 0; i < glow_samples; i++) {
		float angle = float(i) * angle_step;
		vec2 offset = vec2(cos(angle), sin(angle)) * blur;

		vec2 sample_uv = clamp(
			edge_uv + offset,
			vec2(0.0),
			vec2(1.0)
		);

		glow += texture(screen_tex, uv_offset + sample_uv * uv_scale).rgb;
	}

	glow /= float(glow_samples);

	float falloff = 1.0 - smoothstep(0.0, 1.0, t);
	falloff = pow(falloff, glow_power);

	vec3 outside_color = glow * glow_tint * glow_intensity;

	vec3 final_rgb = mix(outside_color, inside_color, inside);
	// Halo coverage fades with intensity, so a screen at 0 has no dark rim
	// (lets adjacent split screens sit edge-to-edge).
	float final_a = mix(falloff * clamp(glow_intensity, 0.0, 1.0), 1.0, inside);

	COLOR = vec4(final_rgb, final_a);
}
