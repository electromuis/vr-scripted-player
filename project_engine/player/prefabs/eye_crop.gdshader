// Copies one eye's part (`rect`, in UV) of a stereo frame, so a Screen's
// effects run on each eye separately. See Screen._build_chains.
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D input_tex : filter_linear, repeat_disable;
uniform vec4 rect = vec4(0.0, 0.0, 1.0, 1.0);

void fragment() {
	COLOR = texture(input_tex, rect.xy + UV * rect.zw);
}
