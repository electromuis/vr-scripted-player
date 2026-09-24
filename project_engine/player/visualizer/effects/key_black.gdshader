// Shows black as transparent: alpha is the brightest channel and colour is
// un-premultiplied by it, so over what's behind, black adds nothing and
// bright stays solid. For laying Shadertoy output over the video.
shader_type canvas_item;
#include "res://player/visualizer/effect_prelude.gdshaderinc"

float getLuma(vec3 rgb) {
    return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec4 c = texture(input_tex, UV);
	float k = getLuma(c.rgb);
	COLOR = vec4(c.rgb / max(k, 0.0001), k);
}
