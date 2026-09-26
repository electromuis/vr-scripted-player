shader_type canvas_item;

// Round-trip fixture: a custom screen shader (copied next to the JSON on export).
uniform sampler2D screen_tex : source_color, filter_linear;
uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform vec3 color : source_color = vec3(1.0);

void fragment() {
	vec2 uv = UV + vec2(sin(UV.y * 20.0 + TIME) * amount * 0.02, 0.0);
	COLOR = texture(screen_tex, uv) * vec4(color, 1.0);
}
