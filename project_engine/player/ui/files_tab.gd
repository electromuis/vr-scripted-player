extends VBoxContainer

## Files tab of the F2 floating panel. An inline `ItemList`-based folder
## browser — no popup dialog (embedded `FileDialog.popup_centered` grabs
## input in a way that freezes the root viewport when hosted in a
## SubViewport). The list shows the parent-nav row `..`, then folders,
## then scripts (`.json`) and video files. Activating a folder navigates
## into it; activating a file hands its path (and the listing's files as the
## next/previous playlist) to main.gd's open_file, which
## loads scripts directly and plays videos (via a same-name `.json` sidecar
## if one exists, otherwise on the default screen).
##
## Other files are hidden — this is a media picker, not a general explorer.
##
## Rows show the OS's own thumbnails (OsThumbnails) as they arrive, in a list
## or as tiles (PlayerSettings.browser_tiles, toggled by the View button).
##
## Folders and files are ordered by PlayerSettings.browser_sort (Sort
## dropdown); folders always come first. The folder shown is remembered in
## PlayerSettings.browser_last_dir and reopened next launch. With no folder
## to start in, or going up from a drive root, the list shows the system's
## drives ("This PC" — _current_dir is "" there).
##
## The header's Back button returns to the previously shown folder (a
## history of user navigations, not of sort/refresh re-lists); Up goes to the
## parent folder, same as the `..` row.

const PARENT_LABEL := ".."
const DRIVES_LABEL := "This PC"
const HISTORY_LIMIT := 100

@onready var back_button: Button = %BackButton
@onready var up_button: Button = %UpButton
@onready var path_label: Label = %PathLabel
@onready var sort_option: OptionButton = %SortOption
@onready var view_button: Button = %ViewButton
@onready var entry_list: ItemList = %EntryList
@onready var status_label: Label = %StatusLabel

var _runner: ScriptRunner
var _open_file: Callable
var _settings: PlayerSettings
var _tiles: bool = false
var _thumbs: OsThumbnails
var _sort: String = "name"
var _current_dir: String = ""  # "" = drives view
var _bound: bool = false  # bind() ran; navigation may start
# Parallel to entry_list rows: {"kind": "up"|"dir"|"file", "path": String}.
var _entries: Array = []
# path → row index, for thumbnails that arrive after the row was added.
var _row_of_path: Dictionary = {}
# Folders shown before the current one, oldest first ("" = drives view).
var _history: Array[String] = []


func _ready() -> void:
	# Single-click activation: `item_activated` requires a double-click, which
	# the mouse-forwarding path treats as two single events unless the raw
	# `double_click` flag survives the forward (see floating_panel.gd). Even
	# with that fixed, single-click is friendlier for VR controllers.
	entry_list.item_selected.connect(_on_item_activated)
	view_button.pressed.connect(_toggle_view)
	back_button.pressed.connect(_go_back)
	up_button.pressed.connect(_go_up)
	for key in PlayerSettings.BROWSER_SORTS:
		sort_option.add_item(PlayerSettings.BROWSER_SORT_LABELS[key])
	sort_option.item_selected.connect(_on_sort_selected)
	_thumbs = OsThumbnails.new()
	_thumbs.name = "OsThumbnails"
	add_child(_thumbs)
	_thumbs.thumbnail_ready.connect(_on_thumbnail_ready)
	_apply_view()


## `thumbs`, when given, replaces this tab's own OsThumbnails, so the
## player shares one helper process and one cache with it.
func bind(runner: ScriptRunner, open_file: Callable, thumbs: OsThumbnails = null) -> void:
	_runner = runner
	_open_file = open_file
	if thumbs != null and thumbs != _thumbs:
		_thumbs.queue_free()
		_thumbs = thumbs
		_thumbs.thumbnail_ready.connect(_on_thumbnail_ready)
	if _runner != null:
		_runner.script_load_failed.connect(_on_script_load_failed)
		_runner.script_loaded.connect(_on_script_loaded)
	_bound = true
	_navigate_to(_initial_dir(), false)


## Shares the list/tiles choice with the Network tab via PlayerSettings, and
## keeps this tab's sort order and last folder there. Bind before bind() so
## the first folder shown is the remembered one.
func bind_view(settings: PlayerSettings) -> void:
	_settings = settings
	if _settings != null:
		_settings.changed.connect(_apply_view)
	_apply_view()


func _on_sort_selected(idx: int) -> void:
	var key: String = PlayerSettings.BROWSER_SORTS[idx]
	var unchanged := key == _sort
	if _settings != null:
		_settings.browser_sort = key  # → changed → _apply_view re-lists
	else:
		_sort = key
	# Picking Random again reshuffles; other changes already re-listed.
	if unchanged or _settings == null:
		_refresh_listing()


func _refresh_listing() -> void:
	if _bound:
		_navigate_to(_current_dir, false)


func _toggle_view() -> void:
	if _settings != null:
		_settings.browser_tiles = not _tiles  # → changed → _apply_view
	else:
		_tiles = not _tiles
		_apply_view()


func _apply_view() -> void:
	if _settings != null:
		_tiles = _settings.browser_tiles
		if _settings.browser_sort != _sort:
			_sort = _settings.browser_sort
			_refresh_listing()
	BrowserView.apply(entry_list, _tiles)
	view_button.text = BrowserView.toggle_label(_tiles)
	sort_option.select(PlayerSettings.BROWSER_SORTS.find(_sort))


func _on_item_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	var entry: Dictionary = _entries[idx]
	match String(entry.get("kind", "")):
		"up", "dir":
			_navigate_to(String(entry.get("path", "")))
		"file":
			if _open_file.is_valid():
				var path := String(entry.get("path", ""))
				var files: Array[String] = []
				for e in _entries:
					if e["kind"] == "file":
						files.append(e["path"])
				_open_file.call(path, Playlist.from_paths(files, path))


func _go_back() -> void:
	if not _history.is_empty():
		_navigate_to(_history.pop_back(), false)


func _go_up() -> void:
	if _current_dir == "":
		return
	var parent := _current_dir.get_base_dir()
	_navigate_to("" if parent == _current_dir else parent)


## `dir` "" shows the drives list. `remember` puts the folder being left on
## the Back history.
func _navigate_to(dir: String, remember: bool = true) -> void:
	var d: DirAccess = null
	if dir != "":
		d = DirAccess.open(dir)
		if d == null:
			status_label.text = "Cannot open %s" % dir
			return
	if remember and dir != _current_dir:
		_history.append(_current_dir)
		if _history.size() > HISTORY_LIMIT:
			_history.pop_front()
	back_button.disabled = _history.is_empty()
	up_button.disabled = dir == ""
	if dir == "":
		_show_drives()
		return
	_current_dir = dir
	path_label.text = dir
	status_label.text = ""
	if _settings != null:
		_settings.browser_last_dir = dir
	_populate_entries(d)


func _clear_entries() -> void:
	entry_list.clear()
	_entries.clear()
	_row_of_path.clear()
	_thumbs.cancel_pending()


func _show_drives() -> void:
	_clear_entries()
	_current_dir = ""
	path_label.text = DRIVES_LABEL
	status_label.text = ""
	for i in DirAccess.get_drive_count():
		var drive := DirAccess.get_drive_name(i)
		if drive == "":
			continue
		# Windows reports "C:"; DirAccess needs "C:/" to open the root.
		var path := drive if drive.ends_with("/") else drive + "/"
		BrowserView.add_row(entry_list, drive, "folder")
		_entries.append({"kind": "dir", "path": path})
	if _entries.is_empty():
		status_label.text = "No drives found."


func _populate_entries(d: DirAccess) -> void:
	_clear_entries()

	# Row 0: parent-nav. At a filesystem root (on Windows, get_base_dir of
	# "C:/" is "C:/" again) it leads to the drives list.
	var parent := _current_dir.get_base_dir()
	if parent == _current_dir:
		parent = ""
	BrowserView.add_row(entry_list, PARENT_LABEL, "up")
	_entries.append({"kind": "up", "path": parent})

	var dirs: Array[String] = []
	var files: Array[String] = []
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name.begins_with("."):
			name = d.get_next()
			continue
		if d.current_is_dir():
			dirs.append(name)
		elif name.get_extension().to_lower() == "json" or DefaultScreen.is_video(name):
			files.append(name)
		name = d.get_next()
	dirs = _sorted(dirs, true)
	files = _sorted(files, false)

	for dn in dirs:
		_add_entry(dn, "dir", "folder")
	for fn in files:
		_add_entry(fn, "file", "video" if DefaultScreen.is_video(fn) else "script")


## Names in `_current_dir` in the current sort order. Size doesn't apply to
## folders, so they fall back to name order there.
func _sorted(names: Array[String], are_dirs: bool) -> Array[String]:
	var mode := _sort
	if mode == "size" and are_dirs:
		mode = "name"
	match mode:
		"random":
			names.shuffle()
		"date", "size":
			# Stat each entry once, not once per comparison.
			var key := {}
			for n in names:
				var path := _current_dir.path_join(n)
				key[n] = FileAccess.get_modified_time(path) if mode == "date" else FileAccess.get_size(path)
			names.sort_custom(func(a: String, b: String) -> bool:
				if key[a] != key[b]:
					return key[a] > key[b]  # newest / largest first
				return a.naturalnocasecmp_to(b) < 0)
		_:
			names.sort_custom(func(a: String, b: String) -> bool:
				return a.naturalnocasecmp_to(b) < 0)
	return names


func _add_entry(name: String, kind: String, placeholder: String) -> void:
	var path := _current_dir.path_join(name)
	var idx := BrowserView.add_row(entry_list, name, placeholder)
	_entries.append({"kind": kind, "path": path})
	_row_of_path[path] = idx
	var tex := _thumbs.request(path)
	if tex != null:
		entry_list.set_item_icon(idx, tex)


func _on_thumbnail_ready(path: String, tex: Texture2D) -> void:
	var idx: int = _row_of_path.get(path, -1)
	if idx >= 0 and idx < entry_list.item_count:
		entry_list.set_item_icon(idx, tex)


func _on_script_loaded(data: TimelineData) -> void:
	status_label.text = "Loaded %s" % data.script_path.get_file()
	# Keep the browser on the folder of whatever is playing, whichever way it
	# was opened (Files tab, drag-and-drop, CLI).
	var dir := _os_dir_of(data.script_path)
	if dir != "" and dir != _current_dir and DirAccess.dir_exists_absolute(dir):
		_navigate_to(dir)


func _on_script_load_failed(err: String) -> void:
	status_label.text = "Load failed: %s" % err


## The playing script's folder, else the remembered one, else "" (drives).
func _initial_dir() -> String:
	if _runner != null and _runner.timeline != null and _runner.timeline.script_path != "" \
			and not DefaultScreen.is_idle(_runner.timeline):
		var dir := _os_dir_of(_runner.timeline.script_path)
		if DirAccess.dir_exists_absolute(dir):
			return dir
	if _settings != null and _settings.browser_last_dir != "" \
			and DirAccess.dir_exists_absolute(_settings.browser_last_dir):
		return _settings.browser_last_dir
	return ""


static func _os_dir_of(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		path = ProjectSettings.globalize_path(path)
	return path.get_base_dir()
