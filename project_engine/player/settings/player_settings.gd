class_name PlayerSettings
extends RefCounted

## App-wide viewer preferences (as opposed to ScreenSettings, which are
## per-preset screen placement). Persisted to a single JSON file and saved
## on every change — there are only a handful of fields.
##
##   locomotion            — LOCKED: sticks seek/volume, viewer never walks.
##                           FREE: left stick moves, right stick snap-turns.
##   allow_script_camera   — honour a script's vr_cut / vr_teleport events.
##   skybox                — built-in key (see SKYBOX_BUILTINS) or an absolute
##                           path to a panorama image.
##   show_floor            — the grey ground plane.
##   show_fps              — a frames-per-second readout (desktop top bar
##                           and wrist HUD).
##   volume                — 0..1 linear.
##   end_action            — what happens when a video ends, one of
##                           END_ACTIONS: stop there, loop it, or play the
##                           next one in the playlist.
##   browser_tiles         — Files/Network tabs show thumbnail tiles instead
##                           of a list.
##   browser_sort          — Files tab order, one of BROWSER_SORTS.
##   browser_last_dir      — folder the Files tab last showed ("" = none),
##                           reopened at startup.
##   live_sync             — follow the authoring editor that started this
##                           player (`--live-sync`); no effect otherwise.
##   fullscreen            — desktop window fills the screen (F11).
##   show_play_bar         — the desktop bottom media bar (H).

signal changed

const PATH := "user://player_settings.json"
const FORMAT_VERSION := 1
const KIND := "player_settings"

enum Locomotion { LOCKED, FREE }

## Files tab sort modes, in dropdown order. Date is newest first, size is
## largest first; folders always come before files.
const BROWSER_SORTS := ["name", "date", "size", "random"]
const BROWSER_SORT_LABELS := {
	"name": "Name",
	"date": "Date",
	"size": "Size",
	"random": "Random",
}

## What to do at the end of a video, in dropdown order.
const END_ACTIONS := ["nothing", "loop", "next"]
const END_ACTION_LABELS := {
	"nothing": "Nothing — stay on the last frame",
	"loop": "Loop the video",
	"next": "Play the next video",
}

## Built-in skybox keys, in dropdown order. Anything else is a file path.
const SKYBOX_BUILTINS := [
	"black", "dark_grey", "light_grey", "navy", "purple", "teal",
	"night", "dusk", "day",
	"forest", "clouds", "space",
]
const SKYBOX_LABELS := {
	"black": "Black",
	"dark_grey": "Dark grey",
	"light_grey": "Light grey",
	"navy": "Navy",
	"purple": "Purple",
	"teal": "Teal",
	"night": "Night gradient",
	"dusk": "Dusk",
	"day": "Daylight",
	"forest": "Forest",
	"clouds": "Above the clouds",
	"space": "Space",
}

var locomotion: int = Locomotion.LOCKED: set = _set_locomotion
var allow_script_camera: bool = true: set = _set_allow_script_camera
var skybox: String = "black": set = _set_skybox
var show_floor: bool = false: set = _set_show_floor
var show_fps: bool = false: set = _set_show_fps
var volume: float = 1.0: set = _set_volume
var end_action: String = "nothing": set = _set_end_action
var browser_tiles: bool = false: set = _set_browser_tiles
var browser_sort: String = "name": set = _set_browser_sort
var browser_last_dir: String = "": set = _set_browser_last_dir
var live_sync: bool = true: set = _set_live_sync
var fullscreen: bool = false: set = _set_fullscreen
var show_play_bar: bool = true: set = _set_show_play_bar

var _path: String = PATH
var _loading: bool = false


## `path` override is for tests.
func _init(path: String = PATH) -> void:
	_path = path


func load_from_disk() -> void:
	if not FileAccess.file_exists(_path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("PlayerSettings: %s is not a JSON object" % _path)
		return
	from_dict(parsed)


func from_dict(d: Dictionary) -> void:
	_loading = true
	locomotion = Locomotion.FREE if String(d.get("locomotion", "locked")) == "free" else Locomotion.LOCKED
	allow_script_camera = bool(d.get("allow_script_camera", true))
	skybox = String(d.get("skybox", "black"))
	show_floor = bool(d.get("show_floor", false))
	show_fps = bool(d.get("show_fps", false))
	volume = clampf(float(d.get("volume", 1.0)), 0.0, 1.0)
	end_action = String(d.get("end_action", "nothing"))
	browser_tiles = String(d.get("browser_view", "list")) == "tiles"
	browser_sort = String(d.get("browser_sort", "name"))
	browser_last_dir = String(d.get("browser_last_dir", ""))
	live_sync = bool(d.get("live_sync", true))
	fullscreen = bool(d.get("fullscreen", false))
	show_play_bar = bool(d.get("show_play_bar", true))
	_loading = false
	changed.emit()


func to_dict() -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"kind": KIND,
		"locomotion": "free" if locomotion == Locomotion.FREE else "locked",
		"allow_script_camera": allow_script_camera,
		"skybox": skybox,
		"show_floor": show_floor,
		"show_fps": show_fps,
		"volume": volume,
		"end_action": end_action,
		"browser_view": "tiles" if browser_tiles else "list",
		"browser_sort": browser_sort,
		"browser_last_dir": browser_last_dir,
		"live_sync": live_sync,
		"fullscreen": fullscreen,
		"show_play_bar": show_play_bar,
	}


func save() -> void:
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f == null:
		push_warning("PlayerSettings: cannot write %s" % _path)
		return
	f.store_string(JSON.stringify(to_dict(), "\t"))


func _touch() -> void:
	if _loading:
		return
	save()
	changed.emit()


func _set_locomotion(v: int) -> void:
	if v == locomotion:
		return
	locomotion = v
	_touch()


func _set_allow_script_camera(v: bool) -> void:
	if v == allow_script_camera:
		return
	allow_script_camera = v
	_touch()


func _set_skybox(v: String) -> void:
	if v == skybox:
		return
	skybox = v
	_touch()


func _set_show_floor(v: bool) -> void:
	if v == show_floor:
		return
	show_floor = v
	_touch()


func _set_show_fps(v: bool) -> void:
	if v == show_fps:
		return
	show_fps = v
	_touch()


func _set_volume(v: float) -> void:
	v = clampf(v, 0.0, 1.0)
	if is_equal_approx(v, volume):
		return
	volume = v
	_touch()


func _set_end_action(v: String) -> void:
	if not v in END_ACTIONS:
		v = "nothing"
	if v == end_action:
		return
	end_action = v
	_touch()


func _set_browser_tiles(v: bool) -> void:
	if v == browser_tiles:
		return
	browser_tiles = v
	_touch()


func _set_browser_sort(v: String) -> void:
	if not v in BROWSER_SORTS:
		v = "name"
	if v == browser_sort:
		return
	browser_sort = v
	_touch()


func _set_live_sync(v: bool) -> void:
	if v == live_sync:
		return
	live_sync = v
	_touch()


func _set_fullscreen(v: bool) -> void:
	if v == fullscreen:
		return
	fullscreen = v
	_touch()


func _set_show_play_bar(v: bool) -> void:
	if v == show_play_bar:
		return
	show_play_bar = v
	_touch()


func _set_browser_last_dir(v: String) -> void:
	if v == browser_last_dir:
		return
	browser_last_dir = v
	# Saved but not signalled: it changes on every folder visit, and
	# listeners (skybox, volume, views) don't depend on it.
	if not _loading:
		save()
