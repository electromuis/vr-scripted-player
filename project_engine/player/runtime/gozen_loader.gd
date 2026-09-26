extends Node

## Loads gde_gozen in exported Windows / Linux builds.
##
## Those builds don't ship the gde_gozen library as a loose file next to the
## executable: it's packed into the .pck (see include_filter in
## export_presets.cfg, which also leaves out gozen.gdextension). A native
## library can only be loaded from a real file, so on startup this writes it
## to user://gozen/ and loads it through a generated .gdextension. The file
## name carries the library's hash, so a running instance holding an older
## copy open never blocks the write.
##
## Registered as the first autoload, so the classes exist before the main
## scene's scripts (video_bridge.gd, video_playback.gd) are compiled. In the
## editor, and on macOS / Android where the library ships inside the app
## bundle / APK, gozen.gdextension has already loaded it and this does nothing.

const ENTRY_SYMBOL := "gozen_library_init"
const COMPATIBILITY_MINIMUM := "4.3"
const EMBEDDED_DIR := "res://addons/gde_gozen/bin"
const EXTRACT_DIR := "user://gozen"
const PROBE_CLASS := "GoZenVideo"


func _init() -> void:
	if ClassDB.class_exists(PROBE_CLASS):
		return
	var err := load_embedded()
	if err != OK:
		push_warning("GoZenLoader: gde_gozen not loaded (%s); video playback disabled." % error_string(err))


## Extracts and loads the embedded library for this OS / architecture.
static func load_embedded() -> Error:
	var source := _embedded_library()
	if source.is_empty():
		return ERR_FILE_NOT_FOUND
	var bytes := FileAccess.get_file_as_bytes(source)
	if bytes.is_empty():
		return ERR_FILE_CANT_READ

	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	var hash := ctx.finish().hex_encode().left(12)

	var dir := ProjectSettings.globalize_path(EXTRACT_DIR)
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return err
	var lib := dir.path_join("%s-%s.%s" % [source.get_file().get_basename(), hash, source.get_extension()])
	if not FileAccess.file_exists(lib) or FileAccess.get_file_as_bytes(lib) != bytes:
		var f := FileAccess.open(lib, FileAccess.WRITE)
		if f == null:
			return FileAccess.get_open_error()
		f.store_buffer(bytes)
		f.close()
		_remove_stale_copies(dir, lib.get_file())

	var cfg_path := dir.path_join("gozen.gdextension")
	var cfg := ConfigFile.new()
	cfg.set_value("configuration", "entry_symbol", ENTRY_SYMBOL)
	cfg.set_value("configuration", "compatibility_minimum", COMPATIBILITY_MINIMUM)
	cfg.set_value("libraries", "%s.%s" % [_os_tag(), Engine.get_architecture_name()], lib)
	err = cfg.save(cfg_path)
	if err != OK:
		return err

	var status := GDExtensionManager.load_extension(cfg_path)
	if status != GDExtensionManager.LOAD_STATUS_OK and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
		return FAILED
	return OK if ClassDB.class_exists(PROBE_CLASS) else FAILED


## res:// path of the packed library for this platform, "" if there is none.
static func _embedded_library() -> String:
	var ext: String = {"windows": "dll", "linux": "so", "macos": "dylib"}.get(_os_tag(), "")
	if ext.is_empty():
		return ""
	var targets := ["template_debug", "template_release"] if OS.is_debug_build() else ["template_release", "template_debug"]
	for target in targets:
		var path := EMBEDDED_DIR.path_join("libgozen.%s.%s.%s.%s" % [_os_tag(), target, Engine.get_architecture_name(), ext])
		if FileAccess.file_exists(path):
			return path
	return ""


static func _os_tag() -> String:
	for tag in ["windows", "linux", "macos"]:
		if OS.has_feature(tag):
			return tag
	return ""


## Old copies from earlier versions. One that's still loaded by another running
## instance can't be deleted on Windows; it goes on the next start.
static func _remove_stale_copies(dir: String, keep: String) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("libgozen.") and f != keep:
			DirAccess.remove_absolute(dir.path_join(f))
