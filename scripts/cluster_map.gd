extends Control

signal group_selected(group_key: String)

const BACKDROP := Color8(6, 14, 23, 255)
const PANEL_FILL := Color8(10, 22, 36, 232)
const PANEL_BORDER := Color8(81, 218, 255, 180)
const PANEL_BORDER_STRONG := Color8(255, 181, 64, 210)
const TEXT := Color8(226, 244, 255, 255)
const TEXT_MUTED := Color8(118, 156, 180, 255)
const SUCCESS := Color8(108, 255, 154, 255)
const WARNING := Color8(255, 181, 64, 255)
const DANGER := Color8(255, 103, 103, 255)
const CORE_GLOW := Color8(74, 234, 255, 100)

var overlay: Control
var groups: Array = []
var nodes: Array = []
var selected_group_key := ""
var current_mode := "Workloads"
var cached_group_slots := []
var cached_node_slots := []
var pulse := 0.0


func _ready() -> void:
	clip_contents = true
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)
	set_process(true)


func set_dashboard_data(groups_data: Array, node_data: Array, group_key: String, mode_name: String) -> void:
	groups = groups_data
	nodes = node_data
	selected_group_key = group_key
	current_mode = mode_name
	_rebuild_overlay()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_inside_tree():
		_rebuild_overlay()
		queue_redraw()


func _process(delta: float) -> void:
	pulse += delta
	queue_redraw()


func _draw() -> void:
	var rect := get_rect().grow(-8.0)
	var frame := _bevel_points(rect, 22.0)
	draw_colored_polygon(frame, BACKDROP)
	_draw_outline(frame, Color(0.24, 0.74, 0.94, 0.10), 8.0)
	_draw_outline(frame, Color(0.24, 0.74, 0.94, 0.72), 2.0)
	var inner := _bevel_points(rect.grow(-10.0), 14.0)
	_draw_outline(inner, Color(0.18, 0.38, 0.5, 0.64), 1.0)
	_draw_header_strip(rect)
	_draw_grid(rect.grow(-14.0))
	_draw_orbit_markers(rect)
	_draw_core(rect)
	_draw_connections(rect)


func _draw_grid(rect: Rect2) -> void:
	var x := rect.position.x
	while x < rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), Color(0.06, 0.16, 0.22, 0.1), 1.0)
		x += 36.0
	var y := rect.position.y
	while y < rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), Color(0.06, 0.16, 0.22, 0.1), 1.0)
		y += 36.0


func _draw_header_strip(rect: Rect2) -> void:
	var top_rect := Rect2(rect.position + Vector2(14.0, 12.0), Vector2(rect.size.x - 28.0, 28.0))
	draw_rect(top_rect, Color(0.05, 0.11, 0.18, 0.92), true)
	draw_rect(top_rect, Color(0.19, 0.44, 0.58, 0.85), false, 1.0)
	draw_line(top_rect.position + Vector2(8.0, 8.0), top_rect.position + Vector2(top_rect.size.x - 76.0, 8.0), Color(0.26, 0.78, 1.0, 0.42), 1.0)
	draw_line(top_rect.position + Vector2(8.0, 14.0), top_rect.position + Vector2(top_rect.size.x - 130.0, 14.0), Color(1.0, 0.66, 0.2, 0.3), 2.0)
	var marker_x := top_rect.position.x + top_rect.size.x * 0.56
	draw_circle(Vector2(marker_x, top_rect.position.y + 14.0), 6.0, Color(1.0, 0.68, 0.2, 0.8))
	draw_circle(Vector2(marker_x, top_rect.position.y + 14.0), 12.0, Color(1.0, 0.68, 0.2, 0.16))
	var font := ThemeDB.fallback_font
	draw_string(font, top_rect.position + Vector2(12.0, 22.0), "INCIDENT REPLAY // %s" % current_mode.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, TEXT_MUTED)
	draw_string(font, top_rect.position + Vector2(top_rect.size.x - 56.0, 22.0), "NOW", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, TEXT_MUTED)


func _draw_orbit_markers(rect: Rect2) -> void:
	var center := rect.get_center()
	for index in range(12):
		var angle := pulse * 0.15 + TAU * float(index) / 12.0
		var point: Vector2 = center + Vector2.from_angle(angle) * (min(rect.size.x, rect.size.y) * 0.32)
		draw_circle(point, 2.0, Color(0.3, 0.95, 1.0, 0.4))
	for index in range(8):
		var angle := -pulse * 0.18 + TAU * float(index) / 8.0
		var point: Vector2 = center + Vector2.from_angle(angle) * (min(rect.size.x, rect.size.y) * 0.22)
		draw_circle(point, 2.0, Color(1.0, 0.66, 0.2, 0.28))


func _draw_core(rect: Rect2) -> void:
	var center := rect.get_center()
	var base_radius: float = min(rect.size.x, rect.size.y) * 0.16
	for ring_index in range(4):
		var radius: float = base_radius + ring_index * 56.0
		var alpha := 0.17 - ring_index * 0.025 + sin(pulse * 1.2 + float(ring_index)) * 0.02
		draw_arc(center, radius, 0.0, TAU, 72, Color(0.3, 0.9, 1.0, clamp(alpha, 0.04, 0.22)), 2.0, true)
	for ring_index in range(3):
		var spin_radius: float = base_radius + 24.0 + ring_index * 82.0
		var start_angle := pulse * 0.35 + ring_index * 0.8
		var end_angle := start_angle + PI * 0.95
		draw_arc(center, spin_radius, start_angle, end_angle, 36, Color(1.0, 0.66, 0.2, 0.20), 2.0, true)
	var points := PackedVector2Array()
	for index in range(6):
		var angle := TAU * float(index) / 6.0 - PI * 0.5
		points.append(center + Vector2.from_angle(angle) * 72.0)
	draw_colored_polygon(points, Color(0.08, 0.18, 0.28, 0.9))
	for index in range(points.size()):
		draw_line(points[index], points[(index + 1) % points.size()], Color(0.45, 0.95, 1.0, 0.65), 2.0)
	draw_circle(center, 48.0 + sin(pulse * 2.0) * 6.0, CORE_GLOW)
	draw_circle(center, 22.0, Color(0.55, 1.0, 1.0, 0.8))
	var font := ThemeDB.fallback_font
	var font_size := 18
	draw_string(font, center + Vector2(-58, -10), "CLUSTER CORE", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, TEXT)
	draw_string(font, center + Vector2(-44, 14), "K8S TOPOLOGY", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, TEXT_MUTED)
	draw_arc(center, 106.0, -PI * 0.8, PI * 0.05, 28, Color(1.0, 0.66, 0.2, 0.25), 3.0, true)
	draw_arc(center, 106.0, PI * 0.2, PI * 0.85, 28, Color(0.24, 0.78, 1.0, 0.24), 3.0, true)


func _draw_connections(rect: Rect2) -> void:
	var center := rect.get_center()
	for node_slot in cached_node_slots:
		var node_point: Vector2 = node_slot.position
		draw_line(center, node_point, Color(0.26, 0.78, 1.0, 0.22), 2.0)
	for group_slot in cached_group_slots:
		var group_point: Vector2 = group_slot.position
		draw_line(center, group_point, Color(0.93, 0.65, 0.2, 0.28), 2.0)
		for node_name in group_slot.nodes:
			for node_slot in cached_node_slots:
				if node_slot.name == node_name:
					draw_line(group_point, node_slot.position, Color(0.3, 1.0, 0.7, 0.23), 2.0)
					break


func _rebuild_overlay() -> void:
	if overlay == null:
		return
	for child in overlay.get_children():
		child.queue_free()
	cached_group_slots.clear()
	cached_node_slots.clear()
	var rect := get_rect().grow(-8.0)
	var display_groups := groups.slice(0, min(groups.size(), 4))
	var display_nodes := nodes.slice(0, min(nodes.size(), 3))
	var group_positions := _group_positions(rect, display_groups.size())
	var node_positions := _node_positions(rect, display_nodes.size())
	for index in range(display_nodes.size()):
		var node: Dictionary = display_nodes[index]
		var node_card := _make_node_card(node)
		var node_size := node_card.custom_minimum_size
		node_card.position = node_positions[index] - node_size * 0.5
		node_card.size = node_size
		overlay.add_child(node_card)
		cached_node_slots.append({
			"name": String(node.get("name", "")),
			"position": node_positions[index],
		})
	for index in range(display_groups.size()):
		var group: Dictionary = display_groups[index]
		var group_card := _make_group_card(group)
		var group_size := group_card.custom_minimum_size
		group_card.position = group_positions[index] - group_size * 0.5
		group_card.size = group_size
		overlay.add_child(group_card)
		cached_group_slots.append({
			"name": String(group.get("name", "")),
			"nodes": group.get("nodes", []),
			"position": group_positions[index],
		})


func _group_positions(rect: Rect2, count: int) -> Array:
	var center := rect.get_center()
	var radius_x := rect.size.x * 0.34
	var radius_y := rect.size.y * 0.28
	var angles := []
	match count:
		1:
			angles = [-PI * 0.35]
		2:
			angles = [-PI * 0.85, -PI * 0.15]
		3:
			angles = [-PI * 0.85, -PI * 0.08, PI * 0.5]
		_:
			angles = [-PI * 0.82, -PI * 0.18, PI * 0.23, PI * 0.68]
	var positions := []
	for angle in angles:
		positions.append(center + Vector2(cos(angle) * radius_x, sin(angle) * radius_y))
	return positions


func _node_positions(rect: Rect2, count: int) -> Array:
	var center := rect.get_center()
	var offsets := []
	match count:
		1:
			offsets = [Vector2(0.0, -rect.size.y * 0.19)]
		2:
			offsets = [Vector2(0.0, -rect.size.y * 0.19), Vector2(0.0, rect.size.y * 0.23)]
		_:
			offsets = [
				Vector2(0.0, -rect.size.y * 0.19),
				Vector2(-rect.size.x * 0.17, rect.size.y * 0.18),
				Vector2(rect.size.x * 0.17, rect.size.y * 0.18),
			]
	var positions := []
	for offset in offsets:
		positions.append(center + offset)
	return positions


func _make_group_card(group: Dictionary) -> Control:
	var is_selected := String(group.get("key", "")) == selected_group_key
	var card := Button.new()
	card.text = ""
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(180.0, 104.0)
	card.add_theme_stylebox_override("normal", _card_style(is_selected, current_mode == "Logs"))
	card.add_theme_stylebox_override("hover", _card_style(true, false))
	card.add_theme_stylebox_override("pressed", _card_style(true, false))
	card.pressed.connect(func(): emit_signal("group_selected", String(group.get("key", ""))))

	var content := MarginContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("margin_left", 14)
	content.add_theme_constant_override("margin_top", 12)
	content.add_theme_constant_override("margin_right", 14)
	content.add_theme_constant_override("margin_bottom", 12)
	card.add_child(content)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	content.add_child(body)

	var title := Label.new()
	title.text = String(group.get("name", "workload")).to_upper()
	title.add_theme_color_override("font_color", TEXT)
	title.add_theme_font_size_override("font_size", 16)
	body.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "%s  |  %d/%d READY" % [
		String(group.get("namespace", "default")).to_upper(),
		int(group.get("ready_pods", 0)),
		int(group.get("pod_count", 0)),
	]
	subtitle.add_theme_color_override("font_color", TEXT_MUTED)
	subtitle.add_theme_font_size_override("font_size", 12)
	body.add_child(subtitle)

	var dots := HBoxContainer.new()
	dots.add_theme_constant_override("separation", 8)
	body.add_child(dots)
	var dot_colors := _status_colors(group)
	for dot_color in dot_colors:
		var indicator := PanelContainer.new()
		indicator.custom_minimum_size = Vector2(14.0, 14.0)
		indicator.add_theme_stylebox_override("panel", _dot_style(dot_color))
		dots.add_child(indicator)

	return card


func _make_node_card(node: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(144.0, 86.0)
	card.add_theme_stylebox_override("panel", _node_style(node))

	var content := MarginContainer.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.add_theme_constant_override("margin_left", 12)
	content.add_theme_constant_override("margin_top", 10)
	content.add_theme_constant_override("margin_right", 12)
	content.add_theme_constant_override("margin_bottom", 10)
	card.add_child(content)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	content.add_child(body)

	var title := Label.new()
	title.text = String(node.get("name", "node")).to_upper()
	title.add_theme_color_override("font_color", TEXT)
	title.add_theme_font_size_override("font_size", 15)
	body.add_child(title)

	var cpu: float = float(node.get("cpu_percent", -1.0))
	var memory: float = float(node.get("memory_percent", -1.0))
	var subtitle := Label.new()
	if cpu >= 0.0 and memory >= 0.0:
		subtitle.text = "CPU %.0f%%  |  MEM %.0f%%" % [cpu, memory]
	else:
		subtitle.text = "READY  |  %s" % ", ".join(node.get("roles", [])).to_upper()
	subtitle.add_theme_color_override("font_color", TEXT_MUTED)
	subtitle.add_theme_font_size_override("font_size", 12)
	body.add_child(subtitle)

	return card


func _status_colors(group: Dictionary) -> Array:
	var colors := []
	var ready := int(group.get("ready_pods", 0))
	var total := int(group.get("pod_count", 0))
	for index in range(total):
		if index < ready:
			colors.append(SUCCESS)
		else:
			colors.append(DANGER)
	while colors.size() < 4:
		colors.append(WARNING if colors.is_empty() else Color(colors[-1].r, colors[-1].g, colors[-1].b, 0.45))
	return colors.slice(0, 4)


func _card_style(is_selected: bool, is_secondary: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.13, 0.2, 0.94)
	style.border_color = PANEL_BORDER_STRONG if is_selected else PANEL_BORDER
	if is_secondary:
		style.border_color = Color(0.28, 0.75, 1.0, 0.56)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(style.border_color.r, style.border_color.g, style.border_color.b, 0.14)
	style.shadow_size = 12
	style.content_margin_left = 0.0
	style.content_margin_top = 0.0
	style.content_margin_right = 0.0
	style.content_margin_bottom = 0.0
	return style


func _node_style(node: Dictionary) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.17, 0.24, 0.92)
	style.border_color = SUCCESS if String(node.get("status", "")) == "Ready" else DANGER
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	return style


func _dot_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(10)
	return style


func _bevel_points(rect: Rect2, cut: float) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(rect.position.x + cut, rect.position.y),
		Vector2(rect.end.x - cut, rect.position.y),
		Vector2(rect.end.x, rect.position.y + cut),
		Vector2(rect.end.x, rect.end.y - cut),
		Vector2(rect.end.x - cut, rect.end.y),
		Vector2(rect.position.x + cut, rect.end.y),
		Vector2(rect.position.x, rect.end.y - cut),
		Vector2(rect.position.x, rect.position.y + cut),
	])


func _draw_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	var closed := PackedVector2Array(points)
	closed.append(points[0])
	draw_polyline(closed, color, width, true)
