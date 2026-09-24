class_name WhirligigServer
extends Node

## Whirligig-compatible timecode server, so MultiFunPlayer (and ScriptPlayer
## and similar tools) can sync device scripts to the player. Protocol, as
## consumed by MultiFunPlayer's WhirligigMediaSource: plain TCP, the player
## pushes newline-terminated UTF-8 lines and never reads anything back:
##
##   C "<absolute media path>"   media changed (bare `C` = no media)
##   duration = <seconds>        media length
##   P <seconds>                 playing, current position (sent repeatedly)
##   S                           stopped / paused
##
## MultiFunPlayer matches funscripts by the media file name, so the path we
## announce is the OS path of the video, not the timeline .json.
##
## State is polled from the ScriptRunner rather than pushed by main.gd, so
## seeks, scrubs and play/pause from any UI surface are reported uniformly.
## "Playing" means the picture is actually moving: a runner on hold (video
## still opening or seeking) reports `S`, so devices don't run ahead.
##
## A media change goes out as `S`, then `C "<path>"`; `duration` follows once
## it is known and `P` once playback really starts, so a client never sees
## positions for the new file before its video is running.

const DEFAULT_PORT := 2000
## Seconds between `P` updates while playing. MultiFunPlayer interpolates
## between updates, so ~20 Hz is plenty.
const POSITION_INTERVAL := 0.05

var _server: TCPServer
var _peers: Array[StreamPeerTCP] = []
var _runner: ScriptRunner
var _media_path: String = ""
var _last_duration: float = -1.0
var _last_playing: bool = false
var _since_position: float = 0.0


## Start listening. bind_address "127.0.0.1" keeps it local; "*" also
## accepts MultiFunPlayer running on another machine.
func start(port: int = DEFAULT_PORT, bind_address: String = "127.0.0.1") -> bool:
	stop()
	_server = TCPServer.new()
	var err := _server.listen(port, bind_address)
	if err != OK:
		push_warning("WhirligigServer: could not listen on %s:%d (error %d)" % [bind_address, port, err])
		_server = null
		return false
	print("Whirligig timecode server listening on %s:%d" % [bind_address, port])
	return true


func stop() -> void:
	for peer in _peers:
		peer.disconnect_from_host()
	_peers.clear()
	if _server != null:
		_server.stop()
		_server = null


func is_listening() -> bool:
	return _server != null and _server.is_listening()


func peer_count() -> int:
	return _peers.size()


func bind(runner: ScriptRunner) -> void:
	_runner = runner


## Announce new media. Empty path = no media (e.g. a script without video).
func set_media_path(os_path: String) -> void:
	_media_path = os_path
	_last_duration = -1.0  # force a fresh duration line after the C line
	_last_playing = false  # the next P goes out as soon as playback starts
	_since_position = 0.0
	_broadcast(stopped_line() + media_line(_media_path))


func _process(delta: float) -> void:
	poll(delta)


## One server step: accept clients, drop dead ones, push state changes.
## Called from _process; tests call it directly.
func poll(delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		peer.set_no_delay(true)
		_peers.append(peer)
		_send_snapshot(peer)
	_prune_peers()
	_broadcast_state(false, delta)


func _exit_tree() -> void:
	stop()


# --- message formatting (static so tests can check the wire format) ---

static func media_line(os_path: String) -> String:
	if os_path == "":
		return "C\n"
	return "C \"%s\"\n" % os_path


static func duration_line(seconds: float) -> String:
	return "duration = %.3f\n" % seconds


static func position_line(seconds: float) -> String:
	return "P %.3f\n" % seconds


static func stopped_line() -> String:
	return "S\n"


# --- internals ---

func _send_snapshot(peer: StreamPeerTCP) -> void:
	var text := media_line(_media_path)
	var duration := _duration()
	if _media_path != "" and duration > 0.0:
		text += duration_line(duration)
		_last_duration = duration
	text += position_line(_runner.playhead) if _is_playing() else stopped_line()
	_send(peer, text)


func _broadcast_state(force: bool, delta: float = 0.0) -> void:
	if _peers.is_empty():
		# Still track state so a later snapshot/edge isn't stale.
		_last_playing = _is_playing()
		return
	var duration := _duration()
	if _media_path != "" and duration > 0.0 and not is_equal_approx(duration, _last_duration):
		_last_duration = duration
		_broadcast(duration_line(duration))
	var playing := _is_playing()
	if playing:
		_since_position += delta
		if force or not _last_playing or _since_position >= POSITION_INTERVAL:
			_since_position = 0.0
			_broadcast(position_line(_runner.playhead))
	elif force or _last_playing:
		_broadcast(stopped_line())
	_last_playing = playing


func _is_playing() -> bool:
	return _runner != null and _runner.playing and not _runner.hold


func _duration() -> float:
	return _runner.effective_duration() if _runner != null else 0.0


func _broadcast(text: String) -> void:
	for peer in _peers:
		_send(peer, text)


func _send(peer: StreamPeerTCP, text: String) -> void:
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	peer.put_data(text.to_utf8_buffer())


func _prune_peers() -> void:
	var alive: Array[StreamPeerTCP] = []
	for peer in _peers:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			alive.append(peer)
	_peers = alive
