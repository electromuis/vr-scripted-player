class_name SkyboxLibrary
extends RefCounted

## Resolves a PlayerSettings.skybox value onto an Environment. Built-in keys
## are solid colours, gradients or sky shaders (no shipped assets); any other value is a path to an
## equirectangular panorama image. User panoramas are discovered in
## `user://skyboxes/` and a `skyboxes/` folder next to the executable.
##
## Ambient light is left alone so script-spawned lit objects look the same
## whichever background is chosen.

const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "hdr"]

const _SOLID := {
	"black": Color.BLACK,
	"dark_grey": Color(0.07, 0.07, 0.08),
	"light_grey": Color(0.55, 0.56, 0.58),
	"navy": Color(0.02, 0.04, 0.14),
	"purple": Color(0.10, 0.03, 0.16),
	"teal": Color(0.01, 0.10, 0.11),
}

## Environments drawn by sky shaders in skies/.
const _SHADERS := {
	"forest": preload("res://player/settings/skies/forest.gdshader"),
	"clouds": preload("res://player/settings/skies/clouds.gdshader"),
	"space": preload("res://player/settings/skies/space.gdshader"),
}

## key -> [sky_top, sky_horizon, ground_bottom, ground_horizon, energy]
const _PROCEDURAL := {
	"night": [Color(0.01, 0.015, 0.04), Color(0.06, 0.07, 0.12), Color(0.0, 0.0, 0.0), Color(0.03, 0.03, 0.05), 1.0],
	"dusk": [Color(0.12, 0.13, 0.3), Color(0.85, 0.45, 0.25), Color(0.04, 0.03, 0.04), Color(0.3, 0.18, 0.15), 0.8],
	"day": [Color(0.38, 0.45, 0.55), Color(0.65, 0.67, 0.7), Color(0.2, 0.17, 0.13), Color(0.65, 0.67, 0.7), 1.0],
}

var _image_cache: Dictionary = {}  # path -> Texture2D


## Folders scanned for user panoramas. Created lazily by the user; missing
## folders are skipped.
static func search_dirs() -> Array[String]:
	var out: Array[String] = [ProjectSettings.globalize_path("user://skyboxes")]
	out.append(OS.get_executable_path().get_base_dir().path_join("skyboxes"))
	return out


## [{key, label}] for the dropdown: built-ins first, then discovered images.
static func list_options() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for key in PlayerSettings.SKYBOX_BUILTINS:
		out.append({"key": key, "label": PlayerSettings.SKYBOX_LABELS[key]})
	for dir in search_dirs():
		var d := DirAccess.open(dir)
		if d == null:
			continue
		var files := Array(d.get_files())
		files.sort()
		for f in files:
			if String(f).get_extension().to_lower() in IMAGE_EXTENSIONS:
				out.append({"key": dir.path_join(f), "label": String(f).get_basename()})
	return out


func apply(env: Environment, key: String) -> void:
	if env == null:
		return
	if _SOLID.has(key):
		_solid(env, _SOLID[key])
	elif _PROCEDURAL.has(key):
		_procedural(env, _PROCEDURAL[key])
	elif _SHADERS.has(key):
		var mat := ShaderMaterial.new()
		mat.shader = _SHADERS[key]
		_set_sky(env, mat)
	elif not _panorama(env, key):
		push_warning("Skybox '%s' unavailable; falling back to black." % key)
		_solid(env, Color.BLACK)


static func _solid(env: Environment, c: Color) -> void:
	env.background_mode = Environment.BG_COLOR
	env.background_color = c


static func _procedural(env: Environment, p: Array) -> void:
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = p[0]
	mat.sky_horizon_color = p[1]
	mat.ground_bottom_color = p[2]
	mat.ground_horizon_color = p[3]
	mat.energy_multiplier = p[4]
	_set_sky(env, mat)


func _panorama(env: Environment, path: String) -> bool:
	var tex: Texture2D = _image_cache.get(path)
	if tex == null:
		if not FileAccess.file_exists(path):
			return false
		var img := Image.load_from_file(path)
		if img == null or img.is_empty():
			return false
		tex = ImageTexture.create_from_image(img)
		_image_cache = {path: tex}  # keep only the current panorama in memory
	var mat := PanoramaSkyMaterial.new()
	mat.panorama = tex
	_set_sky(env, mat)
	return true


static func _set_sky(env: Environment, mat: Material) -> void:
	var sky := Sky.new()
	sky.sky_material = mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
