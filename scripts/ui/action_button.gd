extends TextureButton

const IDLE_PATH := "res://assets/ui/button_nav_frame_idle.png"
const ACTIVE_PATH := "res://assets/ui/button_nav_frame_active.png"
const TEXT := Color8(226, 244, 255, 255)
const TEXT_HOVER := Color8(241, 252, 255, 255)
const TEXT_PRESSED := Color8(255, 247, 231, 255)
const TEXT_SHADOW := Color8(4, 12, 19, 232)
const DEFAULT_HOVER_GLOW := Color8(88, 240, 255, 255)
const DEFAULT_PRESSED_GLOW := Color8(255, 183, 67, 255)
const DEFAULT_WARM_GLOW := Color8(255, 183, 67, 255)

var _label_text := "ACTION"
var _hovered := false
var _pressing := false
var _state_tween: Tween
var _idle_texture: Texture2D
var _active_texture: Texture2D

@export var label_text: String:
	get:
		return _label_text
	set(value):
		_label_text = value
		if is_node_ready():
			_apply_label_text()

@export var hover_glow_color := DEFAULT_HOVER_GLOW
@export var pressed_glow_color := DEFAULT_PRESSED_GLOW
@export var warm_tick_color := DEFAULT_WARM_GLOW


func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(132.0, 40.0)
	_idle_texture = _load_png_texture(IDLE_PATH)
	_active_texture = _load_png_texture(ACTIVE_PATH)
	$Idle.texture = _idle_texture
	$Active.texture = _active_texture
	$Glow.texture = _active_texture
	var add_material := CanvasItemMaterial.new()
	add_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	$Glow.material = add_material
	$Label.add_theme_font_size_override("font_size", 13)
	$LabelShadow.add_theme_font_size_override("font_size", 13)
	_apply_label_text()
	_apply_label_style(TEXT)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	resized.connect(_update_pivots)
	_sync_visual_state()
	call_deferred("_update_pivots")


func _on_mouse_entered() -> void:
	_hovered = true
	_sync_visual_state()


func _on_mouse_exited() -> void:
	_hovered = false
	_pressing = false
	_sync_visual_state()


func _on_button_down() -> void:
	_pressing = true
	_animate_state(1.0, 0.5, pressed_glow_color, 1.0, 1.0, 0.985, TEXT_PRESSED, 1.0)


func _on_button_up() -> void:
	_pressing = false
	_sync_visual_state()


func _sync_visual_state() -> void:
	if _pressing:
		return
	if _hovered:
		_animate_state(0.76, 0.18, hover_glow_color, 0.8, 0.0, 1.0, TEXT_HOVER, 0.0)
	else:
		_animate_state(0.0, 0.0, hover_glow_color, 0.0, 0.0, 1.0, TEXT, 0.0)


func _animate_state(active_alpha: float, glow_alpha: float, glow_color: Color, line_alpha: float, warm_alpha: float, target_scale: float, font_color: Color, label_offset_y: float) -> void:
	if _state_tween:
		_state_tween.kill()
	_state_tween = create_tween()
	_state_tween.set_parallel(true)
	_state_tween.set_trans(Tween.TRANS_QUART)
	_state_tween.set_ease(Tween.EASE_OUT)
	_state_tween.tween_property($Active, "modulate:a", active_alpha, 0.16)
	_state_tween.tween_property($Glow, "modulate:a", glow_alpha, 0.18)
	_state_tween.tween_property($Glow, "scale", Vector2(target_scale, target_scale), 0.18)
	_state_tween.tween_property($TopLine, "modulate:a", line_alpha, 0.14)
	_state_tween.tween_property($WarmTick, "modulate:a", warm_alpha, 0.14)
	_state_tween.tween_property($LabelShadow, "position:y", 9.0 + label_offset_y, 0.12)
	_state_tween.tween_property($Label, "position:y", 8.0 + label_offset_y, 0.12)
	$Glow.modulate = Color(glow_color.r, glow_color.g, glow_color.b, $Glow.modulate.a)
	$TopLine.color = Color(glow_color.r, glow_color.g, glow_color.b, 1.0)
	$WarmTick.color = Color(warm_tick_color.r, warm_tick_color.g, warm_tick_color.b, 1.0)
	_apply_label_style(font_color)


func _update_pivots() -> void:
	$Glow.pivot_offset = $Glow.size * 0.5


func _apply_label_text() -> void:
	$Label.text = _label_text
	$LabelShadow.text = _label_text


func _apply_label_style(font_color: Color) -> void:
	$Label.add_theme_color_override("font_color", font_color)
	$LabelShadow.add_theme_color_override("font_color", TEXT_SHADOW)
	$LabelShadow.modulate = Color(1.0, 1.0, 1.0, 0.96)


func _load_png_texture(texture_path: String) -> Texture2D:
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(texture_path))
	if error != OK:
		push_warning("Unable to load action texture: %s" % texture_path)
		return null
	return ImageTexture.create_from_image(image)
