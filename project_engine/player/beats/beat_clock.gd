class_name BeatClock
extends Node

## The playing video's beat grid, and where the music is in it right now,
## for shaders (Visualizer sets the beat uniforms from it; see
## shadertoy_prelude.gdshaderinc).
##
## The grid is, first found: the script's `media.beats`; a cached result
## for the file (user://beat_grids/, keyed by path, size and modified
## time); else BeatDetector runs over the file on a worker thread, taking
## a second or so for a song, and the result is cached. Streams (URLs)
## aren't scanned, since that would download the whole file. Corrections
## from the panel (shift_downbeat, scale_tempo) are cached too.
##
## main.gd calls advance() every frame with the time of the sound being
## heard; beat values are exact from the grid, so they hold through seeks
## and pauses, and can anticipate a beat.

signal grid_changed

const CACHE_DIR := "user://beat_grids"
## Bump when BeatDetector changes, so old results are re-detected.
const CACHE_VERSION := 1
## Further than this from the audio clock, snap instead of easing.
const SNAP_SECONDS := 0.08

## null = none (nothing loaded, a stream, or still analysing); a grid with
## bpm 0 = analysed, no steady beat.
var grid: BeatGrid = null
## Media seconds of what's being heard, smoothed.
var time: float = 0.0

var _path: String = ""  # file the grid is for
var _from_script: bool = false
var _task: int = -1
var _task_path: String = ""
var _detector: BeatDetector
var _stale: Array[int] = []  # cancelled tasks still to be waited on


func _exit_tree() -> void:
	if _detector != null:
		_detector.cancel()
	for t in _stale + ([_task] if _task != -1 else []):
		WorkerThreadPool.wait_for_task_completion(t)
	_stale.clear()
	_task = -1


## Switch to the video at `os_path` ("" = none). `script_grid` (from the
## script's media.beats) wins over detection when given.
func load_for(os_path: String, script_grid: BeatGrid = null) -> void:
	_cancel_task()
	_path = os_path
	_from_script = script_grid != null
	if _from_script:
		_set_grid(script_grid)
		return
	if os_path == "" or DefaultScreen.is_url(os_path) or not FileAccess.file_exists(os_path):
		_set_grid(null)
		return
	var cached := _load_cache(os_path)
	if cached != null:
		_set_grid(cached)
		return
	_set_grid(null)
	_start_task(os_path)


## Detect again, ignoring the cache (and any corrections in it).
func rescan() -> void:
	if _path == "" or _from_script or DefaultScreen.is_url(_path):
		return
	_cancel_task()
	_start_task(_path)


func is_analyzing() -> bool:
	return _task != -1


## 0..1 of the running analysis.
func analysis_progress() -> float:
	return _detector.progress if _detector != null else 0.0


## Move the downbeat by `beats` and remember it for this file.
func shift_downbeat(beats: int) -> void:
	if grid == null or not grid.is_valid():
		return
	grid.shift_downbeat(beats)
	_edited()


## Double (2) or halve (0.5) the tempo and remember it for this file.
func scale_tempo(factor: float) -> void:
	if grid == null or not grid.is_valid():
		return
	grid.scale_tempo(factor)
	_edited()


## Move the clock on by `delta`: to `audio_t` (media seconds being heard,
## or < 0 when unknown) when `playing`, easing out the audio clock's
## jitter; else straight to `fallback_t`.
func advance(delta: float, audio_t: float, fallback_t: float, playing: bool) -> void:
	if not playing or audio_t < 0.0:
		time = fallback_t
		return
	time += delta
	var err := audio_t - time
	if absf(err) > SNAP_SECONDS:
		time = audio_t
	else:
		time += err * minf(1.0, delta * 8.0)


## Beats since the grid's downbeat at the clock, continuous; 0 without a grid.
func beat() -> float:
	return grid.beat_at(time) if grid != null else 0.0


## Shader uniform values at the clock (all 0 without a grid).
func uniforms() -> Dictionary:
	var g := grid
	if g == null or not g.is_valid():
		return {"beat_bpm": 0.0, "beat_time": 0.0, "beat_phase": 0.0, "bar_time": 0.0,
				"bar_phase": 0.0, "beat_in_bar": 0, "beats_per_bar": 4, "beat_confidence": 0.0}
	var b := g.beat_at(time)
	var bar := b / g.beats_per_bar
	return {
		"beat_bpm": g.bpm,
		"beat_time": b,
		"beat_phase": b - floorf(b),
		"bar_time": bar,
		"bar_phase": bar - floorf(bar),
		"beat_in_bar": posmod(int(floorf(b)), g.beats_per_bar),
		"beats_per_bar": g.beats_per_bar,
		"beat_confidence": g.confidence,
	}


func _process(_delta: float) -> void:
	for t in _stale.duplicate():
		if WorkerThreadPool.is_task_completed(t):
			WorkerThreadPool.wait_for_task_completion(t)
			_stale.erase(t)
	if _task == -1 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var result := _detector.result
	_detector = null
	if result == null or _task_path != _path:
		return
	_save_cache(_task_path, result)
	_set_grid(result)


func _set_grid(g: BeatGrid) -> void:
	grid = g
	grid_changed.emit()


func _edited() -> void:
	if not _from_script:
		_save_cache(_path, grid)
	grid_changed.emit()


func _start_task(path: String) -> void:
	_task_path = path
	_detector = BeatDetector.new()
	_task = WorkerThreadPool.add_task(_worker.bind(path, _detector))
	grid_changed.emit()  # is_analyzing() changed


func _cancel_task() -> void:
	if _task == -1:
		return
	_detector.cancel()
	_stale.append(_task)
	_task = -1
	_detector = null


## Worker thread: decode `path` with its own stream and detect.
func _worker(path: String, detector: BeatDetector) -> void:
	var stream := open_stream(path)
	if stream != null:
		detector.analyze(stream)
	else:
		detector.result = BeatGrid.new()


## A fresh stream for decoding `path`: gozen's FFmpeg stream when the
## addon is loaded (any video or audio file), else Godot's own loaders for
## wav / ogg / mp3.
static func open_stream(path: String) -> AudioStream:
	if ClassDB.class_exists("AudioStreamFFmpeg"):
		var s = ClassDB.instantiate("AudioStreamFFmpeg")
		if s != null and s.open(path, -1) == OK:
			return s
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


# ---------- cache ----------

static func _cache_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	var key := "%s|%d|%d" % [path, size, FileAccess.get_modified_time(path)]
	return CACHE_DIR.path_join(key.md5_text() + ".json")


static func _load_cache(path: String) -> BeatGrid:
	var file := _cache_file(path)
	if not FileAccess.file_exists(file):
		return null
	var d = JSON.parse_string(FileAccess.get_file_as_string(file))
	if typeof(d) != TYPE_DICTIONARY or int(d.get("version", 0)) != CACHE_VERSION:
		return null
	var g := BeatGrid.from_dict(d.get("grid"))
	# A track without a steady beat is cached too, so it isn't re-scanned.
	return g if g != null else BeatGrid.new()


static func _save_cache(path: String, g: BeatGrid) -> void:
	if path == "" or DefaultScreen.is_url(path):
		return
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(_cache_file(path), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": CACHE_VERSION, "path": path, "grid": g.to_dict() if g != null else {}}, "\t"))
