extends SceneTree

## Vanilla test runner. Discovers tests/test_*.gd, invokes every `static func test_*`.
## Run with:
##   Godot_v4.4-stable_win64.exe --headless --path <project> --script res://tests/run.gd

const TESTS_DIR := "res://tests"


func _init() -> void:
	var total := 0
	var passed := 0
	var failed_names: Array = []
	for suite_path in _discover_suites():
		var script: Script = load(suite_path)
		if script == null:
			push_error("Failed to load %s" % suite_path)
			continue
		print("== %s ==" % suite_path)
		for method in script.get_script_method_list():
			var name: String = method.name
			if not name.begins_with("test_"):
				continue
			total += 1
			var tc := TestCase.new()
			tc.begin(name)
			var ok := true
			var err = null
			# Static method call via reflection.
			script.call(name, tc)
			var failures := tc.failures()
			if failures.is_empty():
				passed += 1
				print("  PASS %s" % name)
			else:
				failed_names.append("%s::%s" % [suite_path, name])
				print("  FAIL %s" % name)
				for f in failures:
					print("     %s" % f)
	print("")
	print("Ran %d tests: %d passed, %d failed" % [total, passed, total - passed])
	if failed_names.size() > 0:
		for n in failed_names:
			print("  FAILED %s" % n)
		quit(1)
	quit(0)


func _discover_suites() -> Array:
	var out: Array = []
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var f := dir.get_next()
		if f == "":
			break
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
			out.append(TESTS_DIR.path_join(f))
	dir.list_dir_end()
	out.sort()
	return out
