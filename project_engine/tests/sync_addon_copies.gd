extends SceneTree

## Copies the player's shaders and modifiers helper over the addon's copies
## (the list in test_addon_shader_copies.gd), so edit them in the player and
## run this instead of editing both. Run with:
##   godot --headless --path project_engine --script res://tests/sync_addon_copies.gd

const Copies := preload("res://tests/test_addon_shader_copies.gd")


func _init() -> void:
	var addon_dir := ProjectSettings.globalize_path("res://").path_join("../addon_vj").simplify_path()
	if not DirAccess.dir_exists_absolute(addon_dir):
		push_error("No addon_vj/ next to the project.")
		quit(1)
		return
	var changed := 0
	for player_rel in Copies.COPIES:
		var code := FileAccess.get_file_as_string("res://" + player_rel).replace("\r\n", "\n") \
			.replace("res://player/visualizer/", Copies.ADDON_PREFIX + "visualizer/")
		var target: String = addon_dir.path_join(Copies.COPIES[player_rel])
		if FileAccess.get_file_as_string(target).replace("\r\n", "\n") == code:
			continue
		var f := FileAccess.open(target, FileAccess.WRITE)
		f.store_string(code)
		f.close()
		changed += 1
		print("updated addon_vj/%s" % Copies.COPIES[player_rel])
	print("%d file(s) updated" % changed)
	quit(0)
