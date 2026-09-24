@tool
extends Node

## Editor half of live sync. The player's half is
## project_engine/player/live_sync/ws_client.gd, which documents the
## protocol. This is a WebSocket server on 127.0.0.1; the player that
## Preview starts connects to it (`--live-sync <port>`).
##
## While a player is connected and the previewed scene is the one open:
##   - scrubbing the Animation panel seeks the player,
##   - playing / pausing the animation plays / pauses the player,
##   - when the player pauses, or is scrubbed while paused, the Animation
##     panel's playhead jumps there: watch in the player (or headset), stop
##     at a moment, and keyframe it here.
## Preview and saving the scene send `open`, which hot-reloads the player.

signal connection_changed(connected: bool)

const DEFAULT_PORT := 47810
const PORT_TRIES := 10
## The animation the exporter reads (scene_exporter.gd's _ANIMATION_NAME).
const ANIMATION := "main"
## Scrub seeks go out at most this often; the player coalesces video seeks
## anyway, but each one also reprojects the stage.
const SEEK_INTERVAL_MSEC := 33
## A jump bigger than a frame's worth plus this while playing means the
## timeline was clicked.
const PLAY_JUMP := 0.25
const SAME_TIME := 0.002

var port: int = 0
var _server: TCPServer
var _peers: Array[WebSocketPeer] = []
var _connected: bool = false
var _seq: int = 0
var _scene_path: String = ""  # the previewed .tscn
var _script_path: String = ""  # the JSON it exports to
var _was_playing: bool = false
var _last_t: float = -1.0  # < 0: not watching yet, take the next state as-is
var _seek_pending: bool = false
var _last_seek_msec: int = 0
var _time_box: SpinBox  # the Animation panel's time field, see _panel_time_box


func start(preferred_port: int = DEFAULT_PORT) -> bool:
	if _server != null:
		return true
	_server = TCPServer.new()
	for i in PORT_TRIES:
		if _server.listen(preferred_port + i, "127.0.0.1") == OK:
			port = preferred_port + i
			return true
	push_warning("VJ live sync: no free port in %d-%d; the player won't follow the editor." % [preferred_port, preferred_port + PORT_TRIES - 1])
	_server = null
	return false


func stop() -> void:
	for ws in _peers:
		ws.close()
	_peers.clear()
	if _server != null:
		_server.stop()
		_server = null
	_set_connected(false)


func is_listening() -> bool:
	return _server != null


func is_connected_to_player() -> bool:
	return _connected


## Remember what's being previewed and, if a player is connected, show it
## there from `t`. Without `playing` the player keeps its play state.
## False if no player is connected (the caller launches one).
func open(scene_path: String, script_path: String, t: float, playing: Variant = null) -> bool:
	_scene_path = scene_path
	_script_path = script_path
	_last_t = -1.0
	if not _connected:
		return false
	var msg := {"path": script_path, "t": t}
	if playing != null:
		msg["playing"] = bool(playing)
	_send("open", msg)
	return true


func is_previewing(scene_path: String) -> bool:
	return scene_path != "" and scene_path == _scene_path


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if _server == null:
		return
	_poll_peers()
	var anim := _synced_player()
	if anim == null or not _connected:
		_last_t = -1.0
		return
	_follow_editor(anim, delta)


func _poll_peers() -> void:
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		var ws := WebSocketPeer.new()
		if tcp != null and ws.accept_stream(tcp) == OK:
			_peers.append(ws)
	var open_count := 0
	for ws in _peers.duplicate():
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				open_count += 1
				while ws.get_available_packet_count() > 0:
					var msg = JSON.parse_string(ws.get_packet().get_string_from_utf8())
					if typeof(msg) == TYPE_DICTIONARY and msg.get("type") == "state":
						_on_player_state(msg)
			WebSocketPeer.STATE_CLOSED:
				_peers.erase(ws)
	_set_connected(open_count > 0)


func _set_connected(connected: bool) -> void:
	if connected == _connected:
		return
	_connected = connected
	_last_t = -1.0
	print("VJ live sync: player %s" % ("connected" if connected else "disconnected"))
	connection_changed.emit(connected)


## Editor → player: the Animation panel's play state and scrubbing.
func _follow_editor(anim: AnimationPlayer, delta: float) -> void:
	var playing := anim.is_playing()
	var t := anim.current_animation_position
	if _last_t < 0.0:
		# Just started watching: this is the baseline, not a change to send.
		_last_t = t
		_was_playing = playing
		return
	if playing != _was_playing:
		_send("play" if playing else "pause", {"t": t})
		_seek_pending = false
	elif playing:
		if absf(t - _last_t) > delta * absf(anim.get_playing_speed()) + PLAY_JUMP:
			_send("seek", {"t": t})
	elif absf(t - _last_t) > SAME_TIME:
		_seek_pending = true
	if _seek_pending and Time.get_ticks_msec() - _last_seek_msec >= SEEK_INTERVAL_MSEC:
		_seek_pending = false
		_last_seek_msec = Time.get_ticks_msec()
		_send("seek", {"t": t})
	_was_playing = playing
	_last_t = t


## Player → editor: follow the player's playhead while it is paused. Only
## from states that ack our latest command, so a reply to a seek we've
## already superseded (mid-scrub) doesn't drag the playhead back.
func _on_player_state(msg: Dictionary) -> void:
	if bool(msg.get("playing", false)) or int(msg.get("ack", -1)) != _seq:
		return
	if not _same_path(String(msg.get("script", "")), _script_path):
		return
	var anim := _synced_player()
	if anim == null or anim.is_playing():
		return
	var t := float(msg.get("t", 0.0))
	if absf(t - anim.current_animation_position) < SAME_TIME:
		return
	_set_editor_playhead(anim, t)
	_last_t = anim.current_animation_position
	_seek_pending = false


## The open scene's AnimationPlayer, if that scene is the previewed one and
## its "main" animation is the one in the panel.
func _synced_player() -> AnimationPlayer:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not is_previewing(root.scene_file_path):
		return null
	for child in root.get_children():
		if child is AnimationPlayer and String(child.assigned_animation) == ANIMATION:
			return child
	return null


## Move the Animation panel's playhead. Its time field seeks the player and
## moves the timeline cursor too; AnimationPlayer.seek() alone updates the
## scene but leaves the panel's cursor where it was. Falls back to seek()
## when the panel is showing some other player.
func _set_editor_playhead(anim: AnimationPlayer, t: float) -> void:
	var box := _panel_time_box()
	if box != null and is_equal_approx(box.max_value, anim.get_animation(ANIMATION).length):
		box.value = t
	if absf(anim.current_animation_position - t) > SAME_TIME:
		anim.seek(t, true)


## The time SpinBox in the Animation panel's toolbar: the first SpinBox under
## the (unexposed) AnimationPlayerEditor, as of Godot 4.7.
func _panel_time_box() -> SpinBox:
	if is_instance_valid(_time_box):
		return _time_box
	_time_box = null
	var editors := EditorInterface.get_base_control().find_children("*", "AnimationPlayerEditor", true, false)
	if not editors.is_empty():
		var boxes := editors[0].find_children("*", "SpinBox", true, false)
		if not boxes.is_empty():
			_time_box = boxes[0]
	return _time_box


func _send(type: String, fields: Dictionary) -> void:
	_seq += 1
	fields["type"] = type
	fields["seq"] = _seq
	if fields.has("t"):
		fields["t"] = snappedf(float(fields["t"]), 0.001)
	var text := JSON.stringify(fields)
	for ws in _peers:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(text)


static func _same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").simplify_path().to_lower() == b.replace("\\", "/").simplify_path().to_lower()
