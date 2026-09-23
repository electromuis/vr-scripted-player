## Headless tests for GoZenPlayer functionality
## Tests basic operations: open, play, pause, seek, get_texture

class_name GoZenPlayerTests
extends RefCounted

var TestCaseClass = load("res://tests/test_case.gd")


static func test_gozen_player_initializes(tc: TestCaseClass) -> void:
	# Test that GoZenPlayer class exists and can be instantiated
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	tc.assert_true(player.initialize(), "Player should initialize successfully")
	player.queue_free()


static func test_gozen_player_open_and_close(tc: TestCaseClass) -> void:
	# Test opening and closing a video
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	# Use a test video file
	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()

	var success: bool = player.open(test_video)
	tc.assert_true(success, "Should open video successfully")

	tc.assert_true(player.is_open(), "Player should be open after open()")
	tc.assert_true(player.get_frame_count() > 0, "Video should have frames")
	tc.assert_true(player.get_framerate() > 0, "Video should have framerate")

	player.close()
	tc.assert_false(player.is_open(), "Player should be closed after close()")
	player.queue_free()


static func test_gozen_player_play_pause(tc: TestCaseClass) -> void:
	# Test play and pause functionality
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()
	player.open(test_video)
	player.play()

	tc.assert_true(player.is_playing(), "Player should be playing after play()")

	player.pause()
	tc.assert_false(player.is_playing(), "Player should be paused after pause()")

	player.play()
	tc.assert_true(player.is_playing(), "Player should be playing after resume()")

	player.close()
	player.queue_free()


static func test_gozen_player_seek(tc: TestCaseClass) -> void:
	# Test seeking to specific frames
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()
	player.open(test_video)
	player.play()

	var total_frames: int = player.get_frame_count()
	var mid_frame: int = total_frames / 2

	player.seek_frame(mid_frame)
	var current_frame: int = player.get_current_frame()
	tc.assert_eq(current_frame, mid_frame, "Current frame should match sought frame")

	player.close()
	player.queue_free()


static func test_gozen_player_texture_retrieval(tc: TestCaseClass) -> void:
	# Test getting video texture
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()
	player.open(test_video)
	player.play()

	var texture: ImageTexture = player.get_texture()
	tc.assert_true(texture != null, "Texture should not be null")
	tc.assert_true(texture is ImageTexture, "Texture should be ImageTexture")

	var width: int = player.get_width()
	var height: int = player.get_height()
	tc.assert_true(width > 0, "Width should be positive")
	tc.assert_true(height > 0, "Height should be positive")

	player.close()
	player.queue_free()


static func test_gozen_player_dimensions(tc: TestCaseClass) -> void:
	# Test getting video dimensions
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()
	player.open(test_video)

	var width: int = player.get_width()
	var height: int = player.get_height()
	var actual_res: Vector2 = player.get_actual_resolution()

	tc.assert_true(width > 0, "Width should be positive")
	tc.assert_true(height > 0, "Height should be positive")
	tc.assert_true(actual_res.x > 0, "Actual resolution X should be positive")
	tc.assert_true(actual_res.y > 0, "Actual resolution Y should be positive")

	player.close()
	player.queue_free()


static func test_gozen_player_frame_count_and_framerate(tc: TestCaseClass) -> void:
	# Test getting frame count and framerate
	if not ClassDB.class_exists("GoZenPlayer"):
		tc.fail("GoZenPlayer class not found")
		return

	var test_video := "res://examples/minimal/video.mp4"

	if not FileAccess.file_exists(test_video):
		tc.skip("Test video not found")
		return

	var player: GoZenPlayer = GoZenPlayer.new()
	player.initialize()
	player.open(test_video)

	var frame_count: int = player.get_frame_count()
	var framerate: float = player.get_framerate()

	tc.assert_true(frame_count > 0, "Frame count should be positive")
	tc.assert_true(framerate > 0, "Framerate should be positive")
	tc.assert_true(framerate <= 30.0, "Framerate should be reasonable (<=30)")

	player.close()
	player.queue_free()
