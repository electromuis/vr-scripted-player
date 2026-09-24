// Transparent margin around the picture, so the effects after it have room
// to spread (an outward Edge blur, a glow) instead of being cut off at the
// screen's edge. Not an ordinary effect: the Screen grows this pass and the
// ones after it, and the displayed quad, by the margin, so the picture
// itself stays the same size and place. `amount` is the margin on each
// side as a fraction of the incoming picture's height. Flat screens only
// (180°/360° skip it).
shader_type canvas_item;
#include "res://player/visualizer/effect_prelude.gdshaderinc"

uniform float amount : hint_range(0.0, 1.0, 0.01) = 0.25;

void fragment() {
	// display_aspect is this pass's (padded) shape; undo the margin to get
	// the incoming picture's coordinates.
	float p = max(amount, 0.0);
	float h = 1.0 + 2.0 * p;
	float w = display_aspect * h;  // in incoming heights
	vec2 uv = (UV - 0.5) * vec2(w / (w - 2.0 * p), h) + 0.5;
	bool inside = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
	COLOR = inside ? texture(input_tex, uv) : vec4(0.0);
}
