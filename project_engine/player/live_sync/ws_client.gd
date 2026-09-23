class_name LiveSyncClient
extends Node

signal message_received(msg: Dictionary)
signal connected
signal disconnected

var _ws: WebSocketPeer
var _url: String = ""
var _connected: bool = false


func _ready() -> void:
	set_process(false)


func connect_to(url: String) -> void:
	_url = url
	_ws = WebSocketPeer.new()
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("LiveSyncClient failed to connect to %s: %s" % [url, err])
		return
	set_process(true)


func send(msg: Dictionary) -> void:
	if _ws == null or not _connected:
		return
	_ws.send_text(JSON.stringify(msg))


func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			connected.emit()
		while _ws.get_available_packet_count() > 0:
			var raw := _ws.get_packet().get_string_from_utf8()
			var parsed = JSON.parse_string(raw)
			if typeof(parsed) == TYPE_DICTIONARY:
				message_received.emit(parsed)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected:
			_connected = false
			disconnected.emit()
		set_process(false)
