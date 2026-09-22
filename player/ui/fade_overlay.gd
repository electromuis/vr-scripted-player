class_name FadeOverlay
extends ColorRect

## Full-screen black overlay for vr_cut / vr_teleport fade_to_black transitions.
## Mouse-transparent so it doesn't eat clicks on controls beneath.

func _ready() -> void:
	color = Color(0, 0, 0, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Fade to black over half the duration, run `at_black`, then fade back.
## Duration below ~1 frame runs the action immediately without a tween.
func fade_through(duration: float, at_black: Callable) -> void:
	var half := duration * 0.5
	if half < 0.02:
		at_black.call()
		return
	var t := create_tween()
	t.tween_property(self, "color:a", 1.0, half)
	t.tween_callback(at_black)
	t.tween_property(self, "color:a", 0.0, half)
