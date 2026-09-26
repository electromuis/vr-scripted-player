extends RefCounted

## Tests for player/beats/: BeatGrid maths, BeatDetector on a synthetic
## track with a known grid, BeatClock's uniforms, cache and script grids.

const RATE := 22050
const BPM := 124.0
const DOWNBEAT := 0.61  # seconds: the first "1" (one pickup beat before it)
const SECONDS := 24.0


## Kick on every beat, snare on 2 and 4, hi-hat on the offbeats, and a bass
## note that changes every bar, as 16-bit mono.
static func _synth_track() -> AudioStreamWAV:
	var n := int(SECONDS * RATE)
	var spb := 60.0 / BPM
	var data := PackedFloat32Array()
	data.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var noise := PackedFloat32Array()
	noise.resize(RATE)
	for i in RATE:
		noise[i] = rng.randf_range(-1.0, 1.0)
	var roots := [55.0, 41.2, 49.0, 36.7]
	var k := -1
	while true:
		var t := DOWNBEAT + k * spb
		if t >= SECONDS:
			break
		var beat := posmod(k, 4)
		var bar := floori(float(k) / 4.0)
		var i0 := int(t * RATE)
		for j in int(0.35 * RATE):
			var i := i0 + j
			if i < 0 or i >= n:
				continue
			var x := float(j) / RATE
			var v := 0.8 * sin(TAU * (45.0 * x + 80.0 * (1.0 - exp(-x * 30.0)) / 30.0)) * exp(-x * 8.0)
			if beat == 1 or beat == 3:
				v += 0.3 * noise[j] * exp(-x * 20.0)
			var h := x - spb * 0.5
			if h >= 0.0:
				v += 0.08 * (noise[(j + 1) % RATE] - noise[j]) * exp(-h * 60.0)
			data[i] += v
		# Bass: the bar's root, held for the bar.
		if beat == 0:
			var root: float = roots[posmod(bar, 4)]
			for j in int(4.0 * spb * RATE):
				var i := i0 + j
				if i >= 0 and i < n:
					data[i] += 0.25 * sin(TAU * root * j / RATE)
		k += 1
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(data[i] * 0.6, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav


static func test_grid_math(tc: TestCase) -> void:
	var g := BeatGrid.make(120.0, 0.5)
	tc.assert_eq(g.seconds_per_beat(), 0.5)
	tc.assert_eq(g.beat_at(0.5), 0.0)
	tc.assert_eq(g.beat_at(1.75), 2.5)
	tc.assert_eq(g.bar_at(2.5), 1.0)
	tc.assert_eq(g.time_of_beat(4.0), 2.5)
	g.shift_downbeat(1)
	tc.assert_eq(g.offset, 1.0)
	g.shift_downbeat(-3)  # 1.0 - 1.5 wraps to the next bar's downbeat
	tc.assert_true(is_equal_approx(g.offset, 1.5), "offset %f" % g.offset)
	g.scale_tempo(2.0)
	tc.assert_eq(g.bpm, 240.0)
	tc.assert_true(g.offset < g.seconds_per_beat() * 4.0, "offset kept within a bar")


static func test_grid_dict(tc: TestCase) -> void:
	var g := BeatGrid.from_dict({"bpm": 128, "offset": 0.25, "beats_per_bar": 3})
	tc.assert_eq(g.bpm, 128.0)
	tc.assert_eq(g.beats_per_bar, 3)
	tc.assert_eq(g.confidence, 1.0)
	var back := BeatGrid.from_dict(g.to_dict())
	tc.assert_eq(back.to_dict(), g.to_dict())
	tc.assert_eq(BeatGrid.from_dict({"bpm": 0}), null)
	tc.assert_eq(BeatGrid.from_dict({"offset": 1.0}), null)
	tc.assert_eq(BeatGrid.from_dict("128"), null)


static func test_detects_synthetic_track(tc: TestCase) -> void:
	var g := BeatDetector.new().analyze(_synth_track())
	tc.assert_eq(g.bpm, BPM)
	tc.assert_eq(g.beats_per_bar, 4)
	# Same downbeat, give or take a few milliseconds, bars apart.
	var bar := 4.0 * 60.0 / BPM
	var err := absf(fposmod(g.offset - DOWNBEAT + bar * 0.5, bar) - bar * 0.5)
	tc.assert_true(err < 0.008, "downbeat off by %.4f s (offset %.4f)" % [err, g.offset])
	tc.assert_true(g.confidence > 0.6, "confidence %.2f" % g.confidence)


static func test_silence_has_no_beat(tc: TestCase) -> void:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	var bytes := PackedByteArray()
	bytes.resize(RATE * 2 * 5)
	wav.data = bytes
	var g := BeatDetector.new().analyze(wav)
	tc.assert_false(g.is_valid())


static func test_clock_uniforms(tc: TestCase) -> void:
	var clock := BeatClock.new()
	var u := clock.uniforms()
	tc.assert_eq(u.beat_bpm, 0.0)
	clock.load_for("", BeatGrid.make(120.0, 1.0))
	clock.advance(0.016, -1.0, 2.25, false)  # paused: follows the playhead
	u = clock.uniforms()
	tc.assert_eq(u.beat_bpm, 120.0)
	tc.assert_eq(u.beat_time, 2.5)
	tc.assert_eq(u.beat_phase, 0.5)
	tc.assert_eq(u.beat_in_bar, 2)
	tc.assert_eq(u.bar_phase, 0.625)
	# Before the downbeat: counts back, bars wrap.
	clock.advance(0.016, -1.0, 0.75, false)
	u = clock.uniforms()
	tc.assert_eq(u.beat_time, -0.5)
	tc.assert_eq(u.beat_in_bar, 3)
	# Playing: eases small audio clock jitter, snaps big jumps.
	clock.advance(0.016, 10.0, 0.0, true)
	tc.assert_eq(clock.time, 10.0)
	clock.advance(0.016, 10.026, 0.0, true)
	tc.assert_true(clock.time > 10.016 and clock.time < 10.026, "eased to %f" % clock.time)
	clock.free()


static func test_clock_detects_and_caches(tc: TestCase) -> void:
	var dir := OS.get_user_data_dir().path_join("test_beats")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("track.wav")
	tc.assert_eq(_synth_track().save_to_wav(path), OK)
	var cache := BeatClock._cache_file(path)
	DirAccess.remove_absolute(cache)
	var clock := BeatClock.new()
	clock.load_for(path)
	tc.assert_true(clock.is_analyzing(), "scans an uncached file")
	var waited := 0
	while clock.is_analyzing() and waited < 20000:
		OS.delay_msec(20)
		waited += 20
		clock._process(0.0)
	tc.assert_true(clock.grid != null and clock.grid.bpm == BPM, "detected %s" % [clock.grid.to_dict() if clock.grid else null])
	tc.assert_true(FileAccess.file_exists(cache), "cached")
	# A correction is remembered; the next load comes from the cache.
	clock.shift_downbeat(1)
	var shifted := clock.grid.offset
	clock.load_for("")
	clock.load_for(path)
	tc.assert_false(clock.is_analyzing(), "cache hit")
	tc.assert_true(clock.grid != null and is_equal_approx(clock.grid.offset, shifted), "correction kept")
	# A script's grid wins, and URLs aren't scanned.
	clock.load_for(path, BeatGrid.make(90.0, 0.0))
	tc.assert_eq(clock.grid.bpm, 90.0)
	clock.load_for("http://example.com/x.mp4")
	tc.assert_false(clock.is_analyzing())
	tc.assert_eq(clock.grid, null)
	clock._exit_tree()
	clock.free()
	DirAccess.remove_absolute(cache)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)


static func test_script_beats_field(tc: TestCase) -> void:
	var ok := ScriptFormat.load_from_string('{"format_version":1,"media":{"video":"x.mp4","beats":{"bpm":128,"offset":0.2}}}')
	tc.assert_ok(ok)
	tc.assert_eq(BeatGrid.from_dict(ok.data.media.beats).bpm, 128.0)
	tc.assert_err(ScriptFormat.load_from_string('{"format_version":1,"media":{"video":"x.mp4","beats":{"bpm":0}}}'), "media.beats.bpm")
	tc.assert_err(ScriptFormat.load_from_string('{"format_version":1,"media":{"video":"x.mp4","beats":128}}'), "media.beats")


static func test_beat_shaders_compile(tc: TestCase) -> void:
	for key in ["beat_tunnel", "laser_fan", "kaleido_pulse"]:
		var path := "res://player/visualizer/shaders/%s.gdshader" % key
		var shader := VisualizerShaders.load_shader(path)
		tc.assert_true(shader != null, "%s loads" % key)
		var hints := VisualizerShaders.parse_hints(shader.code)
		tc.assert_true(hints.params.size() >= 3, "%s has controls" % key)
		var labels := VisualizerShaders.list_options([]).map(func(o): return o.key)
		tc.assert_true(labels.has(path), "%s is a built-in" % key)
