extends VBoxContainer

## Presets tab of the F2 floating panel: manage the screen presets the
## Camera tab's dropdown picks from. Clicking a row applies it (single-click,
## like the Files tab, so VR pointers work); the buttons act on the active
## preset. Controls are built in code, like the Config tab.
##
## Delete asks for a second press instead of a dialog — popups in the
## panel's SubViewport are unreliable (see floating_panel.gd).

const STARTUP_MARK := "  ★ startup"
const LOCKED_MARK := "  (locked)"

var _settings: ScreenSettings
var _layers: LayerStack
var _presets: PresetStore
var _refreshing: bool = false
var _confirm_delete: bool = false

var _list: ItemList
var _name_edit: LineEdit
var _rename_button: Button
var _save_button: Button
var _new_button: Button
var _startup_button: Button
var _delete_button: Button
var _status: Label


func _ready() -> void:
	add_theme_constant_override("separation", 10)

	var hint := Label.new()
	hint.text = "Screen and shader-plane presets (placement, curvature, opacity, shader). Click one to apply it. Scripts play with preset 0; your previous preset comes back for plain videos."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(hint)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_row_selected)
	add_child(_list)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Preset name"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(_t: String): _on_rename())
	name_row.add_child(_name_edit)
	_rename_button = _button("Rename", _on_rename, name_row)
	add_child(name_row)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	_save_button = _button("Save current here", _on_save, actions)
	_save_button.tooltip_text = "Overwrite this preset with the Camera tab's current values"
	_new_button = _button("New from current", _on_new, actions)
	_startup_button = _button("Use at startup", _on_set_startup, actions)
	_delete_button = _button("Delete", _on_delete, actions)
	add_child(actions)

	_status = Label.new()
	_status.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	add_child(_status)
	_update_buttons()


func bind(settings: ScreenSettings, presets: PresetStore, layers: LayerStack = null) -> void:
	_settings = settings
	_layers = layers
	_presets = presets
	if _presets != null:
		# Deferred: applying a preset from this list's own item_selected
		# changes the active preset, and the list shouldn't be rebuilt mid-signal.
		_presets.presets_changed.connect(_refresh, CONNECT_DEFERRED)
		_presets.active_changed.connect(func(_i: int): _refresh(), CONNECT_DEFERRED)
	_refresh()


func _button(text: String, on_pressed: Callable, parent: Control) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	parent.add_child(b)
	return b


func _refresh() -> void:
	if _presets == null or _list == null:
		return
	_refreshing = true
	_list.clear()
	var startup := _presets.startup_index()
	for item in _presets.list_presets():
		var idx := int(item.index)
		var label := "%d — %s" % [idx, item.name]
		if PresetStore.is_locked(idx):
			label += LOCKED_MARK
		if idx == startup:
			label += STARTUP_MARK
		var row := _list.add_item(label)
		_list.set_item_metadata(row, idx)
		if idx == _presets.active_index:
			_list.select(row)
	var active := _presets.load_preset(_presets.active_index) if _active_exists() else {}
	_name_edit.text = String(active.get("name", ""))
	_refreshing = false
	_reset_delete_confirm()
	_update_buttons()


func _on_row_selected(row: int) -> void:
	if _refreshing or _presets == null or _settings == null:
		return
	var idx := int(_list.get_item_metadata(row))
	if _presets.apply(idx, _settings, _layers):
		_status.text = "Applied preset %d." % idx
	else:
		_status.text = "Preset %d could not be read." % idx


func _on_rename() -> void:
	if not _active_editable():
		return
	if _presets.rename_preset(_presets.active_index, _name_edit.text):
		_status.text = "Renamed."
	else:
		_status.text = "Enter a name first."


func _on_save() -> void:
	if not _active_editable() or _settings == null:
		return
	var name := String(_presets.load_preset(_presets.active_index).get("name", ""))
	_presets.save_preset(_presets.active_index, name, _settings.to_dict(), _layers_data())
	_status.text = "Saved current values to \"%s\"." % name


func _on_new() -> void:
	if _presets == null or _settings == null:
		return
	var idx := _presets.next_free_index()
	_presets.save_preset(idx, "Preset %d" % idx, _settings.to_dict(), _layers_data())
	_presets.set_active(idx)
	_status.text = "Created preset %d — rename it above." % idx


func _on_set_startup() -> void:
	if not _active_exists():
		return
	_presets.set_startup_index(_presets.active_index)
	_status.text = "Preset %d now loads at startup." % _presets.active_index


func _on_delete() -> void:
	if not _can_delete():
		return
	if not _confirm_delete:
		_confirm_delete = true
		_delete_button.text = "Really delete?"
		return
	var idx := _presets.active_index
	if _presets.delete_preset(idx):
		_status.text = "Deleted preset %d." % idx  # the delete fires _refresh
	else:
		_status.text = "Could not delete preset %d." % idx
		_reset_delete_confirm()


func _reset_delete_confirm() -> void:
	_confirm_delete = false
	if _delete_button != null:
		_delete_button.text = "Delete"


func _active_exists() -> bool:
	return _presets != null and _presets.has_preset(_presets.active_index)


## Exists and isn't the built-in Script preset.
func _active_editable() -> bool:
	return _active_exists() and not PresetStore.is_locked(_presets.active_index)


func _can_delete() -> bool:
	return _active_editable() and _presets.active_index != _presets.default_preset_index()


func _update_buttons() -> void:
	var has := _active_exists()
	var editable := _active_editable()
	_rename_button.disabled = not editable
	_name_edit.editable = editable
	_save_button.disabled = not editable or _settings == null
	_new_button.disabled = _presets == null or _settings == null
	_startup_button.disabled = not has or _presets.startup_index() == _presets.active_index
	_delete_button.disabled = not _can_delete()
	var why := ""
	if has and not editable:
		why = "Built in: scripts play with it. Use New from current to keep changes."
	elif has and not _can_delete():
		why = "Preset 1 is the default and can't be deleted"
	_delete_button.tooltip_text = why
	_rename_button.tooltip_text = why if not editable else ""
	_save_button.tooltip_text = why if not editable else "Overwrite this preset with the Camera tab's current values"


func _layers_data() -> Array:
	return _layers.to_array() if _layers != null else []
