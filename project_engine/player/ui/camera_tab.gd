extends VBoxContainer

## Camera tab of the F2 floating panel. Sliders live-tweak the shared
## ScreenSettings (which drives the ScreenMount wrapping `main_screen`), or
## a shader layer's LayerSettings when "Adjust" picks one. The Layers spin
## box sets how many layers there are (LayerStack; new ones are added at the
## end and selected). For a layer the projection dropdown is swapped for
## the shader picker, and "Lock to screen" shows; the
## shader's hinted uniforms get generated controls under the sliders. Every
## target has an effect list below that (+ Effect, a picker, ↑ / ↓ and −
## per effect, and each effect's own controls). The distance slider is
## inverted (right = nearer) and holds -distance.
##
## The preset dropdown loads named presets from PresetStore and Save
## overwrites the selected preset with the screen and all layers. Preset 1
## is the default; preset 0 is the locked "Script (defaults)" (see PresetStore). Renaming, deleting and the startup choice live
## in the Presets tab; both follow PresetStore.active_index.
##
## The view row (projection + reset view) isn't part of presets: projection
## is per video, reset view is an action. Both are signalled up to main.gd.
##
## At the bottom, the camera effect (a full-view shader; LayerStack's
## camera_fx, saved with the preset): a picker, its strength and its hinted
## uniforms, plus the compile error if the effect has one (set_camera_fx_error).

signal projection_selected(key: String)  ## a VideoProjection.KEYS entry, incl. "auto"
signal reset_view_requested

const LABEL_WIDTH := 110
const VALUE_WIDTH := 90

@onready var preset_option: OptionButton = %PresetOption
@onready var target_option: OptionButton = %TargetOption
@onready var layer_count_spin: SpinBox = %LayerCountSpin
@onready var projection_label: Label = %ProjectionLabel
@onready var projection_option: OptionButton = %ProjectionOption
@onready var shader_option: OptionButton = %ShaderOption
@onready var reset_view_button: Button = %ResetViewButton
@onready var layer_options_row: HBoxContainer = %LayerOptionsRow
@onready var lock_check: CheckBox = %LockCheck
@onready var save_button: Button = %SaveButton
@onready var new_button: Button = %NewButton
@onready var size_slider: HSlider = %SizeSlider
@onready var size_value: Label = %SizeValue
@onready var distance_slider: HSlider = %DistanceSlider
@onready var distance_value: Label = %DistanceValue
@onready var height_slider: HSlider = %HeightSlider
@onready var height_value: Label = %HeightValue
@onready var tilt_slider: HSlider = %TiltSlider
@onready var tilt_value: Label = %TiltValue
@onready var curvature_slider: HSlider = %CurvatureSlider
@onready var curvature_value: Label = %CurvatureValue
@onready var vcurve_slider: HSlider = %VCurveSlider
@onready var vcurve_value: Label = %VCurveValue
@onready var opacity_slider: HSlider = %OpacitySlider
@onready var opacity_value: Label = %OpacityValue
@onready var resolution_slider: HSlider = %ResolutionSlider
@onready var resolution_value: Label = %ResolutionValue
@onready var params_box: VBoxContainer = %ParamsBox
@onready var effects_box: VBoxContainer = %EffectsBox
@onready var add_effect_button: Button = %AddEffectButton

var _settings: ScreenSettings
var _layers: LayerStack
var _presets: PresetStore
var _target: int = 0  # 0 = the screen, n = layer n (1-based)
var _shader_keys: Array[String] = []  # parallel to shader_option items
var _effect_options: Array[Dictionary] = []  # [{key, label}] for effect pickers
var _watched: Array[Callable] = []  # per watched layer, its bound structure_changed handler
var _refreshing: bool = false
var _fx_picker: OptionButton
var _fx_keys: Array[String] = []
var _fx_box: VBoxContainer  # strength + the effect's own controls
var _fx_error: Label


func _ready() -> void:
	size_slider.value_changed.connect(_on_edit.bind("size"))
	distance_slider.value_changed.connect(func(v: float): _on_edit(-v, "distance"))
	height_slider.value_changed.connect(_on_edit.bind("height"))
	tilt_slider.value_changed.connect(_on_edit.bind("tilt"))
	curvature_slider.value_changed.connect(_on_edit.bind("curvature"))
	vcurve_slider.value_changed.connect(_on_edit.bind("vertical_curvature"))
	opacity_slider.value_changed.connect(_on_edit.bind("opacity"))
	resolution_slider.value_changed.connect(_on_edit.bind("resolution"))
	lock_check.toggled.connect(_on_layer_edit.bind("lock_to_screen"))
	layer_count_spin.value_changed.connect(_on_layer_count_changed)
	add_effect_button.pressed.connect(func():
		if _edited() != null:
			_edited().add_effect())
	save_button.pressed.connect(_on_save_pressed)
	new_button.pressed.connect(_on_new_pressed)
	preset_option.item_selected.connect(_on_preset_selected)
	for key in VideoProjection.KEYS:
		projection_option.add_item(VideoProjection.LABELS[key])
	projection_option.item_selected.connect(
		func(idx: int): projection_selected.emit(VideoProjection.KEYS[idx]))
	reset_view_button.pressed.connect(func(): reset_view_requested.emit())
	target_option.item_selected.connect(_set_target)
	shader_option.item_selected.connect(_on_shader_selected)
	_refresh_target_list()
	_update_value_labels()


## Reflect the current projection. `selected` is "auto" or a key; when auto,
## the Auto entry names what was detected so the user can see the guess.
func set_projection_state(selected: String, detected: String) -> void:
	var idx := VideoProjection.KEYS.find(selected)
	if idx < 0:
		return
	projection_option.set_item_text(0, "Auto (%s)" % VideoProjection.LABELS.get(detected, detected))
	projection_option.select(idx)


func bind(settings: ScreenSettings, presets: PresetStore, layers: LayerStack = null) -> void:
	_settings = settings
	_layers = layers
	_presets = presets
	if _settings != null:
		_settings.changed.connect(_refresh_sliders_from_settings)
		_settings.structure_changed.connect(_on_structure_changed.bind(_settings))
	if _layers != null:
		_layers.layers_changed.connect(_on_layers_changed)
	layer_count_spin.editable = _layers != null
	if _presets != null:
		_presets.presets_changed.connect(_refresh_preset_list)
		_presets.active_changed.connect(func(_i: int): _refresh_preset_list())
	_refresh_preset_list()
	_on_layers_changed()
	if _layers != null:
		_build_camera_fx_section()


## Shown under the effect's controls; "" hides it.
func set_camera_fx_error(text: String) -> void:
	if _fx_error == null:
		return
	_fx_error.text = "Doesn't compile, " + text if text != "" else ""
	_fx_error.visible = text != ""


func _build_camera_fx_section() -> void:
	add_child(HSeparator.new())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.text = "Camera effect"
	label.tooltip_text = "A shader over everything you see (see the README for writing your own)"
	row.add_child(label)
	_fx_picker = OptionButton.new()
	_fx_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fx_picker.fit_to_longest_item = false
	_fx_picker.item_selected.connect(func(i: int): _layers.camera_fx.shader = _fx_keys[i])
	row.add_child(_fx_picker)
	var rescan := Button.new()
	rescan.text = "Rescan"
	rescan.tooltip_text = "Look for new camera effects in the shaders folders"
	rescan.pressed.connect(_refresh_camera_fx)
	row.add_child(rescan)
	add_child(row)
	_fx_box = VBoxContainer.new()
	_fx_box.add_theme_constant_override("separation", 12)
	add_child(_fx_box)
	_fx_error = Label.new()
	_fx_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fx_error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
	_fx_error.visible = false
	add_child(_fx_error)
	_layers.camera_fx.structure_changed.connect(_refresh_camera_fx)
	_refresh_camera_fx()


## Picker entries, and the strength + hinted controls for the current effect.
func _refresh_camera_fx() -> void:
	var fx := _layers.camera_fx
	_fx_picker.clear()
	_fx_keys = [""]
	_fx_picker.add_item("None")
	for opt in CameraFxShaders.list_options():
		_fx_picker.add_item(opt.label)
		_fx_keys.append(opt.key)
	var idx := _fx_keys.find(fx.shader)
	if idx < 0:
		_fx_picker.add_item("%s (missing)" % fx.shader.get_file().get_basename())
		_fx_keys.append(fx.shader)
		idx = _fx_keys.size() - 1
	_fx_picker.select(idx)
	for c in _fx_box.get_children():
		_fx_box.remove_child(c)
		c.queue_free()
	if fx.shader == "":
		return
	_fx_box.add_child(_param_control({"name": "strength", "type": "float", "min": 0.0, "max": 1.0, "step": 0.01},
			fx.strength, func(v): fx.strength = v))
	for spec in CameraFxShaders.params_of(CameraFxShaders.code_for(fx.shader)):
		_fx_box.add_child(_param_control(spec, fx.params.get(spec.name, spec.default),
				func(v): fx.set_param(spec.name, v)))


func _refresh_preset_list() -> void:
	if _presets == null or preset_option == null:
		return
	var selected_id := _presets.active_index
	preset_option.clear()
	var items := _presets.list_presets()
	if items.is_empty():
		# list_presets() should have created preset 1 on first call, but be
		# defensive so the dropdown is never empty.
		preset_option.add_item("1 — Default", 1)
	else:
		for item in items:
			preset_option.add_item("%d — %s" % [item.index, item.name], int(item.index))
	if selected_id >= 0:
		var idx := _find_item_by_id(selected_id)
		if idx >= 0:
			preset_option.select(idx)
	var locked := PresetStore.is_locked(_current_preset_id())
	save_button.disabled = locked
	save_button.tooltip_text = "Built-in preset: use New to keep these values" if locked else ""


## The settings the sliders edit: the main screen's or a shader layer's.
func _edited() -> ScreenSettings:
	var layer := _layer()
	return layer if layer != null else _settings


## The shader layer being edited, or null when it's the screen.
func _layer() -> LayerSettings:
	if _layers == null or _target < 1 or _target > _layers.count():
		return null
	return _layers.layers[_target - 1]


## The stack changed (count or a preset): follow the new layers' signals,
## relist them and keep the target in range.
func _on_layers_changed() -> void:
	for link in _watched:
		var l: LayerSettings = link.get_bound_arguments()[0]
		l.changed.disconnect(_refresh_sliders_from_settings)
		l.structure_changed.disconnect(link)
	_watched.clear()
	if _layers != null:
		for l in _layers.layers:
			var link := _on_structure_changed.bind(l)
			l.changed.connect(_refresh_sliders_from_settings)
			l.structure_changed.connect(link)
			_watched.append(link)
		layer_count_spin.set_value_no_signal(_layers.count())
	_refresh_target_list()
	_set_target(mini(_target, _layers.count() if _layers != null else 0))


func _refresh_target_list() -> void:
	target_option.clear()
	target_option.add_item("Screen")
	var n := _layers.count() if _layers != null else 0
	for i in n:
		target_option.add_item("Layer %d" % (i + 1))


func _on_layer_count_changed(v: float) -> void:
	if _layers == null:
		return
	var grew := int(v) > _layers.count()
	_layers.set_count(int(v))
	if grew:
		_set_target(_layers.count())  # jump to the new layer


func _set_target(target: int) -> void:
	_target = target
	target_option.select(target)
	var shader := _layer() != null
	projection_label.text = "Shader" if shader else "Projection"
	projection_option.visible = not shader
	shader_option.visible = shader
	layer_options_row.visible = shader
	if shader:
		# Rescan each time, so files dropped into the shaders folder show up.
		_refresh_shader_list()
	_rebuild_dynamic()
	_refresh_sliders_from_settings()


func _refresh_shader_list() -> void:
	shader_option.clear()
	_shader_keys.clear()
	shader_option.add_item("None")
	_shader_keys.append("")
	for opt in VisualizerShaders.list_options():
		shader_option.add_item(opt.label)
		_shader_keys.append(opt.key)
	_select_current_shader()


func _select_current_shader() -> void:
	var layer := _layer()
	if layer == null or shader_option.item_count == 0:
		return
	var idx := _shader_keys.find(layer.shader)
	if idx < 0:
		# A preset's shader that's no longer on disk: list it so the
		# dropdown still says what's selected.
		shader_option.add_item("%s (missing)" % layer.shader.get_file().get_basename())
		_shader_keys.append(layer.shader)
		idx = _shader_keys.size() - 1
	shader_option.select(idx)


func _on_shader_selected(idx: int) -> void:
	var layer := _layer()
	if layer != null and idx >= 0 and idx < _shader_keys.size():
		layer.shader = _shader_keys[idx]


func _on_structure_changed(source: ScreenSettings) -> void:
	if source == _edited():
		_select_current_shader()
		_rebuild_dynamic()


## Regenerate the layer shader's controls and the effect list for the
## edited target. Only on structural changes: rebuilding mid-drag would
## drop the slider being dragged.
func _rebuild_dynamic() -> void:
	for box in [params_box, effects_box]:
		for c in box.get_children():
			box.remove_child(c)
			c.queue_free()
	var edited := _edited()
	if edited == null:
		return
	var layer := _layer()
	if layer != null and layer.shader != "":
		for spec in VisualizerShaders.hints_for(layer.shader).params:
			params_box.add_child(_param_control(spec, layer.params.get(spec.name, spec.default),
					func(v): layer.set_param(spec.name, v)))
	_effect_options = VisualizerShaders.list_options(VisualizerShaders.search_dirs(), true)
	for i in edited.effects.size():
		_add_effect_rows(edited, i)


func _add_effect_rows(edited: ScreenSettings, i: int) -> void:
	var effect: Dictionary = edited.effects[i]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.custom_minimum_size.x = LABEL_WIDTH
	label.text = "Effect %d" % (i + 1)
	row.add_child(label)
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.fit_to_longest_item = false
	picker.add_item("None")
	var keys: Array[String] = [""]
	for opt in _effect_options:
		picker.add_item(opt.label)
		keys.append(opt.key)
	var idx := keys.find(String(effect.shader))
	if idx < 0:
		picker.add_item("%s (missing)" % String(effect.shader).get_file().get_basename())
		keys.append(effect.shader)
		idx = keys.size() - 1
	picker.select(idx)
	picker.item_selected.connect(func(k: int): edited.set_effect_shader(i, keys[k]))
	row.add_child(picker)
	for move in [[-1, "↑"], [1, "↓"]]:
		var button := Button.new()
		button.text = move[1]
		button.custom_minimum_size.x = 40
		var to: int = i + move[0]
		button.disabled = to < 0 or to >= edited.effects.size()
		button.pressed.connect(func(): edited.move_effect(i, move[0]))
		row.add_child(button)
	var remove := Button.new()
	remove.text = "−"
	remove.custom_minimum_size.x = 40
	remove.pressed.connect(func(): edited.remove_effect(i))
	row.add_child(remove)
	effects_box.add_child(row)
	if String(effect.shader) == "":
		return
	var params: Dictionary = effect.params
	for spec in VisualizerShaders.hints_for(effect.shader).params:
		effects_box.add_child(_param_control(spec, params.get(spec.name, spec.default),
				func(v): edited.set_effect_param(i, spec.name, v)))


## A row for one hinted uniform: a slider with its value, or a checkbox.
func _param_control(spec: Dictionary, value: Variant, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var label := Label.new()
	label.custom_minimum_size.x = LABEL_WIDTH
	label.text = String(spec.name).capitalize()
	row.add_child(label)
	if spec.type == "bool":
		var check := CheckBox.new()
		check.button_pressed = bool(value)
		check.toggled.connect(on_change)
		row.add_child(check)
		return row
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.scrollable = false
	slider.min_value = spec.min
	slider.max_value = spec.max
	slider.step = spec.step
	slider.value = float(value)
	var shown := Label.new()
	shown.custom_minimum_size.x = VALUE_WIDTH
	shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var is_int: bool = spec.type == "int"
	var show_value := func(v: float): shown.text = str(int(v)) if is_int else "%.2f" % v
	show_value.call(slider.value)
	slider.value_changed.connect(func(v: float):
		show_value.call(v)
		on_change.call(int(v) if is_int else v))
	row.add_child(slider)
	row.add_child(shown)
	return row


func _refresh_sliders_from_settings() -> void:
	var edited := _edited()
	if edited == null:
		return
	_refreshing = true
	size_slider.set_value_no_signal(edited.size)
	distance_slider.set_value_no_signal(-edited.distance)
	height_slider.set_value_no_signal(edited.height)
	tilt_slider.set_value_no_signal(edited.tilt)
	curvature_slider.set_value_no_signal(edited.curvature)
	vcurve_slider.set_value_no_signal(edited.vertical_curvature)
	opacity_slider.set_value_no_signal(edited.opacity)
	resolution_slider.set_value_no_signal(edited.resolution)
	# Locked, a layer sits on the screen: height and tilt are unused
	# (distance moves it in front of / behind the screen).
	var layer := _layer()
	var locked := layer != null and layer.lock_to_screen
	lock_check.set_pressed_no_signal(locked)
	for s in [height_slider, tilt_slider]:
		s.editable = not locked
		s.modulate.a = 0.4 if locked else 1.0
	_refreshing = false
	_update_value_labels()


func _update_value_labels() -> void:
	size_value.text = "%.2fx" % size_slider.value
	distance_value.text = "%.2f m" % (0.0 - distance_slider.value)  # no "-0.00"
	height_value.text = "%+.2f m" % height_slider.value
	tilt_value.text = "%+d°" % int(tilt_slider.value)
	curvature_value.text = "%.2f" % curvature_slider.value
	vcurve_value.text = "%.2f" % vcurve_slider.value
	opacity_value.text = "%d%%" % roundi(opacity_slider.value * 100.0)
	resolution_value.text = "%d%%" % roundi(resolution_slider.value * 100.0)


## Set `property` on the edited settings.
func _on_edit(value: Variant, property: String) -> void:
	if not _refreshing and _edited() != null:
		_edited().set(property, value)
	_update_value_labels()


## Set `property` on the edited layer (layer-only controls).
func _on_layer_edit(value: Variant, property: String) -> void:
	if not _refreshing and _layer() != null:
		_layer().set(property, value)


func _on_preset_selected(_idx: int) -> void:
	var id := _current_preset_id()
	if id < 0 or _presets == null or _settings == null:
		return
	if _presets.apply(id, _settings, _layers):
		_refresh_sliders_from_settings()


func _on_save_pressed() -> void:
	if _presets == null or _settings == null:
		return
	var id := _current_preset_id()
	if id < 0 or PresetStore.is_locked(id):
		return
	var name := _current_preset_name()
	_presets.save_preset(id, name, _settings.to_dict(), _layers_data(), _camera_fx_data())
	_presets.set_active(id)


func _on_new_pressed() -> void:
	if _presets == null or _settings == null:
		return
	var id := _presets.next_free_index()
	_presets.save_preset(id, "Preset %d" % id, _settings.to_dict(), _layers_data(), _camera_fx_data())
	_presets.set_active(id)  # → active_changed → list reselects it


func _current_preset_id() -> int:
	if preset_option == null or preset_option.item_count == 0:
		return -1
	var sel := preset_option.get_selected()
	if sel < 0:
		return -1
	return preset_option.get_item_id(sel)


func _current_preset_name() -> String:
	if preset_option == null or preset_option.item_count == 0:
		return ""
	var sel := preset_option.get_selected()
	if sel < 0:
		return ""
	var text := preset_option.get_item_text(sel)
	# Strip the "N — " prefix we added in _refresh_preset_list.
	var em_dash := " — "
	var i := text.find(em_dash)
	return text.substr(i + em_dash.length()) if i >= 0 else text


func _find_item_by_id(id: int) -> int:
	for i in preset_option.item_count:
		if preset_option.get_item_id(i) == id:
			return i
	return -1


func _layers_data() -> Array:
	return _layers.to_array() if _layers != null else []


func _camera_fx_data() -> Dictionary:
	return _layers.camera_fx.to_dict() if _layers != null else {}
