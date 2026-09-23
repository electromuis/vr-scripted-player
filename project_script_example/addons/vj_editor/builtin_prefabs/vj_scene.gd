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

@export_group("Export")
## Absolute filesystem path (or res:// URI) where the exporter writes the JSON.
## Example: "c:/dev/VRmviewer/scripts/moving_screen/video.json"
@export_global_file("*.json") var output_path: String = ""
