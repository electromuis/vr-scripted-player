// Final display pass for the Screen prefab. Samples either the raw video
// texture (passthrough) or the artist-shader output, and handles:
//   shape  0 = flat quad (mesh UVs)
//          1 = 180° dome, 2 = 360° sphere (equirectangular, looked up by
//              view direction so the sphere reads as infinitely far away)
//   stereo 0 = mono, 1 = side-by-side (left eye = left half),
//          2 = top-bottom (left eye = top half)
// Non-XR rendering reports VIEW_INDEX 0, so desktop shows the left eye.
//
// curvature bends the flat quad into a cylinder arc around the viewer:
// 0 = flat, 1 = a half-cylinder (edges swing 90° toward +Z). The quad mesh
// must be subdivided along X for this to look smooth.
// vertical_curvature does the same top-to-bottom (top and bottom edges
// swing toward +Z; needs Y subdivisions). Both together bow a large quad
// into a dome around the viewer.
//
// frame_tex's alpha (straight, not premultiplied) is the flat quad's
// transparency; effects such as Key black and Oval mask set it upstream.
// eyes_split: effects already ran per eye (Screen._build_chains), so
// frame_tex is the left eye and frame_tex_right the right, each whole —
// no stereo UV split here.
//
// opacity (0..1) fades the flat quad as a whole. The immersive sphere is
// opaque (it has to write depth), so it ignores it.
//
// Shared by screen_display.gdshader (flat quad, alpha-blended so artist
// shaders can cut shapes out) and screen_sphere.gdshader (opaque, so the
// camera-centred sphere writes depth and never paints over UI panels).

uniform sampler2D frame_tex : source_color, filter_linear, repeat_disable;
uniform sampler2D frame_tex_right : source_color, filter_linear, repeat_disable;
uniform bool eyes_split = false;
uniform int shape = 0;
uniform int stereo = 0;
uniform float curvature = 0.0;
uniform float half_width = 16.0;  // quad half-width in mesh units
uniform float vertical_curvature = 0.0;
uniform float half_height = 9.0;  // quad half-height in mesh units
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void vertex() {
	if (shape == 0 && curvature > 0.001) {
		float radius = half_width / (curvature * PI * 0.5);
		float a = VERTEX.x / radius;
		VERTEX.x = radius * sin(a);
		VERTEX.z += radius * (1.0 - cos(a));
	}
	if (shape == 0 && vertical_curvature > 0.001) {
		float radius = half_height / (vertical_curvature * PI * 0.5);
		float a = VERTEX.y / radius;
		VERTEX.y = radius * sin(a);
		VERTEX.z += radius * (1.0 - cos(a));
	}
}


void fragment() {
	vec2 uv = UV;
	bool outside = false;
	if (shape != 0) {
		vec3 dir_world = mat3(INV_VIEW_MATRIX) * normalize(VERTEX);
		// Rotation-only model basis, so the node's yaw/tilt orient the video
		// but its scale and position never distort it.
		mat3 rot = mat3(normalize(MODEL_MATRIX[0].xyz), normalize(MODEL_MATRIX[1].xyz), normalize(MODEL_MATRIX[2].xyz));
		vec3 d = transpose(rot) * dir_world;
		float lon = atan(d.x, -d.z);  // 0 = straight ahead (-Z), + = right
		float lat = asin(clamp(d.y, -1.0, 1.0));
		if (shape == 1) {
			uv.x = 0.5 + lon / PI;
			outside = abs(lon) > PI * 0.5;
		} else {
			uv.x = 0.5 + lon / TAU;
		}
		uv.y = 0.5 - lat / PI;
	}
	bool right = VIEW_INDEX == VIEW_RIGHT;
	vec4 c;
	if (eyes_split) {
		c = right ? texture(frame_tex_right, uv) : texture(frame_tex, uv);
	} else {
		float eye = right ? 1.0 : 0.0;
		if (stereo == 1) {
			uv.x = clamp(uv.x, 0.0, 1.0) * 0.5 + 0.5 * eye;
		} else if (stereo == 2) {
			uv.y = clamp(uv.y, 0.0, 1.0) * 0.5 + 0.5 * eye;
		}
		c = texture(frame_tex, uv);
	}
	if (outside) {
		c = vec4(0.0, 0.0, 0.0, 1.0);
	}
	ALBEDO = c.rgb;
#ifndef SCREEN_OPAQUE
	ALPHA = c.a * opacity;
#endif
}
