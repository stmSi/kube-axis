extends "res://scripts/chrome_panel.gd"

const SECTION_FILL_DEFAULT := Color8(9, 20, 33, 232)
const SECTION_TRIM_DEFAULT := Color8(40, 96, 124, 180)
const FRAME_CYAN_PATH := "res://assets/ui/panel_frame_cyan.png"
const FRAME_ORANGE_PATH := "res://assets/ui/panel_frame_orange.png"
const FRAME_GREEN_PATH := "res://assets/ui/panel_frame_green.png"
const RULE_CYAN_PATH := "res://assets/ui/border_rule_cyan.png"
const RULE_ORANGE_PATH := "res://assets/ui/border_rule_orange.png"
const RULE_GREEN_PATH := "res://assets/ui/border_rule_green.png"
const ORANGE_ACCENT := Color8(255, 183, 67, 255)
const GREEN_ACCENT := Color8(104, 255, 154, 255)

@export var section_title := "Section"
@export var section_accent_color := Color8(88, 240, 255, 255)
@export var section_fill_color := SECTION_FILL_DEFAULT
@export var section_emphasize_right := false


func _ready() -> void:
	fill_color = section_fill_color
	accent_color = Color(section_accent_color.r, section_accent_color.g, section_accent_color.b, 0.84)
	trim_color = Color(SECTION_TRIM_DEFAULT.r, SECTION_TRIM_DEFAULT.g, SECTION_TRIM_DEFAULT.b, 0.8)
	glow_color = Color8(255, 183, 67, 255)
	emphasize_right = section_emphasize_right
	show_inner_frame = true
	compact = false
	cut_size = 20.0
	frame_patch_margin = 30
	frame_texture_path = _pick_frame_texture_path()
	super()
	_apply_section()


func _apply_section() -> void:
	$ContentMargin/Shell/HeaderRow/HeaderChip.chip_text = section_title
	$ContentMargin/Shell/HeaderRow/HeaderChip.chip_color = section_accent_color
	_apply_rule_texture()
	queue_redraw()


func _pick_frame_texture_path() -> String:
	if _is_similar_color(section_accent_color, ORANGE_ACCENT):
		return FRAME_ORANGE_PATH
	if _is_similar_color(section_accent_color, GREEN_ACCENT):
		return FRAME_GREEN_PATH
	return FRAME_CYAN_PATH


func _is_similar_color(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.08 and absf(a.g - b.g) < 0.08 and absf(a.b - b.b) < 0.08


func _apply_rule_texture() -> void:
	var rule_wrap: MarginContainer = $ContentMargin/Shell/HeaderRow/RuleWrap
	var legacy_rule := rule_wrap.get_node_or_null("Rule")
	if legacy_rule:
		legacy_rule.visible = false
	var rule_texture := rule_wrap.get_node_or_null("RuleTexture") as TextureRect
	if rule_texture == null:
		rule_texture = TextureRect.new()
		rule_texture.name = "RuleTexture"
		rule_texture.custom_minimum_size = Vector2(0.0, 6.0)
		rule_texture.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rule_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rule_texture.stretch_mode = TextureRect.STRETCH_SCALE
		rule_wrap.add_child(rule_texture)
	var texture_path := _pick_rule_texture_path()
	rule_texture.texture = load(texture_path) as Texture2D
	rule_texture.modulate = Color(1.0, 1.0, 1.0, 0.9)


func _pick_rule_texture_path() -> String:
	if _is_similar_color(section_accent_color, ORANGE_ACCENT):
		return RULE_ORANGE_PATH
	if _is_similar_color(section_accent_color, GREEN_ACCENT):
		return RULE_GREEN_PATH
	return RULE_CYAN_PATH
