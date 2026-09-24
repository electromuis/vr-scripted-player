class_name DefaultScreen
extends RefCounted

## The player's always-on screen. Any timeline that doesn't spawn its own
## `main_screen` gets one injected at t=0, so a script that only adds
## effects (or a plain video with no script at all) still shows the video.
## A script opts out ("says otherwise") by spawning `main_screen` itself or
## by setting `"meta": {"default_screen": false}`.

const SCREEN_ID := "main_screen"
const PREFAB_KEY := "__default_screen"
const PREFAB_PATH := "res://player/prefabs/screen.tscn"
const POSITION := [0.0, 2.0, 0.0]
const SCALE := 0.25  # 8 m wide at the 8 m home distance ≈ 53° field of view

const VIDEO_EXTENSIONS := ["mp4", "m4v", "mkv", "webm", "mov", "avi", "wmv", "flv", "ts", "ogv"]


static func is_video(path: String) -> bool:
	return path.get_extension().to_lower() in VIDEO_EXTENSIONS


## Network video (e.g. a DLNA item). FFmpeg streams these directly, so they
## play wherever a local path does, minus file-system lookups.
static func is_url(path: String) -> bool:
	return path.begins_with("http://") or path.begins_with("https://")


## Same-name .json next to a video (`clip.mp4` → `clip.json`), or "".
static func sidecar_script(video_path: String) -> String:
	if is_url(video_path):
		return ""
	var candidate := video_path.get_basename() + ".json"
	return candidate if FileAccess.file_exists(candidate) else ""


## Whether `data` should get the default screen.
static func wants_default(data: TimelineData) -> bool:
	if data == null or data.meta.get("default_screen", true) == false:
		return false
	for t in data.tracks:
		if typeof(t) == TYPE_DICTIONARY and t.get("type", "") == "event" \
				and t.get("action", "") == "spawn" and String(t.get("id", "")) == SCREEN_ID:
			return false
	return true


## Add the default screen spawn to `data` in place (idempotent).
static func inject(data: TimelineData) -> void:
	if not wants_default(data):
		return
	data.prefabs[PREFAB_KEY] = PREFAB_PATH
	data.tracks.push_front({
		"type": "event",
		"t": 0.0,
		"action": "spawn",
		"id": SCREEN_ID,
		"prefab": PREFAB_KEY,
		"transform": {
			"position": POSITION,
			"rotation_deg": [0.0, 0.0, 0.0],
			"scale": [SCALE, SCALE, SCALE],
		},
		"config": {"fit_aspect": true},
	})


## Empty timeline for before anything is opened: just the default screen,
## showing the video bridge's placeholder card, so there is something to
## look at (and point at) from the first frame.
static func idle_timeline() -> TimelineData:
	var data := TimelineData.new()
	data.format_version = 1
	data.meta = {"title": "", "idle": true}
	data.script_path = "<memory>"
	data.synthetic = true
	return data


static func is_idle(data: TimelineData) -> bool:
	return data != null and data.meta.get("idle", false) == true


## In-memory timeline that just plays `video_path` (the runner injects the
## screen when it applies it). `file_name` names a URL whose path doesn't
## (e.g. `clip_180_LR.mp4` for a DLNA item); it is stored as
## meta.video_name and used for the title and projection detection.
## `thumbnail_url` (a DLNA item's image) is kept as meta.thumbnail_url for
## the screen to show while the video opens.
static func timeline_for_video(video_path: String, file_name: String = "",
		thumbnail_url: String = "") -> TimelineData:
	var data := TimelineData.new()
	data.format_version = 1
	var name := file_name if file_name != "" else video_path.get_file()
	data.meta = {"title": name, "video_name": name}
	if thumbnail_url != "":
		data.meta["thumbnail_url"] = thumbnail_url
	data.media = {"video": video_path}
	data.script_path = video_path
	data.base_dir = video_path.get_base_dir()
	data.synthetic = true
	return data
