extends RefCounted

## PresetStore: rename / delete / startup / active tracking, against a
## throwaway folder so the user's real presets are never touched.

const TEST_DIR := "user://test_presets_tmp"


static func _fresh_store() -> PresetStore:
	_wipe()
	return PresetStore.new(TEST_DIR)


static func _wipe() -> void:
	var dir := DirAccess.open(TEST_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(TEST_DIR)


static func test_default_preset_auto_created(t: TestCase) -> void:
	var store := _fresh_store()
	t.assert_eq(String(store.load_preset(1).get("name", "")), "Default")
	t.assert_true(store.has_preset(1), "preset 1 written on first load")
	t.assert_eq(store.startup_index(), 1, "startup defaults to preset 1")
	_wipe()


static func test_rename(t: TestCase) -> void:
	var store := _fresh_store()
	store.save_preset(2, "Old", {"size": 2.0})
	t.assert_true(store.rename_preset(2, "  Couch  "))
	t.assert_eq(String(store.load_preset(2)["name"]), "Couch", "trimmed")
	t.assert_eq(float(store.load_preset(2)["screen"]["size"]), 2.0, "values kept")
	t.assert_false(store.rename_preset(2, "   "), "blank name refused")
	t.assert_false(store.rename_preset(9, "Nope"), "missing preset refused")
	_wipe()


static func test_delete_rules(t: TestCase) -> void:
	var store := _fresh_store()
	store.load_preset(1)
	store.save_preset(2, "Bed", {"size": 1.5})
	store.set_startup_index(2)
	store.set_active(2)
	t.assert_false(store.delete_preset(1), "preset 1 can't be deleted")
	t.assert_true(store.delete_preset(2))
	t.assert_false(store.has_preset(2))
	t.assert_eq(store.startup_index(), 1, "startup falls back to 1")
	t.assert_eq(store.active_index, 1, "active falls back to 1")
	_wipe()


static func test_apply_sets_values_and_active(t: TestCase) -> void:
	var store := _fresh_store()
	store.save_preset(3, "Far", {"size": 1.2, "distance": 4.0, "height": 0.5, "tilt": 10.0, "curvature": 0.3})
	var settings := ScreenSettings.new()
	t.assert_true(store.apply(3, settings))
	t.assert_eq(settings.distance, 4.0)
	t.assert_eq(settings.curvature, 0.3)
	t.assert_eq(store.active_index, 3)
	t.assert_false(store.apply(8, settings), "missing preset")
	t.assert_eq(store.active_index, 3, "failed apply keeps active")
	_wipe()


static func test_startup_ignores_missing_preset(t: TestCase) -> void:
	var store := _fresh_store()
	store.load_preset(1)
	store.set_startup_index(5)
	t.assert_eq(store.startup_index(), 1, "points at a preset that doesn't exist")
	_wipe()


static func test_script_preset_is_locked_defaults(t: TestCase) -> void:
	var store := _fresh_store()
	var idx := PresetStore.SCRIPT_PRESET_INDEX
	t.assert_true(store.has_preset(idx))
	t.assert_eq(int(store.list_presets()[0]["index"]), idx, "listed first")
	t.assert_eq(store.load_preset(idx)["screen"], ScreenSettings.new().to_dict(), "software defaults")
	t.assert_false(store.save_preset(idx, "Mine", {"size": 3.0}), "can't save over")
	t.assert_false(store.rename_preset(idx, "Mine"), "can't rename")
	t.assert_false(store.delete_preset(idx), "can't delete")
	t.assert_false(FileAccess.file_exists(TEST_DIR.path_join("preset_0.json")), "never a file")
	t.assert_eq(store.next_free_index(), 1, "numbering still starts at 1")

	var settings := ScreenSettings.new()
	var layers := LayerStack.new()
	settings.size = 2.5
	layers.set_count(2)
	t.assert_true(store.apply(idx, settings, layers))
	t.assert_eq(settings.size, 1.0, "size reset")
	t.assert_eq(layers.count(), 0, "no layers")
	t.assert_eq(store.active_index, idx)
	_wipe()
