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
var _ports: Array = []          # отметки портов (кэш, см. _rebuild_navy_air)
var _ports_key := ""



# Готовые текстуры фишки (рисуются один раз при запуске, в 3× размере):
# плашка — белая заливка с тёмной каймой (окрашивается цветом страны), обводка
# выделения, тень, круглый знак. Одна текстура вместо 6–8 сглаженных фигур.
const TEX_K := 3
# Все части фишки и знаки родов войск — в одном атласе: рисовка идёт пачкой
# без смены текстуры; числа рисуются отдельным проходом после всех плашек.
var _atlas: Texture2D
var _r_plate: Rect2
var _r_sel: Rect2
var _r_shadow: Rect2
var _r_badge: Rect2
var _r_bars: Rect2
var _r_white: Rect2
var _r_icons: Array = []        # Rect2 по шаблону дивизии (пустой — нет иконки)
var _texts: Array = []          # отложенные числа фишек: [позиция, текст, ширина, размер]
var draw_count := 0             # для замеров: сколько раз рисовался слой
var draw_total_usec := 0


## Отметки боёв — отдельный узел поверх фишек: их пульс не перерисовывает
## весь слой со стрелками и подписями.
class BattleMarks:
	extends Node2D
	var layer: UnitLayer

	func _draw() -> void:
		layer._draw_battles(self)


var _battles: BattleMarks


func _ready() -> void:
	_battles = BattleMarks.new()
	_battles.layer = self
	add_child(_battles)
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	font = UiStyle.text_font()
	bold = UiStyle.bold_font()
	label_font = UiStyle.title_font(500, 3)
	_build_atlas()


func _build_atlas() -> void:
	var cw := 40 * TEX_K
	var ch := 22 * TEX_K
	var r := ch * 0.5
	var parts := [
		_rr_img(cw, ch, r, TEX_K * 1.0, Color(1, 1, 1), Color(0.06, 0.06, 0.06, 0.9), 0.0),
		_rr_img(cw, ch, r, TEX_K * 2.0, Color(1, 1, 1, 0), Color(1, 1, 1), 0.0),
		_rr_img(cw, ch, r, 0.0, Color(0, 0, 0, 0.35), Color(0, 0, 0, 0.35), TEX_K * 1.5),
		_rr_img(ch, ch, r, TEX_K * 1.0, Color(1, 1, 1), Color(0.06, 0.06, 0.06, 0.6), 0.0),
		_rr_img(cw, 7 * TEX_K, 2.0 * TEX_K, 0.0, Color(0, 0, 0, 0.55), Color(0, 0, 0, 0.55), 0.0),
	]
	var white := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	parts.append(white)
	for name in TPL_ICONS:
		var ic := UiStyle.icon_image(name, 64)
		parts.append(ic if ic != null else Image.create(1, 1, false, Image.FORMAT_RGBA8))
	# раскладка по строкам с полями 4 пикс. (чтобы мипмапы не смешивали соседей)
	var pad := 4
	var w := 512
	var x := pad
	var y := pad
	var row_h := 0
	var rects: Array = []
	for im: Image in parts:
		if x + im.get_width() + pad > w:
			x = pad
			y += row_h + pad
			row_h = 0
		rects.append(Rect2(x, y, im.get_width(), im.get_height()))
		x += im.get_width() + pad
		row_h = maxi(row_h, im.get_height())
	var atlas := Image.create(w, y + row_h + pad, false, Image.FORMAT_RGBA8)
	for i in parts.size():
		var im: Image = parts[i]
		atlas.blit_rect(im, Rect2i(0, 0, im.get_width(), im.get_height()), Vector2i(rects[i].position))
	atlas.generate_mipmaps()
	_atlas = ImageTexture.create_from_image(atlas)
	_r_plate = rects[0]
	_r_sel = rects[1]
	_r_shadow = rects[2]
	_r_badge = rects[3]
	_r_bars = rects[4]
	_r_white = Rect2(rects[5].position + Vector2(2, 2), Vector2(4, 4))
	_r_icons.clear()
	for i in TPL_ICONS.size():
		var rr: Rect2 = rects[6 + i]
		_r_icons.append(rr if rr.size.x > 1 else Rect2())


## Скруглённый прямоугольник в текстуру: заливка, кайма шириной bw, мягкость
## края soft (для тени). Сглаживание — по расстоянию до края.
static func _rr_img(w: int, h: int, rad: float, bw: float, fill: Color, border: Color, soft: float) -> Image:
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
	return img


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
	if _dirty:
		_dirty = false
		queue_redraw()
		_battles.queue_redraw()
		_anim_msec = now
	elif _has_battles and now - _anim_msec >= 80:
		# пульс боёв — только маленький слой отметок, не весь слой фишек
		_anim_msec = now
		_battles.queue_redraw()


func _wp(p: int) -> Vector2:
	return world.p_center[p] * MapView.SCALE


## Собрать список отрисовки. Вызывать ТОЛЬКО под блокировкой мира.
func rebuild(sel_fleet: int = -1, sel_wing: int = -1) -> void:
	var r := build(sel_fleet, sel_wing)
	items = r[0]
	_has_battles = r[1]
	_dirty = true


## Принять список, собранный потоком симуляции (конвейер экрана, main._publish).
func take(list: Array, battles: bool) -> void:
	items = list
	_has_battles = battles
	_dirty = true


## Собрать список отрисовки по миру → [список, есть ли бои]. Только чтение мира
## и своих кэшей подписей и портов: вызывается под замком мира — из главного
## потока (выделение) или из потока симуляции сразу после дня.
func build(sel_fleet: int = -1, sel_wing: int = -1) -> Array:
	var out: Array = []
	if world == null:
		return [out, false]
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
	var has_battles := not battle_provs.is_empty()
	# фишки: по одной на (провинция, страна) — стопки считает ядро World.k_counters
	# (C++ или GDScript); выделение и цвет армии игрока — здесь, по ключу
	# провинция·страна
	var marks := {}      # ключ -> [выделена, цвет армии]
	for slot in sel:
		var key: int = a_prov[slot] * 1024 + a_owner[slot]
		marks[key] = [true, Color(0, 0, 0, 0)]
	if player >= 0:
		for i in n_div:
			if a_owner[i] != player or a_alive[i] == 0 or a_transit[i] > 0:
				continue
			var grp: int = divs[i].group
			if grp < 0:
				continue
			var key: int = a_prov[i] * 1024 + player
			var m: Array = marks.get(key, [false, Color(0, 0, 0, 0)])
			var gc: Color = m[1]
			if gc.a == 0.0:
				m[1] = world.groups[grp].color
				marks[key] = m
	var cs: Array = world.k_counters()
	var c_prov: PackedInt32Array = cs[0]
	var c_owner: PackedInt32Array = cs[1]
	var c_n: PackedInt32Array = cs[2]
	var c_tpl: PackedInt32Array = cs[3]
	var c_str: PackedFloat64Array = cs[4]
	var c_org: PackedFloat64Array = cs[5]
	var c_sup: PackedFloat64Array = cs[6]
	var k := 0
	for ci in c_prov.size():
		var p := c_prov[ci]
		k = k + 1 if ci > 0 and c_prov[ci - 1] == p else 0
		var o := c_owner[ci]
		var n := c_n[ci]
		var m: Array = marks.get(p * 1024 + o, [false, Color(0, 0, 0, 0)])
		out.append([COUNTER, centers[p] * sc, k, nat_cols[o], n, c_tpl[ci],
			c_str[ci] / (100.0 * n), c_org[ci] / n, m[0], m[1], c_sup[ci] < 0.3, o == player])
	_rebuild_navy_air(out, sel_fleet, sel_wing)
	return [out, has_battles]


func _rebuild_navy_air(out: Array, sel_fleet: int, sel_wing: int) -> void:
	# порты и военно-морские базы (свои и союзные)
	# список меняется со сменой владельцев (палитра) и плацдармами — пересчёт
	# по всем прибрежным провинциям раз в 10 дней или при смене владельцев
	if player >= 0 and world.p_naval_base.size() == world.prov_count:
		var key := "%d/%d/%d" % [player, map.palette_version if map != null else 0, world.day / 10]
		if key != _ports_key:
			_ports_key = key
			_ports.clear()
			for p in world.prov_count:
				if world.p_land[p] == 0 or world.p_coastal[p] == 0:
					continue
				var c := world.p_controller[p]
				if c < 0 or (c != player and world.ally[player * world.nation_count + c] == 0):
					continue
				var base := world.p_naval_base[p] == 1
				if base or Forces.is_port(world, p):
					_ports.append([PORT, _wp(p), base])
		out.append_array(_ports)
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
	_texts.clear()
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
				if not it[3] and not screen.has_point(pts[0]) and not screen.has_point(pts[pts.size() - 1]):
					continue   # стрелка целиком за экраном
				var col: Color = it[2]
				# без сглаживания: сглаженная ломаная — отдельная дорогая сетка на каждую стрелку
				draw_polyline(pts, col, 3.0 if it[3] else 2.0, false)
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
				pass   # рисует отдельный слой _battles (пульсирует, не трогая фишки)
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
	for tx in _texts:
		draw_string(bold, tx[0], tx[1], HORIZONTAL_ALIGNMENT_CENTER, tx[2], tx[3], Color(0.97, 0.95, 0.9))
	draw_usec = Time.get_ticks_usec() - t0
	draw_count += 1
	draw_total_usec += draw_usec


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
	draw_texture_rect_region(_atlas, Rect2(pos + Vector2(1.5, 2.5), counter), _r_shadow)
	draw_texture_rect_region(_atlas, rect, _r_plate, nat_col.darkened(0.12))
	if any_sel:
		draw_texture_rect_region(_atlas, rect, _r_sel)
	var badge_r := counter.y * 0.5 - 1.5
	var bc := pos + Vector2(badge_r + 1.5, counter.y * 0.5)
	draw_texture_rect_region(_atlas, Rect2(bc - Vector2(badge_r, badge_r), Vector2(badge_r, badge_r) * 2.0), _r_badge, nat_col.lightened(0.45))
	var ir: Rect2 = _r_icons[clampi(it[5], 0, _r_icons.size() - 1)]
	if ir.size.x > 0:
		var isz := badge_r * 1.56
		draw_texture_rect_region(_atlas, Rect2(bc - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), ir, Color(0.1, 0.09, 0.08))
	else:
		_draw_icon(Rect2(bc - Vector2(badge_r, badge_r) * 0.82, Vector2(badge_r, badge_r) * 1.64), it[5], Color(0.1, 0.09, 0.08))
	var tx := bc.x + badge_r + 1.0
	# число — отдельным проходом (другая текстура — шрифт)
	_texts.append([Vector2(tx, pos.y + counter.y * 0.5 + font_size * 0.36), str(it[4]), pos.x + counter.x - tx - 2.0, font_size])
	var grp: Color = it[9]
	if grp.a > 0.0:
		draw_texture_rect_region(_atlas, Rect2(pos + Vector2(rad * 0.6, -4), Vector2(counter.x - rad * 1.2, 3)), _r_white, grp)
	if it[10]:
		# нет снабжения: красный восклицательный знак
		var c2 := pos + Vector2(counter.x + 5, 3)
		draw_circle(c2, 6.5, Color(0.85, 0.15, 0.1), true, -1.0, true)
		draw_string(font, c2 + Vector2(-2.5, 5), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	# полоски под плашкой: зелёная — сила, жёлтая — организация (со скруглёнными краями)
	var bx := pos.x + rad * 0.5
	var bw := counter.x - rad
	draw_texture_rect_region(_atlas, Rect2(bx - 1, pos.y + counter.y + 1, bw + 2, 7), _r_bars)
	if it[6] > 0.02:
		draw_texture_rect_region(_atlas, Rect2(bx, pos.y + counter.y + 2, bw * it[6], 2.5), _r_white, Color(0.40, 0.85, 0.38))
	if it[7] > 0.02:
		draw_texture_rect_region(_atlas, Rect2(bx, pos.y + counter.y + 5, bw * it[7], 2.5), _r_white, Color(0.96, 0.80, 0.30))


# Подписи стран рисуются шрифтом одного размера LBL_PX и масштабируются
# преобразованием: буквы растеризуются один раз (раньше каждый новый размер
# при масштабировании растеризовался заново — до 60 мс на кадр).
const LBL_PX := 48
var _lbl_w := {}   # ширина подписи при LBL_PX


func _draw_label(l: Array, z: float) -> void:
	if z > 1.6:
		return
	var text: String = l[2]
	var bw: float = _lbl_w.get(text, -1.0)
	if bw < 0.0:
		bw = label_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, LBL_PX).x
		_lbl_w[text] = bw
	var size := clampf(l[3] * z, 12, 60)
	var fit: float = l[4] * z * 0.95
	var w := bw * size / LBL_PX
	if w > fit and w > 0.0:
		size *= fit / w
		w = fit
	if size < 11.0:
		return
	var pos := map.world_to_screen(l[1])
	var vp := get_viewport_rect()
	if pos.x + w * 0.5 < 0 or pos.x - w * 0.5 > vp.size.x or pos.y + size < 0 or pos.y - size > vp.size.y:
		return
	var alpha := clampf((1.6 - z) * 2.0, 0.0, 0.75)
	var k := size / LBL_PX
	draw_set_transform(pos - Vector2(w * 0.5, 0), 0.0, Vector2(k, k))
	draw_string_outline(label_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LBL_PX, int(4.0 / k), Color(0.95, 0.92, 0.84, alpha * 0.45))
	draw_string(label_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LBL_PX, Color(0.10, 0.08, 0.06, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _rebuild_labels() -> void:
	# Подпись — по связному куску территории со столицей (иначе «Великобритания»
	# уезжает в Африку, «Дания» — в Гренландию), без столицы — по самому большому.
	_labels_day = world.day
	_labels.clear()
	if Native.core != null:
		# то же в C++ (MeowqCore.label_regions): заливка по всем провинциям
		var caps0 := PackedInt32Array()
		for nn in world.nations:
			caps0.append(nn.capital)
		var r: PackedFloat64Array = Native.core.call("label_regions", world.p_controller, world.p_land,
			world.adj_start, world.adj_list, world.p_pixels, world.p_center, caps0)
		for c in world.nations.size():
			if r[c * 8 + 7] == 0.0 or not world.nations[c].alive:
				continue
			var px0 := r[c * 8]
			var center0 := Vector2(r[c * 8 + 1], r[c * 8 + 2]) / maxf(1.0, px0)
			var span0 := (Vector2(r[c * 8 + 5], r[c * 8 + 6]) - Vector2(r[c * 8 + 3], r[c * 8 + 4])) * MapView.SCALE
			_labels.append([center0 * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(px0) * 0.5, maxf(span0.x, span0.y * 0.8)])
		return
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


func _draw_battles(ci: CanvasItem) -> void:
	if map == null:
		return
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	var screen := Rect2(Vector2.ZERO, vp).grow(40)
	var counter := Vector2(40, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
	var r := 10.0 + sin(Time.get_ticks_msec() * 0.008) * 1.5
	var btex := UiStyle.icon("battle", 64)
	for it in items:
		if it[0] != BATTLE:
			continue
		var c := map.world_to_screen(it[1]) + Vector2(0, -counter.y)
		if not screen.has_point(c):
			continue
		ci.draw_circle(c, r + 2, Color(0.1, 0.05, 0.05, 0.8))
		ci.draw_circle(c, r, Color(0.78, 0.16, 0.12))
		if btex != null:
			ci.draw_texture_rect(btex, Rect2(c - Vector2(7, 7), Vector2(14, 14)), false, Color(1, 0.95, 0.85))
		else:
			ci.draw_line(c + Vector2(-5, -5), c + Vector2(5, 5), Color.WHITE, 2.0)
			ci.draw_line(c + Vector2(5, -5), c + Vector2(-5, 5), Color.WHITE, 2.0)
