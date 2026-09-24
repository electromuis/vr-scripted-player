class_name VideoProjection
extends RefCounted

## How a video frame maps onto the viewer: a flat screen or an immersive
## 180°/360° sphere, each either mono or stereo (side-by-side / top-bottom).
##
## detect() follows the filename conventions shared by DeoVR, Skybox,
## HereSphere etc.: tokens like `_180`, `_360`, `_LR`/`_SBS`/`_3DH`,
## `_TB`/`_OU`/`_3DV`, separated by any non-alphanumeric character.
## A 180° file with no stereo tag is assumed side-by-side (the de-facto
## default for VR180); a 360° file with no tag is assumed mono.

enum Shape { FLAT, DOME_180, SPHERE_360 }
enum Stereo { MONO, SBS, TB }

## Dropdown order. "auto" means "use detect() on the current file".
const KEYS := ["auto", "flat", "flat_sbs", "flat_tb", "180_sbs", "180_tb", "180_mono", "360_mono", "360_tb", "360_sbs"]
const LABELS := {
	"auto": "Auto (from filename)",
	"flat": "Flat 2D",
	"flat_sbs": "Flat 3D side-by-side",
	"flat_tb": "Flat 3D top-bottom",
	"180_sbs": "180° 3D side-by-side",
	"180_tb": "180° 3D top-bottom",
	"180_mono": "180° 2D",
	"360_mono": "360° 2D",
	"360_tb": "360° 3D top-bottom",
	"360_sbs": "360° 3D side-by-side",
}

const _SBS_TOKENS := ["lr", "sbs", "3dh", "sidebyside", "hsbs", "fsbs"]
const _TB_TOKENS := ["tb", "ou", "3dv", "overunder", "topbottom", "htb", "hou"]
const _180_TOKENS := ["180", "vr180", "180x180", "180sbs", "180lr"]
const _360_TOKENS := ["360", "vr360", "360x180", "mono360"]


## Filename (or path) → projection key (never "auto").
static func detect(path: String) -> String:
	var tokens := _tokens(path.get_file().get_basename())
	var shape := "flat"
	if _any_in(tokens, _360_TOKENS):
		shape = "360"
	elif _any_in(tokens, _180_TOKENS):
		shape = "180"
	var stereo := ""
	if _any_in(tokens, _SBS_TOKENS) or tokens.has("180sbs") or tokens.has("180lr"):
		stereo = "sbs"
	elif _any_in(tokens, _TB_TOKENS):
		stereo = "tb"
	match shape:
		"flat":
			return "flat" if stereo == "" else "flat_" + stereo
		"180":
			return "180_" + (stereo if stereo != "" else "sbs")
		_:
			return "360_" + (stereo if stereo != "" else "mono")


static func shape_of(key: String) -> int:
	if key.begins_with("180"):
		return Shape.DOME_180
	if key.begins_with("360"):
		return Shape.SPHERE_360
	return Shape.FLAT


static func stereo_of(key: String) -> int:
	if key.ends_with("_sbs"):
		return Stereo.SBS
	if key.ends_with("_tb"):
		return Stereo.TB
	return Stereo.MONO


## Aspect ratio of one eye's image given the full frame aspect.
static func eye_aspect(key: String, frame_aspect: float) -> float:
	match stereo_of(key):
		Stereo.SBS:
			return frame_aspect * 0.5
		Stereo.TB:
			return frame_aspect * 2.0
	return frame_aspect


static func _tokens(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			cur += ch
		elif cur != "":
			out.append(cur)
			cur = ""
	if cur != "":
		out.append(cur)
	return out


static func _any_in(tokens: PackedStringArray, needles: Array) -> bool:
	for n in needles:
		if tokens.has(n):
			return true
	return false
