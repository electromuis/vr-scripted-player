// Shadertoy compatibility layer, part 1 of 2 (see VisualizerShaders).
// Include right after `shader_type canvas_item;`, paste the Shadertoy code
// (its mainImage), then include shadertoy_main.gdshaderinc.
//
// iChannel0 is the live audio texture, laid out like Shadertoy's music
// input: 512×2, row 0 (sample y = 0.25) the spectrum 0–11 kHz, row 1
// (y = 0.75) the waveform with 0.5 = silence. iChannel1–3 are unbound.
// A `// @iChannelN video` line in the shader binds that channel to the
// playing video's frame instead (any channel, 0 too; see VisualizerShaders).
// That's the whole frame: for a stereo video both eyes, laid out as
// `video_stereo` says, and the layer's screen splits the output the same
// way, so a shader that works on the full frame lines up per eye. Its
// top row is v = 0 (unlike Shadertoy's flipped video), so sample it at
// vec2(uv.x, 1.0 - uv.y) with uv = fragCoord / iResolution.xy. Clamp to
// one eye's half to keep a blur from crossing into the other (channels
// 1–3 repeat).
// There is no mouse, keyboard or multipass buffer support.

render_mode blend_disabled;

uniform sampler2D iChannel0 : filter_linear, repeat_disable;
uniform sampler2D iChannel1 : filter_linear, repeat_enable;
uniform sampler2D iChannel2 : filter_linear, repeat_enable;
uniform sampler2D iChannel3 : filter_linear, repeat_enable;
uniform vec3 iChannelResolution[4];
uniform vec3 iResolution = vec3(960.0, 540.0, 1.0);
uniform vec4 iMouse = vec4(0.0);
uniform vec4 iDate = vec4(0.0);
uniform float iSampleRate = 44100.0;
// The video's stereo layout: 0 mono, 1 side-by-side, 2 top-bottom.
uniform int video_stereo = 0;

// Band levels (0..1) from the same analysis, for shaders written natively.
uniform float audio_level = 0.0;
uniform float audio_bass = 0.0;
uniform float audio_mid = 0.0;
uniform float audio_high = 0.0;

#define iTime TIME
#define iGlobalTime TIME
#define iTimeDelta (1.0 / 60.0)
#define iFrameRate 60.0
#define iFrame int(TIME * 60.0)
#define texture2D texture
