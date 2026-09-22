class_name ScriptRunner
extends Node

signal script_loaded(data: TimelineData)
signal script_load_failed(error: String)
signal event_fired(event: Dictionary)

@export var stage_path: NodePath
@export var autostart: bool = false

var timeline: TimelineData
var playhead: float = 0.0
var playing: bool = false

var _registry: ObjectRegistry
var _prefabs: PrefabLibrary
var _stage: Node3D
var _fired_events: Dictionary = {}


func _ready() -> void:
	_registry = ObjectRegistry.new()
	_registry.name = "ObjectRegistry"
	add_child(_registry)
	_prefabs = PrefabLibrary.new()
	if stage_path:
		_stage = get_node_or_null(stage_path)


func load_script(path: String) -> bool:
	var result := ScriptFormat.load_from_file(path)
	if not result.ok:
		script_load_failed.emit(result.error)
		push_error("Script load failed: %s" % result.error)
		return false
	timeline = result.data
	playhead = 0.0
	_fired_events.clear()
	_registry.clear()
	script_loaded.emit(timeline)
	if autostart:
		playing = true
	return true


func play() -> void:
	playing = true


func pause() -> void:
	playing = false


func seek(t: float) -> void:
	playhead = clampf(t, 0.0, _duration())
	_fired_events.clear()


func _process(delta: float) -> void:
	if not playing or timeline == null:
		return
	playhead = clampf(playhead + delta, 0.0, _duration())
	_fire_pending_events()
	_evaluate_continuous_tracks()


func _duration() -> float:
	if timeline == null:
		return 0.0
	return float(timeline.media.get("duration", 0.0))


func _fire_pending_events() -> void:
	# Phase 2 will implement this.
	pass


func _evaluate_continuous_tracks() -> void:
	# Phase 2 will implement this.
	pass
