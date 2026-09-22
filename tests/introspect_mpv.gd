extends SceneTree

func _init() -> void:
	print("--- MPV classes ---")
	var all := ClassDB.get_class_list()
	var found: Array = []
	for c in all:
		if c.to_lower().contains("mpv"):
			found.append(c)
	for c in found:
		var parent := ClassDB.get_parent_class(c)
		print("%s (extends %s)" % [c, parent])
		var methods := ClassDB.class_get_method_list(c, true)
		for m in methods:
			var args := PackedStringArray()
			for a in m.args:
				args.append("%s: %s" % [a.name, type_string(a.type)])
			print("  %s(%s) -> %s" % [m.name, ", ".join(args), type_string(m.return.type)])
		var props := ClassDB.class_get_property_list(c, true)
		for p in props:
			print("  [prop] %s: %s" % [p.name, type_string(p.type)])
		var signals := ClassDB.class_get_signal_list(c, true)
		for s in signals:
			print("  [signal] %s" % s.name)
		print()
	if found.is_empty():
		print("(no MPV classes found)")
	quit()
