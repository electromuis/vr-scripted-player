class_name FileWatcher
extends Node

signal file_changed(path: String)

const POLL_INTERVAL := 0.5

var _mtimes: Dictionary = {}
var _timer: Timer


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = POLL_INTERVAL
	_timer.autostart = true
	_timer.timeout.connect(_poll)
	add_child(_timer)


func watch(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	_mtimes[path] = FileAccess.get_modified_time(path)


func unwatch(path: String) -> void:
	_mtimes.erase(path)


func watched_paths() -> Array:
	return _mtimes.keys()


func _poll() -> void:
	for path in _mtimes.keys():
		if not FileAccess.file_exists(path):
			continue
		var mt := FileAccess.get_modified_time(path)
		if mt != _mtimes[path]:
			_mtimes[path] = mt
			file_changed.emit(path)
