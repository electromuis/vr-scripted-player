// Effect shader prelude (see VisualizerShaders). Include right after
// `shader_type canvas_item;`. An effect runs on a layer's (or the video
// screen's) output, after the layer's shader and any earlier effects:
//   input_tex       — that output; sample it at UV
//   display_aspect  — width / height of the screen it ends up on, for
//                     shapes that must stay round
// COLOR is written as-is with straight (not premultiplied) alpha, which the
// display pass uses as the screen's transparency.
// Uniforms with a hint_range (or bools) get controls in the Camera tab.

render_mode blend_disabled;

uniform sampler2D input_tex : filter_linear, repeat_disable;
uniform float display_aspect = 1.7777778;
