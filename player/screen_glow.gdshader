shader_type spatial;

render_mode blend_mix, unshaded, cull_disabled, depth_prepass_alpha;

uniform sampler2D screen_tex : source_color, filter_linear;

uniform vec4 video_uv_bounds = vec4(0.25, 0.25, 0.75, 0.75);

uniform float glow_intensity : hint_range(0.0, 4.0) = 1.6;
uniform float glow_radius : hint_range(0.01, 1.0) = 0.32;
uniform float glow_power : hint_range(0.5, 6.0) = 2.0;

uniform vec3 glow_tint : source_color = vec3(1.0);

uniform float edge_blur : hint_range(0.0, 0.3) = 0.08;

uniform float inner_glow_strength : hint_range(0.0, 2.0) = 0.3;
uniform float inner_glow_width : hint_range(0.001, 0.4) = 0.06;


void fragment() {

	vec2 uv = UV;

	vec2 vmin = video_uv_bounds.xy;
	vec2 vmax = video_uv_bounds.zw;


	// ---------------------------------------------------------
	// Video UV
	// ---------------------------------------------------------

	vec2 video_size = vmax - vmin;

	vec2 vuv = clamp(
		(uv - vmin) / video_size,
		vec2(0.0),
		vec2(1.0)
	);


	// ---------------------------------------------------------
	// Distance outside rectangle
	//
	// 0 inside the video.
	// ---------------------------------------------------------

	vec2 outside = max(
		max(vmin - uv, uv - vmax),
		vec2(0.0)
	);

	float dist = length(outside);

	float inside = 1.0 - step(0.00001, dist);


	// =========================================================
	// VIDEO COLOR
	// =========================================================

	vec3 video = texture(screen_tex, vuv).rgb;


	// =========================================================
	// INNER EDGE
	// =========================================================

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


	// =========================================================
	// OUTER GLOW
	// =========================================================

	float radius = max(glow_radius, 0.0001);

	float t = clamp(
		dist / radius,
		0.0,
		1.0
	);


	// ---------------------------------------------------------
	// Closest point on the video rectangle.
	// This is deliberately done in the SAME UV space as the
	// original shader.
	// ---------------------------------------------------------

	vec2 edge_uv = clamp(
		uv,
		vmin,
		vmax
	);

	edge_uv = clamp(
		(edge_uv - vmin) / video_size,
		vec2(0.0),
		vec2(1.0)
	);


	// ---------------------------------------------------------
	// Direction from edge into video.
	//
	// Unlike the previous version, this is based on the
	// ORIGINAL rectangle coordinates, so it cannot make the
	// entire material disappear because of a coordinate-space
	// mismatch.
	// ---------------------------------------------------------

	vec2 local = edge_uv;

	float left   = local.x;
	float right  = 1.0 - local.x;
	float top    = local.y;
	float bottom = 1.0 - local.y;

	vec2 dir;

	if (min(left, right) < min(top, bottom)) {

		dir = (left < right)
			? vec2(1.0, 0.0)
			: vec2(-1.0, 0.0);

	} else {

		dir = (top < bottom)
			? vec2(0.0, 1.0)
			: vec2(0.0, -1.0);
	}


	// ---------------------------------------------------------
	// 3 samples instead of 7.
	//
	// Fixed weights are considerably cheaper than exp().
	// ---------------------------------------------------------

	float blur = edge_blur * t;

	vec2 offset = dir * blur;

	vec3 c0 = texture(
		screen_tex,
		clamp(edge_uv, vec2(0.0), vec2(1.0))
	).rgb;

	vec3 c1 = texture(
		screen_tex,
		clamp(edge_uv + offset, vec2(0.0), vec2(1.0))
	).rgb;

	vec3 c2 = texture(
		screen_tex,
		clamp(edge_uv - offset, vec2(0.0), vec2(1.0))
	).rgb;


	vec3 glow =
		c0 * 0.50 +
		c1 * 0.25 +
		c2 * 0.25;


	// ---------------------------------------------------------
	// Glow falloff
	// ---------------------------------------------------------

	float falloff =
		1.0 - smoothstep(0.0, 1.0, t);

	falloff = pow(
		falloff,
		glow_power
	);


	vec3 outside_color =
		glow *
		glow_tint *
		glow_intensity;


	// =========================================================
	// COMBINE
	// =========================================================

	ALBEDO = mix(
		outside_color,
		inside_color,
		inside
	);

	ALPHA = mix(
		falloff,
		1.0,
		inside
	);
}