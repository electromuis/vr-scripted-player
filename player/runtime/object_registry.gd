class_name ObjectRegistry
extends Node

var _by_id: Dictionary = {}


func register(id: String, node: Node3D) -> void:
	_by_id[id] = node


func unregister(id: String) -> void:
	_by_id.erase(id)


func get_node_by_id(id: String) -> Node3D:
	return _by_id.get(id)


func has_id(id: String) -> bool:
	return _by_id.has(id)


func all_ids() -> Array:
	return _by_id.keys()


func clear() -> void:
	for id in _by_id.keys():
		var n: Node3D = _by_id[id]
		if is_instance_valid(n):
			n.queue_free()
	_by_id.clear()
