class_name ObjectRegistry
extends Node

## Tracks timeline-addressable Node3Ds by id.
##
## Objects fall into two categories:
##   - runner-owned: spawned by ScriptRunner from spawn events; despawned on
##     reconcile or on explicit despawn events.
##   - external: registered by the host scene. These survive script reloads
##     and are never touched by reconciliation.

signal object_spawned(id: String, node: Node3D)

var _by_id: Dictionary = {}
var _external: Dictionary = {}       # id -> true
var _fading_out: Dictionary = {}     # id -> {time_left, duration}


func register(id: String, node: Node3D, external: bool = false) -> void:
	_by_id[id] = node
	if external:
		_external[id] = true
	object_spawned.emit(id, node)


func unregister(id: String) -> void:
	_by_id.erase(id)
	_external.erase(id)
	_fading_out.erase(id)


func get_node_by_id(id: String) -> Node3D:
	return _by_id.get(id)


func has_id(id: String) -> bool:
	return _by_id.has(id) and is_instance_valid(_by_id[id])


func is_external(id: String) -> bool:
	return _external.get(id, false)


func all_ids() -> Array:
	return _by_id.keys()


func owned_ids() -> Array:
	var out: Array = []
	for id in _by_id.keys():
		if not _external.has(id):
			out.append(id)
	return out


func spawn(id: String, prefab: PackedScene, stage: Node3D, xform: Transform3D) -> Node3D:
	if _by_id.has(id):
		push_warning("ObjectRegistry: id '%s' already exists; despawning first." % id)
		despawn(id, 0.0)
	if prefab == null:
		push_warning("ObjectRegistry: cannot spawn '%s' from null prefab." % id)
		return null
	var node := prefab.instantiate() as Node3D
	if node == null:
		push_warning("ObjectRegistry: prefab for '%s' did not instantiate a Node3D." % id)
		return null
	node.transform = xform
	stage.add_child(node)
	_by_id[id] = node
	object_spawned.emit(id, node)
	return node


func despawn(id: String, fade_duration: float) -> void:
	var node: Node3D = _by_id.get(id)
	if node == null or not is_instance_valid(node):
		_by_id.erase(id)
		return
	if fade_duration <= 0.0:
		_by_id.erase(id)
		node.queue_free()
		return
	_fading_out[id] = { "time_left": fade_duration, "duration": fade_duration }


func tick_fades(delta: float) -> void:
	if _fading_out.is_empty():
		return
	var done: Array = []
	for id in _fading_out.keys():
		var state: Dictionary = _fading_out[id]
		state.time_left -= delta
		var t01 := clampf(state.time_left / state.duration, 0.0, 1.0)
		_apply_alpha_to_id(id, t01)
		if state.time_left <= 0.0:
			done.append(id)
	for id in done:
		var node: Node3D = _by_id.get(id)
		_fading_out.erase(id)
		_by_id.erase(id)
		if node != null and is_instance_valid(node):
			node.queue_free()


func clear_owned() -> void:
	# Frees only runner-owned objects; externals (like main_screen) survive.
	var to_remove: Array = []
	for id in _by_id.keys():
		if not _external.has(id):
			to_remove.append(id)
	for id in to_remove:
		var n: Node3D = _by_id[id]
		_by_id.erase(id)
		if is_instance_valid(n):
			n.queue_free()
	_fading_out.clear()


func _apply_alpha_to_id(id: String, alpha: float) -> void:
	var node: Node3D = _by_id.get(id)
	if node == null or not is_instance_valid(node):
		return
	_apply_alpha_recursive(node, alpha)


func _apply_alpha_recursive(node: Node, alpha: float) -> void:
	if node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		var mat: Material = gi.get_active_material(0)
		if mat is StandardMaterial3D:
			var sm := mat as StandardMaterial3D
			sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var c := sm.albedo_color
			c.a = alpha
			sm.albedo_color = c
	for child in node.get_children():
		_apply_alpha_recursive(child, alpha)
