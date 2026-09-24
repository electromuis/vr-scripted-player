class_name AudioAnalyzer
extends Node

## Live audio analysis for sound-reactive shaders. Taps an audio bus (the
## video player's) with a spectrum analyzer and a capture effect, and every
## frame publishes a Shadertoy-style 512×2 `texture`:
##   row 0 — spectrum, 0–11 kHz in 512 bins, dB mapped to 0..1 and smoothed
##           like Web Audio's AnalyserNode (which Shadertoy uses)
##   row 1 — the last 512 samples of the waveform, 0.5 = silence
## plus `level` / `bass` / `mid` / `high` (0..1) for simpler effects.
##
## The player applies its volume before the bus, so the analysis divides it
## back out (set_input_gain): visuals don't dim with the volume slider.

const BINS := 512
const MAX_HZ := 11025.0
## dB window mapped to 0..1. Web Audio uses -100..-30, but its Blackman
## window reads a full-scale sine ~7.5 dB lower than Godot's analyzer
## (-6 dB), so the window is shifted to match Shadertoy's levels.
const MIN_DB := -92.5
const MAX_DB := -22.5
## Fraction of the previous value kept per 60 Hz frame (AnalyserNode's
## smoothingTimeConstant); scaled for the actual frame rate.
const SMOOTHING := 0.8
const BASS_MAX_HZ := 250.0
const MID_MAX_HZ := 2000.0

var texture: ImageTexture
var level: float = 0.0
var bass: float = 0.0
var mid: float = 0.0
var high: float = 0.0

var _spectrum: AudioEffectSpectrumAnalyzer
var _capture: AudioEffectCapture
var _instance: AudioEffectSpectrumAnalyzerInstance
var _bus_name: String = ""
var _gain: float = 1.0
var _smoothed := PackedFloat32Array()
var _wave := PackedFloat32Array()  # last BINS mono samples
var _bytes := PackedByteArray()
var _image: Image


func _init() -> void:
	_smoothed.resize(BINS)
	_wave.resize(BINS)
	_bytes.resize(BINS * 2)
	_write_waveform()
	_image = Image.create_from_data(BINS, 2, false, Image.FORMAT_R8, _bytes)
	texture = ImageTexture.create_from_image(_image)


## Add the analysis effects to `bus_name`. Returns false if there is no
## such bus.
func attach(bus_name: String) -> bool:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return false
	_spectrum = AudioEffectSpectrumAnalyzer.new()
	_spectrum.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_2048
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 0.1
	# Ahead of the bus's own effects (gozen's pitch shift for off-speed
	# playback), so they don't colour the analysis.
	AudioServer.add_bus_effect(idx, _capture, 0)
	AudioServer.add_bus_effect(idx, _spectrum, 0)
	_bus_name = bus_name
	_instance = null
	return true


## Linear gain the source applies before the bus (its volume).
func set_input_gain(gain: float) -> void:
	_gain = 1.0 / maxf(gain, 1e-4)


## Analysis runs in _process; switch it off while nothing reads it. The
## capture buffer is dropped on resume so the waveform starts fresh.
func set_active(on: bool) -> void:
	if on and not is_processing() and _capture != null:
		_capture.clear_buffer()
	set_process(on)


func _process(delta: float) -> void:
	if _spectrum == null:
		return
	if _instance == null:
		_instance = _find_instance()
		if _instance == null:
			return
	_analyze_spectrum(pow(SMOOTHING, delta * 60.0))
	_read_waveform()
	_write_waveform()
	_image.set_data(BINS, 2, false, Image.FORMAT_R8, _bytes)
	texture.update(_image)


func _analyze_spectrum(keep: float) -> void:
	var hz := MAX_HZ / BINS
	var sums := [0.0, 0.0, 0.0]
	var counts := [0, 0, 0]
	for i in BINS:
		var m := _instance.get_magnitude_for_frequency_range(i * hz, (i + 1) * hz)
		_smoothed[i] = lerpf(maxf(m.x, m.y) * _gain, _smoothed[i], keep)
		var v := clampf((linear_to_db(_smoothed[i]) - MIN_DB) / (MAX_DB - MIN_DB), 0.0, 1.0)
		_bytes[i] = int(v * 255.0)
		var band := 0 if i * hz < BASS_MAX_HZ else (1 if i * hz < MID_MAX_HZ else 2)
		sums[band] += v
		counts[band] += 1
	bass = sums[0] / counts[0]
	mid = sums[1] / counts[1]
	high = sums[2] / counts[2]


func _read_waveform() -> void:
	var n := _capture.get_frames_available()
	if n <= 0:
		return
	var buf := _capture.get_buffer(n)
	var fresh := PackedFloat32Array()
	var sq := 0.0
	for i in range(maxi(0, buf.size() - BINS), buf.size()):
		var s := (buf[i].x + buf[i].y) * 0.5 * _gain
		fresh.append(s)
		sq += s * s
	_wave = (_wave + fresh).slice(-BINS)
	level = clampf(sqrt(sq / fresh.size()) * 2.0, 0.0, 1.0)


func _write_waveform() -> void:
	for i in BINS:
		_bytes[BINS + i] = int(clampf(_wave[i] * 0.5 + 0.5, 0.0, 1.0) * 255.0)


func _find_instance() -> AudioEffectSpectrumAnalyzerInstance:
	var idx := AudioServer.get_bus_index(_bus_name)
	if idx < 0:
		return null
	for e in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, e) == _spectrum:
			return AudioServer.get_bus_effect_instance(idx, e) as AudioEffectSpectrumAnalyzerInstance
	return null
