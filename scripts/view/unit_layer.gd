class_name UnitLayer
extends Node2D
## Фишки дивизий, стрелки приказов, значки боёв и названия стран. Рисуется в
## экранных координатах (в своём CanvasLayer), поэтому текст всегда чёткий.

var map: MapView
var world: World
var selected: Array = []        # выбранные дивизии
var player := -1
var font: Font
var _labels: Array = []         # [world_pos, name, size]
var _labels_day := -1


func _ready() -> void:
	font = ThemeDB.fallback_font


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if map == null or world == null:
		return
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	_draw_nation_labels(z, vp)

	var counter := Vector2(34, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
	# стрелки движения
	for d in world.divisions:
		if not d.alive or d.path.is_empty():
			continue
		if d.owner != player and z < 1.4:
			continue
		var is_sel: bool = selected.has(d)
		var a := map.world_to_screen(map.province_world_pos(d.prov))
		var col := Color(1, 1, 1, 0.85) if is_sel else Color(world.nations[d.owner].color.darkened(0.5), 0.7)
		var pts := PackedVector2Array([a])
		var limit: int = d.path.size() if is_sel else 1
		for i in limit:
			pts.append(map.world_to_screen(map.province_world_pos(d.path[i])))
		if pts.size() >= 2:
			draw_polyline(pts, col, 3.0 if is_sel else 2.0, true)
			var tip := pts[pts.size() - 1]
			var dir := (tip - pts[pts.size() - 2]).normalized()
			var side := Vector2(-dir.y, dir.x)
			draw_colored_polygon(PackedVector2Array([tip, tip - dir * 11 + side * 6, tip - dir * 11 - side * 6]), col)
			# прогресс к первой провинции
			var p0 := pts[0].lerp(pts[1], clampf(d.progress, 0.0, 1.0))
			draw_circle(p0, 3.0, col)

	# значки боёв
	var battle_provs := {}
	for d in world.divisions:
		if d.alive and d.in_battle and not d.path.is_empty():
			battle_provs[d.path[0]] = true
	for p in battle_provs:
		var c := map.world_to_screen(map.province_world_pos(p)) + Vector2(0, -counter.y)
		if not Rect2(Vector2.ZERO, vp).grow(40).has_point(c):
			continue
		var r := 9.0 + sin(Time.get_ticks_msec() * 0.008) * 1.5
		draw_circle(c, r + 2, Color(0.1, 0.05, 0.05, 0.8))
		draw_circle(c, r, Color(0.85, 0.2, 0.15))
		draw_line(c + Vector2(-5, -5), c + Vector2(5, 5), Color.WHITE, 2.0)
		draw_line(c + Vector2(5, -5), c + Vector2(-5, 5), Color.WHITE, 2.0)

	# фишки: по одной на (провинция, страна)
	var font_size := int(clampf(12 + z * 2, 12, 20))
	for p in world.prov_count:
		var list: Array = world.prov_divs[p]
		if list.is_empty():
			continue
		var groups := {}
		for d in list:
			if d.alive:
				if not groups.has(d.owner):
					groups[d.owner] = []
				groups[d.owner].append(d)
		var base := map.world_to_screen(map.province_world_pos(p))
		if not Rect2(Vector2.ZERO, vp).grow(40).has_point(base):
			continue
		var k := 0
		for owner in groups:
			var g: Array = groups[owner]
			var pos := base + Vector2(k * (counter.x + 4), 0) - counter * 0.5
			k += 1
			if z < 0.55 and owner != player:
				draw_rect(Rect2(base - Vector2(4, 4), Vector2(8, 8)), world.nations[owner].color.darkened(0.35))
				continue
			var any_sel := false
			var str_sum := 0.0
			var org_sum := 0.0
			for d in g:
				str_sum += d.strength
				org_sum += d.org / maxf(1.0, world.division_max_org(d.owner))
				if selected.has(d):
					any_sel = true
			var nat_col: Color = world.nations[owner].color
			var rect := Rect2(pos, counter)
			draw_rect(Rect2(pos + Vector2(2, 2), counter), Color(0, 0, 0, 0.35))
			draw_rect(rect, nat_col.darkened(0.15))
			draw_rect(Rect2(pos, Vector2(counter.x * 0.32, counter.y)), nat_col.lightened(0.25))
			draw_rect(rect, Color.WHITE if any_sel else Color(0.08, 0.08, 0.08), false, 2.5 if any_sel else 1.5)
			draw_string(font, pos + Vector2(counter.x * 0.36, counter.y * 0.5 + font_size * 0.36), str(g.size()),
				HORIZONTAL_ALIGNMENT_CENTER, counter.x * 0.6, font_size, Color(0.05, 0.05, 0.05))
			# полоски: зелёная — сила, жёлтая — организация
			var bw := counter.x
			var s := str_sum / (100.0 * g.size())
			var o := org_sum / g.size()
			draw_rect(Rect2(pos + Vector2(0, counter.y + 1), Vector2(bw, 3)), Color(0, 0, 0, 0.6))
			draw_rect(Rect2(pos + Vector2(0, counter.y + 1), Vector2(bw * s, 3)), Color(0.35, 0.85, 0.35))
			draw_rect(Rect2(pos + Vector2(0, counter.y + 4), Vector2(bw, 3)), Color(0, 0, 0, 0.6))
			draw_rect(Rect2(pos + Vector2(0, counter.y + 4), Vector2(bw * o, 3)), Color(0.95, 0.8, 0.25))


func _draw_nation_labels(z: float, vp: Vector2) -> void:
	if z > 1.6:
		return
	if _labels_day != world.day or world.palette_dirty:
		_rebuild_labels()
	for l in _labels:
		var pos := map.world_to_screen(l[0])
		var size := int(clampf(l[2] * z, 12, 64))
		if size < 13:
			continue
		var w := font.get_string_size(l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var alpha := clampf((1.6 - z) * 2.0, 0.0, 0.75)
		draw_string_outline(font, pos - Vector2(w * 0.5, 0), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(1, 1, 1, alpha * 0.4))
		draw_string(font, pos - Vector2(w * 0.5, 0), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.08, 0.07, 0.06, alpha))


func _rebuild_labels() -> void:
	_labels_day = world.day
	_labels.clear()
	var sums := {}
	for p in world.prov_count:
		var c := world.p_controller[p]
		if c < 0 or world.p_land[p] == 0:
			continue
		if not sums.has(c):
			sums[c] = [Vector2.ZERO, 0]
		sums[c][0] += world.p_center[p] * world.p_pixels[p]
		sums[c][1] += world.p_pixels[p]
	for c in sums:
		if not world.nations[c].alive:
			continue
		var px: int = sums[c][1]
		var center: Vector2 = sums[c][0] / maxf(1.0, px)
		_labels.append([center * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(float(px)) * 0.55])
