class_name BeatDetector
extends RefCounted

## Finds a track's tempo, beat positions and downbeat offline, from the
## whole track at once, so the grid is right from the first frame and
## survives seeking (see BeatClock). Runs on a worker thread; one detector
## per analysis.
##
## The tempo and beat phase follow ArrowVortex's BPM finder
## (github.com/uvcat7/ArrowVortex, src/Editor/FindTempo.cpp), reimplemented
## here, not copied:
##   1. note onsets, from the rise of three band energies (bass, mids, highs);
##   2. for every beat interval from 60 / MAX_BPM to 60 / MIN_BPM seconds,
##      wrap the onsets onto one interval and score the best phase: onset
##      strength within ±23 ms of it, plus half of that at the offbeat;
##   3. subtract a cubic fit of score against interval (longer intervals
##      collect more onsets), refine around the best intervals, prefer an
##      integer BPM when it fits as well, drop halves and doubles;
##   4. the beat phase is the best-supported onset position, moved to the
##      offbeat if the level rises more there (kicks are on the beat).
## The downbeat (not in ArrowVortex) is picked from the beats_per_bar
## candidates by how much the sound changes across each candidate's bar
## lines (chords, basslines and sections change on the 1) and where the
## kick and backbeat fall.
##
## Constant tempo only: a track with tempo changes gets its average grid.

const MIN_BPM := 89.0
const MAX_BPM := 205.0
const BEATS_PER_BAR := 4
## Analysed at the mix rate over this (playback rate scale): ~11 kHz.
const DECIMATION := 4.0
const HOP := 64  # analysis samples per envelope frame (~5.8 ms)
const CHUNK := 16384  # frames per mix_audio call
const LOW_HZ := 150.0  # bass band: below this
const MID_HZ := 1500.0  # mids: LOW_HZ..this; highs above
const BAND_WEIGHTS := [1.0, 0.7, 0.5]  # onset strength per band (bass, mids, highs)
## Longest stretch analysed; a longer video uses its start.
const MAX_SECONDS := 15.0 * 60.0
## A fast tempo whose every other beat carries less than this share of the
## onset strength of the beats between is taken at half speed: that's
## eighth notes over a slower beat, not a fast beat.
const HALF_TIME_RATIO := 0.7
## Gap window: onsets this far from a candidate beat (either side) still
## count for it, weighted by a triangle.
const WINDOW := 0.023
const COARSE_STEP := 10.0 / 44100.0  # interval step of the first pass (s)
const FINE_STEP := 1.0 / 44100.0
const COARSE_BIN := 0.002  # phase histogram bin, first pass (s)
const FINE_BIN := 0.0005

## 0..1 while analyze() runs, for a progress readout. Written by the worker.
var progress: float = 0.0
## What analyze() returned last, for callers polling a worker thread.
var result: BeatGrid = null

var _cancelled: bool = false
# Envelope frames: per-hop mean square of each band, and mean |level|.
var _fps: float = 0.0
var _bands: Array[PackedFloat32Array] = []
var _level := PackedFloat32Array()
# Onsets (seconds) and their strengths.
var _onsets := PackedFloat64Array()
var _strengths := PackedFloat32Array()
var _hist := PackedFloat32Array()  # scratch for _phase_scores
var _poly := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _poly_center: float = 0.0


## Stop a running analyze() at its next check; it returns null.
func cancel() -> void:
	_cancelled = true


## Decode `stream` from the start and find its beat grid. Returns null if
## cancelled, or a grid with bpm 0 when there's no audio or no steady beat.
func analyze(stream: AudioStream) -> BeatGrid:
	progress = 0.0
	if stream == null or not _extract(stream):
		result = null if _cancelled else BeatGrid.new()
	else:
		result = _analyze_envelopes()
	return result


func _analyze_envelopes() -> BeatGrid:
	_find_onsets()
	if _onsets.size() < 16:
		progress = 1.0
		return BeatGrid.new()
	var tempo := _find_tempo()
	if _cancelled:
		return null
	if tempo.is_empty():
		progress = 1.0
		return BeatGrid.new()
	var bpm: float = tempo.bpm
	var phase := _find_phase(60.0 / bpm)
	var down := _find_downbeat(bpm, phase)
	progress = 1.0
	return BeatGrid.make(bpm, phase + down * 60.0 / bpm, BEATS_PER_BAR, _confidence(60.0 / bpm, phase))


# ---------- decoding and envelopes ----------

## Decode the stream at 1/DECIMATION of the mix rate and reduce it to
## envelope frames. False if nothing could be decoded. The stream is asked
## to play DECIMATION times fast, which its resampler does cheaply; one
## that ignores the rate is mixed at 1× and averaged instead.
func _extract(stream: AudioStream) -> bool:
	var r := _extract_with(stream, false)
	if r < 0:
		r = _extract_with(stream, true)
	return r > 0


## 1 = done, 0 = nothing decoded (or cancelled), -1 = the stream didn't
## play at the asked rate (only checked when not `average`).
func _extract_with(stream: AudioStream, average: bool) -> int:
	var playback := stream.instantiate_playback()
	if playback == null:
		return 0
	var mix_rate := AudioServer.get_mix_rate()
	var fs := mix_rate / DECIMATION
	var step := int(DECIMATION) if average else 1
	var rate := 1.0 if average else DECIMATION
	var length := stream.get_length()
	var total := int(minf(length if length > 0.0 else MAX_SECONDS, MAX_SECONDS) * fs)
	_fps = fs / HOP
	_bands = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
	_level = PackedFloat32Array()
	var frames := total / HOP + 1
	for b in _bands:
		b.resize(frames)
	_level.resize(frames)
	var a_low := 1.0 - exp(-TAU * LOW_HZ / fs)
	var a_mid := 1.0 - exp(-TAU * MID_HZ / fs)
	var inv_step := 1.0 / step
	var lp_low := 0.0
	var lp_mid := 0.0
	var s_low := 0.0
	var s_mid := 0.0
	var s_high := 0.0
	var s_abs := 0.0
	var acc := 0.0
	var j := 0
	var k := 0
	var frame := 0
	var low: PackedFloat32Array = _bands[0]
	var mid: PackedFloat32Array = _bands[1]
	var high: PackedFloat32Array = _bands[2]
	var done := 0  # analysis samples
	playback.start(0.0)
	while done < total and not _cancelled:
		var buf := playback.mix_audio(rate, mini(CHUNK, total - done) * step)
		if buf.is_empty():
			break
		if done == 0 and not average and length > 0.0:
			var expected := buf.size() * DECIMATION / mix_rate
			var pos := playback.get_playback_position()
			if absf(pos - expected) > 0.2 * expected:
				playback.stop()
				return -1
		for v in buf:
			acc += v.x + v.y
			j += 1
			if j < step:
				continue
			var m := acc * 0.5 * inv_step
			acc = 0.0
			j = 0
			lp_low += a_low * (m - lp_low)
			lp_mid += a_mid * (m - lp_mid)
			var md := lp_mid - lp_low
			var hi := m - lp_mid
			s_low += lp_low * lp_low
			s_mid += md * md
			s_high += hi * hi
			s_abs += absf(m)
			k += 1
			if k == HOP:
				low[frame] = s_low / HOP
				mid[frame] = s_mid / HOP
				high[frame] = s_high / HOP
				_level[frame] = s_abs / HOP
				frame += 1
				k = 0
				s_low = 0.0
				s_mid = 0.0
				s_high = 0.0
				s_abs = 0.0
		done += buf.size() / step
		progress = 0.8 * done / total
		if length <= 0.0 and not playback.is_playing():
			break
	playback.stop()
	for b in _bands:
		b.resize(frame)
	_level.resize(frame)
	return 1 if frame > 0 and not _cancelled else 0


# ---------- onsets ----------

## Band log energies (over a 3-frame trailing window, so a bass cycle
## longer than a frame doesn't flicker), their frame-to-frame rise summed
## over bands, and its peaks. The rise in log energy finds quiet notes as
## well as loud ones; each onset's strength is how much louder the sound
## got, so a kick outweighs a hi-hat.
func _find_onsets() -> void:
	var n := _level.size()
	var odf := PackedFloat32Array()
	odf.resize(n)
	var loud := PackedFloat32Array()  # weighted band power, 3-frame window
	loud.resize(n)
	for b in _bands.size():
		var e: PackedFloat32Array = _bands[b]
		var mean := 0.0
		for i in n:
			mean += e[i]
		var eps := maxf(0.05 * mean / maxi(n, 1), 1e-12)
		var w: float = BAND_WEIGHTS[b]
		var prev := log(eps)
		for i in n:
			var s := (e[i] + (e[i - 1] if i >= 1 else 0.0) + (e[i - 2] if i >= 2 else 0.0)) / 3.0
			loud[i] += w * s
			var l := log(s + eps)
			if l > prev:
				odf[i] += w * (l - prev)
			prev = l
	_onsets = PackedFloat64Array()
	_strengths = PackedFloat32Array()
	if n < 4:
		return
	for i in n:
		loud[i] = sqrt(loud[i])
	# Peaks above 1.5× the local mean (±0.1 s) plus a floor from the whole
	# track, at least 30 ms apart.
	var total := 0.0
	var prefix := PackedFloat64Array()
	prefix.resize(n + 1)
	for i in n:
		total += odf[i]
		prefix[i + 1] = total
	var floor_ := 0.2 * total / n
	var half := maxi(1, roundi(0.1 * _fps))
	var min_gap := 0.03
	var peaks := PackedFloat32Array()  # odf at each onset, for the gap rule
	for i in range(1, n - 1):
		var o := odf[i]
		if o <= 0.0 or o < odf[i - 1] or o <= odf[i + 1]:
			continue
		var a := maxi(0, i - half)
		var b := mini(n, i + half + 1)
		var local := (prefix[b] - prefix[a]) / (b - a)
		if o < 1.5 * local + floor_:
			continue
		# Parabolic peak position between frames.
		var den := odf[i - 1] - 2.0 * o + odf[i + 1]
		var d := clampf(0.5 * (odf[i - 1] - odf[i + 1]) / den, -0.5, 0.5) if den < 0.0 else 0.0
		var t := (i + d) / _fps
		var after := maxf(loud[i], maxf(loud[mini(i + 1, n - 1)], loud[mini(i + 2, n - 1)]))
		var strength := maxf(0.0, after - loud[i - 1])
		var last := _onsets.size() - 1
		if last >= 0 and t - _onsets[last] < min_gap:
			if o > peaks[last]:
				_onsets[last] = t
				_strengths[last] = strength
				peaks[last] = o
			continue
		_onsets.append(t)
		_strengths.append(strength)
		peaks.append(o)
	# Relative to the loud end of the onsets (90th percentile), capped, so
	# a few huge hits don't outvote the rest and quiet ones still count.
	var sorted := _strengths.duplicate()
	sorted.sort()
	var ref := sorted[int(sorted.size() * 0.9)] if sorted.size() > 0 else 1.0
	for i in _strengths.size():
		_strengths[i] = clampf(_strengths[i] / maxf(ref, 1e-9), 0.05, 1.5)


# ---------- tempo ----------

## Best {bpm, fitness}, or {} if there's no steady beat.
func _find_tempo() -> Dictionary:
	var lo := 60.0 / MAX_BPM
	var hi := 60.0 / MIN_BPM
	var count := int((hi - lo) / COARSE_STEP) + 1
	var intervals := PackedFloat64Array()
	var fitness := PackedFloat64Array()
	intervals.resize(count)
	fitness.resize(count)
	for i in count:
		if _cancelled:
			return {}
		intervals[i] = lo + i * COARSE_STEP
		fitness[i] = maxf(_interval_fitness(intervals[i], COARSE_BIN), 0.001)
		progress = 0.8 + 0.15 * i / count
	_fit_cubic(intervals, fitness)
	var best := 0.0
	for i in count:
		fitness[i] -= _poly_at(intervals[i])
		best = maxf(best, fitness[i])
	if best <= 0.0:
		return {}
	# Refine at each local maximum above 40% of the best.
	var candidates: Array[Dictionary] = []
	for i in count:
		var f := fitness[i]
		if f < 0.4 * best or (i > 0 and fitness[i - 1] > f) or (i < count - 1 and fitness[i + 1] >= f):
			continue
		var top := {"interval": intervals[i], "fitness": -INF}
		var t := intervals[i] - COARSE_STEP
		while t <= intervals[i] + COARSE_STEP:
			var ff := _interval_fitness(t, FINE_BIN) - _poly_at(t)
			if ff > top.fitness:
				top = {"interval": t, "fitness": ff}
			t += FINE_STEP
		candidates.append({"bpm": 60.0 / top.interval, "fitness": top.fitness})
	candidates.sort_custom(func(a, b): return a.fitness > b.fitness)
	# Drop near-duplicates, halves and doubles of a better candidate.
	var kept: Array[Dictionary] = []
	for c in candidates:
		var dup := false
		for k in kept:
			var b: float = k.bpm
			if minf(absf(c.bpm - b), minf(absf(c.bpm - 2.0 * b), absf(c.bpm - 0.5 * b))) < 0.1:
				dup = true
				break
		if not dup:
			kept.append(c)
	if kept.is_empty():
		return {}
	# Music made to a click is usually at a whole BPM: take it when it
	# scores as well, or drifts less than 1/20 beat over the track.
	var seconds := _level.size() / _fps
	for c in kept:
		var r := roundf(c.bpm)
		var diff := absf(c.bpm - r)
		if diff < 0.01 or (diff < 0.05 and diff * seconds / 60.0 < 0.05):
			c.bpm = r
		elif diff < 0.05:
			var at_r := _interval_fitness(60.0 / r, FINE_BIN) - _poly_at(60.0 / r)
			var at_c := _interval_fitness(60.0 / c.bpm, FINE_BIN) - _poly_at(60.0 / c.bpm)
			if at_r > at_c * 0.99:
				c.bpm = r
	var best_c := kept[0]
	if best_c.bpm * 0.5 >= MIN_BPM and _alternation(120.0 / best_c.bpm) < HALF_TIME_RATIO:
		best_c.bpm *= 0.5
	return best_c


## Weaker over stronger of the two beat phases of `interval` (twice the
## beat interval being tested): ~1 when both halves are alike.
func _alternation(interval: float) -> float:
	var scores := _phase_scores(interval, FINE_BIN, true)
	var nb := scores.size()
	var half := nb / 2
	var best := 0.0
	var other := 0.0
	for b in nb:
		var s := maxf(scores[b], scores[(b + half) % nb])
		if s > best:
			best = s
			other = minf(scores[b], scores[(b + half) % nb])
	return other / best if best > 0.0 else 1.0


## How well onsets line up with a beat every `interval` seconds, at the
## best phase: max over phases of _phase_scores.
func _interval_fitness(interval: float, bin: float) -> float:
	var scores := _phase_scores(interval, bin, true)
	var nb := scores.size()
	var half := nb / 2
	var best := 0.0
	for b in nb:
		best = maxf(best, scores[b] + 0.5 * scores[(b + half) % nb])
	return best


## Onset support for each phase bin of an `interval`: onset strength (or
## 1 each when not `weighted`) near it, triangle-weighted over ±WINDOW.
func _phase_scores(interval: float, bin: float, weighted: bool) -> PackedFloat32Array:
	var nb := maxi(int(ceil(interval / bin)), 4)
	var bw := interval / nb
	_hist.resize(nb)
	_hist.fill(0.0)
	var inv := 1.0 / bw
	for i in _onsets.size():
		var p := int(fposmod(_onsets[i], interval) * inv)
		_hist[p if p < nb else 0] += _strengths[i] if weighted else 1.0
	# A triangle is a box over a box: each box ±h bins, together ±2h ≈ ±WINDOW.
	var h := maxi(1, roundi(WINDOW / (2.0 * bw)))
	var once := _circular_box(_hist, h)
	var twice := _circular_box(once, h)
	var scale := 1.0 / (2 * h + 1)
	for b in nb:
		twice[b] *= scale
	return twice


## Sum of `src` over ±h around each index, wrapping.
static func _circular_box(src: PackedFloat32Array, h: int) -> PackedFloat32Array:
	var nb := src.size()
	var out := PackedFloat32Array()
	out.resize(nb)
	var s := 0.0
	for j in range(-h, h + 1):
		s += src[posmod(j, nb)]
	for b in nb:
		out[b] = s
		s += src[(b + h + 1) % nb] - src[posmod(b - h, nb)]
	return out


## Least-squares cubic through (x, y), x centred for conditioning.
func _fit_cubic(x: PackedFloat64Array, y: PackedFloat64Array) -> void:
	var n := x.size()
	_poly_center = (x[0] + x[n - 1]) * 0.5
	# Normal equations: A[i][j] = Σ x^(i+j), r[i] = Σ x^i y.
	var a := []
	var r := [0.0, 0.0, 0.0, 0.0]
	var pw := PackedFloat64Array()
	pw.resize(7)
	pw.fill(0.0)
	for k in n:
		var xc := (x[k] - _poly_center) * 10.0
		var p := 1.0
		for e in 7:
			pw[e] += p
			if e < 4:
				r[e] += p * y[k]
			p *= xc
	for i in 4:
		a.append([pw[i], pw[i + 1], pw[i + 2], pw[i + 3]])
	# Gaussian elimination with partial pivoting.
	for col in 4:
		var piv := col
		for row in range(col + 1, 4):
			if absf(a[row][col]) > absf(a[piv][col]):
				piv = row
		var tmp = a[col]
		a[col] = a[piv]
		a[piv] = tmp
		var tr = r[col]
		r[col] = r[piv]
		r[piv] = tr
		if absf(a[col][col]) < 1e-12:
			_poly = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
			return
		for row in range(col + 1, 4):
			var f: float = a[row][col] / a[col][col]
			for c in range(col, 4):
				a[row][c] -= f * a[col][c]
			r[row] -= f * r[col]
	for i in range(3, -1, -1):
		var s: float = r[i]
		for c in range(i + 1, 4):
			s -= a[i][c] * _poly[c]
		_poly[i] = s / a[i][i]


func _poly_at(x: float) -> float:
	var xc := (x - _poly_center) * 10.0
	return _poly[0] + xc * (_poly[1] + xc * (_poly[2] + xc * _poly[3]))


# ---------- beat phase ----------

## Time of a beat (0 <= t < interval): the best-supported phase, refined
## to the mean of the onsets near it, then swapped for its offbeat if the
## level rises more there.
func _find_phase(interval: float) -> float:
	var scores := _phase_scores(interval, FINE_BIN, false)
	var nb := scores.size()
	var half := nb / 2
	var best_b := 0
	var best := -1.0
	for b in nb:
		var s := scores[b] + 0.5 * scores[(b + half) % nb]
		if s > best:
			best = s
			best_b = b
	var phase := (best_b + 0.5) * interval / nb
	# Mean deviation of the onsets within the window (wrapped).
	var sum := 0.0
	var wsum := 0.0
	for i in _onsets.size():
		var d := fposmod(_onsets[i] - phase + interval * 0.5, interval) - interval * 0.5
		if absf(d) <= WINDOW:
			var w := 1.0 - absf(d) / WINDOW
			sum += d * w
			wsum += w
	if wsum > 0.0:
		phase = fposmod(phase + sum / wsum, interval)
	var off := fposmod(phase + interval * 0.5, interval)
	return off if _rise_at(off, interval) > _rise_at(phase, interval) else phase


## Sum over the track of how much the level rises (50 ms after vs 50 ms
## before) at every `interval` from `phase`.
func _rise_at(phase: float, interval: float) -> float:
	var n := _level.size()
	var prefix := PackedFloat64Array()
	prefix.resize(n + 1)
	var acc := 0.0
	for i in n:
		acc += _level[i]
		prefix[i + 1] = acc
	var w := maxi(1, roundi(0.05 * _fps))
	var total := 0.0
	var t := phase
	while true:
		var i := roundi(t * _fps)
		if i + w > n:
			break
		if i >= w:
			total += maxf(0.0, (prefix[i + w] - prefix[i]) - (prefix[i] - prefix[i - w]))
		t += interval
	return total


# ---------- downbeat ----------

## Which of the next BEATS_PER_BAR beats from `phase` is a downbeat.
func _find_downbeat(bpm: float, phase: float) -> int:
	var spb := 60.0 / bpm
	var n := _level.size()
	var beats := int((n / _fps - phase) / spb)
	if beats < BEATS_PER_BAR * 4:
		return 0
	# Per beat: mean log energy of each band over the beat, and the onset
	# strength of the bass (kick) and the mids + highs (snare, clap) at it.
	var feats: Array[PackedFloat32Array] = []
	var eps := PackedFloat32Array()
	for b in _bands.size():
		var e: PackedFloat32Array = _bands[b]
		var mean := 0.0
		for i in n:
			mean += e[i]
		eps.append(maxf(0.05 * mean / n, 1e-12))
	var kick := PackedFloat32Array()
	var snare := PackedFloat32Array()
	kick.resize(beats)
	snare.resize(beats)
	for b in _bands.size():
		var f := PackedFloat32Array()
		f.resize(beats)
		feats.append(f)
	for k in beats:
		var a := roundi((phase + k * spb) * _fps)
		var z := mini(n, roundi((phase + (k + 1) * spb) * _fps))
		for b in _bands.size():
			var e: PackedFloat32Array = _bands[b]
			var s := 0.0
			for i in range(a, z):
				s += e[i]
			feats[b][k] = log(s / maxi(z - a, 1) + eps[b])
		kick[k] = _rise(_bands[0], a, eps[0])
		snare[k] = _rise(_bands[1], a, eps[1]) + _rise(_bands[2], a, eps[2])
	# Bar lines: change between the bar-long windows either side of each
	# beat. Right bar lines see whole bars change; wrong ones a mix.
	var novelty := PackedFloat32Array()
	novelty.resize(BEATS_PER_BAR)
	var counts := PackedInt32Array()
	counts.resize(BEATS_PER_BAR)
	for k in range(BEATS_PER_BAR, beats - BEATS_PER_BAR):
		var d := 0.0
		for b in _bands.size():
			var before := 0.0
			var after := 0.0
			for j in BEATS_PER_BAR:
				before += feats[b][k - 1 - j]
				after += feats[b][k + j]
			d += absf(after - before) / BEATS_PER_BAR
		novelty[k % BEATS_PER_BAR] += d
		counts[k % BEATS_PER_BAR] += 1
	var kick_by := PackedFloat32Array()
	var snare_by := PackedFloat32Array()
	kick_by.resize(BEATS_PER_BAR)
	snare_by.resize(BEATS_PER_BAR)
	for k in beats:
		kick_by[k % BEATS_PER_BAR] += kick[k]
		snare_by[k % BEATS_PER_BAR] += snare[k]
	var nov_sum := 0.0
	var acc_sum := 0.0
	for p in BEATS_PER_BAR:
		novelty[p] /= maxi(counts[p], 1)
		nov_sum += novelty[p]
		acc_sum += kick_by[p] + snare_by[p]
	# Backbeat: in 4/4 the kick leans to 1 and 3, the snare to 2 and 4.
	var best_p := 0
	var best := -INF
	for p in BEATS_PER_BAR:
		var score := novelty[p] / maxf(nov_sum, 1e-9)
		if BEATS_PER_BAR % 2 == 0:
			var q := (p + 1) % BEATS_PER_BAR
			var r := (p + 2) % BEATS_PER_BAR
			var s := (p + 3) % BEATS_PER_BAR
			var back := (kick_by[p] + kick_by[r] - kick_by[q] - kick_by[s]) + (snare_by[q] + snare_by[s] - snare_by[p] - snare_by[r])
			score += 0.5 * back / maxf(acc_sum, 1e-9)
		if score > best:
			best = score
			best_p = p
	return best_p


## Rise in log energy of `e` over the first 3 frames from frame `i`.
static func _rise(e: PackedFloat32Array, i: int, eps: float) -> float:
	var n := e.size()
	if i < 3 or i + 3 > n:
		return 0.0
	var before := (e[i - 1] + e[i - 2] + e[i - 3]) / 3.0
	var after := (e[i] + e[i + 1] + e[i + 2]) / 3.0
	return maxf(0.0, log(after + eps) - log(before + eps))


# ---------- confidence ----------

## Share of onset strength within ±WINDOW of a beat or offbeat, mapped so
## onsets at random times read 0 and a tight groove reads near 1.
func _confidence(interval: float, phase: float) -> float:
	var total := 0.0
	var on := 0.0
	var half := interval * 0.5
	for i in _onsets.size():
		var d := fposmod(_onsets[i] - phase + interval * 0.25, half) - interval * 0.25
		total += _strengths[i]
		if absf(d) <= WINDOW:
			on += _strengths[i]
	if total <= 0.0:
		return 0.0
	var chance := minf(4.0 * WINDOW / interval, 1.0)  # share random onsets land on
	return clampf((on / total - chance) / maxf(1.0 - chance, 1e-6) * 1.5, 0.0, 1.0)
