extends Control

const BADGE_FRAME_PATH := "res://assets/ui/status_badge_frame.png"
const TEXT := Color8(226, 244, 255, 255)

var _text := ""
var _font_color := TEXT

@export var text: String:
	get:
		return _text
	set(value):
		_text = value
		if is_node_ready():
			$Label.text = _text

@export var font_color: Color:
	get:
		return _font_color
	set(value):
		_font_color = value
		if is_node_ready():
			$Label.add_theme_color_override("font_color", _font_color)


func _ready() -> void:
	custom_minimum_size = Vector2(124.0, 36.0)
	$Background.texture = _load_png_texture(BADGE_FRAME_PATH)
	$Background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	$Background.stretch_mode = TextureRect.STRETCH_SCALE
	$Label.text = _text
	$Label.add_theme_color_override("font_color", _font_color)
	$Label.add_theme_font_size_override("font_size", 12)


func _load_png_texture(texture_path: String) -> Texture2D:
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(texture_path))
	if error != OK:
		push_warning("Unable to load badge texture: %s" % texture_path)
		return null
	return ImageTexture.create_from_image(image)
