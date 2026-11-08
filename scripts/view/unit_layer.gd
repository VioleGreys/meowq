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
var bold: Font
var label_font: Font   # подписи стран — Oswald с разрядкой
var items: Array = []           # список отрисовки: [тип, данные...]
var _labels: Array = []         # [мировая позиция, имя, размер, ширина]
var _labels_day := -1
var _labels_pv := -1



# Готовые текстуры фишки (рисуются один раз при запуске, в 3× размере):
# плашка — белая заливка с тёмной каймой (окрашивается цветом страны), обводка
# выделения, тень, круглый знак. Одна текстура вместо 6–8 сглаженных фигур.
const TEX_K := 3
var _t_plate: Texture2D
var _t_sel: Texture2D
var _t_shadow: Texture2D
var _t_badge: Texture2D
var _t_bars: Texture2D


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	font = UiStyle.text_font()
	bold = UiStyle.bold_font()
	label_font = UiStyle.title_font(500, 3)
	var cw := 40 * TEX_K
	var ch := 22 * TEX_K
	var r := ch * 0.5
	_t_plate = _rr_tex(cw, ch, r, TEX_K * 1.0, Color(1, 1, 1), Color(0.06, 0.06, 0.06, 0.9), 0.0)
	_t_sel = _rr_tex(cw, ch, r, TEX_K * 2.0, Color(1, 1, 1, 0), Color(1, 1, 1), 0.0)
	_t_shadow = _rr_tex(cw, ch, r, 0.0, Color(0, 0, 0, 0.35), Color(0, 0, 0, 0.35), TEX_K * 1.5)
	_t_badge = _rr_tex(ch, ch, r, TEX_K * 1.0, Color(1, 1, 1), Color(0.06, 0.06, 0.06, 0.6), 0.0)
	_t_bars = _rr_tex(cw, 7 * TEX_K, 2.0 * TEX_K, 0.0, Color(0, 0, 0, 0.55), Color(0, 0, 0, 0.55), 0.0)


## Скруглённый прямоугольник в текстуру: заливка, кайма шириной bw, мягкость
## края soft (для тени). Сглаживание — по расстоянию до края.
static func _rr_tex(w: int, h: int, rad: float, bw: float, fill: Color, border: Color, soft: float) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var half := Vector2(w, h) * 0.5
	var inner := half - Vector2(rad, rad)
	for y in h:
		for x in w:
			var q := (Vector2(x + 0.5, y + 0.5) - half).abs() - inner
			var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - rad
			var a := clampf(0.5 - d / maxf(1.0, soft), 0.0, 1.0) if soft > 0.0 else clampf(0.5 - d, 0.0, 1.0)
			var c := fill
			if bw > 0.0:
				c = fill.lerp(border, clampf(d + bw + 0.5, 0.0, 1.0))
			img.set_pixel(x, y, Color(c.r, c.g, c.b, c.a * a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# Слой перерисовывается только при изменениях: сдвиг/масштаб карты, новый
# список отрисовки; бои пульсируют — тогда не чаще 12 раз в секунду.
var _dirty := true
var _last_xf := Transform2D()
var _has_battles := false
var _anim_msec := 0


func _process(_dt: float) -> void:
	var xf := get_viewport().get_canvas_transform()
	if map != null and map.camera != null:
		xf = map.get_viewport().get_canvas_transform()
	var now := Time.get_ticks_msec()
	if xf != _last_xf:
		_last_xf = xf
		_dirty = true
	elif _has_battles and now - _anim_msec >= 80:
		_dirty = true
	if _dirty:
		_dirty = false
		_anim_msec = now
		queue_redraw()


func _wp(p: int) -> Vector2:
	return world.p_center[p] * MapView.SCALE


## Собрать список отрисовки. Вызывать ТОЛЬКО под блокировкой мира.
func rebuild(sel_fleet: int = -1, sel_wing: int = -1) -> void:
	var out: Array = []
	if world == null:
		items = out
		_dirty = true
		return
	# подписи стран пересчитываются (заливка по провинциям) только когда менялись
	# владельцы — не чаще раза в 5 дней
	var pv := map.palette_version if map != null else 0
	if _labels_day < 0 or world.day < _labels_day or (pv != _labels_pv and world.day - _labels_day >= 5):
		_labels_pv = pv
		_rebuild_labels()
	for l in _labels:
		out.append([LABEL, l[0], l[1], l[2], l[3]])
	# Читаем плоские массивы дивизий напрямую (свойства Division — обёртки с
	# вызовом на каждое чтение; список пересобирается каждый игровой день).
	var sel := {}
	for d in selected:
		if d.alive and d.slot >= 0:
			sel[d.slot] = d
	var divs: Array = world.divisions
	var n_div := divs.size()
	var a_alive := world.d_alive
	var a_owner := world.d_owner
	var a_prov := world.d_prov
	var a_next := world.d_next
	var a_transit := world.d_transit
	var a_prog := world.d_prog
	var a_battle := world.d_battle
	var a_str := world.d_str
	var a_org := world.d_org
	var a_morg := world.d_morg
	var a_sup := world.d_sup
	var a_tpl := world.d_tpl
	var centers := world.p_center
	var nat_cols: Array = []
	var arrow_cols: Array = []
	for nn in world.nations:
		nat_cols.append(nn.color)
		arrow_cols.append(Color(nn.color.darkened(0.5), 0.7))
	var sc := MapView.SCALE
	# стрелки движения и бои
	var battle_provs := {}
	for i in n_div:
		if a_alive[i] == 0 or a_next[i] < 0 or a_transit[i] > 0:
			continue
		var nx := a_next[i]
		if a_battle[i] != 0:
			battle_provs[nx] = true
		var pts := PackedVector2Array([centers[a_prov[i]] * sc])
		var col: Color
		var is_sel := sel.has(i)
		if is_sel:
			var path: PackedInt32Array = divs[i].path
			for q in path:
				pts.append(centers[q] * sc)
			col = Color(1, 1, 1, 0.85)
		else:
			pts.append(centers[nx] * sc)
			col = arrow_cols[a_owner[i]]
		out.append([ARROW, pts, col, is_sel, clampf(a_prog[i], 0.0, 1.0), a_owner[i] == player])
	# фронты и цели армий игрока
	for g in world.groups:
		if not g.alive or g.owner != player:
			continue
		var fp: PackedInt32Array = g.front_pairs
		for i in range(0, fp.size(), 2):
			out.append([FRONT, _wp(fp[i]), _wp(fp[i + 1]), g.color])
		if g.objective >= 0 and g.mode == "attack":
			out.append([OBJECTIVE, _wp(g.objective), g.color])
	for p in battle_provs:
		out.append([BATTLE, _wp(p)])
	_has_battles = not battle_provs.is_empty()
	# фишки: по одной на (провинция, страна); стопка — подряд идущие в списке
	# провинции дивизии одной страны собираются по владельцу
	var head := world.pl_head
	var nxt := world.d_nx
	var g_owner := PackedInt32Array()
	var g_n := PackedInt32Array()
	var g_str := PackedFloat64Array()
	var g_org := PackedFloat64Array()
	var g_sup := PackedFloat64Array()
	var g_sel := PackedByteArray()
	var g_tplc: Array = []
	var g_grp: Array = []
	for p in world.prov_count:
		var h := head[p]
		if h < 0:
			continue
		g_owner.clear()
		g_n.clear()
		g_str.clear()
		g_org.clear()
		g_sup.clear()
		g_sel.clear()
		g_tplc.clear()
		g_grp.clear()
		while h >= 0:
			if a_alive[h] != 0:
				var o := a_owner[h]
				var k := g_owner.find(o)
				if k < 0:
					k = g_owner.size()
					g_owner.append(o)
					g_n.append(0)
					g_str.append(0.0)
					g_org.append(0.0)
					g_sup.append(1.0)
					g_sel.append(0)
					g_tplc.append(PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0]))
					g_grp.append(Color(0, 0, 0, 0))
				g_n[k] += 1
				g_str[k] += a_str[h]
				g_org[k] += a_org[h] / maxf(1.0, a_morg[h])
				g_sup[k] = minf(g_sup[k], a_sup[h])
				var tc: PackedInt32Array = g_tplc[k]
				tc[clampi(a_tpl[h], 0, 7)] += 1
				g_tplc[k] = tc
				if o == player:
					var gc: Color = g_grp[k]
					if gc.a == 0.0:
						var grp: int = divs[h].group
						if grp >= 0:
							g_grp[k] = world.groups[grp].color
				if sel.has(h):
					g_sel[k] = 1
			h = nxt[h]
		for k in g_owner.size():
			var tc: PackedInt32Array = g_tplc[k]
			var main_tpl := 0
			for t in 8:
				if tc[t] > tc[main_tpl]:
					main_tpl = t
			var n := g_n[k]
			out.append([COUNTER, centers[p] * sc, k, nat_cols[g_owner[k]], n, main_tpl,
				g_str[k] / (100.0 * n), g_org[k] / n, g_sel[k] == 1, g_grp[k], g_sup[k] < 0.3, g_owner[k] == player])
	_rebuild_navy_air(out, sel_fleet, sel_wing)
	items = out
	_dirty = true


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
	var a_alive := world.d_alive
	var a_transit := world.d_transit
	var a_owner := world.d_owner
	var divs: Array = world.divisions
	for i in divs.size():
		if a_alive[i] != 0 and a_transit[i] > 0:
			var d: World.Division = divs[i]
			var t := 1.0 - float(a_transit[i]) / maxf(1.0, d.transit_total)
			out.append([TRANSIT, _wp(d.transit_from), _wp(d.transit_target), t, world.nations[a_owner[i]].color, a_owner[i] == player])
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


var draw_usec := 0   # время последней отрисовки слоя (для нижней строки)


func _draw() -> void:
	if map == null:
		return
	var t0 := Time.get_ticks_usec()
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	var screen := Rect2(Vector2.ZERO, vp).grow(40)
	var counter := Vector2(40, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
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
	draw_usec = Time.get_ticks_usec() - t0


func _draw_counter(it: Array, z: float, counter: Vector2, font_size: int, screen: Rect2) -> void:
	var base := map.world_to_screen(it[1])
	if not screen.has_point(base):
		return
	var nat_col: Color = it[3]
	if z < 0.55 and not it[11]:
		if z >= 0.25:   # на масштабе всего мира стопки не рисуем — как в жанре
			draw_circle(base, 4.5, Color(0.05, 0.05, 0.05, 0.7), true, -1.0, true)
			draw_circle(base, 3.5, nat_col.lightened(0.15), true, -1.0, true)
		return
	var pos: Vector2 = base + Vector2(it[2] * (counter.x + 5), 0) - counter * 0.5
	var any_sel: bool = it[8]
	var rect := Rect2(pos, counter)
	var rad := int(counter.y * 0.5)
	# тень, плашка цвета страны с тёмной каймой, обводка выделения, круглый знак
	draw_texture_rect(_t_shadow, Rect2(pos + Vector2(1.5, 2.5), counter), false)
	draw_texture_rect(_t_plate, rect, false, nat_col.darkened(0.12))
	if any_sel:
		draw_texture_rect(_t_sel, rect, false)
	var badge_r := counter.y * 0.5 - 1.5
	var bc := pos + Vector2(badge_r + 1.5, counter.y * 0.5)
	draw_texture_rect(_t_badge, Rect2(bc - Vector2(badge_r, badge_r), Vector2(badge_r, badge_r) * 2.0), false, nat_col.lightened(0.45))
	_draw_icon(Rect2(bc - Vector2(badge_r, badge_r) * 0.82, Vector2(badge_r, badge_r) * 1.64), it[5], Color(0.1, 0.09, 0.08))
	var tx := bc.x + badge_r + 1.0
	draw_string(bold, Vector2(tx, pos.y + counter.y * 0.5 + font_size * 0.36), str(it[4]),
		HORIZONTAL_ALIGNMENT_CENTER, pos.x + counter.x - tx - 2.0, font_size, Color(0.97, 0.95, 0.9))
	var grp: Color = it[9]
	if grp.a > 0.0:
		draw_rect(Rect2(pos + Vector2(rad * 0.6, -4), Vector2(counter.x - rad * 1.2, 3)), grp)
	if it[10]:
		# нет снабжения: красный восклицательный знак
		var c2 := pos + Vector2(counter.x + 5, 3)
		draw_circle(c2, 6.5, Color(0.85, 0.15, 0.1), true, -1.0, true)
		draw_string(font, c2 + Vector2(-2.5, 5), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	# полоски под плашкой: зелёная — сила, жёлтая — организация (со скруглёнными краями)
	var bx := pos.x + rad * 0.5
	var bw := counter.x - rad
	draw_texture_rect(_t_bars, Rect2(bx - 1, pos.y + counter.y + 1, bw + 2, 7), false)
	if it[6] > 0.02:
		draw_rect(Rect2(bx, pos.y + counter.y + 2, bw * it[6], 2.5), Color(0.40, 0.85, 0.38))
	if it[7] > 0.02:
		draw_rect(Rect2(bx, pos.y + counter.y + 5, bw * it[7], 2.5), Color(0.96, 0.80, 0.30))


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
	var pc := world.p_controller
	var land := world.p_land
	var pix := world.p_pixels
	var cen := world.p_center
	var a_s := world.adj_start
	var a_l := world.adj_list
	var caps := PackedInt32Array()
	for nn in world.nations:
		caps.append(nn.capital)
	var stack := PackedInt32Array()
	var best := {}   # нация -> [пиксели, сумма центров, мин, макс, счёт]
	for p in world.prov_count:
		var c := pc[p]
		if c < 0 or land[p] == 0 or comp[p] >= 0:
			continue
		comp[p] = p
		stack.clear()
		stack.append(p)
		var px := 0
		var sum := Vector2.ZERO
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var has_cap := false
		var cap := caps[c]
		while not stack.is_empty():
			var q := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			if q == cap:
				has_cap = true
			var w := pix[q]
			var cq := cen[q]
			px += w
			sum += cq * w
			lo = lo.min(cq)
			hi = hi.max(cq)
			for k in range(a_s[q], a_s[q + 1]):
				var r := a_l[k]
				if comp[r] < 0 and land[r] == 1 and pc[r] == c:
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
