// Immersive (180°/360°) display pass for the Screen prefab's sphere. Opaque:
// the sphere is centred on the camera, so as a transparent object it would
// sort nearest and draw over the floating panel and wrist HUD.
// See screen_display.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

#define SCREEN_OPAQUE
#include "res://player/prefabs/screen_display.gdshaderinc"
