extends RefCounted

## LiveSyncClient over a real loopback WebSocket, with the test playing the
## editor's server; plus ScriptRunner.reload(), which an `open` for the
## script already showing uses.

const TEST_PORT := 23918
const SCRIPT := "C:/pieces/demo/demo.json"


static func test_same_path(t: TestCase) -> void:
	t.assert_true(LiveSyncClient.same_path("C:\\Pieces\\demo\\demo.json", "c:/pieces/demo/demo.json"))
	t.assert_true(LiveSyncClient.same_path("C:/pieces/x/../demo/demo.json", SCRIPT))
	t.assert_false(LiveSyncClient.same_path("C:/pieces/other.json", SCRIPT))


static func test_loopback_commands_and_acks(t: TestCase) -> void:
	var runner := ScriptRunner.new()
	runner.timeline = TimelineData.new()
	runner.timeline.script_path = SCRIPT
	runner.playhead = 3.0

	var server := TCPServer.new()
	if server.listen(TEST_PORT, "127.0.0.1") != OK:
		t.fail("could not listen on %d" % TEST_PORT)
		runner.free()
		return
	var client := LiveSyncClient.new()
	client.bind(runner)
	client.set_script_path(SCRIPT)
	client.connect_to_editor(TEST_PORT)
	var got := {"seek": [], "play": 0, "pause": 0, "open": []}
	client.seek_requested.connect(func(s: float): got["seek"].append(s))
	client.play_requested.connect(func(): got["play"] += 1)
	client.pause_requested.connect(func(): got["pause"] += 1)
	client.open_requested.connect(func(p: String, s: float, playing: bool): got["open"].append([p, s, playing]))

	var editor: Array = [null]  # the server-side WebSocketPeer, once accepted
	var state := _pump(server, editor, client, func(m: Dictionary): return m.get("type") == "state")
	t.assert_eq(state.get("script"), SCRIPT, "hello state names the script")
	t.assert_eq(state.get("ack"), 0)
	t.assert_eq(state.get("t"), 3.0)
	t.assert_true(client.is_connected_to_editor())

	_send(editor, {"type": "seek", "t": 12.5, "seq": 1})
	state = _pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 1)
	t.assert_eq(got["seek"], [12.5], "seek forwarded")
	runner.playhead = 12.5  # main.gd would have seeked

	# Play right where the player already is: no extra seek.
	_send(editor, {"type": "play", "t": 12.52, "seq": 2})
	state = _pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 2)
	t.assert_eq(got["play"], 1)
	t.assert_eq(got["seek"].size(), 1, "no seek within tolerance")

	# Pause somewhere else: pause, then seek.
	_send(editor, {"type": "pause", "t": 20.0, "seq": 3})
	_pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 3)
	t.assert_eq(got["pause"], 1)
	t.assert_eq(got["seek"], [12.5, 20.0])

	# The viewer opened another file: transport is ignored, but still acked.
	runner.timeline.script_path = "C:/videos/other.mp4"
	_send(editor, {"type": "seek", "t": 5.0, "seq": 4})
	state = _pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 4)
	t.assert_eq(got["seek"].size(), 2, "seek ignored for a foreign script")
	t.assert_eq(state.get("script"), "C:/videos/other.mp4")

	# open without `playing` keeps the current play state.
	runner.playing = true
	_send(editor, {"type": "open", "path": SCRIPT, "t": 7.0, "seq": 5})
	_pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 5)
	t.assert_eq(got["open"], [[SCRIPT, 7.0, true]])
	_send(editor, {"type": "open", "path": SCRIPT, "t": 8.0, "playing": false, "seq": 6})
	_pump(server, editor, client, func(m: Dictionary): return m.get("ack") == 6)
	t.assert_eq(got["open"][1], [SCRIPT, 8.0, false])

	# Reports while the playhead moves, and on play/pause changes.
	runner.timeline.script_path = SCRIPT
	runner.playhead = 30.0
	state = _pump(server, editor, client, func(m: Dictionary): return m.get("t") == 30.0)
	t.assert_eq(state.get("playing"), true, "moving playhead reported")
	runner.playing = false
	state = _pump(server, editor, client, func(m: Dictionary): return m.get("playing") == false)
	t.assert_eq(state.get("t"), 30.0, "pause reported")

	if editor[0] != null:
		editor[0].close()
	server.stop()
	client.free()
	runner.free()


static func test_setting_persists(t: TestCase) -> void:
	var path := "user://test_live_sync_settings.json"
	var s := PlayerSettings.new(path)
	t.assert_true(s.live_sync, "on by default")
	s.live_sync = false
	var s2 := PlayerSettings.new(path)
	s2.load_from_disk()
	t.assert_false(s2.live_sync, "saved off")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func test_disable_drops_and_reenable_reconnects(t: TestCase) -> void:
	var runner := ScriptRunner.new()
	var server := TCPServer.new()
	if server.listen(TEST_PORT + 1, "127.0.0.1") != OK:
		t.fail("could not listen on %d" % (TEST_PORT + 1))
		runner.free()
		return
	var client := LiveSyncClient.new()
	client.bind(runner)
	client.connect_to_editor(TEST_PORT + 1)
	var editor: Array = [null]
	_pump(server, editor, client, func(m: Dictionary): return m.get("type") == "state")
	t.assert_true(client.is_connected_to_editor())

	client.set_enabled(false)
	t.assert_false(client.is_connected_to_editor(), "off drops the connection")
	editor[0] = null
	_pump(server, editor, client, func(_m: Dictionary): return false)
	t.assert_true(editor[0] == null, "no reconnect while off")

	client.set_enabled(true)
	var state := _pump(server, editor, client, func(m: Dictionary): return m.get("type") == "state")
	t.assert_eq(state.get("type"), "state", "reconnects when back on")
	t.assert_true(client.is_connected_to_editor())

	if editor[0] != null:
		editor[0].close()
	server.stop()
	client.free()
	runner.free()


static func test_runner_reload_keeps_playhead(t: TestCase) -> void:
	var path := "user://test_live_sync_reload.json"
	_write(path, "First")
	var runner := ScriptRunner.new()
	runner._registry = ObjectRegistry.new()
	runner.add_child(runner._registry)
	runner._prefabs = PrefabLibrary.new()
	if not runner.load_script(path):
		t.fail("fixture script did not load")
		runner.free()
		return
	runner.playhead = 4.0
	_write(path, "Second")
	t.assert_true(runner.reload(), "reload parses")
	t.assert_eq(runner.timeline.title(), "Second")
	t.assert_eq(runner.playhead, 4.0, "playhead kept")

	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ truncated")
	f.close()
	t.assert_false(runner.reload(), "a broken file doesn't reload")
	t.assert_eq(runner.timeline.title(), "Second", "last good timeline kept")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	runner.free()


static func _write(path: String, title: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"format_version": 1,
		"meta": {"title": title},
		"media": {"video": "x.mp4", "duration": 10.0},
		"objects": [],
		"tracks": [],
	}))
	f.close()


static func _send(editor: Array, msg: Dictionary) -> void:
	if editor[0] != null:
		editor[0].send_text(JSON.stringify(msg))


## Step both ends until a message from the client matches `done` or ~2s
## pass. Returns the last message received ({} if none).
static func _pump(server: TCPServer, editor: Array, client: LiveSyncClient, done: Callable) -> Dictionary:
	var last := {}
	for _i in 200:
		if editor[0] == null and server.is_connection_available():
			var ws := WebSocketPeer.new()
			ws.accept_stream(server.take_connection())
			editor[0] = ws
		client.poll(0.05)
		var ws: WebSocketPeer = editor[0]
		if ws != null:
			ws.poll()
			while ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.get_available_packet_count() > 0:
				var msg = JSON.parse_string(ws.get_packet().get_string_from_utf8())
				if typeof(msg) == TYPE_DICTIONARY:
					last = msg
					if done.call(msg):
						return msg
		OS.delay_msec(10)
	return last
