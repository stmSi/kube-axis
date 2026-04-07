extends "res://scripts/chrome_panel.gd"

const TEXT_DEFAULT := Color8(88, 240, 255, 255)

var _chip_text := "SECTION"
var _chip_color := TEXT_DEFAULT

@export var chip_text: String:
	get:
		return _chip_text
	set(value):
		_chip_text = value
		if is_node_ready():
			_apply_chip()

@export var chip_color: Color:
	get:
		return _chip_color
	set(value):
		_chip_color = value
		if is_node_ready():
			_apply_chip()


func _ready() -> void:
	compact = true
	show_inner_frame = false
	fill_color = Color(0.07, 0.15, 0.22, 0.98)
	accent_color = Color(_chip_color.r, _chip_color.g, _chip_color.b, 0.85)
	trim_color = Color(0.24, 0.45, 0.56, 0.7)
	glow_color = Color8(255, 183, 67, 255)
	cut_size = 12.0
	super()
	_apply_chip()


func _apply_chip() -> void:
	accent_color = Color(_chip_color.r, _chip_color.g, _chip_color.b, 0.85)
	$Label.text = _chip_text.to_upper()
	$Label.add_theme_color_override("font_color", _chip_color)
	$Label.add_theme_font_size_override("font_size", 12)
	custom_minimum_size = Vector2(max(124.0, 84.0 + _chip_text.length() * 5.0), 30.0)
	queue_redraw()
