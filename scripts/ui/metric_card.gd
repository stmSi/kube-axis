extends "res://scripts/chrome_panel.gd"

const TITLE_COLOR := Color8(226, 244, 255, 255)
const VALUE_COLOR := Color8(121, 158, 184, 255)

var _card_title := "METRIC"
var _line_color := Color8(88, 240, 255, 255)

@export var card_title: String:
	get:
		return _card_title
	set(value):
		_card_title = value
		if is_node_ready():
			$Margin/Body/Title.text = _card_title.to_upper()

@export var line_color: Color:
	get:
		return _line_color
	set(value):
		_line_color = value
		if is_node_ready():
			_apply_metric_visuals()


func _ready() -> void:
	compact = true
	show_inner_frame = false
	fill_color = Color(0.08, 0.15, 0.23, 0.94)
	accent_color = Color(_line_color.r, _line_color.g, _line_color.b, 0.86)
	trim_color = Color(0.17, 0.34, 0.44, 0.75)
	glow_color = Color8(255, 183, 67, 255)
	cut_size = 12.0
	super()
	$Margin/Body/Title.add_theme_color_override("font_color", TITLE_COLOR)
	$Margin/Body/Title.add_theme_font_size_override("font_size", 12)
	$Margin/Body/Value.add_theme_color_override("font_color", VALUE_COLOR)
	$Margin/Body/Value.add_theme_font_size_override("font_size", 13)
	_apply_metric_visuals()


func set_value_text(value: String) -> void:
	$Margin/Body/Value.text = value


func set_points(values: Array) -> void:
	$Margin/Body/Sparkline.set_points(values)


func _apply_metric_visuals() -> void:
	accent_color = Color(_line_color.r, _line_color.g, _line_color.b, 0.86)
	$Margin/Body/Title.text = _card_title.to_upper()
	$Margin/Body/Sparkline.set_line_color(_line_color)
	queue_redraw()
