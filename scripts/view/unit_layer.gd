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

	# фронты и цели армий игрока
	for g in world.groups:
		if not g.alive or g.owner != player:
			continue
		var fp: PackedInt32Array = g.front_pairs
		for i in range(0, fp.size(), 2):
			var a := map.province_world_pos(fp[i])
			var b := map.province_world_pos(fp[i + 1])
			var m := map.world_to_screen((a + b) * 0.5)
			var dir := map.world_to_screen(b) - map.world_to_screen(a)
			var side := Vector2(-dir.y, dir.x).normalized() * minf(dir.length() * 0.45, 40.0)
			draw_line(m - side, m + side, Color(g.color, 0.9), 5.0)
			draw_line(m - side, m + side, Color(0, 0, 0, 0.35), 1.5)
		if g.objective >= 0 and g.mode == "attack":
			var c := map.world_to_screen(map.province_world_pos(g.objective))
			draw_arc(c, 16, 0, TAU, 24, g.color, 4.0)
			draw_line(c + Vector2(-22, 0), c + Vector2(22, 0), g.color, 2.0)
			draw_line(c + Vector2(0, -22), c + Vector2(0, 22), g.color, 2.0)

	_draw_navy_air(z, vp)

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
			var tpl_count := {}
			var min_supply := 1.0
			var grp := -1
			var str_sum := 0.0
			var org_sum := 0.0
			for d in g:
				str_sum += d.strength
				org_sum += d.org / maxf(1.0, d.max_org)
				tpl_count[d.tpl] = int(tpl_count.get(d.tpl, 0)) + 1
				min_supply = minf(min_supply, d.supply)
				if d.group >= 0 and grp < 0:
					grp = d.group
				if selected.has(d):
					any_sel = true
			var nat_col: Color = world.nations[owner].color
			var rect := Rect2(pos, counter)
			draw_rect(Rect2(pos + Vector2(2, 2), counter), Color(0, 0, 0, 0.35))
			draw_rect(rect, nat_col.darkened(0.15))
			var icon_rect := Rect2(pos + Vector2(2, 2), Vector2(counter.x * 0.42, counter.y - 4))
			draw_rect(icon_rect, nat_col.lightened(0.35))
			var main_tpl := 0
			var best := -1
			for t in tpl_count:
				if tpl_count[t] > best:
					best = tpl_count[t]
					main_tpl = t
			_draw_icon(icon_rect, main_tpl, Color(0.08, 0.08, 0.08))
			draw_rect(rect, Color.WHITE if any_sel else Color(0.08, 0.08, 0.08), false, 2.5 if any_sel else 1.5)
			draw_string(font, pos + Vector2(counter.x * 0.44, counter.y * 0.5 + font_size * 0.36), str(g.size()),
				HORIZONTAL_ALIGNMENT_CENTER, counter.x * 0.56, font_size, Color(0.05, 0.05, 0.05))
			if grp >= 0 and owner == player:
				draw_rect(Rect2(pos + Vector2(0, -4), Vector2(counter.x, 3)), world.groups[grp].color)
			if min_supply < 0.3:
				# нет снабжения: красный восклицательный знак
				var c2 := pos + Vector2(counter.x + 6, 4)
				draw_circle(c2, 7, Color(0.85, 0.15, 0.1))
				draw_string(font, c2 + Vector2(-3, 5), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
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
	if _labels_day < 0 or world.day - _labels_day >= 5 or world.day < _labels_day:
		_rebuild_labels()
	for l in _labels:
		var pos := map.world_to_screen(l[0])
		var size := int(clampf(l[2] * z, 12, 60))
		var w := font.get_string_size(l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var fit: float = l[3] * z * 0.95
		if w > fit and w > 0.0:
			size = int(size * fit / w)
			w = font.get_string_size(l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if size < 11:
			continue
		var alpha := clampf((1.6 - z) * 2.0, 0.0, 0.75)
		draw_string_outline(font, pos - Vector2(w * 0.5, 0), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(1, 1, 1, alpha * 0.4))
		draw_string(font, pos - Vector2(w * 0.5, 0), l[1], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.08, 0.07, 0.06, alpha))


func _rebuild_labels() -> void:
	# Подпись — по самому большому связному куску территории страны
	# (иначе «Франция» уезжает в Алжир, а «Великобритания» — в Средиземное море).
	_labels_day = world.day
	_labels.clear()
	var comp := PackedInt32Array()
	comp.resize(world.prov_count)
	comp.fill(-1)
	var best := {}   # нация -> [пиксели, сумма центров, мин, макс]
	for p in world.prov_count:
		var c := world.p_controller[p]
		if c < 0 or world.p_land[p] == 0 or comp[p] >= 0:
			continue
		comp[p] = p
		var stack := [p]
		var px := 0
		var sum := Vector2.ZERO
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		while not stack.is_empty():
			var q: int = stack.pop_back()
			px += world.p_pixels[q]
			sum += world.p_center[q] * world.p_pixels[q]
			lo = lo.min(world.p_center[q])
			hi = hi.max(world.p_center[q])
			for r in world.p_adj[q]:
				if comp[r] < 0 and world.p_land[r] == 1 and world.p_controller[r] == c:
					comp[r] = p
					stack.append(r)
		if not best.has(c) or best[c][0] < px:
			best[c] = [px, sum, lo, hi]
	for c in best:
		if not world.nations[c].alive:
			continue
		var b: Array = best[c]
		var center: Vector2 = b[1] / maxf(1.0, b[0])
		var span: Vector2 = (b[3] - b[2]) * MapView.SCALE
		_labels.append([center * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(float(b[0])) * 0.5, maxf(span.x, span.y * 0.8)])


## Условные знаки родов войск (в духе военных карт).
func _draw_icon(r: Rect2, tpl: int, col: Color) -> void:
	var a := r.position
	var b := r.position + r.size
	match tpl:
		Military.T_INF, Military.T_MNT, Military.T_ART:
			draw_line(a, b, col, 1.5)
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), col, 1.5)
			if tpl == Military.T_MNT:
				var c := Vector2(r.get_center().x, b.y)
				draw_colored_polygon(PackedVector2Array([c + Vector2(-4, 0), c + Vector2(4, 0), c + Vector2(0, -5)]), col)
			if tpl == Military.T_ART:
				draw_circle(r.get_center(), 2.5, col)
		Military.T_CAV:
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), col, 1.5)
		Military.T_MOT:
			draw_line(a, b, col, 1.5)
			draw_line(Vector2(a.x, b.y), Vector2(b.x, a.y), col, 1.5)
			draw_line(Vector2(r.get_center().x, a.y), Vector2(r.get_center().x, b.y), col, 1.5)
		Military.T_ARM:
			var c := r.get_center()
			var rx := r.size.x * 0.36
			var ry := r.size.y * 0.28
			var pts := PackedVector2Array()
			for i in 17:
				var t := TAU * i / 16.0
				pts.append(c + Vector2(cos(t) * rx, sin(t) * ry))
			draw_polyline(pts, col, 1.5)


func _draw_navy_air(z: float, vp: Vector2) -> void:
	var screen := Rect2(Vector2.ZERO, vp).grow(40)
	var game = get_tree().current_scene if get_tree() else null
	var sel_fleet: int = game.selected_fleet if game != null and "selected_fleet" in game else -1
	var sel_wing: int = game.selected_wing if game != null and "selected_wing" in game else -1
	# порты и военно-морские базы (свои и союзные) при приближении
	if z >= 0.9 and player >= 0 and world.p_naval_base.size() == world.prov_count:
		for p in world.prov_count:
			if world.p_land[p] == 0 or world.p_coastal[p] == 0:
				continue
			var c := world.p_controller[p]
			if c < 0 or (c != player and world.ally[player * world.nation_count + c] == 0):
				continue
			var base := world.p_naval_base[p] == 1
			if not base and not Forces.is_port(world, p):
				continue
			var pos := map.world_to_screen(map.province_world_pos(p)) + Vector2(-26, 14)
			if not screen.has_point(pos):
				continue
			if base:
				_anchor_icon(pos)
			else:
				draw_circle(pos, 4.5, Color(0.05, 0.05, 0.05, 0.85))
				draw_circle(pos, 3.0, Color(0.55, 0.85, 1.0))
	# планы высадок и войска в море
	for plan in world.invasions:
		if plan.alive and plan.owner == player:
			var a := map.world_to_screen(map.province_world_pos(plan.port))
			var b := map.world_to_screen(map.province_world_pos(plan.target))
			draw_dashed_line(a, b, Color(0.4, 0.8, 1.0, 0.85), 2.5, 8.0)
			draw_string(font, b + Vector2(8, -6), "%d дн." % plan.days_left if plan.days_left > 0 else "готово",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.9, 1.0))
	for d in world.divisions:
		if d.alive and d.transit_days > 0 and (d.owner == player or z > 0.8):
			var a := map.world_to_screen(map.province_world_pos(d.transit_from))
			var b := map.world_to_screen(map.province_world_pos(d.transit_target))
			var t := 1.0 - float(d.transit_days) / maxf(1.0, d.transit_total)
			draw_line(a, b, Color(1, 1, 1, 0.4), 1.5)
			_ship_icon(a.lerp(b, t), world.nations[d.owner].color, 0.8)
	# флоты
	for f in world.fleets:
		if not f.alive or f.zone < 0:
			continue
		if f.owner != player and z < 0.6 and not world.is_at_war(player, f.owner):
			continue
		var c := map.world_to_screen(map.province_world_pos(f.zone))
		if f.mission == "raid":
			c += Vector2(0, 16)
		if not screen.has_point(c):
			continue
		if f.id == sel_fleet and not f.path.is_empty():
			var pts := PackedVector2Array([c])
			for q in f.path:
				pts.append(map.world_to_screen(map.province_world_pos(q)))
			draw_polyline(pts, Color(0.6, 0.9, 1.0), 2.5)
		_ship_icon(c, world.nations[f.owner].color, 1.0 if f.mission != "raid" else 0.8)
		if f.id == sel_fleet:
			draw_arc(c, 18, 0, TAU, 20, Color.WHITE, 2.0)
		draw_string(font, c + Vector2(13, 5), str(Forces.fleet_size(f)), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		if f.in_battle:
			draw_circle(c + Vector2(-14, -10), 5, Color(0.9, 0.2, 0.1))
	# авиация игрока (и вражеская при войне): один значок на район и тип
	var groups := {}
	for wg in world.wings:
		if not wg.alive or wg.region < 0:
			continue
		if wg.owner != player and not world.is_at_war(player, wg.owner):
			continue
		var key := "%d:%d:%d" % [wg.region, 0 if wg.owner == player else 1, wg.kind]
		if not groups.has(key):
			groups[key] = [wg.region, wg.owner, wg.kind, 0.0, false]
		groups[key][3] += wg.planes
		if wg.id == sel_wing:
			groups[key][4] = true
	for key in groups:
		var g: Array = groups[key]
		var anchor: int = world.region_anchor[g[0]]
		var mine: bool = g[1] == player
		var c := map.world_to_screen(map.province_world_pos(anchor)) + Vector2(-30 + (0 if mine else 56), -34 - g[2] * 18)
		if not screen.has_point(c):
			continue
		_plane_icon(c, world.nations[g[1]].color if mine else Color(0.9, 0.3, 0.25), g[2], g[4])
		draw_string_outline(font, c + Vector2(14, 5), str(int(g[3])), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
		draw_string(font, c + Vector2(14, 5), str(int(g[3])), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


func _anchor_icon(c: Vector2) -> void:
	var dark := Color(0.05, 0.05, 0.05, 0.9)
	var col := Color(0.7, 0.9, 1.0)
	for pass_i in 2:
		var w := 4.0 if pass_i == 0 else 2.0
		var cc := dark if pass_i == 0 else col
		draw_line(c + Vector2(0, -7), c + Vector2(0, 6), cc, w)
		draw_line(c + Vector2(-4, -4), c + Vector2(4, -4), cc, w)
		draw_arc(c + Vector2(0, 1), 6, 0.2, PI - 0.2, 10, cc, w)


func _ship_icon(c: Vector2, col: Color, s: float) -> void:
	var pts := PackedVector2Array([c + Vector2(-12, -2) * s, c + Vector2(12, -2) * s, c + Vector2(8, 5) * s, c + Vector2(-9, 5) * s])
	draw_colored_polygon(pts, col.darkened(0.2))
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(0, 0, 0, 0.8), 1.5)
	draw_rect(Rect2(c + Vector2(-3, -7) * s, Vector2(6, 5) * s), col.darkened(0.4))


func _plane_icon(c: Vector2, col: Color, kind: int, selected: bool) -> void:
	var wing := 9.0 if kind == 0 else 12.0
	var dark := Color(0.05, 0.05, 0.05, 0.9)
	draw_line(c + Vector2(0, -8), c + Vector2(0, 8), dark, 5.0)
	draw_line(c + Vector2(-wing - 1, -1), c + Vector2(wing + 1, -1), dark, 5.0)
	draw_line(c + Vector2(-5, 6), c + Vector2(5, 6), dark, 4.0)
	col = col.lightened(0.35)
	draw_line(c + Vector2(0, -7), c + Vector2(0, 7), col, 3.0)
	draw_line(c + Vector2(-wing, -1), c + Vector2(wing, -1), col, 3.0)
	draw_line(c + Vector2(-4, 6), c + Vector2(4, 6), col, 2.0)
	if selected:
		draw_arc(c, 14, 0, TAU, 20, Color.WHITE, 2.0)
