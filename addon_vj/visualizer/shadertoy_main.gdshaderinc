// Shadertoy compatibility layer, part 2 of 2: calls the pasted mainImage
// with a bottom-left-origin fragCoord, as Shadertoy does. Alpha is forced
// opaque (Shadertoy ignores it); the visualizer keys black out instead.

void fragment() {
	vec4 st_color = vec4(0.0, 0.0, 0.0, 1.0);
	mainImage(st_color, vec2(FRAGCOORD.x, iResolution.y - FRAGCOORD.y));
	COLOR = vec4(st_color.rgb, 1.0);
}
