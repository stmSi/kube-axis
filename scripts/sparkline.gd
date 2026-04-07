extends Control

const GRID := Color8(31, 72, 96, 110)
const FILL := Color8(34, 163, 210, 42)

var points: PackedFloat32Array = PackedFloat32Array()
var line_color := Color8(92, 237, 255, 255)


func set_points(values: Array) -> void:
	points = PackedFloat32Array(values)
	queue_redraw()


func set_line_color(color: Color) -> void:
	line_color = color
	queue_redraw()


func _draw() -> void:
	var rect := get_rect().grow(-4.0)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	draw_rect(rect, Color(0.03, 0.08, 0.12, 0.88), true)
	for index in range(1, 4):
		var y := rect.position.y + rect.size.y * float(index) / 4.0
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), GRID, 1.0)
	if points.size() == 0:
		return
	var min_value := points[0]
	var max_value := points[0]
	for value in points:
		min_value = min(min_value, value)
		max_value = max(max_value, value)
	if is_equal_approx(min_value, max_value):
		min_value -= 1.0
		max_value += 1.0
	var polyline := PackedVector2Array()
	for index in range(points.size()):
		var value := points[index]
		var x: float = rect.position.x + rect.size.x * float(index) / max(float(points.size() - 1), 1.0)
		var normalized := inverse_lerp(min_value, max_value, value)
		var y := rect.end.y - normalized * rect.size.y
		polyline.append(Vector2(x, y))
	if polyline.size() >= 2:
		var fill_poly := PackedVector2Array()
		fill_poly.append(Vector2(polyline[0].x, rect.end.y))
		for point in polyline:
			fill_poly.append(point)
		fill_poly.append(Vector2(polyline[-1].x, rect.end.y))
		draw_colored_polygon(fill_poly, Color(line_color.r, line_color.g, line_color.b, 0.16) + FILL)
		draw_polyline(polyline, line_color, 2.5, true)
