extends TextureButton

const IDLE_PATH := "res://assets/ui/nav_shell_idle.png"
const ACTIVE_PATH := "res://assets/ui/nav_shell_active.png"
const ICON_IDLE_PATH := "res://assets/ui/nav_icon_idle.png"
const ICON_ACTIVE_PATH := "res://assets/ui/nav_icon_active.png"
const CHEVRON_PATH := "res://assets/ui/nav_chevron.png"
const TEXT := Color8(226, 244, 255, 255)
const TEXT_HOVER := Color8(241, 252, 255, 255)
const TEXT_SELECTED := Color8(232, 250, 255, 255)
const TEXT_SHADOW := Color8(4, 12, 19, 232)
const HOVER_GLOW := Color8(88, 240, 255, 255)
const SELECTED_GLOW := Color8(110, 241, 255, 255)
const WARM_GLOW := Color8(255, 183, 67, 255)

var _label_text := "BUTTON"
var _hovered := false
var _state_tween: Tween
var _pulse_tween: Tween
var _idle_texture: Texture2D
var _active_texture: Texture2D
var _icon_idle_texture: Texture2D
var _icon_active_texture: Texture2D
var _chevron_texture: Texture2D

@export var label_text: String:
	get:
		return _label_text
	set(value):
		_label_text = value
		if is_node_ready():
			_apply_label_text()


func _ready() -> void:
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(206.0, 42.0)
	_idle_texture = _load_png_texture(IDLE_PATH)
	_active_texture = _load_png_texture(ACTIVE_PATH)
	_icon_idle_texture = _load_png_texture(ICON_IDLE_PATH)
	_icon_active_texture = _load_png_texture(ICON_ACTIVE_PATH)
	_chevron_texture = _load_png_texture(CHEVRON_PATH)
	$Idle.texture = _idle_texture
	$Active.texture = _active_texture
	$Glow.texture = _active_texture
	$IconIdle.texture = _icon_idle_texture
	$IconActive.texture = _icon_active_texture
	$Chevron.texture = _chevron_texture
	var add_material := CanvasItemMaterial.new()
	add_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	$Glow.material = add_material
	$Label.add_theme_font_size_override("font_size", 13)
	$LabelShadow.add_theme_font_size_override("font_size", 13)
	_apply_label_text()
	_apply_label_style(TEXT)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	toggled.connect(_on_toggled)
	button_down.connect(_on_button_down)
	button_up.connect(_sync_visual_state)
	resized.connect(_update_pivots)
	_sync_visual_state()
	call_deferred("_update_pivots")


func _on_mouse_entered() -> void:
	_hovered = true
	_sync_visual_state()


func _on_mouse_exited() -> void:
	_hovered = false
	_sync_visual_state()


func _on_toggled(_pressed_state: bool) -> void:
	_sync_visual_state()


func _on_button_down() -> void:
	_animate_state(1.0, 0.24 if not button_pressed else 0.22, SELECTED_GLOW if button_pressed else HOVER_GLOW, 1.0, 1.2, 0.985, TEXT_SELECTED if button_pressed else TEXT_HOVER)


func _sync_visual_state() -> void:
	_stop_selected_pulse()
	if button_pressed:
		_animate_state(1.0, 0.16, SELECTED_GLOW, 0.9, 0.8, 1.0, TEXT_SELECTED)
		_start_selected_pulse()
	elif _hovered:
		_animate_state(0.54, 0.14, HOVER_GLOW, 0.64, 0.8, 1.0, TEXT_HOVER)
	else:
		_animate_state(0.0, 0.0, HOVER_GLOW, 0.0, 0.0, 1.0, TEXT)


func _animate_state(active_alpha: float, glow_alpha: float, glow_color: Color, line_alpha: float, warm_alpha: float, target_scale: float, font_color: Color) -> void:
	if _state_tween:
		_state_tween.kill()
	_state_tween = create_tween()
	_state_tween.set_parallel(true)
	_state_tween.set_trans(Tween.TRANS_QUART)
	_state_tween.set_ease(Tween.EASE_OUT)
	_state_tween.tween_property($Active, "modulate:a", active_alpha, 0.16)
	_state_tween.tween_property($Glow, "modulate:a", glow_alpha, 0.18)
	_state_tween.tween_property($Glow, "scale", Vector2(target_scale, target_scale), 0.18)
	_state_tween.tween_property($IconActive, "modulate:a", min(active_alpha + glow_alpha, 1.0), 0.16)
	_state_tween.tween_property($IconIdle, "modulate:a", 1.0 - min(active_alpha, 1.0), 0.16)
	_state_tween.tween_property($TopLine, "modulate:a", line_alpha, 0.14)
	_state_tween.tween_property($WarmTick, "modulate:a", warm_alpha, 0.14)
	_state_tween.tween_property($LabelShadow, "position:x", 81.0 if target_scale <= 1.0 else 85.0, 0.16)
	_state_tween.tween_property($Label, "position:x", 80.0 if target_scale <= 1.0 else 84.0, 0.16)
	_state_tween.tween_property($Chevron, "position:x", size.x - 33.0, 0.16)
	$Glow.modulate = Color(glow_color.r, glow_color.g, glow_color.b, $Glow.modulate.a)
	$TopLine.color = Color(glow_color.r, glow_color.g, glow_color.b, 1.0)
	$WarmTick.color = Color(WARM_GLOW.r, WARM_GLOW.g, WARM_GLOW.b, 1.0)
	_apply_label_style(font_color)
	$Chevron.modulate = font_color


func _start_selected_pulse() -> void:
	if _pulse_tween:
		return
	_pulse_tween = create_tween()
	_pulse_tween.set_loops()
	_pulse_tween.set_trans(Tween.TRANS_SINE)
	_pulse_tween.set_ease(Tween.EASE_IN_OUT)
	_pulse_tween.tween_property($Glow, "modulate:a", 0.2, 0.92)
	_pulse_tween.parallel().tween_property($Glow, "scale", Vector2(1.01, 1.01), 0.92)
	_pulse_tween.tween_property($Glow, "modulate:a", 0.12, 1.08)
	_pulse_tween.parallel().tween_property($Glow, "scale", Vector2(1.0, 1.0), 1.08)


func _stop_selected_pulse() -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null


func _update_pivots() -> void:
	$Glow.pivot_offset = $Glow.size * 0.5
	$Chevron.position.x = size.x - 33.0


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
		push_warning("Unable to load nav texture: %s" % texture_path)
		return null
	return ImageTexture.create_from_image(image)
