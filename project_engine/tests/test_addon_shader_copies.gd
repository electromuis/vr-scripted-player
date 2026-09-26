extends RefCounted

## The authoring addon (<repo>/addon_vj) carries copies of the player's
## built-in shaders so screens and layers preview in the editor (its
## exporter maps them back to the player's own), and of the modifiers
## helper both sides apply objects' modifiers with. Keep them in step.

const ADDON_PREFIX := "res://addons/vj_editor/"
## player path -> addon path, both relative to their project / addon root.
const COPIES := {
	"player/visualizer/effect_prelude.gdshaderinc": "visualizer/effect_prelude.gdshaderinc",
	"player/visualizer/shadertoy_prelude.gdshaderinc": "visualizer/shadertoy_prelude.gdshaderinc",
	"player/visualizer/shadertoy_main.gdshaderinc": "visualizer/shadertoy_main.gdshaderinc",
	"player/visualizer/effects/edge_blur.gdshader": "visualizer/effects/edge_blur.gdshader",
	"player/visualizer/effects/key_black.gdshader": "visualizer/effects/key_black.gdshader",
	"player/visualizer/effects/oval_mask.gdshader": "visualizer/effects/oval_mask.gdshader",
	"player/visualizer/effects/padding.gdshader": "visualizer/effects/padding.gdshader",
	"player/visualizer/effects/glow.gdshader": "visualizer/effects/glow.gdshader",
	"player/visualizer/effects/crop.gdshader": "visualizer/effects/crop.gdshader",
	"player/visualizer/effects/rounded_corners.gdshader": "visualizer/effects/rounded_corners.gdshader",
	"player/visualizer/effects/keep_center.gdshader": "visualizer/effects/keep_center.gdshader",
	"player/visualizer/shaders/light_ring.gdshader": "visualizer/shaders/light_ring.gdshader",
	"player/visualizer/shaders/spectrum_bars.gdshader": "visualizer/shaders/spectrum_bars.gdshader",
	"player/visualizer/shaders/video_blur.gdshader": "visualizer/shaders/video_blur.gdshader",
	"player/runtime/modifiers.gd": "modifiers/modifiers.gd",
}


static func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path).replace("\r\n", "\n")


static func test_addon_shaders_match_player(tc: TestCase) -> void:
	var addon_dir := ProjectSettings.globalize_path("res://").path_join("../addon_vj").simplify_path()
	if not DirAccess.dir_exists_absolute(addon_dir):
		return  # player checked out on its own
	for player_rel in COPIES:
		var player_code := _read("res://" + player_rel).replace("res://player/visualizer/", ADDON_PREFIX + "visualizer/")
		var addon_code := _read(addon_dir.path_join(COPIES[player_rel]))
		tc.assert_eq(addon_code, player_code, "addon_vj/%s differs from %s (fix: godot --headless --path project_engine --script res://tests/sync_addon_copies.gd)" % [COPIES[player_rel], player_rel])
