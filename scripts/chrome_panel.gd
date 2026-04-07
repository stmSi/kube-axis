extends PanelContainer

const DEFAULT_FILL := Color8(8, 18, 30, 235)
const DEFAULT_ACCENT := Color8(84, 232, 255, 190)
const DEFAULT_TRIM := Color8(49, 108, 144, 170)
const DEFAULT_GLOW := Color8(255, 177, 69, 210)

@export var fill_color: Color = DEFAULT_FILL
@export var accent_color: Color = DEFAULT_ACCENT
@export var trim_color: Color = DEFAULT_TRIM
@export var glow_color: Color = DEFAULT_GLOW
@export var compact := false
@export var emphasize_right := false
@export var show_inner_frame := true
@export var cut_size := 20.0
@export_file("*.png") var frame_texture_path := ""
@export var frame_patch_margin := 28

var _frame_texture: Texture2D
var _loaded_frame_texture_path := ""

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x < 40.0 or rect.size.y < 28.0:
		return
	var frame_texture := _get_frame_texture()
	if frame_texture:
		_draw_nine_patch(frame_texture, rect, frame_patch_margin)
		return

	var cut: float = min(cut_size, min(rect.size.x, rect.size.y) * 0.22)
	if compact:
		cut = min(cut, 12.0)

	var outer := _bevel_points(rect.grow(-1.0), cut)
	draw_colored_polygon(outer, fill_color)
	_draw_outline(outer, Color(accent_color.r, accent_color.g, accent_color.b, 0.22), 1.5)

	var inner_rect := rect.grow(-7.0)
	if inner_rect.size.x > 20.0 and inner_rect.size.y > 20.0:
		var inner := _bevel_points(inner_rect, max(cut - 6.0, 6.0))
		_draw_outline(inner, Color(trim_color.r, trim_color.g, trim_color.b, 0.32), 1.0)
		if show_inner_frame:
			var inset_rect := rect.grow(-13.0)
			if inset_rect.size.x > 20.0 and inset_rect.size.y > 20.0:
				var inset := _bevel_points(inset_rect, max(cut - 11.0, 4.0))
				_draw_outline(inset, Color(trim_color.r, trim_color.g, trim_color.b, 0.16), 1.0)

	_draw_top_track(rect, cut)
	if emphasize_right:
		_draw_right_emitter(rect)


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


func _draw_top_track(rect: Rect2, cut: float) -> void:
	var y := rect.position.y + (10.0 if compact else 14.0)
	var left_x := rect.position.x + cut + 10.0
	var right_x := rect.end.x - cut - 10.0
	draw_line(Vector2(left_x, y), Vector2(right_x, y), Color(trim_color.r, trim_color.g, trim_color.b, 0.22), 1.0)
	draw_line(Vector2(left_x, y), Vector2(min(left_x + rect.size.x * 0.22, right_x), y), Color(accent_color.r, accent_color.g, accent_color.b, 0.82), 2.0)


func _draw_right_emitter(rect: Rect2) -> void:
	var x := rect.end.x - 8.0
	var top_y := rect.position.y + rect.size.y * 0.42
	var bottom_y := rect.position.y + rect.size.y * 0.58
	draw_line(Vector2(x, top_y), Vector2(x, bottom_y), Color(accent_color.r, accent_color.g, accent_color.b, 0.5), 2.0)


func _get_frame_texture() -> Texture2D:
	if frame_texture_path == _loaded_frame_texture_path:
		return _frame_texture
	_loaded_frame_texture_path = frame_texture_path
	_frame_texture = null
	if frame_texture_path.is_empty():
		return null
	var image := Image.new()
	var error := image.load(ProjectSettings.globalize_path(frame_texture_path))
	if error != OK:
		push_warning("Unable to load frame texture: %s" % frame_texture_path)
		return null
	_frame_texture = ImageTexture.create_from_image(image)
	return _frame_texture


func _draw_nine_patch(texture: Texture2D, rect: Rect2, margin: int) -> void:
	var texture_size := texture.get_size()
	var left: float = min(float(margin), min(rect.size.x * 0.5, texture_size.x * 0.5))
	var right: float = min(float(margin), min(rect.size.x * 0.5, texture_size.x * 0.5))
	var top: float = min(float(margin), min(rect.size.y * 0.5, texture_size.y * 0.5))
	var bottom: float = min(float(margin), min(rect.size.y * 0.5, texture_size.y * 0.5))

	var destination_x: Array[float] = [rect.position.x, rect.position.x + left, rect.end.x - right]
	var destination_y: Array[float] = [rect.position.y, rect.position.y + top, rect.end.y - bottom]
	var destination_w: Array[float] = [left, max(rect.size.x - left - right, 0.0), right]
	var destination_h: Array[float] = [top, max(rect.size.y - top - bottom, 0.0), bottom]
	var source_x: Array[float] = [0.0, left, texture_size.x - right]
	var source_y: Array[float] = [0.0, top, texture_size.y - bottom]
	var source_w: Array[float] = [left, max(texture_size.x - left - right, 0.0), right]
	var source_h: Array[float] = [top, max(texture_size.y - top - bottom, 0.0), bottom]

	for row in range(3):
		for column in range(3):
			if destination_w[column] <= 0.0 or destination_h[row] <= 0.0:
				continue
			if source_w[column] <= 0.0 or source_h[row] <= 0.0:
				continue
			draw_texture_rect_region(
				texture,
				Rect2(destination_x[column], destination_y[row], destination_w[column], destination_h[row]),
				Rect2(source_x[column], source_y[row], source_w[column], source_h[row])
			)
