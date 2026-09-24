class_name LiveSyncClient
extends Node

## Live sync with the authoring editor (addon_vj/live_sync/live_sync.gd). The
## editor runs a WebSocket server on 127.0.0.1 and starts the player with
## `--live-sync <port>`; this connects to it, retrying every second, so an
## editor restart or addon reload reconnects on its own. JSON text messages
## with a `type`:
##
##   editor → player
##     open   {path, t, playing?, seq} show the script from t (reload in place if
##                                      already showing it); no `playing` = keep play state
##     seek   {t, seq}
##     play   {t, seq}                 seek to t first if we're elsewhere
##     pause  {t, seq}
##   player → editor
##     state  {script, t, playing, ack}  on connect, after each command, on
##                                       play/pause, and ~10 Hz while the playhead moves
##
## `ack` is the seq of the last editor command applied. The editor only moves
## its own playhead from states that ack its latest command, so replies to
## commands it has since superseded (mid-scrub) don't pull it back.
##
## seek/play/pause only apply while the player shows the editor's script:
## once the viewer opens something else here, the editor's scrubbing leaves
## it alone until the next open. main.gd does the actual work, via the
## *_requested signals; the runner is only read, for state.

signal open_requested(path: String, t: float, playing: bool)
signal seek_requested(t: float)
signal play_requested
signal pause_requested

const RETRY_INTERVAL := 1.0
const STATE_INTERVAL := 0.1
## A play/pause at a time closer than this to the playhead doesn't seek, so
## pressing play in the editor right where the player is paused doesn't
## stall the video on a seek.
const SEEK_TOLERANCE := 0.05

var _runner: ScriptRunner
var _url: String = ""
var _enabled: bool = true
var _ws: WebSocketPeer
var _open: bool = false
var _retry_in: float = 0.0
var _script_path: String = ""  # the editor's script
var _ack: int = 0
var _last_playing: bool = false
var _last_t: float = -1.0
var _since_state: float = 0.0


func bind(runner: ScriptRunner) -> void:
	_runner = runner


## The script the editor launched us with (`--script`); later `open`s replace it.
func set_script_path(path: String) -> void:
	_script_path = path


func connect_to_editor(port: int) -> void:
	_url = "ws://127.0.0.1:%d" % port
	_retry_in = 0.0


## Off: drop the connection and stop retrying until switched back on.
func set_enabled(on: bool) -> void:
	if on == _enabled:
		return
	_enabled = on
	if not on and _ws != null:
		_ws.close()
		_ws = null
		if _open:
			print("Live sync: off")
		_open = false
	_retry_in = 0.0


func is_connected_to_editor() -> bool:
	return _open


func showing_editor_script() -> bool:
	return _runner != null and _runner.timeline != null and _script_path != "" \
			and same_path(_runner.timeline.script_path, _script_path)


## Windows paths: separators and case don't matter.
static func same_path(a: String, b: String) -> bool:
	return a.replace("\\", "/").simplify_path().to_lower() == b.replace("\\", "/").simplify_path().to_lower()


func _process(delta: float) -> void:
	poll(delta)


## One client step: (re)connect, read commands, report state. Called from
## _process; tests call it directly.
func poll(delta: float) -> void:
	if _url == "" or not _enabled:
		return
	if _ws == null:
		_retry_in -= delta
		if _retry_in > 0.0:
			return
		_ws = WebSocketPeer.new()
		if _ws.connect_to_url(_url) != OK:
			_ws = null
			_retry_in = RETRY_INTERVAL
			return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _open:
				_open = true
				print("Live sync: connected to the editor at %s" % _url)
				_send_state()
			while _ws.get_available_packet_count() > 0:
				var parsed = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY:
					_handle(parsed)
			_report_state(delta)
		WebSocketPeer.STATE_CLOSED:
			if _open:
				print("Live sync: editor disconnected, reconnecting...")
			_open = false
			_ws = null
			_retry_in = RETRY_INTERVAL


func _exit_tree() -> void:
	if _ws != null:
		_ws.close()


func _handle(msg: Dictionary) -> void:
	var type := String(msg.get("type", ""))
	var t := float(msg.get("t", 0.0))
	_ack = int(msg.get("seq", _ack))
	match type:
		"open":
			_script_path = String(msg.get("path", ""))
			if _script_path != "":
				var playing := _runner != null and _runner.playing
				open_requested.emit(_script_path, t, bool(msg.get("playing", playing)))
		"seek":
			if showing_editor_script():
				seek_requested.emit(t)
		"play":
			if showing_editor_script():
				if absf(t - _runner.playhead) > SEEK_TOLERANCE:
					seek_requested.emit(t)
				play_requested.emit()
		"pause":
			if showing_editor_script():
				pause_requested.emit()
				if absf(t - _runner.playhead) > SEEK_TOLERANCE:
					seek_requested.emit(t)
		_:
			return
	_send_state()


func _report_state(delta: float) -> void:
	if _runner == null:
		return
	_since_state += delta
	var moved := absf(_runner.playhead - _last_t) > 0.0005
	if _runner.playing != _last_playing or (moved and _since_state >= STATE_INTERVAL):
		_send_state()


func _send_state() -> void:
	if _ws == null or not _open:
		return
	var script := ""
	var t := 0.0
	var playing := false
	if _runner != null:
		script = _runner.timeline.script_path if _runner.timeline != null else ""
		t = _runner.playhead
		playing = _runner.playing
	_last_t = t
	_last_playing = playing
	_since_state = 0.0
	_ws.send_text(JSON.stringify(state_message(script, t, playing, _ack)))


static func state_message(script: String, t: float, playing: bool, ack: int) -> Dictionary:
	return {"type": "state", "script": script, "t": snappedf(t, 0.001), "playing": playing, "ack": ack}
