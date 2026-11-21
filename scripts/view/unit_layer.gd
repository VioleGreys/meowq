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

enum { ARROW, FRONT, OBJECTIVE, BATTLE, COUNTER, LABEL, PORT, PLAN, TRANSIT, FLEET, PLANES, CITY }

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
var _cities: Array = []         # города (очки ≥ 4): [мировая позиция, имя, очки, провинция], крупные первыми
var _city_occ := {}             # занятые знаками и подписями городов места: клетка экрана -> [Rect2]
var fog_on := not "--nofog" in OS.get_cmdline_user_args()   # туман войны (для снимков — `-- --nofog`)
var units_on := true            # войска на карте (в главном меню и при выборе страны — нет)
var _vis := PackedByteArray()   # видимые игроком провинции (кэш _visible на день)
var _vis_key := ""



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
var _r_city: Array = []         # Rect2 знаков городов в атласе: город, крупный, столица
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


## Подписи стран и знаки городов — свой холст под фишками (show_behind_parent):
## меняются редко, а слой фишек на скорости перерисовывается каждый день
## (знаков городов ~1800 — было до 2/3 времени перерисовки).
class StaticMarks:
	extends Node2D
	var layer: UnitLayer

	func _draw() -> void:
		layer._draw_static(self)


var _battles: BattleMarks
var _static: StaticMarks
var _static_n := 0            # в начале items: подписи и города (рисует _static)
var _static_dirty := true
var _shown_st_ver := -1       # версия подписей и городов, что сейчас нарисована
var _st_ver := 0              # (поток сборки) версия, ключ городов и версия подписей
var _st_key := PackedByteArray()
var _st_lver := -1
var _labels_ver := 0


func _ready() -> void:
	_static = StaticMarks.new()
	_static.layer = self
	_static.show_behind_parent = true
	add_child(_static)
	_battles = BattleMarks.new()
	_battles.layer = self
	_battles.use_parent_material = true
	add_child(_battles)
	_warp = ShaderMaterial.new()
	_warp.shader = load("res://shaders/unit_warp.gdshader")
	material = _warp
	_swarp = ShaderMaterial.new()
	_swarp.shader = _warp.shader
	_static.material = _swarp
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
	for kind in [1, 2, 3]:
		parts.append(_city_img(kind))
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
	_r_city.clear()
	for i in 3:
		_r_city.append(rects[6 + TPL_ICONS.size() + i])


## Знак города (вид 1–3) — в атлас один раз: тень, кольцо, тёмный круг, звезда
## столицы или дома. Раньше — три сглаженных круга и многоугольник на каждый знак в
## каждой перерисовке (на телефоне — заметная доля «фишки:города»).
static func _city_img(kind: int) -> Image:
	var k := float(TEX_K)
	var r: float = CITY_R[kind] * k
	var half := ceilf(r + 3.5 * k)
	var n := int(half * 2.0)
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(half, half)
	var ring := Color(0.86, 0.68, 0.27) if kind == 3 else Color(0.80, 0.77, 0.70)
	var sym := Color(0.98, 0.80, 0.30) if kind == 3 else Color(0.93, 0.90, 0.82)
	var star := PackedVector2Array()
	var houses: Array = []
	if kind == 3:
		for i in 10:
			var ang := -PI * 0.5 + i * PI / 5.0
			star.append(c + Vector2(cos(ang), sin(ang)) * r * (0.78 if i % 2 == 0 else 0.33))
	else:
		var u := r / 8.0
		var bl := c.y + 4.5 * u
		var hs: Array = [[-4.5, 2.6, 6.0], [-1.5, 3.0, 9.0], [1.9, 2.6, 4.5]] if kind == 2 else [[-3.6, 3.2, 7.5], [0.4, 3.2, 5.0]]
		for b: Array in hs:
			houses.append(Rect2(c.x + b[0] * u, bl - b[2] * u, b[1] * u, b[2] * u))
	var sh := c + Vector2(1.0, 1.5) * k
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5)
			var col := Color(0, 0, 0, 0)
			col = _over(col, Color(0, 0, 0, 0.35), clampf(r + 1.5 * k - p.distance_to(sh) + 0.5, 0.0, 1.0))
			var dc := p.distance_to(c)
			col = _over(col, ring, clampf(r + 1.5 * k - dc + 0.5, 0.0, 1.0))
			col = _over(col, Color(0.13, 0.12, 0.11, 0.95), clampf(r - dc + 0.5, 0.0, 1.0))
			if dc > r:
				img.set_pixel(x, y, col)
				continue
			var cov := 0.0
			if kind == 3:
				for sy in 3:
					for sx in 3:
						if Geometry2D.is_point_in_polygon(Vector2(x + (sx + 0.5) / 3.0, y + (sy + 0.5) / 3.0), star):
							cov += 1.0 / 9.0
			else:
				var px := Rect2(x, y, 1, 1)
				for h: Rect2 in houses:
					cov += px.intersection(h).get_area()
			col = _over(col, sym, minf(cov, 1.0))
			img.set_pixel(x, y, col)
	return img


## Наложение цвета src (с долей покрытия cov) поверх dst — без предумножения.
static func _over(dst: Color, src: Color, cov: float) -> Color:
	var sa := src.a * cov
	var oa := sa + dst.a * (1.0 - sa)
	if oa <= 0.0:
		return Color(0, 0, 0, 0)
	var rgb := (Color(src.r, src.g, src.b) * sa + Color(dst.r, dst.g, dst.b) * (dst.a * (1.0 - sa))) / oa
	return Color(rgb.r, rgb.g, rgb.b, oa)


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


# Слой перерисовывается только при изменениях данных (новый список, выделение)
# и камеры. Сдвиг камеры (решение пользователя, ноябрь 2026: на телефоне
# перерисовка слоя — ~7,5 мс на кадр): слой нарисован для опорной камеры, вершины
# переносит под текущую шейдер unit_warp (без наклона — точно). Перерисовка —
# если масштаб ушёл больше WARP_ZOOM, сдвиг больше запаса отрисовки (фишки за
# краем рисуются с запасом DRAW_MARGIN), при наклоне — не чаще WARP_TILT_MSEC
# (перспектива переносом точна не везде) и сразу после остановки камеры.
# Бои пульсируют — их слой не чаще 12 раз в секунду.
# Подписи стран и знаки городов (_static) — со своей опорной камерой: пока камера
# движется, перерисовываются не чаще STATIC_MSEC (масштаб — до STATIC_ZOOM, наклон —
# до STATIC_TILT от опорной), между ними — переносом; после остановки — точно.
# На телефоне одна их перерисовка — 10–29 мс скриптов (отчёт 15, ноябрь 2026).
# Данные городов меняются почти каждый день (войска вошли в город — знак
# сдвигается от фишки): по ним — не чаще STATIC_DATA_MSEC.
const WARP_ZOOM := 1.03
const WARP_TILT_MSEC := 100
const STATIC_MSEC := 100
const STATIC_DATA_MSEC := 400     # новые данные (войска вошли в город — знак сдвигается) — не чаще
const STATIC_ZOOM := 1.3
const STATIC_TILT := 0.12
const DRAW_MARGIN := 0.15          # запас отрисовки за краем экрана (доля большей стороны)
var _dirty := true
var _has_battles := false
var _anim_msec := 0
var _warp: ShaderMaterial
var _r_pos := Vector2.ZERO          # опорная камера — с которой нарисован слой
var _r_zoom := 1.0
var _r_tilt := 0.0
var _draw_msec := 0
var _prev_pos := Vector2.ZERO       # камера прошлого кадра
var _prev_zoom := 0.0
var _prev_tilt := 0.0
var redraw_skipped := 0             # для замеров: кадров со сдвигом без перерисовки


func _process(_dt: float) -> void:
	if map == null or map.camera == null:
		if _dirty:
			_dirty = false
			queue_redraw()
			_static.queue_redraw()
		return
	var now := Time.get_ticks_msec()
	var pos := map.camera.position
	var z := map.camera.zoom.x
	var th := map.tilt()
	var same := pos == _r_pos and z == _r_zoom and th == _r_tilt
	var moved_now := pos != _prev_pos or z != _prev_zoom or th != _prev_tilt
	_prev_pos = pos
	_prev_zoom = z
	_prev_tilt = th
	if not _dirty and not same:
		var zr := z / maxf(1e-6, _r_zoom)
		var half := get_viewport_rect().size * 0.5
		var shift := (map.world_to_screen(_r_pos) - half).abs()
		var m := maxf(half.x, half.y) * 2.0 * DRAW_MARGIN
		if zr > WARP_ZOOM or zr < 1.0 / WARP_ZOOM or absf(th - _r_tilt) > 0.01 \
				or shift.x > m or shift.y > m \
				or (th > 0.0 and (now - _draw_msec >= WARP_TILT_MSEC or not moved_now)):
			_dirty = true   # при наклоне после остановки — точный кадр
		else:
			redraw_skipped += 1
	if _dirty:
		_dirty = false
		_r_pos = pos
		_r_zoom = z
		_r_tilt = th
		_draw_msec = now
		queue_redraw()
		if not _static_cam(pos, z, th):
			_static_lag = true
		_battles.queue_redraw()
		_anim_msec = now
	elif _has_battles and now - _anim_msec >= 80:
		# пульс боёв — только маленький слой отметок, не весь слой фишек
		_anim_msec = now
		_battles.queue_redraw()
	if (_static_dirty and now - _s_msec >= STATIC_DATA_MSEC) or (_static_lag and not _static_cam(pos, z, th) \
			and (not moved_now or now - _s_msec >= STATIC_MSEC or not _static_warp_ok(pos, z, th))):
		_static_dirty = false
		_static_lag = false
		_s_pos = pos
		_s_zoom = z
		_s_tilt = th
		_s_msec = now
		_static.queue_redraw()
	_set_warp(pos, z, th)
	_set_swarp(pos, z, th)


var _s_pos := Vector2.ZERO          # камера, с которой нарисованы подписи и города
var _s_zoom := 0.0
var _s_tilt := -1.0
var _s_msec := 0
var _static_lag := false            # камера ушла от опорной городов: перерисовать при случае
var _swarp: ShaderMaterial          # перенос подписей и городов (своя опорная камера _s_*)
var _swarp_key := []


## Перенос подписей и городов ещё терпим (размеры знаков — от опорной камеры).
func _static_warp_ok(pos: Vector2, z: float, th: float) -> bool:
	var zr := z / maxf(1e-6, _s_zoom)
	if zr > STATIC_ZOOM or zr < 1.0 / STATIC_ZOOM or absf(th - _s_tilt) > STATIC_TILT:
		return false
	var half := get_viewport_rect().size * 0.5
	var shift := (map.world_to_screen(_s_pos) - half).abs()
	var m := maxf(half.x, half.y) * 2.0 * DRAW_MARGIN
	return shift.x <= m and shift.y <= m


func _set_swarp(pos: Vector2, z: float, th: float) -> void:
	var on := not _static_cam(pos, z, th)
	var key := [on, pos, z, th, _s_pos, _s_zoom, _s_tilt]
	if key == _swarp_key:
		return
	_swarp_key = key
	_swarp.set_shader_parameter("on", on)
	if not on:
		return
	_swarp.set_shader_parameter("r_pos", _s_pos)
	_swarp.set_shader_parameter("r_zoom", _s_zoom)
	_swarp.set_shader_parameter("r_tilt", _s_tilt)
	_swarp.set_shader_parameter("c_pos", pos)
	_swarp.set_shader_parameter("c_zoom", z)
	_swarp.set_shader_parameter("c_tilt", th)
	_swarp.set_shader_parameter("cam_f", map.cam_focal())
	_swarp.set_shader_parameter("half_size", get_viewport_rect().size * 0.5)


func _static_cam(pos: Vector2, z: float, th: float) -> bool:
	return pos == _s_pos and z == _s_zoom and th == _s_tilt


## Перенос слоя под текущую камеру (вершинный шейдер).
var _warp_key := []


func _set_warp(pos: Vector2, z: float, th: float) -> void:
	var on := not (pos == _r_pos and z == _r_zoom and th == _r_tilt)
	var key := [on, pos, z, th, _r_pos, _r_zoom, _r_tilt]
	if key == _warp_key:
		return   # без изменений — не трогать материал (иначе кадр рисуется заново)
	_warp_key = key
	_warp.set_shader_parameter("on", on)
	if not on:
		return
	_warp.set_shader_parameter("r_pos", _r_pos)
	_warp.set_shader_parameter("r_zoom", _r_zoom)
	_warp.set_shader_parameter("r_tilt", _r_tilt)
	_warp.set_shader_parameter("c_pos", pos)
	_warp.set_shader_parameter("c_zoom", z)
	_warp.set_shader_parameter("c_tilt", th)
	_warp.set_shader_parameter("cam_f", map.cam_focal())
	_warp.set_shader_parameter("half_size", get_viewport_rect().size * 0.5)


var edit_ids := {}                      # армии, чей участок правится кистью (main): id -> true
var edit_sel := PackedInt32Array()      # выделение кистью (армии или группы армий)


func _wp(p: int) -> Vector2:
	return world.p_center[p] * MapView.SCALE


## Собрать список отрисовки. Вызывать ТОЛЬКО под блокировкой мира.
func rebuild(sel_fleet: int = -1, sel_wing: int = -1) -> void:
	var r := build(sel_fleet, sel_wing)
	_set_items(r[0], r[3], r[4])
	_has_battles = r[1]
	if map != null:
		map.set_front(r[2])
	_dirty = true


## Принять список, собранный потоком симуляции (конвейер экрана, main._publish).
func take(list: Array, battles: bool, marks: Dictionary = {}, st_ver := -1, st_n := 0) -> void:
	_set_items(list, st_ver, st_n)
	_has_battles = battles
	if map != null:
		map.set_front(marks)
	_dirty = true


## Новый список: подписи и города (первые st_n) перерисовываются, только если
## сменилась их версия (build).
func _set_items(list: Array, st_ver: int, st_n: int) -> void:
	if st_ver != _shown_st_ver or st_ver < 0:
		_static_dirty = true
	_shown_st_ver = st_ver
	items = list
	_static_n = st_n


## Собрать список отрисовки по миру → [список, есть ли бои]. Только чтение мира
## и своих кэшей подписей и портов: вызывается под замком мира — из главного
## потока (выделение) или из потока симуляции сразу после дня.
func build(sel_fleet: int = -1, sel_wing: int = -1) -> Array:
	var out: Array = []
	if world == null:
		return [out, false, {}, -1, 0]
	# подписи стран пересчитываются (заливка по провинциям) только когда менялись
	# владельцы — не чаще раза в 5 дней
	var pv := map.palette_version if map != null else 0
	if _labels_day < 0 or world.day < _labels_day or (pv != _labels_pv and world.day - _labels_day >= 5):
		_labels_pv = pv
		_rebuild_labels()
	for l in _labels:
		out.append([LABEL, l[0], l[1], l[2], l[3]])
	var city_at := out.size()   # значки городов — под фишками, вставляются после них
	if not units_on:
		# главное меню и выбор страны: только подписи и города, без войск
		var st_n0 := _merge_cities(out, city_at, {})
		return [out, false, {}, _st_ver, st_n0]
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
	# туман войны (_visible): чужие дивизии, флоты и авиация — только в видимых
	# провинциях; невидимое не попадает в список и не рисуется
	var vis := _visible()
	var ally := world.ally
	var nc := world.nation_count
	var seen := func(p: int, o: int) -> bool:
		return vis.is_empty() or o == player or ally[player * nc + o] == 1 or vis[p] == 1
	# стрелки движения и бои
	var battle_provs := {}
	for i in n_div:
		if a_alive[i] == 0 or a_next[i] < 0 or a_transit[i] > 0:
			continue
		if not seen.call(a_prov[i], a_owner[i]):
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
	# фронты и цели армий игрока: линия по границе и штриховка целей рисует
	# шейдер карты (front_marks → MapView.set_front), здесь — только значок цели
	var fmarks := front_marks()
	for g in world.groups:
		if not g.alive or g.owner != player:
			continue
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
	var prev := -1
	var troops := {}   # провинция -> есть видимые фишки (значок города — в сторону)
	for ci in c_prov.size():
		var p := c_prov[ci]
		var o := c_owner[ci]
		if not seen.call(p, o):
			continue
		k = k + 1 if p == prev else 0
		prev = p
		troops[p] = true
		var n := c_n[ci]
		var m: Array = marks.get(p * 1024 + o, [false, Color(0, 0, 0, 0)])
		out.append([COUNTER, centers[p] * sc, k, nat_cols[o], n, c_tpl[ci],
			c_str[ci] / (100.0 * n), c_org[ci] / n, m[0], m[1], c_sup[ci] < 0.3, o == player])
	var static_n := _merge_cities(out, city_at, troops)
	_rebuild_navy_air(out, sel_fleet, sel_wing, vis)
	return [out, has_battles, fmarks, _st_ver, static_n]


## Вставить значки городов в список на место city_at (под фишки) → число
## неизменных элементов (подписи и города). Версия подписей и городов новая,
## только если они изменились (сверка здесь, в потоке симуляции, а не в кадре).
func _merge_cities(out: Array, city_at: int, troops: Dictionary) -> int:
	var cities: Array = []
	_add_cities(cities, troops)
	var skey := PackedByteArray()
	skey.resize(cities.size())
	for i in cities.size():
		skey[i] = cities[i][4] * 2 + (1 if cities[i][5] else 0)
	if skey != _st_key or _labels_ver != _st_lver:
		_st_key = skey
		_st_lver = _labels_ver
		_st_ver += 1
	var tail := out.slice(city_at)
	out.resize(city_at)
	out.append_array(cities)
	out.append_array(tail)
	return city_at + cities.size()


## Туман войны игрока: 1 — провинция (суша или морская зона) видна. Видно: своя
## и союзная земля и всё в 1 шаге от неё; FOG_R шагов от своих и союзных
## дивизий (World.fog_table, как у ИИ); морская зона своего или союзного флота. Пусто — тумана нет (нет игрока или `-- --nofog`). Считается
## раз в игровой день (дивизии и флоты двигаются только в тике).
func _visible() -> PackedByteArray:
	if player < 0 or not fog_on:
		return PackedByteArray()
	var key := "%d/%d/%d" % [world.get_instance_id(), player, world.day]
	if key == _vis_key:
		return _vis
	var pc := world.prov_count
	var nc := world.nation_count
	var fog := world.fog_table(PackedInt32Array([player]))
	var vis := fog.slice(player * pc, player * pc + pc)
	var ctrl := world.p_controller
	var ally := world.ally
	var a0 := player * nc
	var as_ := world.adj_start
	var al := world.adj_list
	# (не лямбдой: упакованный массив попал бы в неё копией)
	var eyes := PackedInt32Array()
	for p in pc:
		var c := ctrl[p]
		if c >= 0 and (c == player or ally[a0 + c] == 1):
			eyes.append(p)
	for p in eyes:
		vis[p] = 1
		for j in range(as_[p], as_[p + 1]):
			vis[al[j]] = 1
	for f in world.fleets:
		if f.alive and f.zone >= 0 and (f.owner == player or ally[a0 + f.owner] == 1):
			vis[f.zone] = 1
	_vis = vis
	_vis_key = key
	return vis


## Отметки фронтов армий игрока для шейдера карты: провинция -> [роль, цвет]
## (биты роли — MapView.set_front). Армии, участок которых правится кистью
## (edit_ids), показывают выделение и участок по нему сразу — до плана дня.
func front_marks() -> Dictionary:
	var marks := {}
	if player < 0:
		return marks
	var ctrl := world.p_controller
	for g in world.groups:
		if not g.alive or g.owner != player:
			continue
		var col: Color = g.color
		var fp: PackedInt32Array = g.front_pairs
		var atk: bool = g.mode == "attack"
		if edit_ids.has(g.id):
			var fr: Dictionary = Simulation.sel_fronts(world, g.owner, g.front_sel)
			fp = PackedInt32Array()
			# предпросмотр: пары «наша — цель» из выделения
			for k in fr:
				var q: int = k
				if q >= 0:
					continue
				q = -q - 1
				for j in range(world.adj_start[q], world.adj_start[q + 1]):
					var p := world.adj_list[j]
					if fr.has(p) and ctrl[p] == g.owner:
						fp.append(p)
						fp.append(q)
		for i in range(0, fp.size(), 2):
			var a := fp[i]
			var b := fp[i + 1]
			var ma: Array = marks.get(a, [0, col])
			ma[0] = int(ma[0]) | 1
			marks[a] = ma
			var mb: Array = marks.get(b, [0, col])
			mb[0] = int(mb[0]) | (10 if atk else 2)
			marks[b] = mb
	for p in edit_sel:
		var m: Array = marks.get(p, [0, Color(1.0, 0.92, 0.55)])
		m[0] = int(m[0]) | 4
		marks[p] = m
	return marks


func _rebuild_navy_air(out: Array, sel_fleet: int, sel_wing: int, vis: PackedByteArray) -> void:
	var ally := world.ally
	var a0 := player * world.nation_count
	var friend := func(o: int) -> bool:
		return vis.is_empty() or o == player or ally[a0 + o] == 1
	# видимые районы авиации: есть видимая провинция или своё и союзное крыло
	var reg_vis := PackedByteArray()
	if not vis.is_empty():
		reg_vis.resize(world.region_count)
		var pr := world.p_region
		for p in world.prov_count:
			if vis[p] == 1 and pr[p] >= 0:
				reg_vis[pr[p]] = 1
		for wg in world.wings:
			if wg.alive and wg.region >= 0 and friend.call(wg.owner):
				reg_vis[wg.region] = 1
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
			if not friend.call(a_owner[i]) and vis[d.transit_from] == 0 and vis[d.transit_target] == 0:
				continue
			var t := 1.0 - float(a_transit[i]) / maxf(1.0, d.transit_total)
			out.append([TRANSIT, _wp(d.transit_from), _wp(d.transit_target), t, world.nations[a_owner[i]].color, a_owner[i] == player])
	# флоты
	for f in world.fleets:
		if not f.alive or f.zone < 0:
			continue
		if not friend.call(f.owner) and vis[f.zone] == 0:
			continue
		var pts := PackedVector2Array()
		if f.id == sel_fleet:
			for q in f.path:
				pts.append(_wp(q))
		var relevant: bool = f.owner == player or world.is_at_war(player, f.owner)
		# силуэт — по роду с наибольшей силой (линкоры, крейсеры, эсминцы, подлодки, авианосцы)
		var fam := ShipDesigns.FAM_CR
		var fp: PackedFloat64Array = f.fam_power
		var best := -1.0
		for k in fp.size():
			if fp[k] > best:
				best = fp[k]
				fam = k
		out.append([FLEET, _wp(f.zone), world.nations[f.owner].color, f.mission == "raid", Forces.fleet_size(f),
			f.id == sel_fleet, f.in_battle, pts, relevant, fam])
	# авиация игрока (и вражеская при войне): один значок на район и тип
	var groups := {}
	for wg in world.wings:
		if not wg.alive or wg.region < 0:
			continue
		if wg.owner != player and not world.is_at_war(player, wg.owner):
			continue
		if not friend.call(wg.owner) and reg_vis[wg.region] == 0:
			continue
		var key := "%d:%d:%d" % [wg.region, 0 if wg.owner == player else 1, wg.kind]
		if not groups.has(key):
			groups[key] = [wg.region, wg.owner, wg.kind, 0.0, false, {}]
		groups[key][3] += wg.planes
		if wg.id == sel_wing:
			groups[key][4] = true
		# силуэт бомбардировщиков — по заданию большинства: поддержка войск,
		# бомбёжка заводов (тяжёлые), удары по флоту
		var ms: Dictionary = groups[key][5]
		ms[wg.mission] = float(ms.get(wg.mission, 0.0)) + wg.planes
	for key in groups:
		var g: Array = groups[key]
		var mine: bool = g[1] == player
		var sub := 0
		if g[2] == 1:
			sub = 1
			var ms: Dictionary = g[5]
			var bm := -1.0
			for m in ms:
				if ms[m] > bm:
					bm = ms[m]
					sub = 2 if m == "bomb" else (3 if m == "naval" else 1)
		out.append([PLANES, _wp(world.region_anchor[g[0]]), world.nations[g[1]].color, g[2], g[4], int(g[3]), mine, sub])


var draw_usec := 0   # время последней отрисовки слоя (для нижней строки)


func _draw() -> void:
	if map == null:
		return
	var t0 := Time.get_ticks_usec()
	_texts.clear()
	_occ.clear()
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	# с запасом: при сдвиге слой не перерисовывается, пока запас не кончится
	var screen := Rect2(Vector2.ZERO, vp).grow(40.0 + maxf(vp.x, vp.y) * DRAW_MARGIN)
	var counter := Vector2(40, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
	var font_size := int(clampf(12 + z * 2, 12, 20))
	for i in range(_static_n, items.size()):
		var it: Array = items[i]
		match it[0]:
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
				if z < CLUSTER_Z:
					_cluster_add(it, z)
				else:
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
				var tc := a.lerp(b, it[3])
				var tr := Rect2(tc - Vector2(17, 6), Vector2(34, 12))
				for o in [Vector2(-1.2, 0), Vector2(1.2, 0), Vector2(0, -1.2), Vector2(0, 1.2)]:
					_navair_draw("ship_5", Rect2(tr.position + o, tr.size), Color(0.04, 0.04, 0.04, 0.85))
				if not _navair_draw("ship_5", tr, it[4].lightened(0.3)):
					_ship_icon(tc, it[4], 0.8)
			FLEET:
				if not it[8] and z < 0.6:
					continue
				var c0 := map.world_to_screen(it[1])
				if not screen.has_point(c0):
					continue
				var c := _place(c0 + Vector2(0, 14 if it[3] else 0), Vector2(66, 22))
				var wpts: PackedVector2Array = it[7]
				if not wpts.is_empty():
					var pts := PackedVector2Array([c])
					for wpt in wpts:
						pts.append(map.world_to_screen(wpt))
					draw_polyline(pts, Color(0.6, 0.9, 1.0), 2.5)
				_navair_plate(c, Vector2(66, 22), it[2], "ship_%d" % it[9], Vector2(46, 17), str(it[4]), it[5], it[6], it[3])
			PLANES:
				var c0 := map.world_to_screen(it[1])
				if not screen.has_point(c0):
					continue
				var c := _place(c0 + Vector2(0, -34), Vector2(52, 22))
				_navair_plate(c, Vector2(52, 22), it[2], "plane_%d" % it[7], Vector2(21, 21), str(it[5]), it[4], false, false)
	if not _clusters.is_empty():
		_draw_clusters(z, counter, font_size, screen)
	for tx in _texts:
		draw_string(bold, tx[0], tx[1], HORIZONTAL_ALIGNMENT_CENTER, tx[2], tx[3], Color(0.97, 0.95, 0.9))
	for tx in _texts_dark:
		draw_string(bold, tx[0], tx[1], HORIZONTAL_ALIGNMENT_CENTER, tx[2], 13, Color(0.08, 0.07, 0.06))
	_texts_dark.clear()
	draw_usec = Time.get_ticks_usec() - t0
	FrameProf.add("фишки", draw_usec)
	draw_count += 1
	draw_total_usec += draw_usec


## Подписи стран и знаки городов (холст _static, под фишками; камера — та же,
## что у слоя, перенос — общий шейдер).
func _draw_static(ci: CanvasItem) -> void:
	if map == null:
		return
	var t0 := Time.get_ticks_usec()
	_city_occ.clear()
	var z := map.zoom_level()
	var vp := get_viewport_rect().size
	var screen := Rect2(Vector2.ZERO, vp).grow(40.0 + maxf(vp.x, vp.y) * DRAW_MARGIN)
	var counter := Vector2(40, 22) * clampf(0.75 + z * 0.25, 0.8, 1.5)
	# Отсев до вызова (тот же итог, что проверки внутри _draw_city): прямоугольник
	# мира, который виден в screen (при наклоне — по углам; горизонт в кадре —
	# без отсева), и наибольший масштаб в кадре (у нижнего края).
	var th := map.tilt()
	var zmax := z
	var wbox := Rect2()
	var cull := true
	if th > 0.0:
		var f := map.cam_focal()
		if cos(th) + sin(th) * (screen.position.y - vp.y * 0.5) / f < 0.05:
			cull = false
		else:
			zmax = maxf(z, map.local_zoom(map.screen_to_world(Vector2(vp.x * 0.5, screen.end.y)))) * 1.01
	if cull:
		var c0 := map.screen_to_world(screen.position)
		wbox = Rect2(c0, Vector2.ZERO)
		for q: Vector2 in [Vector2(screen.end.x, screen.position.y), screen.end, Vector2(screen.position.x, screen.end.y)]:
			wbox = wbox.expand(map.screen_to_world(q))
		wbox = wbox.grow(maxf(wbox.size.x, wbox.size.y) * 0.01 + 1.0)
	var n := mini(_static_n, items.size())
	var first_city := n
	for i in n:
		var it: Array = items[i]
		if it[0] != LABEL:
			first_city = i
			break
		_draw_label(ci, it, map.local_zoom(it[1]))
	# города: не все — только из клеток сетки, попавших в кадр; столицы, затем
	# остальные по убыванию очков (от порядка зависит, чья подпись уступает место)
	var idx: Array
	if zmax < CITY_Z[3]:
		n = first_city   # издали знаков городов нет совсем
	if cull:
		if _cgrid.is_empty():
			_build_cgrid(first_city, n)
		var g0 := (wbox.position / CGRID).floor()
		var g1 := (wbox.end / CGRID).floor()
		for gy in range(int(g0.y), int(g1.y) + 1):
			for gx in range(int(g0.x), int(g1.x) + 1):
				var cell: Array = _cgrid.get(Vector2i(gx, gy), [])
				idx.append_array(cell)
		idx.sort()
	else:
		idx = range(n - first_city)
	for pass_caps: bool in [true, false]:
		for k: int in idx:
			var it: Array = items[first_city + k]
			var kind: int = it[4]
			if (kind == 3) != pass_caps:
				continue
			if not pass_caps and zmax < _city_z0(kind, it[3]):
				break   # дальше — только города мельче: все не видны
			if cull and not wbox.has_point(it[1]):
				continue
			_draw_city(ci, it, map.local_zoom(it[1]), counter, screen)
	FrameProf.add("фишки:города", Time.get_ticks_usec() - t0)


## Издали (масштаб < CLUSTER_Z) фишки одной страны в клетке сетки мира (~CLUSTER_PX
## пикс. экрана; размер клетки — степень двойки, чтобы при плавном масштабе кучки
## не перестраивались каждый кадр) сливаются в одну: число — сумма дивизий,
## сила и организация — средние, знак — рода войск большинства, место — среднее.
const CLUSTER_Z := 0.55
const CLUSTER_PX := 90.0
var _clusters := {}   # (клетка, страна) -> [сумма позиций, дивизий, цвет, шаблон->число, сила·n, орг·n, выделена, без снабжения, своя]


func _cluster_add(it: Array, z: float) -> void:
	var cell := pow(2.0, ceil(log(CLUSTER_PX / z) / log(2.0)))
	var wp: Vector2 = it[1]
	var key := Vector3i(int(floor(wp.x / cell)), int(floor(wp.y / cell)), it[3].to_rgba32())
	var n: int = it[4]
	var c: Array = _clusters.get(key, [])
	if c.is_empty():
		c = [Vector2.ZERO, 0, it[3], {}, 0.0, 0.0, false, 0, it[11]]
		_clusters[key] = c
	c[0] += wp * float(n)
	c[1] += n
	var tp: Dictionary = c[3]
	tp[it[5]] = int(tp.get(it[5], 0)) + n
	c[4] += it[6] * n
	c[5] += it[7] * n
	c[6] = c[6] or it[8]
	c[7] += n if it[10] else 0


func _draw_clusters(z: float, counter: Vector2, font_size: int, screen: Rect2) -> void:
	var used := {}   # клетка экрана -> сколько кучек уже стоит (сдвиг вправо, как в стопке)
	for key in _clusters:
		var c: Array = _clusters[key]
		var n: int = c[1]
		var pos: Vector2 = c[0] / float(n)
		var tp: Dictionary = c[3]
		var best := 0
		var best_n := -1
		for t in tp:
			if tp[t] > best_n:
				best_n = tp[t]
				best = t
		var sk := Vector2i((map.world_to_screen(pos) / counter.x).floor())
		var k: int = used.get(sk, 0)
		used[sk] = k + 1
		_draw_counter([COUNTER, pos, k, c[2], n, best, c[4] / n, c[5] / n, c[6], Color(0, 0, 0, 0), c[7] * 2 > n, c[8]],
			CLUSTER_Z, counter, font_size, screen)
	_clusters.clear()


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
	_occ.append(Rect2(pos, counter + Vector2(0, 9)))
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


func _draw_label(ci: CanvasItem, l: Array, z: float) -> void:
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
	var mg := maxf(vp.size.x, vp.size.y) * DRAW_MARGIN   # запас — как у фишек
	if pos.x + w * 0.5 < -mg or pos.x - w * 0.5 > vp.size.x + mg or pos.y + size < -mg or pos.y - size > vp.size.y + mg:
		return
	var alpha := clampf((1.6 - z) * 2.0, 0.0, 0.75)
	var k := size / LBL_PX
	# строка — серединой заглавных по точке страны (базовая линия ниже на половину
	# высоты заглавных ~0.7 кегля); раньше вся подпись стояла над точкой
	ci.draw_set_transform(pos - Vector2(w * 0.5, -size * 0.35), 0.0, Vector2(k, k))
	# обводка — одна из трёх толщин (4 / 8 / 16 при LBL_PX): каждая толщина — свой
	# растр букв в кэше шрифта; при плавной 4/k (3…17) масштаб каждый раз растрировал
	# новые — фризы при приближении и отдалении на телефоне (ноябрь 2026)
	var ol := 4 if k > 0.7 else (8 if k > 0.35 else 16)
	ci.draw_string_outline(label_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LBL_PX, ol, Color(0.95, 0.92, 0.84, alpha * 0.45))
	ci.draw_string(label_font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LBL_PX, Color(0.10, 0.08, 0.06, alpha))
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Значки городов (как в жанре): столица — золотая звезда в медальоне, крупный
## город (очки 50) — три дома, город (15) — два дома, малые (8, 4) — квадратик.
## Чем мельче город, тем ближе масштаб, с которого он виден; подпись — под знаком.
## Список городов — один раз; столицы — по странам на каждой сборке.
func _add_cities(out: Array, troops: Dictionary) -> void:
	if _cities.is_empty():
		var re := RegEx.create_from_string("\\s+\\d+$")
		var order: Array = []
		for p in world.prov_count:
			if world.p_land[p] and world.p_vp[p] >= 4:
				order.append(p)
		order.sort_custom(func(a, b): return world.p_vp[a] > world.p_vp[b] or (world.p_vp[a] == world.p_vp[b] and a < b))
		for p in order:
			_cities.append([_wp(p), re.sub(world.p_name[p], ""), world.p_vp[p], p])
	var caps := {}
	for nn in world.nations:
		if nn.alive and nn.capital >= 0:
			caps[nn.capital] = true
	# порядок — всегда как в _cities (по убыванию очков): по нему строится
	# сетка мест (_cgrid); столицы — первыми — при отрисовке (_draw_static)
	for c in _cities:
		var kind: int = 3 if caps.has(c[3]) else (2 if c[2] >= 50 else (1 if c[2] >= 15 else 0))
		out.append([CITY, c[0], c[1], c[2], kind, troops.has(c[3])])


var _city_w := {}   # ширина подписи города: «имя|вид» -> пикс.
const CITY_Z := [2.0, 1.25, 0.8, 0.45]
const CITY_R := [4.0, 8.0, 9.5, 10.5]      # радиус знака, пикс.: малый, город, крупный, столица   # с какого масштаба виден знак: малый, город, крупный, столица


const CGRID := 256.0          # клетка сетки городов, единиц мира
var _cgrid := {}              # Vector2i клетки -> номера городов в _cities (по возрастанию)


## Сетка знаков городов по месту (города не двигаются — один раз).
func _build_cgrid(from: int, to: int) -> void:
	for i in range(from, to):
		var key := Vector2i((items[i][1] / CGRID).floor())
		if not _cgrid.has(key):
			_cgrid[key] = []
		_cgrid[key].append(i - from)


## С какого масштаба виден знак города (растёт с убыванием очков — на этом
## держится ранний выход в _draw_static).
## Занятые места подписей городов — по клеткам экрана (раньше — перебор всех
## прямоугольников на каждый знак и подпись).
const OCC_CELL := 64.0


func _occ_hit(r: Rect2) -> bool:
	var a := Vector2i((r.position / OCC_CELL).floor())
	var b := Vector2i((r.end / OCC_CELL).floor())
	for gy in range(a.y, b.y + 1):
		for gx in range(a.x, b.x + 1):
			var cell: Array = _city_occ.get(Vector2i(gx, gy), [])
			for q: Rect2 in cell:
				if q.intersects(r):
					return true
	return false


func _occ_add(r: Rect2) -> void:
	var a := Vector2i((r.position / OCC_CELL).floor())
	var b := Vector2i((r.end / OCC_CELL).floor())
	for gy in range(a.y, b.y + 1):
		for gx in range(a.x, b.x + 1):
			var key := Vector2i(gx, gy)
			if not _city_occ.has(key):
				_city_occ[key] = []
			_city_occ[key].append(r)


static func _city_z0(kind: int, vp: int) -> float:
	return 3.0 if kind == 0 and vp < 8 else CITY_Z[kind]


func _draw_city(ci: CanvasItem, it: Array, z: float, counter: Vector2, screen: Rect2) -> void:
	var kind: int = it[4]
	var z0 := _city_z0(kind, it[3])
	if z < z0:
		return
	var base := map.world_to_screen(it[1])
	if not screen.has_point(base):
		return
	var a := clampf((z - z0) * 6.0, 0.0, 1.0)
	var r: float = CITY_R[kind]
	# знак — в центре провинции; стоят войска (фишка в центре) — слева от фишки
	var c := base
	if it[5] and z >= CLUSTER_Z:
		c = base - Vector2(counter.x * 0.5 + r + 7.0, 0)
	var nr := Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0)
	if kind < 2 and _occ_hit(nr):
		return
	if kind == 0:
		ci.draw_rect(nr.grow(1.5), Color(0.08, 0.07, 0.06, 0.9 * a))
		ci.draw_rect(nr, Color(0.93, 0.90, 0.82, a))
	else:   # знак — из атласа (_city_img)
		var rr: Rect2 = _r_city[kind - 1]
		var hs := rr.size / TEX_K
		ci.draw_texture_rect_region(_atlas, Rect2(c - hs * 0.5, hs), rr, Color(1, 1, 1, a))
	_occ_add(nr)
	# подпись — чуть позже знака, если не налезает на другие
	if z < z0 + 0.25:
		return
	var text: String = it[2]
	var fs: int = [11, 12, 13, 15][kind]
	var f: Font = font if kind == 0 else bold
	var wk := text + "|" + str(kind)
	var tw: float = _city_w.get(wk, -1.0)
	if tw < 0.0:
		tw = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		_city_w[wk] = tw
	var tp := Vector2(c.x - tw * 0.5, c.y + r + 3 + fs * 0.8)
	var tr := Rect2(tp.x - 2, tp.y - fs * 0.8, tw + 4, fs * 1.05)
	if _occ_hit(tr):
		return
	_occ_add(tr)
	var ta := clampf((z - z0 - 0.25) * 6.0, 0.0, 1.0) * a
	ci.draw_string_outline(f, tp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0.08, 0.07, 0.06, 0.8 * ta))
	ci.draw_string(f, tp, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.96, 0.93, 0.85, ta) if kind > 0 else Color(0.90, 0.87, 0.80, ta))


func _rebuild_labels() -> void:
	_labels_ver += 1
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
			_labels.append([center0 * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(px0) * 0.5, maxf(span0.x, span0.y * 0.8), c])
		_fix_label_pos()
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
		_labels.append([center * MapView.SCALE, world.nations[c].name.to_upper(), sqrt(float(b[0])) * 0.5, maxf(span.x, span.y * 0.8), c])
	_fix_label_pos()


## Центр тяжести вытянутой или изогнутой страны бывает на чужой земле
## («НОРВЕГИЯ» над Швецией): тогда подпись — в «глубину» своей территории рядом
## с ним (провинция с наибольшим числом шагов до чужой провинции или моря, ближе
## к центру; не дальше полуразмаха — иначе ушла бы в колонии).
func _fix_label_pos() -> void:
	var need: Array = []
	for i in _labels.size():
		var l: Array = _labels[i]
		var p := world.province_at_pixel(l[0] / MapView.SCALE)
		if p < 0 or world.p_controller[p] != int(l[4]) or world.p_land[p] == 0:
			need.append(i)
	if need.is_empty():
		return
	# глубина: шагов до провинции другого владельца или моря (одним обходом)
	var n := world.prov_count
	var pc := world.p_controller
	var land := world.p_land
	var a_s := world.adj_start
	var a_l := world.adj_list
	var depth := PackedInt32Array()
	depth.resize(n)
	depth.fill(-1)
	var q := PackedInt32Array()
	for p in n:
		if land[p] == 0 or pc[p] < 0:
			continue
		for k in range(a_s[p], a_s[p + 1]):
			var r := a_l[k]
			if land[r] == 0 or pc[r] != pc[p]:
				depth[p] = 0
				q.append(p)
				break
	var head := 0
	while head < q.size():
		var p := q[head]
		head += 1
		for k in range(a_s[p], a_s[p + 1]):
			var r := a_l[k]
			if depth[r] < 0 and land[r] == 1 and pc[r] == pc[p]:
				depth[r] = depth[p] + 1
				q.append(r)
	var cen := world.p_center
	for i in need:
		var l: Array = _labels[i]
		var c: int = l[4]
		var ctr: Vector2 = l[0] / MapView.SCALE
		var lim: float = l[3] / MapView.SCALE * 0.5
		var best := -1
		var best_s := -INF
		for p in n:
			if pc[p] != c or land[p] == 0:
				continue
			var d := cen[p].distance_to(ctr)
			if d > lim:
				continue
			var sc := float(maxi(depth[p], 0)) * 3.0 - d / maxf(lim, 1.0) * 4.0
			if sc > best_s:
				best_s = sc
				best = p
		if best >= 0:
			l[0] = cen[best] * MapView.SCALE


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


## Раскладка флотов и авиации без наложений: плашка ищет ближайшее свободное
## место вокруг своей точки (кольцами по размеру плашки), не налезая на фишки
## дивизий и уже поставленные плашки. Флоты выбираются списком (вкладка флота),
## поэтому сдвиг значка на выбор не влияет.
var _texts_dark: Array = []   # числа на плашках флотов и авиации: [позиция, текст, ширина]
var _occ: Array = []   # занятые в кадре прямоугольники (фишки, флоты, авиация)


var _rings: Array = []   # смещения мест по кольцам (одни и те же — считаются один раз)


func _place_rings() -> Array:
	if _rings.is_empty():
		for ring in 4:
			var cands: Array = [Vector2.ZERO] if ring == 0 else []
			if ring > 0:
				for dy in range(-ring, ring + 1):
					for dx in range(-ring, ring + 1):
						if maxi(absi(dx), absi(dy)) == ring:
							cands.append(Vector2(dx, dy))
				# ближние к точке — первыми (по горизонтали дешевле)
				cands.sort_custom(func(a, b): return a.x * a.x * 0.5 + a.y * a.y < b.x * b.x * 0.5 + b.y * b.y)
			_rings.append(cands)
	return _rings


func _place(c: Vector2, size: Vector2) -> Vector2:
	var step := size + Vector2(4, 4)
	var best := c
	for cands: Array in _place_rings():
		var found := false
		for o: Vector2 in cands:
			var q := c + o * step
			var r := Rect2(q - size * 0.5, size)
			var free := true
			for o2: Rect2 in _occ:
				if o2.intersects(r):
					free = false
					break
			if free:
				best = q
				found = true
				break
		if found:
			break
	_occ.append(Rect2(best - size * 0.5, size))
	return best


## Плашка флота или авиации: светлая подложка цвета страны с тёмной каймой (как у
## фишки дивизии), слева силуэт (свой класс кораблей / тип самолётов), справа число.
## mark — рейдеры (красная полоса снизу), battle — в бою (красная точка).
func _navair_plate(c: Vector2, size: Vector2, col: Color, icon: String, isz: Vector2, num: String, sel: bool, battle: bool, mark: bool) -> void:
	var r := Rect2(c - size * 0.5, size)
	draw_texture_rect_region(_atlas, Rect2(r.position + Vector2(1.5, 2.5), size), _r_shadow)
	draw_texture_rect_region(_atlas, r, _r_plate, col.lightened(0.35))
	if sel:
		draw_texture_rect_region(_atlas, r, _r_sel)
	var ic := Vector2(r.position.x + 5.0 + isz.x * 0.5, c.y)
	if not _navair_draw(icon, Rect2(ic - isz * 0.5, isz), Color(0.09, 0.08, 0.07)):
		var tex := UiStyle.icon("fleet" if icon.begins_with("ship") else "bomber", 64)
		if tex != null:
			draw_texture_rect(tex, Rect2(ic - Vector2(isz.y, isz.y) * 0.5, Vector2(isz.y, isz.y)), false, Color(0.09, 0.08, 0.07))
	var tx := ic.x + isz.x * 0.5 + 2.0
	_texts_dark.append([Vector2(tx, c.y + 5.0), num, r.end.x - tx - 3.0])
	if mark:
		draw_texture_rect_region(_atlas, Rect2(r.position.x + 8, r.end.y - 3.5, size.x - 16, 2.5), _r_white, Color(0.75, 0.15, 0.1))
	if battle:
		draw_circle(r.position + Vector2(2, 2), 5, Color(0.9, 0.2, 0.1), true, -1.0, true)


## Силуэты флотов и авиации: атлас assets/icons/navair.png.bin + navair.json
## (tools/build_navair.py): белый силуэт по альфе, окрашивается при рисовании.
var _navair_atlas: Texture2D
var _navair_rects := {}


func _navair_load() -> void:
	if _navair_atlas != null or not FileAccess.file_exists("res://assets/icons/navair.png.bin"):
		return
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes("res://assets/icons/navair.png.bin")) != OK:
		return
	img.generate_mipmaps()
	_navair_atlas = ImageTexture.create_from_image(img)
	var d = JSON.parse_string(FileAccess.get_file_as_string("res://assets/icons/navair.json"))
	if typeof(d) == TYPE_DICTIONARY:
		for k in d.get("icons", {}):
			var r: Array = d["icons"][k]
			_navair_rects[k] = Rect2(r[0], r[1], r[2], r[3])


## Силуэт в прямоугольник r (с сохранением пропорций, по центру).
func _navair_draw(name: String, r: Rect2, col: Color) -> bool:
	_navair_load()
	if _navair_atlas == null or not _navair_rects.has(name):
		return false
	var src: Rect2 = _navair_rects[name]
	var k := minf(r.size.x / src.size.x, r.size.y / src.size.y)
	var sz := src.size * k
	draw_texture_rect_region(_navair_atlas, Rect2(r.get_center() - sz * 0.5, sz), src, col)
	return true


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
	# с запасом: при сдвиге слой не перерисовывается, пока запас не кончится
	var screen := Rect2(Vector2.ZERO, vp).grow(40.0 + maxf(vp.x, vp.y) * DRAW_MARGIN)
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
