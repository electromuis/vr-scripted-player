class_name BrowserView
extends RefCounted

## Shared presentation for the panel's ItemList browsers (Files, Network):
## list vs. tiles layout, the placeholder icons shown until (or instead of)
## a real thumbnail, and decoding thumbnail bytes. Every row always carries
## an icon so list rows stay aligned whether or not a thumbnail arrives.

## Icon box per mode; thumbnails are fitted inside keeping their aspect.
const LIST_ICON := Vector2i(48, 27)
const TILE_ICON := Vector2i(160, 90)
const TILE_COLUMN_WIDTH := 172

## Placeholder kinds: "up", "folder", "server", "video", "script".
static var _placeholders: Dictionary = {}


static func apply(list: ItemList, tiles: bool) -> void:
	if tiles:
		list.icon_mode = ItemList.ICON_MODE_TOP
		list.max_columns = 0
		list.same_column_width = true
		list.fixed_column_width = TILE_COLUMN_WIDTH
		list.fixed_icon_size = TILE_ICON
		list.max_text_lines = 2
	else:
		list.icon_mode = ItemList.ICON_MODE_LEFT
		list.max_columns = 1
		list.same_column_width = false
		list.fixed_column_width = 0
		list.fixed_icon_size = LIST_ICON
		list.max_text_lines = 1


## Adds a row with its placeholder icon; returns its index.
static func add_row(list: ItemList, text: String, kind: String) -> int:
	var idx := list.add_item(text, placeholder(kind))
	list.set_item_tooltip(idx, text)
	return idx


## Label for the view-mode button: names the mode it switches to.
static func toggle_label(tiles: bool) -> String:
	return "List" if tiles else "Tiles"


## JPEG / PNG / WebP / BMP bytes → texture, or null if undecodable.
static func texture_from_bytes(bytes: PackedByteArray) -> Texture2D:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(bytes)
	elif bytes[0] == 0x42 and bytes[1] == 0x4D:
		err = img.load_bmp_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


static func placeholder(kind: String) -> Texture2D:
	if not _placeholders.has(kind):
		_placeholders[kind] = ImageTexture.create_from_image(_draw_placeholder(kind))
	return _placeholders[kind]


static func _draw_placeholder(kind: String) -> Image:
	var w := TILE_ICON.x
	var h := TILE_ICON.y
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	match kind:
		"up", "folder":
			var c := Color(0.45, 0.47, 0.52) if kind == "up" else Color(0.78, 0.63, 0.32)
			img.fill_rect(Rect2i(34, 14, 36, 10), c.darkened(0.15))
			img.fill_rect(Rect2i(34, 20, 92, 58), c)
			if kind == "up":
				# Upward arrow on the folder body.
				_fill_triangle(img, Vector2i(80, 30), 16, Color(0.9, 0.9, 0.9))
				img.fill_rect(Rect2i(74, 46, 12, 22), Color(0.9, 0.9, 0.9))
		"server":
			for i in 3:
				img.fill_rect(Rect2i(40, 14 + i * 22, 80, 18), Color(0.3, 0.38, 0.5))
				img.fill_rect(Rect2i(48, 21 + i * 22, 6, 4), Color(0.45, 0.85, 0.55))
		"script":
			img.fill_rect(Rect2i(50, 6, 60, 78), Color(0.25, 0.27, 0.32))
			for i in 5:
				img.fill_rect(Rect2i(58, 18 + i * 12, 44 - (i % 3) * 10, 4), Color(0.6, 0.7, 0.85))
		_:  # video
			img.fill_rect(Rect2i(8, 6, w - 16, h - 12), Color(0.2, 0.21, 0.25))
			_fill_triangle_right(img, Vector2i(70, 27), 36, Color(0.8, 0.82, 0.88))
	return img


## Upward-pointing triangle with apex at `top`, `size` tall.
static func _fill_triangle(img: Image, top: Vector2i, size: int, c: Color) -> void:
	for dy in size:
		img.fill_rect(Rect2i(top.x - dy, top.y + dy, dy * 2 + 1, 1), c)


## Right-pointing (play) triangle; `left_top` is the top of its left edge.
static func _fill_triangle_right(img: Image, left_top: Vector2i, size: int, c: Color) -> void:
	var half := size / 2
	for dy in size:
		var span := half - absi(dy - half)
		img.fill_rect(Rect2i(left_top.x, left_top.y + dy, span + 1, 1), c)
