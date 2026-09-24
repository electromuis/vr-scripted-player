@tool
class_name VJObject
extends Node3D

## Modifier and reactive fields for any VJ object, right on the object: key
## `forest:opacity` or `forest:spin` next to `forest:position`. Attach this
## script to a custom prefab's instance in your scene (right-click → Make VJ
## object, or Attach Script), or leave it to the builtins: VJScreen and
## VJLayer extend it. A plain Node3D with it is a group. The prefab itself
## stays untouched; a prefab whose root has its own script can extend this
## one instead.
##
## Modifiers are Godot-native properties set on everything under the object,
## multiplied down through groups (see modifiers.gd). They preview while you
## scrub; the scene is saved with the prefab's own values. They export as
## `config.modifiers` and `<id>.modifiers` tracks.
##
## Reactive motion is computed on top of the animated transform. Nothing
## moves in the editor viewport (the saved transform stays yours); spin shows
## in the F5 desktop preview and the player, pulse (it needs the music's
## analysis) in the player only. It exports as `config.reactive` and
## `<id>.reactive` tracks.

const Mods := preload("res://addons/vj_editor/modifiers/modifiers.gd")
const MODIFIER_FIELDS := ["opacity", "tint", "flash", "speed", "sort_offset"]
const REACTIVE_FIELDS := ["spin", "pulse"]

@export_group("Modifiers")
## 1 = as authored, 0 = gone (every mesh's transparency). On screens and
## layers it's their own display fade instead.
@export_range(0.0, 1.0, 0.01) var opacity: float = 1.0:
	set(value):
		opacity = value
		_opacity_changed()
## Multiplies the colour; white = unchanged.
@export var tint: Color = Color.WHITE:
	set(value):
		tint = value
		_refresh_modifiers()
## Light added on top; alpha is the strength (0 = none).
@export var flash: Color = Color(1, 1, 1, 0):
	set(value):
		flash = value
		_refresh_modifiers()
## Speed of the object's particles and AnimationPlayers.
@export_range(0.0, 4.0, 0.01, "or_greater") var speed: float = 1.0:
	set(value):
		speed = value
		_refresh_modifiers()
## Draw-order nudge in metres for while it's see-through (Godot's
## sorting_offset): negative sorts it behind other see-through things, e.g.
## a big faded environment that would otherwise cover a screen inside it.
@export var sort_offset: float = 0.0:
	set(value):
		sort_offset = value
		_refresh_modifiers()

@export_group("Reactive")
## Degrees per second around the object's own X, Y and Z axes.
@export var spin: Vector3 = Vector3.ZERO
## 0 = still; 1 = grows by the full bass level (scale 1 + pulse × bass).
@export_range(0.0, 1.0, 0.01) var pulse: float = 0.0

@export_group("")

## A node's modifier values ({} for nodes without this script).
static var lookup := func(node: Node) -> Dictionary:
	return node.modifier_values() if node.has_method("modifier_values") else {}

var _reactive_state := {}
var _anim: AnimationPlayer
## Between the editor's pre- and post-save notifications. Godot applies the
## RESET animation after pre-save; modifiers written then would be saved.
var _saving := false


## The modifiers this object applies to what's under it.
func modifier_values() -> Dictionary:
	return {"opacity": opacity, "tint": tint, "flash": flash, "speed": speed, "sort_offset": sort_offset}


func _ready() -> void:
	_refresh_modifiers()
	if not Engine.is_editor_hint():
		_follow_animation()


func _exit_tree() -> void:
	Mods.restore(self)


func _notification(what: int) -> void:
	# Never save modified values into the scene.
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_saving = true
		Mods.restore(self)
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_saving = false
		_refresh_modifiers()


## VJScreen overrides this: its opacity is its display fade.
func _opacity_changed() -> void:
	_refresh_modifiers()


func _refresh_modifiers() -> void:
	if is_inside_tree() and not _saving:
		Mods.refresh(self, lookup)


# ---------- reactive (F5 desktop preview) ----------

func _follow_animation() -> void:
	var scene := get_parent()
	while scene != null and not scene.has_method("get_preview_texture"):
		scene = scene.get_parent()
	if scene == null:
		return
	for c in scene.get_children():
		if c is AnimationPlayer:
			_anim = c
	if _anim != null:
		_anim.mixer_applied.connect(_after_animation)


## The animation has just written this frame's transform: put the spin back
## on top, at the animation's time.
func _after_animation() -> void:
	if spin == Vector3.ZERO and _reactive_state.is_empty():
		return
	Mods.begin_frame(self, _reactive_state)
	var angle := Mods.spin_angle(_reactive_state, func(_t: float) -> Vector3: return spin, _anim.current_animation_position)
	Mods.end_frame(self, _reactive_state, angle, 1.0)
