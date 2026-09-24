class_name Playlist
extends RefCounted

## What next / previous step through: the folder listing (Files or Network
## tab) the playing video was picked from, in the order it was shown there.
## Opening a file some other way (drag-and-drop, command line) uses its
## folder in the browser's sort order (see from_folder).
##
## Items are {"path": String, "name": String}: path is an OS path or URL;
## name stands in for a URL's file name (see main.gd open_url), "" for
## local files. Network items may also carry "thumb", the server's
## thumbnail URL. Stepping stops at either end rather than wrapping.

var items: Array[Dictionary] = []
var index: int = -1


func _init(p_items: Array[Dictionary] = [], p_index: int = -1) -> void:
	items = p_items
	index = p_index


## Local files in listing order, positioned on `current`. A script (.json)
## that is the sidecar of a video in the list is dropped: opening the video
## already plays it, and keeping both would play the same thing twice.
static func from_paths(paths: Array[String], current: String) -> Playlist:
	var videos := {}
	for p in paths:
		if DefaultScreen.is_video(p):
			videos[p.get_basename().to_lower()] = true
	var out: Array[Dictionary] = []
	for p in paths:
		if p.get_extension().to_lower() != "json" or not videos.has(p.get_basename().to_lower()):
			out.append({"path": p, "name": ""})
	var at := out.map(func(it: Dictionary) -> String: return it["path"]).find(current)
	if at == -1:
		# `current` is a dropped sidecar: stand on its video.
		at = out.map(func(it: Dictionary) -> String: return String(it["path"]).get_basename()) \
				.find(current.get_basename())
	return Playlist.new(out, at)


## The videos and scripts in `path`'s folder, positioned on it, ordered by
## `sort` (a PlayerSettings.BROWSER_SORTS key, as in the Files tab: date
## newest first, size largest first, ties by name).
static func from_folder(path: String, sort: String = "name") -> Playlist:
	var dir := path.get_base_dir()
	var d := DirAccess.open(dir)
	if d == null:
		return Playlist.new()
	var paths: Array[String] = []
	for f in d.get_files():
		if f.get_extension().to_lower() == "json" or DefaultScreen.is_video(f):
			paths.append(dir.path_join(f))
	if sort == "random":
		paths.shuffle()
	else:
		# Stat each file once, not once per comparison.
		var key := {}
		for p in paths:
			match sort:
				"date": key[p] = FileAccess.get_modified_time(p)
				"size": key[p] = FileAccess.get_size(p)
				_: key[p] = 0
		paths.sort_custom(func(a: String, b: String) -> bool:
			if key[a] != key[b]:
				return key[a] > key[b]  # newest / largest first
			return a.get_file().naturalnocasecmp_to(b.get_file()) < 0)
	return from_paths(paths, dir.path_join(path.get_file()))


func is_empty() -> bool:
	return items.is_empty()


## Moves one item forward (+1) or back (-1) and returns it, or {} at the end.
func step(dir: int) -> Dictionary:
	var i := index + dir
	if i < 0 or i >= items.size():
		return {}
	index = i
	return items[i]
