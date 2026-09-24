@tool
@icon("res://addons/vj_editor/builtin_prefabs/effect_icon.svg")
class_name VJEffect
extends Node

## One effect pass on the screen or layer it's a child of. Effects run in
## child order over the picture (drag to reorder); each is a ShaderMaterial
## with one of addons/vj_editor/visualizer/effects/ (the player's built-in
## Key black, Oval mask, Edge blur, Padding, Glow, Crop, Rounded corners) or your own
## effect shader (include visualizer/effect_prelude.gdshaderinc).
##
## The parent exports its effects as `config.effects`, in order. Animate
## `<screen>/<effect>:material:shader_parameter/<p>`; the exporter turns it
## into a `<screen id>.effect<N>` track, N being this effect's place among
## the parent's enabled ones at export time.
##
## Right-click a screen or layer > Add VJ effect adds one with a built-in
## shader already set.

## The effect shader and its params.
@export var material: ShaderMaterial:
	set(value):
		material = value
		update_configuration_warnings()

## Off: skipped in the preview and left out of the export. Not animatable
## (the player's effect chain is fixed per spawn).
@export var enabled: bool = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	var parent := get_parent()
	if parent != null and not parent.has_method("effect_nodes"):
		out.append("A VJ effect only does something as a direct child of a screen or layer.")
	if material == null or material.shader == null:
		out.append("Set a ShaderMaterial with an effect shader (addons/vj_editor/visualizer/effects/).")
	return out


## Whether this effect takes part (the preview and the export skip it if not).
func is_active() -> bool:
	return enabled and material != null and material.shader != null
