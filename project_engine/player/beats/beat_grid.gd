class_name BeatGrid
extends RefCounted

## A constant-tempo beat grid in media time: beat n sounds at
## `offset + n * 60 / bpm` (n may be negative), and beat 0, like every
## `beats_per_bar`-th beat from it, is a downbeat (the "1" of a bar).
## BeatDetector finds one for a whole track; a script can also give one
## (`media.beats`).

var bpm: float = 0.0  # 0 = no grid
var offset: float = 0.0  # seconds; a downbeat
var beats_per_bar: int = 4
## How clearly the track has a steady beat, 0..1 (1 for a grid given by hand).
var confidence: float = 0.0


static func make(bpm_: float, offset_: float, beats_per_bar_: int = 4, confidence_: float = 1.0) -> BeatGrid:
	var g := BeatGrid.new()
	g.bpm = bpm_
	g.offset = offset_
	g.beats_per_bar = maxi(beats_per_bar_, 1)
	g.confidence = confidence_
	g._normalize()
	return g


func is_valid() -> bool:
	return bpm > 0.0


func seconds_per_beat() -> float:
	return 60.0 / bpm if bpm > 0.0 else 0.0


## Beats since the downbeat at `offset` at media time `t`, continuous
## (negative before it). 0 without a grid.
func beat_at(t: float) -> float:
	return (t - offset) * bpm / 60.0 if bpm > 0.0 else 0.0


## Bars since the downbeat at `offset`, continuous.
func bar_at(t: float) -> float:
	return beat_at(t) / beats_per_bar


## Media time of beat `n`.
func time_of_beat(n: float) -> float:
	return offset + n * seconds_per_beat()


## Make the downbeat `beats` beats later (earlier if negative): the beats
## stay where they are, the "1" of the bar moves.
func shift_downbeat(beats: int) -> void:
	offset += beats * seconds_per_beat()
	_normalize()


## Multiply the tempo (2 or 0.5 to fix a double / half time detection),
## keeping the downbeat. Halving keeps every other beat from it.
func scale_tempo(factor: float) -> void:
	if factor > 0.0:
		bpm *= factor
	_normalize()


## Keep `offset` the first downbeat at or after 0 (well-defined for
## comparisons and short numbers in the cache).
func _normalize() -> void:
	if bpm > 0.0:
		offset = fposmod(offset, seconds_per_beat() * beats_per_bar)


func to_dict() -> Dictionary:
	return {"bpm": bpm, "offset": offset, "beats_per_bar": beats_per_bar, "confidence": confidence}


## A grid from `d` (`bpm`, optional `offset`, `beats_per_bar`,
## `confidence`); null if it has no positive bpm.
static func from_dict(d) -> BeatGrid:
	if typeof(d) != TYPE_DICTIONARY:
		return null
	var b := float(d.get("bpm", 0.0))
	if not (b > 0.0 and b < 1000.0):
		return null
	return make(b, float(d.get("offset", 0.0)), int(d.get("beats_per_bar", 4)), float(d.get("confidence", 1.0)))
