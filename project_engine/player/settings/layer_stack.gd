class_name LayerStack
extends RefCounted

## The shader layers, in draw order (first = furthest back on its side of
## the video). Starts empty; the Camera tab's layer count adds and removes
## at the end. Each layer's own edits fire its LayerSettings signals;
## `layers_changed` is for the list itself.

signal layers_changed

const MAX_LAYERS := 8

var layers: Array[LayerSettings] = []


func count() -> int:
	return layers.size()


## Grow (blank layers in front of the video) or shrink (from the end) to `n`.
func set_count(n: int) -> void:
	n = clampi(n, 0, MAX_LAYERS)
	if n == layers.size():
		return
	while layers.size() < n:
		layers.append(LayerSettings.new())
	layers.resize(n)
	layers_changed.emit()


func from_array(list: Array) -> void:
	layers.clear()
	for d in list:
		if typeof(d) == TYPE_DICTIONARY and layers.size() < MAX_LAYERS:
			var l := LayerSettings.new()
			l.from_dict(d)
			layers.append(l)
	layers_changed.emit()


func to_array() -> Array:
	return layers.map(func(l: LayerSettings): return l.to_dict())
