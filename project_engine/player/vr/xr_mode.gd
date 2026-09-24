class_name XRMode
extends Node

## Handles OpenXR initialization. Desktop works standalone; VR is entered
## automatically at startup when a headset is detected, by CLI (--vr), or by
## user action ("Enter VR" button / bound key). --desktop skips the auto-entry.

signal entered_vr
signal exited_vr
signal vr_init_failed(reason: String)

var _xr_interface: XRInterface
var _in_vr: bool = false


func is_in_vr() -> bool:
	return _in_vr


## True when a headset is ready to use. With xr/openxr/enabled on, Godot
## initializes OpenXR at boot and only succeeds if the runtime found an HMD,
## so this is a side-effect-free check — it never starts a runtime itself.
func headset_detected() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


func try_enter_vr() -> bool:
	if _in_vr:
		return true
	_xr_interface = XRServer.find_interface("OpenXR")
	if _xr_interface == null:
		vr_init_failed.emit("OpenXR interface not found in this Godot build.")
		return false
	if not _xr_interface.is_initialized():
		if not _xr_interface.initialize():
			# Common cause on Windows: SteamVR is running but isn't the active
			# OpenXR runtime (Windows Mixed Reality or another runtime is set
			# as default). Fix in SteamVR → Settings → Developer → Set
			# SteamVR as OpenXR runtime.
			vr_init_failed.emit("OpenXR failed to initialize. Headset connected? In SteamVR: Settings → Developer → Set SteamVR as OpenXR runtime.")
			return false
	# Fall back to desktop cleanly if the runtime tears the session down
	# (headset unplug, SteamVR quit). Connect once — reconnecting on every
	# try_enter_vr would stack callbacks.
	if _xr_interface.has_signal("session_stopping") and not _xr_interface.session_stopping.is_connected(_on_session_stopping):
		_xr_interface.session_stopping.connect(_on_session_stopping)
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
	_leave_xr_viewport()
	if _xr_interface != null and _xr_interface.is_initialized():
		_xr_interface.uninitialize()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	_in_vr = false
	exited_vr.emit()


func _on_session_stopping() -> void:
	# Runtime side told us the session ended. Mirror exit_vr()'s teardown
	# without calling uninitialize() again — the runtime is already tearing
	# down and a second uninit can crash on some drivers.
	if not _in_vr:
		return
	_leave_xr_viewport()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	_in_vr = false
	exited_vr.emit()


## Hand the main viewport back to the desktop window. While use_xr is on the
## viewport is sized to the headset's render target (e.g. 2496x2688), and
## turning it off doesn't size it back — the desktop view stays stretched
## and mouse coordinates no longer match what's drawn. Re-assigning the
## window size makes Godot recompute the viewport from the window.
func _leave_xr_viewport() -> void:
	var vp := get_viewport()
	vp.use_xr = false
	var win := get_window()
	win.size = win.size
