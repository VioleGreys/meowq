class_name UnitLayer
extends Node2D
## Фишки дивизий, стрелки приказов, бои, фронты, флоты, авиация и названия
## стран. Рисуется в экранных координатах (в своём CanvasLayer) — текст чёткий.
##
## Симуляция идёт в фоновом потоке, поэтому слой устроен в два шага:
##  * rebuild() — под блокировкой мира собирает «список отрисовки» из чистых
##    данных (мировые координаты, цвета, числа), без ссылок на объекты мира;
##  * _draw() — каждый кадр рисует только из этого списка (мир не трогает),
##    поэтому сдвиг и масштаб карты плавные, даже пока считается игровой день.

enum { ARROW, FRONT, OBJECTIVE, BATTLE, COUNTER, LABEL, PORT, PLAN, TRANSIT, FLEET, PLANES }

var map: MapView
var world: World
var selected: Array = []        # выбранные дивизии (объекты; читаются только в rebuild)
var player := -1
var font: Font
var label_font: Font   # подписи стран — Oswald с разрядкой
var items: Array = []           # список отрисовки: [тип, данные...]
var _labels: Array = []         # [мировая позиция, имя, размер, ширина]
var _labels_day := -1


func _ready() -> void:
	font = UiStyle.text_font()
	label_font = UiStyle.title_font(500, 3)


func _process(_dt: float) -> void:
	queue_redraw()


func _wp(p: int) -> Vector2:
	return world.p_center[p] * MapView.SCALE


## Собрать список отрисовки. Вызывать ТОЛЬКО под блокировкой мира.
func rebuild(sel_fleet: int = -1, sel_wing: int = -1) -> void:
	var out: Array = []
	if world == null:
		items = out
		return
	if _labels_day < 0 or world.day - _labels_day >= 5 or world.day < _labels_day:
		_rebuild_labels()
	for l in _labels:
		out.append([LABEL, l[0], l[1], l[2], l[3]])
	var sel := {}
	for d in selected:
		sel[d] = true
	# стрелки движения
	for d in world.divisions:
		if not d.alive or d.path.is_empty() or d.transit_days > 0:
			continue
		var is_sel: bool = sel.has(d)
		var pts := PackedVector2Array([_wp(d.prov)])
		var limit: int = d.path.size() if is_sel else 1
		for i in limit:
			pts.append(_wp(d.path[i]))
		var col := Color(1, 1, 1, 0.85) if is_sel else Color(world.nations[d.owner].color.darkened(0.5), 0.7)
		out.append([ARROW, pts, col, is_sel, clampf(d.progress, 0.0, 1.0), d.owner == player])
	# фронты и цели армий игрока
	for g in world.groups:
		if not g.alive or g.owner != player:
			continue
		var fp: PackedInt32Array = g.front_pairs
		for i in range(0, fp.size(), 2):
			out.append([FRONT, _wp(fp[i]), _wp(fp[i + 1]), g.color])
		if g.objective >= 0 and g.mode == "attack":
			out.append([OBJECTIVE, _wp(g.objective), g.color])
	# бои
	var battle_provs := {}
	for d in world.divisions:
		if d.alive and d.in_battle and not d.path.is_empty() and d.transit_days <= 0:
			battle_provs[d.path[0]] = true
	for p in battle_provs:
		out.append([BATTLE, _wp(p)])
	# фишки: по одной на (провинция, страна)
	for p in world.prov_count:
		if world.pl_head[p] < 0:
			continue
		var list: Array = world.divs_in(p)
		var groups := {}
		var order: Array = []
		for d in list:
			if d.alive:
				if not groups.has(d.owner):
					groups[d.owner] = []
					order.append(d.owner)
				groups[d.owner].append(d)
		var k := 0
		for owner in order:
			var g: Array = groups[owner]
			var any_sel := false
			var tpl_count := {}
			var min_supply := 1.0
			var grp_color := Color(0, 0, 0, 0)
			var str_sum := 0.0
			var org_sum := 0.0
			for d in g:
				str_sum += d.strength
				org_sum += d.org / maxf(1.0, d.max_org)
				tpl_count[d.tpl] = int(tpl_count.get(d.tpl, 0)) + 1
				min_supply = minf(min_supply, d.supply)
				if d.group >= 0 and grp_color.a == 0.0 and owner == player:
					grp_color = world.groups[d.group].color
				if sel.has(d):
					any_sel = true
			var main_tpl := 0
			var best := -1
			for t in tpl_count:
				if tpl_count[t] > best:
					best = tpl_count[t]
					main_tpl = t
			out.append([COUNTER, _wp(p), k, world.nations[owner].color, g.size(), main_tpl,
				str_sum / (100.0 * g.size()), org_sum / g.size(), any_sel, grp_color, min_supply < 0.3, owner == player])
			k += 1
	_rebuild_navy_air(out, sel_fleet, sel_wing)
	items = out


func _rebuild_navy_air(out: Array, sel_fleet: int, sel_wing: int) -> void:
	# порты и военно-морские базы (свои и союзные)
	if player >= 0 and world.p_naval_base.size() == world.prov_count:
		for p in world.prov_count:
			if world.p_land[p] == 0 or world.p_coastal[p] == 0:
				continue
			var c := world.p_controller[p]
			if c < 0 or (c != player and world.ally[player * world.nation_count + c] == 0):
				continue
			var base := world.p_naval_base[p] == 1
			if base or Forces.is_port(world, p):
				out.append([PORT, _wp(p), base])
	# планы высадок и войска в море
	for plan in world.invasions:
		if plan.alive and plan.owner == player:
			out.append([PLAN, _wp(plan.port), _wp(plan.target), plan.days_left])
	for d in world.divisions:
		if d.alive and d.transit_days > 0:
			var t := 1.0 - float(d.transit_days) / maxf(1.0, d.transit_total)
			out.append([TRANSIT, _wp(d.transit_from), _wp(d.transit_target), t, world.nations[d.owner].color, d.owner == player])
	# флоты
	for f in world.fleets:
		if not f.alive or f.zone < 0:
			continue
		var pts := PackedVector2Array()
		if f.id == sel_fleet:
			for q in f.path:
				pts.append(_wp(q))
		var relevant: bool = f.owner == player or world.is_at_war(player, f.owner)
		out.append([FLEET, _wp(f.zone), world.nations[f.owner].color, f.mission == "raid", Forces.fleet_size(f),
			f.id == sel_fleet, f.in_battle, pts, relevant])
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
		var mine: bool = g[1] == player
		out.append([PLANES, _wp(world.region_anchor[g[0]]), world.nations[g[1]].color if mine else Color(0.9, 0.3, 0.25),
			g[2], g[4], int(g[3]), mine])


func _draw() -> void:
	if map == null:
		return
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	var screen := Rect2(Vector2.ZERO, vp).grow(40)
	var counter := Vector2(34, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
	var font_size := int(clampf(12 + z * 2, 12, 20))
	for it in items:
		match it[0]:
			LABEL:
				_draw_label(it, z)
			ARROW:
				if not it[5] and z < 1.4:
					continue
				var wpts: PackedVector2Array = it[1]
				var pts := PackedVector2Array()
				for wpt in wpts:
					pts.append(map.world_to_screen(wpt))
				var col: Color = it[2]
				draw_polyline(pts, col, 3.0 if it[3] else 2.0, true)
				var tip := pts[pts.size() - 1]
				var dir := (tip - pts[pts.size() - 2]).normalized()
				var side := Vector2(-dir.y, dir.x)
				draw_colored_polygon(PackedVector2Array([tip, tip - dir * 11 + side * 6, tip - dir * 11 - side * 6]), col)
				draw_circle(pts[0].lerp(pts[1], it[4]), 3.0, col)
			FRONT:
				var a := map.world_to_screen(it[1])
				var b := map.world_to_screen(it[2])
				var m := (a + b) * 0.5
				if not screen.has_point(m):
					continue
				var dir := b - a
				var side := Vector2(-dir.y, dir.x).normalized() * minf(dir.length() * 0.45, 40.0)
				draw_line(m - side, m + side, Color(it[3], 0.9), 5.0)
				draw_line(m - side, m + side, Color(0, 0, 0, 0.35), 1.5)
			OBJECTIVE:
				var c := map.world_to_screen(it[1])
				var col: Color = it[2]
				draw_arc(c, 16, 0, TAU, 24, col, 4.0)
				draw_line(c + Vector2(-22, 0), c + Vector2(22, 0), col, 2.0)
				draw_line(c + Vector2(0, -22), c + Vector2(0, 22), col, 2.0)
			BATTLE:
				var c := map.world_to_screen(it[1]) + Vector2(0, -counter.y)
				if not screen.has_point(c):
					continue
				var r := 10.0 + sin(Time.get_ticks_msec() * 0.008) * 1.5
				draw_circle(c, r + 2, Color(0.1, 0.05, 0.05, 0.8))
				draw_circle(c, r, Color(0.78, 0.16, 0.12))
				var btex := UiStyle.icon("battle", 64)
				if btex != null:
					draw_texture_rect(btex, Rect2(c - Vector2(7, 7), Vector2(14, 14)), false, Color(1, 0.95, 0.85))
				else:
					draw_line(c + Vector2(-5, -5), c + Vector2(5, 5), Color.WHITE, 2.0)
					draw_line(c + Vector2(5, -5), c + Vector2(-5, 5), Color.WHITE, 2.0)
			COUNTER:
				_draw_counter(it, z, counter, font_size, screen)
			PORT:
				if z < 0.9:
					continue
				var pos := map.world_to_screen(it[1]) + Vector2(-26, 14)
				if not screen.has_point(pos):
					continue
				if it[2]:
					_anchor_icon(pos)
				else:
					draw_circle(pos, 4.5, Color(0.05, 0.05, 0.05, 0.85))
					draw_circle(pos, 3.0, Color(0.55, 0.85, 1.0))
			PLAN:
				var a := map.world_to_screen(it[1])
				var b := map.world_to_screen(it[2])
				draw_dashed_line(a, b, Color(0.4, 0.8, 1.0, 0.85), 2.5, 8.0)
				draw_string(font, b + Vector2(8, -6), "%d дн." % it[3] if it[3] > 0 else "готово",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.6, 0.9, 1.0))
			TRANSIT:
				if not it[5] and z <= 0.8:
					continue
				var a := map.world_to_screen(it[1])
				var b := map.world_to_screen(it[2])
				draw_line(a, b, Color(1, 1, 1, 0.4), 1.5)
				_ship_icon(a.lerp(b, it[3]), it[4], 0.8)
			FLEET:
				if not it[8] and z < 0.6:
					continue
				var c := map.world_to_screen(it[1])
				if it[3]:
					c += Vector2(0, 16)
				if not screen.has_point(c):
					continue
				var wpts: PackedVector2Array = it[7]
				if not wpts.is_empty():
					var pts := PackedVector2Array([c])
					for wpt in wpts:
						pts.append(map.world_to_screen(wpt))
					draw_polyline(pts, Color(0.6, 0.9, 1.0), 2.5)
				_ship_icon(c, it[2], 0.8 if it[3] else 1.0, it[3])
				if it[5]:
					draw_arc(c, 18, 0, TAU, 20, Color.WHITE, 2.0)
				draw_string(font, c + Vector2(13, 5), str(it[4]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
				if it[6]:
					draw_circle(c + Vector2(-14, -10), 5, Color(0.9, 0.2, 0.1))
			PLANES:
				var c := map.world_to_screen(it[1]) + Vector2(-30 + (0 if it[6] else 56), -34 - it[3] * 18)
				if not screen.has_point(c):
					continue
				_plane_icon(c, it[2], it[3], it[4])
				draw_string_outline(font, c + Vector2(14, 5), str(it[5]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
				draw_string(font, c + Vector2(14, 5), str(it[5]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


func _draw_counter(it: Array, z: float, counter: Vector2, font_size: int, screen: Rect2) -> void:
	var base := map.world_to_screen(it[1])
	if not screen.has_point(base):
		return
	var nat_col: Color = it[3]
	if z < 0.55 and not it[11]:
		if z >= 0.25:   # на масштабе всего мира стопки не рисуем — как в жанре
			draw_rect(Rect2(base - Vector2(4, 4), Vector2(8, 8)), nat_col.darkened(0.35))
		return
	var pos: Vector2 = base + Vector2(it[2] * (counter.x + 4), 0) - counter * 0.5
	var any_sel: bool = it[8]
	var rect := Rect2(pos, counter)
	draw_rect(Rect2(pos + Vector2(2, 2), counter), Color(0, 0, 0, 0.35))
	draw_rect(rect, nat_col.darkened(0.15))
	var icon_rect := Rect2(pos + Vector2(2, 2), Vector2(counter.x * 0.42, counter.y - 4))
	draw_rect(icon_rect, nat_col.lightened(0.35))
	_draw_icon(icon_rect, it[5], Color(0.08, 0.08, 0.08))
	draw_rect(rect, Color.WHITE if any_sel else Color(0.08, 0.08, 0.08), false, 2.5 if any_sel else 1.5)
	draw_string(font, pos + Vector2(counter.x * 0.44, counter.y * 0.5 + font_size * 0.36), str(it[4]),
		HORIZONTAL_ALIGNMENT_CENTER, counter.x * 0.56, font_size, Color(0.05, 0.05, 0.05))
	var grp: Color = it[9]
	if grp.a > 0.0:
		draw_rect(Rect2(pos + Vector2(0, -4), Vector2(counter.x, 3)), grp)
	if it[10]:
		# нет снабжения: красный восклицательный знак
		var c2 := pos + Vector2(counter.x + 6, 4)
		draw_circle(c2, 7, Color(0.85, 0.15, 0.1))
		draw_string(font, c2 + Vector2(-3, 5), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	# полоски: зелёная — сила, жёлтая — организация
	var bw := counter.x
	draw_rect(Rect2(pos + Vector2(0, counter.y + 1), Vector2(bw, 3)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(pos + Vector2(0, counter.y + 1), Vector2(bw * it[6], 3)), Color(0.35, 0.85, 0.35))
	draw_rect(Rect2(pos + Vector2(0, counter.y + 4), Vector2(bw, 3)), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(pos + Vector2(0, counter.y + 4), Vector2(bw * it[7], 3)), Color(0.95, 0.8, 0.25))


func _draw_label(l: Array, z: float) -> void:
	if z > 1.6:
		return
	var pos := map.world_to_screen(l[1])
	var size := int(clampf(l[3] * z, 12, 60))
	var w := label_font.get_string_size(l[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var fit: float = l[4] * z * 0.95
	if w > fit and w > 0.0:
		size = int(size * fit / w)
		if size < 11:
			return
		w = label_font.get_string_size(l[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if size < 11:
		return
	var alpha := clampf((1.6 - z) * 2.0, 0.0, 0.75)
	draw_string_outline(label_font, pos - Vector2(w * 0.5, 0), l[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color(0.95, 0.92, 0.84, alpha * 0.45))
	draw_string(label_font, pos - Vector2(w * 0.5, 0), l[2], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.10, 0.08, 0.06, alpha))


func _rebuild_labels() -> void:
	# Подпись — по связному куску территории со столицей (иначе «Великобритания»
	# уезжает в Африку, «Дания» — в Гренландию), без столицы — по самому большому.
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
		var has_cap := false
		while not stack.is_empty():
			var q: int = stack.pop_back()
			if q == world.nations[c].capital:
				has_cap = true
			px += world.p_pixels[q]
			sum += world.p_center[q] * world.p_pixels[q]
			lo = lo.min(world.p_center[q])
			hi = hi.max(world.p_center[q])
			for r in world.p_adj[q]:
				if comp[r] < 0 and world.p_land[r] == 1 and world.p_controller[r] == c:
					comp[r] = p
					stack.append(r)
		var score := px + (1 << 30 if has_cap else 0)
		if not best.has(c) or best[c][4] < score:
			best[c] = [px, sum, lo, hi, score]
	for c in best:
		if not world.nations[c].alive:
			continue
		var b: Array = best[c]
		var center: Vector2 = b[1] / maxf(1.0, b[0])
		var span: Vector2 = (b[3] - b[2]) * MapView.SCALE
		_labels.append([center * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(float(b[0])) * 0.5, maxf(span.x, span.y * 0.8)])


## Условные знаки родов войск (в духе военных карт).
const TPL_ICONS := ["inf", "mnt", "cav", "art", "mot", "arm"]


func _draw_icon(r: Rect2, tpl: int, col: Color) -> void:
	# иконка рода войск (game-icons.net); нет файла — условный знак кодом
	var tex := UiStyle.icon(TPL_ICONS[clampi(tpl, 0, TPL_ICONS.size() - 1)], 64)
	if tex != null:
		var s := minf(r.size.x, r.size.y) * 0.95
		draw_texture_rect(tex, Rect2(r.get_center() - Vector2(s, s) * 0.5, Vector2(s, s)), false, col)
		return
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


func _anchor_icon(c: Vector2) -> void:
	var tex := UiStyle.icon("anchor", 64)
	if tex != null:
		_icon_outlined(tex, c, 18.0, Color(0.7, 0.9, 1.0))
		return
	var dark := Color(0.05, 0.05, 0.05, 0.9)
	var col := Color(0.7, 0.9, 1.0)
	for pass_i in 2:
		var w := 4.0 if pass_i == 0 else 2.0
		var cc := dark if pass_i == 0 else col
		draw_line(c + Vector2(0, -7), c + Vector2(0, 6), cc, w)
		draw_line(c + Vector2(-4, -4), c + Vector2(4, -4), cc, w)
		draw_arc(c + Vector2(0, 1), 6, 0.2, PI - 0.2, 10, cc, w)


## Иконка с тёмной обводкой (тень в 4 стороны) — читается на любой подложке.
func _icon_outlined(tex: Texture2D, c: Vector2, size: float, col: Color) -> void:
	var r := Rect2(c - Vector2(size, size) * 0.5, Vector2(size, size))
	var dark := Color(0.04, 0.04, 0.04, 0.85)
	for o in [Vector2(-1.5, 0), Vector2(1.5, 0), Vector2(0, -1.5), Vector2(0, 1.5)]:
		draw_texture_rect(tex, Rect2(r.position + o, r.size), false, dark)
	draw_texture_rect(tex, r, false, col)


func _ship_icon(c: Vector2, col: Color, s: float, sub := false) -> void:
	var tex := UiStyle.icon("sub" if sub else "fleet", 64)
	if tex != null:
		_icon_outlined(tex, c, 26.0 * s, col.lightened(0.25))
		return
	var pts := PackedVector2Array([c + Vector2(-12, -2) * s, c + Vector2(12, -2) * s, c + Vector2(8, 5) * s, c + Vector2(-9, 5) * s])
	draw_colored_polygon(pts, col.darkened(0.2))
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), Color(0, 0, 0, 0.8), 1.5)
	draw_rect(Rect2(c + Vector2(-3, -7) * s, Vector2(6, 5) * s), col.darkened(0.4))


func _plane_icon(c: Vector2, col: Color, kind: int, selected_icon: bool) -> void:
	var tex := UiStyle.icon("fighter" if kind == 0 else "bomber", 64)
	if tex != null:
		_icon_outlined(tex, c, 22.0 if kind == 0 else 26.0, col.lightened(0.35))
		if selected_icon:
			draw_arc(c, 15, 0, TAU, 20, Color.WHITE, 2.0)
		return
	var wing := 9.0 if kind == 0 else 12.0
	var dark := Color(0.05, 0.05, 0.05, 0.9)
	draw_line(c + Vector2(0, -8), c + Vector2(0, 8), dark, 5.0)
	draw_line(c + Vector2(-wing - 1, -1), c + Vector2(wing + 1, -1), dark, 5.0)
	draw_line(c + Vector2(-5, 6), c + Vector2(5, 6), dark, 4.0)
	col = col.lightened(0.35)
	draw_line(c + Vector2(0, -7), c + Vector2(0, 7), col, 3.0)
	draw_line(c + Vector2(-wing, -1), c + Vector2(wing, -1), col, 3.0)
	draw_line(c + Vector2(-4, 6), c + Vector2(4, 6), col, 2.0)
	if selected_icon:
		draw_arc(c, 14, 0, TAU, 20, Color.WHITE, 2.0)
