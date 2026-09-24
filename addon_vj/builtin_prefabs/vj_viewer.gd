@tool
class_name VJViewer
extends Camera3D

## Where the viewer stands. Put one directly under the VJScene root and
## keyframe its `position` / `rotation` on the "main" animation: every key
## (after t=0) exports as a `vr_cut` event. The cut lands at the key's time
## — with a fade, the event starts `fade_duration / 2` earlier so the screen
## is fully black exactly when the view jumps.
##
## Its rest pose should match the player's home pose (0, 2, 8) looking
## down -Z, since the player starts every script there. Use this camera's
## "Preview" toggle in the 3D editor to see what the viewer sees.

## Transition on each cut: "fade_to_black" or "none" (a hard cut).
@export_enum("fade_to_black", "none") var transition: String = "fade_to_black"
@export_range(0.0, 5.0, 0.05) var fade_duration: float = 1.0
