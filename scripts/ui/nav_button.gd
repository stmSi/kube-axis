extends TextureButton

const IDLE_PATH := "res://assets/ui/nav_shell_idle.png"
const ACTIVE_PATH := "res://assets/ui/nav_shell_active.png"
const ICON_IDLE_PATH := "res://assets/ui/nav_icon_idle.png"
const ICON_ACTIVE_PATH := "res://assets/ui/nav_icon_active.png"
const CHEVRON_PATH := "res://assets/ui/nav_chevron.png"
const TEXT := Color8(226, 244, 255, 255)
const TEXT_HOVER := Color8(241, 252, 255, 255)
const TEXT_SELECTED := Color8(242, 253, 255, 255)
const TEXT_SHADOW := Color8(4, 12, 19, 232)
const HOVER_GLOW := Color8(88, 240, 255, 255)
const SELECTED_GLOW := Color8(148, 255, 248, 255)
const WARM_GLOW := Color8(255, 183, 67, 255)

static var _texture_cache := {}

var _label_text := "BUTTON"
var _hovered := false
var _state_tween: Tween
var _pulse_tween: Tween
var _sweep_mode := ""
var _sweep_phase := 0.0
var _sweep_speed := 0.0
var _sweep_strength := 0.0
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
	clip_contents = true
	custom_minimum_size = Vector2(184.0, 40.0)
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
	var sweep_material := CanvasItemMaterial.new()
	sweep_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	$SweepGlow.material = sweep_material
	$Label.add_theme_font_size_override("font_size", 13)
	$LabelShadow.add_theme_font_size_override("font_size", 13)
	_apply_label_text()
	_apply_label_style(TEXT)
	set_process(false)
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
	_animate_state(1.0, 0.28 if not button_pressed else 0.46, SELECTED_GLOW if button_pressed else HOVER_GLOW, 1.0, 1.4, 1.0, TEXT_SELECTED if button_pressed else TEXT_HOVER)


func _sync_visual_state() -> void:
	_stop_selected_pulse()
	if button_pressed:
		_animate_state(1.0, 0.42, SELECTED_GLOW, 1.0, 1.35, 1.03, TEXT_SELECTED)
		_set_sweep_state("selected")
		_start_selected_pulse()
	elif _hovered:
		_animate_state(0.54, 0.16, HOVER_GLOW, 0.72, 0.9, 1.0, TEXT_HOVER)
		_set_sweep_state("hover")
	else:
		_animate_state(0.0, 0.0, HOVER_GLOW, 0.0, 0.0, 1.0, TEXT)
		_set_sweep_state("")


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
	_state_tween.tween_property($LabelShadow, "position:x", 67.0 if target_scale <= 1.0 else 71.0, 0.16)
	_state_tween.tween_property($Label, "position:x", 66.0 if target_scale <= 1.0 else 70.0, 0.16)
	_state_tween.tween_property($Chevron, "position:x", size.x - 27.0, 0.16)
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
	_pulse_tween.tween_property($Glow, "modulate:a", 0.54, 0.84)
	_pulse_tween.parallel().tween_property($Glow, "scale", Vector2(1.07, 1.07), 0.84)
	_pulse_tween.tween_property($Glow, "modulate:a", 0.34, 0.96)
	_pulse_tween.parallel().tween_property($Glow, "scale", Vector2(1.02, 1.02), 0.96)


func _stop_selected_pulse() -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null


func _update_pivots() -> void:
	$Glow.pivot_offset = $Glow.size * 0.5
	$Chevron.position.x = size.x - 27.0
	_update_sweep_geometry()


func _apply_label_text() -> void:
	$Label.text = _label_text
	$LabelShadow.text = _label_text


func _apply_label_style(font_color: Color) -> void:
	$Label.add_theme_color_override("font_color", font_color)
	$LabelShadow.add_theme_color_override("font_color", TEXT_SHADOW)
	$LabelShadow.modulate = Color(1.0, 1.0, 1.0, 0.96)


func _load_png_texture(texture_path: String) -> Texture2D:
	if _texture_cache.has(texture_path):
		return _texture_cache[texture_path]
	var texture := load(texture_path) as Texture2D
	if texture == null:
		push_warning("Unable to load nav texture: %s" % texture_path)
		return null
	_texture_cache[texture_path] = texture
	return texture


func _process(delta: float) -> void:
	if _sweep_mode.is_empty() and $SweepGlow.modulate.a <= 0.01 and $SweepCore.modulate.a <= 0.01:
		set_process(false)
		return

	var lane_start: float = 52.0
	var lane_end: float = maxf(size.x - 44.0, lane_start + 1.0)
	var travel: float = lane_end - lane_start + 40.0
	if _sweep_mode.is_empty():
		$SweepGlow.modulate.a = move_toward($SweepGlow.modulate.a, 0.0, delta * 4.5)
		$SweepCore.modulate.a = move_toward($SweepCore.modulate.a, 0.0, delta * 6.5)
		return

	_sweep_phase = wrapf(_sweep_phase + delta * _sweep_speed, 0.0, travel)
	var normalized: float = _sweep_phase / travel
	var envelope: float = sin(normalized * PI)
	var glow_alpha: float = _sweep_strength * envelope
	var core_alpha: float = minf(_sweep_strength + 0.22, 0.82) * envelope
	var x: float = lane_start - 28.0 + _sweep_phase

	$SweepGlow.position.x = x
	$SweepCore.position.x = x + 10.0
	$SweepGlow.modulate.a = glow_alpha
	$SweepCore.modulate.a = core_alpha


func _set_sweep_state(mode: String) -> void:
	if _sweep_mode == mode:
		return
	_sweep_mode = mode
	match mode:
		"selected":
			_sweep_speed = 86.0
			_sweep_strength = 0.44
			$SweepGlow.color = SELECTED_GLOW
			$SweepCore.color = Color(0.92, 1.0, 0.98, 1.0)
		"hover":
			_sweep_speed = 132.0
			_sweep_strength = 0.28
			$SweepGlow.color = HOVER_GLOW
			$SweepCore.color = Color(0.86, 0.98, 1.0, 1.0)
		_:
			_sweep_speed = 0.0
			_sweep_strength = 0.0
	if not mode.is_empty():
		_sweep_phase = 0.0
		_update_sweep_geometry()
		set_process(true)
	elif $SweepGlow.modulate.a > 0.01 or $SweepCore.modulate.a > 0.01:
		set_process(true)


func _update_sweep_geometry() -> void:
	$SweepGlow.position = Vector2(-36.0, 6.0)
	$SweepCore.position = Vector2(-24.0, 8.0)
