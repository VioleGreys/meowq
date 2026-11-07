class_name Flag
extends Control
## Упрощённый флаг, нарисованный по описанию из nations.json:
## {"t": тип, "c": [цвета...]}. Гербы и сложные эмблемы сведены к простым
## фигурам — стилизация, а не точная копия.

var spec: Dictionary = {}:
	set(v):
		spec = v
		queue_redraw()


static func make(s: Dictionary, sz: Vector2 = Vector2(42, 28)) -> Flag:
	var f := Flag.new()
	f.spec = s
	f.custom_minimum_size = sz
	f.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return f


func _c(i: int) -> Color:
	var cs: Array = spec.get("c", ["#888888"])
	return Color(cs[mini(i, cs.size() - 1)])


func _draw() -> void:
	var w := size.x
	var h := size.y
	var cs: Array = spec.get("c", ["#888888"])
	match spec.get("t", "h"):
		"h":
			for i in cs.size():
				draw_rect(Rect2(0, h * i / cs.size(), w, h / cs.size() + 0.5), _c(i))
		"h3":   # широкая полоса посередине уже (Латвия)
			draw_rect(Rect2(0, 0, w, h), _c(0))
			draw_rect(Rect2(0, h * 0.4, w, h * 0.2), _c(1))
		"v":
			for i in cs.size():
				draw_rect(Rect2(w * i / cs.size(), 0, w / cs.size() + 0.5, h), _c(i))
		"nordic":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			var t := h * 0.24
			draw_rect(Rect2(w * 0.28, 0, t, h), _c(1))
			draw_rect(Rect2(0, (h - t) * 0.5, w, t), _c(1))
			if cs.size() > 2:
				var t2 := t * 0.5
				draw_rect(Rect2(w * 0.28 + (t - t2) * 0.5, 0, t2, h), _c(2))
				draw_rect(Rect2(0, (h - t2) * 0.5, w, t2), _c(2))
		"swiss":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			var arm := h * 0.18
			draw_rect(Rect2(w * 0.5 - arm * 0.5, h * 0.2, arm, h * 0.6), _c(1))
			draw_rect(Rect2(w * 0.5 - h * 0.3, h * 0.5 - arm * 0.5, h * 0.6, arm), _c(1))
		"union":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			draw_line(Vector2.ZERO, Vector2(w, h), _c(1), h * 0.2)
			draw_line(Vector2(0, h), Vector2(w, 0), _c(1), h * 0.2)
			draw_line(Vector2.ZERO, Vector2(w, h), _c(2), h * 0.07)
			draw_line(Vector2(0, h), Vector2(w, 0), _c(2), h * 0.07)
			draw_rect(Rect2(w * 0.5 - h * 0.17, 0, h * 0.34, h), _c(1))
			draw_rect(Rect2(0, h * 0.33, w, h * 0.34), _c(1))
			draw_rect(Rect2(w * 0.5 - h * 0.1, 0, h * 0.2, h), _c(2))
			draw_rect(Rect2(0, h * 0.4, w, h * 0.2), _c(2))
		"canton_star":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			_star(Vector2(w * 0.2, h * 0.27), h * 0.14, _c(1))
		"czech":
			draw_rect(Rect2(0, 0, w, h * 0.5), _c(0))
			draw_rect(Rect2(0, h * 0.5, w, h * 0.5), _c(1))
			draw_colored_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w * 0.5, h * 0.5), Vector2(0, h)]), _c(2))
		"greece":
			for i in 9:
				draw_rect(Rect2(0, h * i / 9.0, w, h / 9.0 + 0.5), _c(i % 2))
			var cw := h * 5.0 / 9.0
			draw_rect(Rect2(0, 0, cw, cw), _c(0))
			draw_rect(Rect2(cw * 0.4, 0, cw * 0.2, cw), _c(1))
			draw_rect(Rect2(0, cw * 0.4, cw, cw * 0.2), _c(1))
		"portugal":
			draw_rect(Rect2(0, 0, w * 0.4, h), _c(0))
			draw_rect(Rect2(w * 0.4, 0, w * 0.6, h), _c(1))
			draw_circle(Vector2(w * 0.4, h * 0.5), h * 0.25, _c(2))
			draw_circle(Vector2(w * 0.4, h * 0.5), h * 0.15, Color("#da291c"))
		"crescent":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			var c := Vector2(w * 0.38, h * 0.5)
			draw_circle(c, h * 0.25, _c(1))
			draw_circle(c + Vector2(h * 0.07, 0), h * 0.2, _c(0))
			_star(Vector2(w * 0.58, h * 0.5), h * 0.11, _c(1))
		"egypt":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			var c := Vector2(w * 0.45, h * 0.5)
			draw_circle(c, h * 0.27, _c(1))
			draw_circle(c + Vector2(h * 0.08, 0), h * 0.22, _c(0))
			for k in 3:
				_star(Vector2(w * 0.55, h * (0.3 + 0.2 * k)), h * 0.06, _c(1))
		"iraq":
			for i in 3:
				draw_rect(Rect2(0, h * i / 3.0, w, h / 3.0 + 0.5), _c(i))
			draw_colored_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w * 0.25, h * 0.33),
				Vector2(w * 0.25, h * 0.67), Vector2(0, h)]), _c(3))
		"saudi":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			draw_rect(Rect2(w * 0.2, h * 0.62, w * 0.6, h * 0.06), _c(1))
			draw_rect(Rect2(w * 0.22, h * 0.3, w * 0.56, h * 0.18), _c(1).darkened(0.05))
		"emblem":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			var c := Vector2(w * 0.5, h * 0.5)
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -h * 0.32), c + Vector2(h * 0.25, 0),
				c + Vector2(0, h * 0.32), c + Vector2(-h * 0.25, 0)]), _c(1))
		"danzig":
			draw_rect(Rect2(0, 0, w, h), _c(0))
			for y in [0.42, 0.72]:
				var c := Vector2(w * 0.3, h * y)
				draw_line(c - Vector2(h * 0.1, h * 0.1), c + Vector2(h * 0.1, h * 0.1), _c(1), 2.0)
				draw_line(c - Vector2(h * 0.1, -h * 0.1), c + Vector2(h * 0.1, -h * 0.1), _c(1), 2.0)
			draw_rect(Rect2(w * 0.22, h * 0.12, w * 0.16, h * 0.12), _c(2))
		_:
			draw_rect(Rect2(0, 0, w, h), _c(0))
	if spec.has("emblem"):
		draw_circle(Vector2(w * 0.5, h * 0.5), h * 0.12, Color(spec["emblem"]))
	draw_rect(Rect2(0, 0, w, h), Color(0, 0, 0, 0.6), false, 1.0)


func _star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2 + i * PI / 5
		var rr := r if i % 2 == 0 else r * 0.42
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	draw_colored_polygon(pts, col)
