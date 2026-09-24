// Editor-preview display pass for VJScreen / VJLayer: samples the shader
// (and effect) output and bends the quad like the player's screen_display
// pass does (flat only — no 180°/360°/stereo in the authoring preview).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D frame_tex : source_color, filter_linear, repeat_disable;
uniform float curvature = 0.0;
uniform float half_width = 16.0;
uniform float vertical_curvature = 0.0;
uniform float half_height = 9.0;
uniform float opacity = 1.0;

void vertex() {
	if (curvature > 0.001) {
		float radius = half_width / (curvature * PI * 0.5);
		float a = VERTEX.x / radius;
		VERTEX.x = radius * sin(a);
		VERTEX.z += radius * (1.0 - cos(a));
	}
	if (vertical_curvature > 0.001) {
		float radius = half_height / (vertical_curvature * PI * 0.5);
		float a = VERTEX.y / radius;
		VERTEX.y = radius * sin(a);
		VERTEX.z += radius * (1.0 - cos(a));
	}
}

void fragment() {
	vec4 c = texture(frame_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a * opacity;
}
