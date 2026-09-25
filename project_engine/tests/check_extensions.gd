extends SceneTree

## CI smoke check: the GDExtension classes the player needs are loadable.
## Run with:
##   godot --headless --path project_engine --script res://tests/check_extensions.gd

const REQUIRED := ["GoZenVideo", "AudioStreamFFmpeg"]


func _init() -> void:
	var missing: Array = []
	for cls in REQUIRED:
		if not ClassDB.class_exists(cls):
			missing.append(cls)
	if missing.is_empty():
		print("GDExtension classes present: %s" % ", ".join(REQUIRED))
		quit(0)
	else:
		push_error("Missing GDExtension classes: %s" % ", ".join(missing))
		quit(1)
