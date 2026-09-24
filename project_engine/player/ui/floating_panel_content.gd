extends PanelContainer

## Root of the F2 floating panel's tab contents. Forwards binds to the
## individual tab scripts (Camera, Files, Network, Config, Presets) and owns
## the header's close (X) and Quit buttons.

signal close_requested
signal quit_requested

## Quit needs a second press within this many seconds, so a stray click in
## VR doesn't drop the viewer out of the app.
const QUIT_CONFIRM_SECONDS := 3.0

@onready var camera_tab: Node = %CameraTab
@onready var files_tab: Node = %FilesTab
@onready var network_tab: Node = %NetworkTab
@onready var config_tab: Node = %ConfigTab
@onready var presets_tab: Node = %PresetsTab
@onready var close_button: Button = %CloseButton
@onready var quit_button: Button = %QuitButton

var _quit_armed: bool = false


func _ready() -> void:
	close_button.pressed.connect(close_requested.emit)
	quit_button.pressed.connect(_on_quit_pressed)


## The VR laser (XRToolsViewport2DIn3DBody) reports every press twice: as a
## screen touch and as a mouse click. The touch opens an OptionButton's
## popup, then the mouse press lands outside it and closes it again, so
## dropdowns never stay open. The mouse events carry everything the panel
## needs; drop the touches.
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		get_viewport().set_input_as_handled()


func _on_quit_pressed() -> void:
	if _quit_armed:
		quit_requested.emit()
		return
	_quit_armed = true
	quit_button.text = "Really quit?"
	await get_tree().create_timer(QUIT_CONFIRM_SECONDS).timeout
	_quit_armed = false
	quit_button.text = "Quit"


func bind_camera(settings: ScreenSettings, presets: PresetStore, layers: LayerStack = null) -> void:
	if camera_tab != null and camera_tab.has_method("bind"):
		camera_tab.bind(settings, presets, layers)
	if presets_tab != null and presets_tab.has_method("bind"):
		presets_tab.bind(settings, presets, layers)


func bind_files(runner: ScriptRunner, open_file: Callable, thumbs: OsThumbnails = null) -> void:
	if files_tab != null and files_tab.has_method("bind"):
		files_tab.bind(runner, open_file, thumbs)


func bind_network(client: DlnaClient, open_url: Callable) -> void:
	if network_tab != null and network_tab.has_method("bind"):
		network_tab.bind(client, open_url)


func bind_config(settings: PlayerSettings) -> void:
	if config_tab != null and config_tab.has_method("bind"):
		config_tab.bind(settings)
	# The Files and Network browsers share the list/tiles preference.
	for tab in [files_tab, network_tab]:
		if tab != null and tab.has_method("bind_view"):
			tab.bind_view(settings)
