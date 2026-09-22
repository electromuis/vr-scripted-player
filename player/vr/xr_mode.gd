class_name XRMode
extends Node

## Handles opt-in OpenXR initialization. Desktop is the default; VR is entered
## by CLI (--vr) or user action ("Enter VR" button / bound key).

signal entered_vr
signal exited_vr
signal vr_init_failed(reason: String)

var _xr_interface: XRInterface
var _in_vr: bool = false


func is_in_vr() -> bool:
	return _in_vr


func try_enter_vr() -> bool:
	if _in_vr:
		return true
	_xr_interface = XRServer.find_interface("OpenXR")
	if _xr_interface == null:
		vr_init_failed.emit("OpenXR interface not found in this Godot build.")
		return false
	if not _xr_interface.is_initialized():
		if not _xr_interface.initialize():
			vr_init_failed.emit("OpenXR failed to initialize. Is a headset connected and an OpenXR runtime (e.g. SteamVR) active?")
			return false
	var vp := get_viewport()
	vp.use_xr = true
	# XR needs vsync off (headset drives its own pacing).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_in_vr = true
	entered_vr.emit()
	return true


func exit_vr() -> void:
	if not _in_vr:
		return
	var vp := get_viewport()
	vp.use_xr = false
	if _xr_interface != null and _xr_interface.is_initialized():
		_xr_interface.uninitialize()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	_in_vr = false
	exited_vr.emit()
