@tool
class_name VJScene
extends Node3D

## Scene-root marker for a VJ script authored in Godot.
##
## Holds the metadata that ends up in the exported JSON's `meta` and `media`
## blocks, plus the target output path. The exporter (Tools > VJ menu) walks
## this node's children and its sibling AnimationPlayer to build the JSON.

@export_group("Meta")
@export var title: String = ""
@export var author: String = ""
@export var created: String = ""

@export_group("Media")
## Path to the video file, relative to the output JSON's directory.
@export var video_relative_path: String = ""
## Optional duration in seconds written to `media.duration`. 0 = let the
## player use the video's length.
@export var duration: float = 0.0

@export_group("Export")
## Where the exporter writes the JSON: an absolute path, or res:// (which
## may climb out of the project, e.g. "res://../scripts/x/video.json").
@export var output_path: String = ""

@export_group("Preview")
## Still image shown on screens in the editor (there's no video decoder in
## the authoring project). Any PNG/JPG path; res:// or absolute. Empty =
## a generated three-column test card. The player always shows the video.
@export_file("*.png", "*.jpg", "*.jpeg", "*.webp") var preview_image: String = "":
	set(value):
		preview_image = value
		_preview_cache = null
		for child in get_children():
			if child.has_method("refresh_preview"):
				child.refresh_preview()

@export_group("Desktop preview")
## Running this scene (F5) adds a fly camera, a media bar and — when the
## gde_gozen addon is in the project — the actual video. Never in the editor.
@export var desktop_preview: bool = true

var _preview_cache: Texture2D


func _ready() -> void:
	for child in get_children():
		_fix_discrete_seeking(child)
	child_entered_tree.connect(_fix_discrete_seeking)
	if desktop_preview and not Engine.is_editor_hint():
		var preview: Node = load("res://addons/vj_editor/preview/desktop_preview.gd").new()
		preview.name = "DesktopPreview"
		add_child(preview)


## With the default discrete mode, seeking backwards across a discrete key
## (the `visible` and Viewer cut tracks) applies that key's value instead of
## the one at the new time, so scrubbing in the editor leaves objects shown
## or hidden at random. Force-continuous evaluates them like nearest-
## interpolated tracks: the key at or before the playhead, from any seek.
func _fix_discrete_seeking(node: Node) -> void:
	if node is AnimationPlayer:
		node.callback_mode_discrete = AnimationMixer.ANIMATION_CALLBACK_MODE_DISCRETE_FORCE_CONTINUOUS


func get_preview_texture() -> Texture2D:
	if _preview_cache != null or preview_image.is_empty():
		return _preview_cache
	# Read the file directly rather than through the import system so any
	# image (including one outside the project) works without importing.
	var img := Image.load_from_file(ProjectSettings.globalize_path(preview_image))
	if img != null:
		_preview_cache = ImageTexture.create_from_image(img)
	return _preview_cache
