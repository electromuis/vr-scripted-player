// Shows one part of the picture stretched over the whole screen: the
// rectangle `width` × `height` from (`left`, `top`), in fractions of the
// picture. Split screens use thirds: `left` 0, ⅓, ⅔ with `width` ⅓, each on
// a screen scaled to a third of the width. Put it first: effects before it
// get cropped too, and after a Padding the fractions include the margin.
shader_type canvas_item;
#include "res://addons/vj_editor/visualizer/effect_prelude.gdshaderinc"

uniform float left : hint_range(0.0, 1.0, 0.001) = 0.0;
uniform float top : hint_range(0.0, 1.0, 0.001) = 0.0;
uniform float width : hint_range(0.001, 1.0, 0.001) = 1.0;
uniform float height : hint_range(0.001, 1.0, 0.001) = 1.0;

void fragment() {
	COLOR = texture(input_tex, vec2(left, top) + UV * vec2(width, height));
}
