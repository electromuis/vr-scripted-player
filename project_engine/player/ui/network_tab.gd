extends VBoxContainer

## Network tab of the F2 floating panel: browse DLNA media servers on the
## LAN and play their videos. Same inline ItemList pattern as the Files tab
## (single-click activation, no popups). The top level lists servers found
## by DlnaClient; activating one browses its folders; activating a video
## hands its URL to main.gd's open_url, along with the folder's videos as
## the next/previous playlist. Non-video items are hidden.
##
## Folders and videos are ordered by PlayerSettings.browser_sort (Sort
## dropdown, shared with the Files tab): name, dc:date (newest first), file
## size (largest first; folders fall back to name) or random. Folders always
## come first; the server list keeps discovery order.
##
## Thumbnails are whatever the server provides (upnp:albumArtURI or a
## JPEG_TN resource on items/folders, the device icon for servers), fetched
## a few at a time as rows appear; nothing is generated locally. List/tiles
## layout is shared with the Files tab (PlayerSettings.browser_tiles).
##
## The header's Back button returns to the previously shown folder (or the
## server list); Up goes to the parent folder, same as the `..` row.

const PARENT_LABEL := ".."
## Concurrent thumbnail downloads.
const MAX_THUMB_FETCHES := 4
const THUMB_CACHE_LIMIT := 1000
const HISTORY_LIMIT := 100

@onready var back_button: Button = %NetBackButton
@onready var up_button: Button = %NetUpButton
@onready var path_label: Label = %NetPathLabel
@onready var sort_option: OptionButton = %NetSortOption
@onready var view_button: Button = %NetViewButton
@onready var refresh_button: Button = %NetRefreshButton
@onready var entry_list: ItemList = %NetEntryList
@onready var status_label: Label = %NetStatusLabel

var _client: DlnaClient
var _open_url: Callable
var _settings: PlayerSettings
var _tiles: bool = false
var _sort: String = "name"
## Pending downloads for the current view: [{"url", "row"}]; dropped on
## navigation (the generation check discards any already in flight).
var _thumb_queue: Array[Dictionary] = []
var _thumb_fetches: int = 0
## url → Texture2D, or null when the server's image was unusable.
var _thumb_cache: Dictionary = {}
## Where we are: [] = server list, else [{"server", "id", "title"}, ...]
## from the server root down to the current folder.
var _stack: Array[Dictionary] = []
## Earlier values of _stack, oldest first, for the Back button.
var _history: Array = []
## Parallel to entry_list rows: {"kind": "up"|"server"|"dir"|"video", ...}.
var _entries: Array[Dictionary] = []
## Bumped on every navigation so a slow Browse can't overwrite a newer view.
var _generation: int = 0
## The current folder's Browse result, kept so a sort change re-lists
## without asking the server again; null while loading or on the server list.
var _items = null


func _ready() -> void:
	entry_list.item_selected.connect(_on_item_activated)
	refresh_button.pressed.connect(_refresh)
	view_button.pressed.connect(_toggle_view)
	back_button.pressed.connect(_go_back)
	up_button.pressed.connect(_go_up)
	for key in PlayerSettings.BROWSER_SORTS:
		sort_option.add_item(PlayerSettings.BROWSER_SORT_LABELS[key])
	sort_option.item_selected.connect(_on_sort_selected)
	_apply_view()


func bind(client: DlnaClient, open_url: Callable) -> void:
	_client = client
	_open_url = open_url
	if _client == null:
		status_label.text = "Network browsing unavailable."
		return
	_client.server_found.connect(_on_server_found)
	_client.discovery_finished.connect(_on_discovery_finished)
	_client.discover()
	_show_servers()


## Shares the list/tiles choice and sort order with the Files tab via
## PlayerSettings.
func bind_view(settings: PlayerSettings) -> void:
	_settings = settings
	if _settings != null:
		_settings.changed.connect(_apply_view)
	_apply_view()


func _toggle_view() -> void:
	if _settings != null:
		_settings.browser_tiles = not _tiles  # → changed → _apply_view
	else:
		_tiles = not _tiles
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
		_relist()


func _apply_view() -> void:
	if _settings != null:
		_tiles = _settings.browser_tiles
		if _settings.browser_sort != _sort:
			_sort = _settings.browser_sort
			_relist()
	BrowserView.apply(entry_list, _tiles)
	view_button.text = BrowserView.toggle_label(_tiles)
	sort_option.select(PlayerSettings.BROWSER_SORTS.find(_sort))


func _relist() -> void:
	if _items != null:
		_populate(_items)


func _refresh() -> void:
	if _client == null:
		return
	if _stack.is_empty():
		_client.discover()
		_show_servers()
	else:
		_browse_current()


func _on_item_activated(idx: int) -> void:
	if idx < 0 or idx >= _entries.size():
		return
	var entry: Dictionary = _entries[idx]
	match String(entry["kind"]):
		"up":
			_go_up()
		"server":
			var server: Dictionary = entry["server"]
			_go_to([{"server": server, "id": DlnaXml.ROOT_OBJECT_ID, "title": server["name"]}])
		"dir":
			var stack := _stack.duplicate()
			stack.append({"server": _stack[-1]["server"], "id": entry["id"], "title": entry["title"]})
			_go_to(stack)
		"video":
			if _open_url.is_valid():
				status_label.text = "Opening %s..." % entry["title"]
				_open_url.call(entry["url"], entry["file_name"], _playlist_from(idx))


func _go_up() -> void:
	if not _stack.is_empty():
		_go_to(_stack.slice(0, _stack.size() - 1))


func _go_back() -> void:
	if not _history.is_empty():
		_show(_history.pop_back())


## Shows `stack` (see _stack), remembering the current place for Back.
func _go_to(stack: Array) -> void:
	_history.append(_stack.duplicate())
	if _history.size() > HISTORY_LIMIT:
		_history.pop_front()
	_show(stack)


func _show(stack: Array) -> void:
	if stack.is_empty():
		_show_servers()
	else:
		_stack.assign(stack)
		_browse_current()


func _update_nav_buttons() -> void:
	back_button.disabled = _history.is_empty()
	up_button.disabled = _stack.is_empty()


# --- server list ---

func _show_servers() -> void:
	_generation += 1
	_stack.clear()
	_items = null
	path_label.text = "Media servers"
	_update_nav_buttons()
	_clear_rows()
	for server in _client.servers:
		_add_server_row(server)
	_update_server_status()


func _on_server_found(server: Dictionary) -> void:
	if _stack.is_empty():
		_add_server_row(server)
		_update_server_status()


func _on_discovery_finished() -> void:
	if _stack.is_empty():
		_update_server_status()


func _add_server_row(server: Dictionary) -> void:
	var idx := BrowserView.add_row(entry_list, String(server["name"]), "server")
	_entries.append({"kind": "server", "server": server})
	_want_thumb(idx, String(server.get("icon_url", "")))


func _update_server_status() -> void:
	var n := _client.servers.size()
	if _client.is_discovering():
		status_label.text = "Searching the network... (%d found)" % n
	elif n == 0:
		status_label.text = "No DLNA media servers found. Check that the server is running and on this network, then Refresh."
	else:
		status_label.text = "%d server%s found." % [n, "" if n == 1 else "s"]


# --- folders ---

func _browse_current() -> void:
	_generation += 1
	var gen := _generation
	var here: Dictionary = _stack[-1]
	path_label.text = " / ".join(_stack.map(func(s): return String(s["title"])))
	_update_nav_buttons()
	_items = null
	_clear_rows()
	_add_up_row()
	status_label.text = "Loading..."
	var result: Dictionary = await _client.browse(here["server"], here["id"])
	if gen != _generation:
		return  # the user navigated elsewhere meanwhile
	if not result["ok"]:
		status_label.text = "Could not list folder: %s" % result["error"]
		return
	_items = result["entries"]
	_populate(_items)


## (Re)builds the rows below ".." from a Browse result in the current order.
func _populate(items: Array) -> void:
	_generation += 1  # rows move: drop thumbnails still aimed at old indices
	_clear_rows()
	_add_up_row()
	var dirs: Array = []  # [entry, {}]
	var vids: Array = []  # [entry, resource]
	var hidden := 0
	for e in items:
		if e["kind"] == "container":
			dirs.append([e, {}])
		elif e["kind"] == "item":
			var res := DlnaXml.pick_video_resource(e) if DlnaXml.is_video_item(e) else {}
			if res.is_empty():
				hidden += 1
			else:
				vids.append([e, res])
	for pair in _sorted(dirs, true):
		var d: Dictionary = pair[0]
		var idx := BrowserView.add_row(entry_list, String(d["title"]), "folder")
		_entries.append({"kind": "dir", "id": d["id"], "title": d["title"]})
		_want_thumb(idx, DlnaXml.thumbnail_url(d))
	for pair in _sorted(vids, false):
		var e: Dictionary = pair[0]
		var res: Dictionary = pair[1]
		var idx := BrowserView.add_row(entry_list, String(e["title"]), "video")
		_want_thumb(idx, DlnaXml.thumbnail_url(e))
		_entries.append({
			"kind": "video",
			"title": e["title"],
			"url": res["url"],
			"file_name": DlnaXml.video_file_name(e["title"], res),
			"thumb": DlnaXml.thumbnail_url(e),
		})
	var folders := dirs.size()
	var videos := vids.size()
	status_label.text = "%d folder%s, %d video%s" % [folders, "" if folders == 1 else "s", videos, "" if videos == 1 else "s"]
	if hidden > 0:
		status_label.text += " (%d non-video item%s hidden)" % [hidden, "" if hidden == 1 else "s"]


## [entry, resource] pairs in the current sort order (resource is {} for
## folders). Ties fall back to title so the order is stable.
func _sorted(pairs: Array, are_dirs: bool) -> Array:
	var mode := _sort
	if mode == "size" and are_dirs:
		mode = "name"
	if mode == "random":
		pairs.shuffle()
		return pairs
	pairs.sort_custom(func(a: Array, b: Array) -> bool:
		if mode == "date" and a[0]["date"] != b[0]["date"]:
			return String(a[0]["date"]) > String(b[0]["date"])  # newest first; undated last
		if mode == "size" and a[1]["size"] != b[1]["size"]:
			return int(a[1]["size"]) > int(b[1]["size"])  # largest first
		return String(a[0]["title"]).naturalnocasecmp_to(String(b[0]["title"])) < 0)
	return pairs


## The folder's videos in the order shown, positioned on row `row`.
func _playlist_from(row: int) -> Playlist:
	var items: Array[Dictionary] = []
	var at := -1
	for i in _entries.size():
		if _entries[i]["kind"] != "video":
			continue
		if i == row:
			at = items.size()
		items.append({"path": _entries[i]["url"], "name": _entries[i]["file_name"],
				"thumb": _entries[i]["thumb"]})
	return Playlist.new(items, at)


func _add_up_row() -> void:
	BrowserView.add_row(entry_list, PARENT_LABEL, "up")
	_entries.append({"kind": "up"})


func _clear_rows() -> void:
	entry_list.clear()
	_entries.clear()
	_thumb_queue.clear()


# --- thumbnails ---

func _want_thumb(row: int, url: String) -> void:
	if url == "":
		return
	if _thumb_cache.has(url):
		if _thumb_cache[url] != null:
			entry_list.set_item_icon(row, _thumb_cache[url])
		return
	_thumb_queue.append({"url": url, "row": row})
	_pump_thumbs()


func _pump_thumbs() -> void:
	while _thumb_fetches < MAX_THUMB_FETCHES and not _thumb_queue.is_empty():
		_fetch_thumb(_thumb_queue.pop_front())


func _fetch_thumb(job: Dictionary) -> void:
	var gen := _generation
	var url: String = job["url"]
	_thumb_fetches += 1
	var tex: Texture2D = null
	if _thumb_cache.has(url):
		tex = _thumb_cache[url]
	else:
		tex = BrowserView.texture_from_bytes(await _client.fetch_bytes(url))
		if _thumb_cache.size() >= THUMB_CACHE_LIMIT:
			_thumb_cache.clear()
		_thumb_cache[url] = tex
	_thumb_fetches -= 1
	var row: int = job["row"]
	if tex != null and gen == _generation and row < entry_list.item_count:
		entry_list.set_item_icon(row, tex)
	_pump_thumbs()
