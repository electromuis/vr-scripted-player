extends RefCounted

## WhirligigServer wire format + a real loopback TCP round-trip. Lines must
## match what MultiFunPlayer's WhirligigMediaSource parses.

const TEST_PORT := 23917


static func test_line_format(t: TestCase) -> void:
	t.assert_eq(WhirligigServer.media_line("C:/videos/a b.mp4"), "C \"C:/videos/a b.mp4\"\n")
	t.assert_eq(WhirligigServer.media_line(""), "C\n")
	t.assert_eq(WhirligigServer.duration_line(125.5), "duration = 125.500\n")
	t.assert_eq(WhirligigServer.position_line(3.25), "P 3.250\n")
	t.assert_eq(WhirligigServer.stopped_line(), "S\n")


static func test_loopback_snapshot_and_updates(t: TestCase) -> void:
	var runner := ScriptRunner.new()
	runner.set_video_duration(60.0)
	var server := WhirligigServer.new()
	server.bind(runner)
	if not server.start(TEST_PORT):
		t.fail("could not listen on %d" % TEST_PORT)
		server.free()
		runner.free()
		return
	server.set_media_path("C:/videos/clip.mp4")

	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", TEST_PORT)
	var received := _pump(server, client, func(s: String): return s.contains("S\n"))
	t.assert_has(received, "C \"C:/videos/clip.mp4\"\n", "snapshot media")
	t.assert_has(received, "duration = 60.000\n", "snapshot duration")
	t.assert_has(received, "S\n", "snapshot paused state")
	t.assert_eq(server.peer_count(), 1)

	runner.playing = true
	runner.playhead = 12.5
	received = _pump(server, client, func(s: String): return s.contains("P "))
	t.assert_has(received, "P 12.500\n", "position on play")

	runner.playing = false
	received = _pump(server, client, func(s: String): return s.contains("S\n"))
	t.assert_has(received, "S\n", "stop on pause")

	# New media while playing: S then C straight away, nothing more while the
	# video opens (runner on hold), then P once it really plays.
	runner.playing = true
	_pump(server, client, func(s: String): return s.contains("P "))
	runner.hold = true
	runner.playhead = 0.0
	server.set_media_path("C:/videos/next.mp4")
	received = _pump(server, client, func(s: String): return s.contains("next.mp4"))
	t.assert_true(received.begins_with("S\nC \"C:/videos/next.mp4\"\n"), "pause, then media: %s" % received.c_escape())
	received = _pump(server, client, func(_s: String): return false)
	t.assert_false(received.contains("P "), "no position while loading")
	runner.hold = false
	received = _pump(server, client, func(s: String): return s.contains("P "))
	t.assert_has(received, "P 0.000\n", "position once playback starts")

	client.disconnect_from_host()
	server.stop()
	server.free()
	runner.free()


## Step server + client until `done` matches the received text or ~1s passes.
static func _pump(server: WhirligigServer, client: StreamPeerTCP, done: Callable) -> String:
	var text := ""
	for _i in 100:
		server.poll(0.1)
		client.poll()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var n := client.get_available_bytes()
			if n > 0:
				text += client.get_utf8_string(n)
			if done.call(text):
				break
		OS.delay_msec(10)
	return text
