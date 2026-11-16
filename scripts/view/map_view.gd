class_name MapView
extends Node2D
## Карта: спрайт с шейдером провинций, камера и сенсорное управление
## (перетаскивание — сдвиг, два пальца — масштаб, касание — выбор).

signal province_tapped(prov: int)
signal view_changed

const SCALE := 2.0
const MIN_ZOOM := 0.1
const MAX_ZOOM := 5.0
const TAP_SLOP := 14.0

enum MapMode { POLITICAL, TERRAIN, INDUSTRY, FACTIONS, SUPPLY, RESOURCES }
## Цвета ресурсов на карте: нефть, сталь, алюминий, каучук, вольфрам, хром.
## Масштаб для сравнения ресурсов между собой (≈ мировой итог / 100).
const RES_SCALE := [2.6, 5.3, 3.2, 1.4, 0.5, 1.3]
const RES_COLORS := [Color(0.18, 0.15, 0.12), Color(0.36, 0.45, 0.58), Color(0.72, 0.8, 0.86),
	Color(0.25, 0.6, 0.3), Color(0.55, 0.35, 0.7), Color(0.85, 0.55, 0.2)]

var world: World
var id_texture: ImageTexture   # карта провинций 1× (id в RG) — для шейдера
var quad: ColorRect            # прямоугольник во весь буфер: шейдер сам считает проекцию камеры
var camera: Camera2D
var mat: ShaderMaterial
var ctrl_img: Image
var owner_img: Image
var ctrl_tex: ImageTexture
var owner_tex: ImageTexture
const ART_DIR := "res://assets/map/"
const ART_FILES := {"color_w": "colormap_w.jpg", "color_e": "colormap_e.jpg", "normal_w": "normal_w.png", "normal_e": "normal_e.png"}
const ART_PAD := 32.0   # перекрытие половин (tools/build_map_art.py PAD)
var front_img: Image          # фронты армий игрока: rgb — цвет армии, a — роль (шейдер front_tex)
var front_tex: ImageTexture
var _front_hash := 0
var paint_mode := false       # кисть участка фронта: один палец рисует, два — двигают карту
const BRUSH_PX := 16.0        # радиус кисти на экране
signal province_painted(provs: PackedInt32Array, first: bool)
var _paint_last := Vector2.ZERO
var map_mode := MapMode.POLITICAL
# Карта рисуется во внутренний буфер (SubViewport) и только при изменениях:
# сдвиг, масштаб, новый день (палитра), выбор. В остальные кадры экран
# просто показывает готовую картинку — шейдер не пересчитывает каждый пиксель.
var map_vp: SubViewport
var view_sprite: Sprite2D
var lite_vp: SubViewport
var lite_quad: ColorRect
var lite_sprite: Sprite2D
const FADE_OUT := 0.35        # за сколько растворяется сдвигаемый полный кадр, с
const FADE_IN := 0.25         # за сколько проявляется новый полный кадр, с
var _full_alpha := 1.0
var _full_cam := Vector2.ZERO  # камера (позиция, масштаб), с которой нарисован буфер
var _full_zoom := 1.0
var _full_size := Vector2.ONE
var _full_tilt := 0.0
var _lite_cam := Vector2.ZERO
var _lite_zoom := 1.0
var _lite_size := Vector2.ONE
var _fading_in := false
var res_scale := 1.0
var _dirty := true
# Пока карту двигают, она рисуется упрощённо (низкое качество, 50%), а через
# MOTION_SETTLE после остановки — в выбранном качестве (Settings.map_motion_lite).
const MOTION_SETTLE := 0.15
var quality := 2
var _art_ok := false
var _elev_loaded := false
var _winter := -1.0
var motion_lite := true
var _moving := 0.0           # сколько ещё считать карту «в движении», с
var _lite_drawn := false
var _wheel := false          # масштаб колесом/жестом тачпада — тоже движение     # последний кадр карты нарисован упрощённо
var redraws := 0             # сколько раз перерисована карта (для замеров)
var view_version := 0        # растёт при каждом изменении вида (сдвиг, масштаб, наклон)
var palette_version := 0     # растёт при каждом обновлении палитры (смена владельцев)
var _pal_ctrl := PackedInt32Array()   # чем покрашена провинция в палитре (политическая карта)
var _pal_own := PackedInt32Array()
var _pal_mode := -1

var _touches := {}           # index -> Vector2 (экранные координаты)
var _gesture_moved := 0.0
var _gesture_multi := false
var _pinch_dist := 0.0


func setup(w: World) -> void:
	world = w
	_pal_ctrl.clear()
	_pal_own.clear()
	_pal_mode = -1
	for c in get_children():
		c.queue_free()
	id_texture = ImageTexture.create_from_image(world.id_image)
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map.gdshader")
	quad = ColorRect.new()
	quad.material = mat
	quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_vp = SubViewport.new()
	map_vp.disable_3d = true
	map_vp.transparent_bg = false
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(map_vp)
	map_vp.add_child(quad)
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	# второй буфер — упрощённая карта при движении (под основным): основной кадр
	# полного качества сдвигается вместе с картой и плавно растворяется, после
	# остановки новый полный кадр плавно проявляется (без резкой смены графики)
	lite_vp = SubViewport.new()
	lite_vp.disable_3d = true
	lite_vp.transparent_bg = false
	lite_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(lite_vp)
	lite_quad = ColorRect.new()
	lite_quad.material = mat
	lite_quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lite_vp.add_child(lite_quad)
	lite_sprite = Sprite2D.new()
	lite_sprite.centered = false
	lite_sprite.texture = lite_vp.get_texture()
	lite_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	lite_sprite.visible = false
	layer.add_child(lite_sprite)
	view_sprite = Sprite2D.new()
	view_sprite.centered = false
	view_sprite.texture = map_vp.get_texture()
	view_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(view_sprite)
	_full_alpha = 1.0
	RenderingServer.viewport_set_measure_render_time(map_vp.get_viewport_rid(), true)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if not get_viewport().size_changed.is_connected(redraw):
		get_viewport().size_changed.connect(redraw)
	set_res_scale(Settings.RES_SCALES[Settings.map_res()])
	Settings.apply_fps_cap()
	motion_lite = Settings.motion_lite()
	tilt_enabled = Settings.map_tilt()
	mat.set_shader_parameter("world_size", Vector2(world.width, world.height) * SCALE)

	var rows := int(ceil(world.prov_count / 64.0))
	ctrl_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	owner_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	ctrl_tex = ImageTexture.create_from_image(ctrl_img)
	owner_tex = ImageTexture.create_from_image(owner_img)
	front_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	front_tex = ImageTexture.create_from_image(front_img)
	_front_hash = 0
	mat.set_shader_parameter("front_tex", front_tex)
	mat.set_shader_parameter("front_on", false)
	mat.set_shader_parameter("id_tex", id_texture)
	mat.set_shader_parameter("ctrl_tex", ctrl_tex)
	mat.set_shader_parameter("owner_tex", owner_tex)
	# области провинций (обводка средней линией): r + g·256 — номер + 1, 0 — нет
	var st_img := Image.create(64, rows, false, Image.FORMAT_RGBA8)
	var has_st := world.p_state.size() == world.prov_count
	if has_st:
		for p in world.prov_count:
			var sv := world.p_state[p] + 1
			st_img.set_pixel(p % 64, p / 64, Color8(sv & 255, (sv >> 8) & 255, 0, 255))
	mat.set_shader_parameter("state_tex", ImageTexture.create_from_image(st_img))
	mat.set_shader_parameter("has_states", has_st)
	mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(world.height_image))
	if world.terrain_image != null:
		mat.set_shader_parameter("terrain_tex", ImageTexture.create_from_image(world.terrain_image))
		mat.set_shader_parameter("has_terrain", true)
	else:
		mat.set_shader_parameter("has_terrain", false)
	# графика карты в полном разрешении (tools/build_map_art.py; импорт Godot со
	# сжатием в видеопамяти): цвет природных зон и нормали рельефа суши и дна
	# (вдвое подробнее карты, половинами запад/восток с перекрытием ART_PAD)
	var art := world.width == 5632
	for k in ["color_w", "color_e", "normal_w", "normal_e"]:
		art = art and ResourceLoader.exists(ART_DIR + ART_FILES[k])
	if art:
		var cw: Texture2D = load(ART_DIR + ART_FILES["color_w"])
		for k in ART_FILES:
			mat.set_shader_parameter(k, load(ART_DIR + ART_FILES[k]))
		var w2 := float(world.width * 2)
		mat.set_shader_parameter("art_geom", Vector4(w2, w2 * 0.5 - ART_PAD, float(cw.get_width()), float(cw.get_height())))
	mat.set_shader_parameter("has_art", art)
	_art_ok = art
	_load_elev()
	_winter = -1.0
	set_day(world.day)
	if world.detail_image != null:
		mat.set_shader_parameter("detail_tex", ImageTexture.create_from_image(world.detail_image))
		mat.set_shader_parameter("has_detail", true)
	else:
		mat.set_shader_parameter("has_detail", false)
	mat.set_shader_parameter("map_size", Vector2(world.width, world.height))
	# карта провинций для отрисовки вдвое подробнее (tools/build_ids2x.py):
	# границы стран, областей и берег — по векторным контурам, а не лесенкой
	var ids := _ids2() if world.width == 5632 else []
	mat.set_shader_parameter("has_ids2", not ids.is_empty())
	mat.set_shader_parameter("id_k", 2.0 if not ids.is_empty() else 1.0)
	if not ids.is_empty():
		var tw: ImageTexture = ids[0]
		mat.set_shader_parameter("id_w", ids[0])
		mat.set_shader_parameter("id_e", ids[1])
		mat.set_shader_parameter("map_size", Vector2(world.width * 2, world.height * 2))
		mat.set_shader_parameter("ids_half", world.width)
		mat.set_shader_parameter("ids_off", world.width - (tw.get_width() - world.width))
	# нормали волн (tools/build_water.py) — рябь и блики на воде вблизи
	var wpath := "res://data/world1936/water.png.bin"
	var has_w := FileAccess.file_exists(wpath)
	if has_w:
		var wimg := Image.new()
		has_w = wimg.load_png_from_buffer(FileAccess.get_file_as_bytes(wpath)) == OK
		if has_w:
			wimg.generate_mipmaps()
			mat.set_shader_parameter("water_tex", ImageTexture.create_from_image(wimg))
	mat.set_shader_parameter("has_water", has_w)
	# поле расстояний до рек (tools/build_rivers.py) — реки гладкие вблизи
	var rpath := "res://data/world1936/rivers.png.bin"
	var has_r := world.width == 5632 and FileAccess.file_exists(rpath)
	if has_r:
		var rimg := Image.new()
		has_r = rimg.load_png_from_buffer(FileAccess.get_file_as_bytes(rpath)) == OK
		if has_r:
			rimg.convert(Image.FORMAT_RGBA8)
			rimg.generate_mipmaps()
			mat.set_shader_parameter("river_tex", ImageTexture.create_from_image(rimg))
	mat.set_shader_parameter("has_rivers", has_r)
	# поле расстояний до границ провинций (tools/build_sdf.py) — линии границ гладкие
	var sdf := _sdf2() if not ids.is_empty() else []
	mat.set_shader_parameter("has_sdf", not sdf.is_empty())
	if not sdf.is_empty():
		var sw: ImageTexture = sdf[0]
		mat.set_shader_parameter("sdf_w", sdf[0])
		mat.set_shader_parameter("sdf_e", sdf[1])
		mat.set_shader_parameter("sdf_wd", float(sw.get_width()))

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	var vp := get_viewport_rect().size
	var fit := minf(vp.x / (world.width * SCALE), vp.y / (world.height * SCALE))
	camera.zoom = Vector2.ONE * clampf(fit * 1.05, MIN_ZOOM, MAX_ZOOM)
	camera.position = world_size() * 0.5
	update_palette()
	set_quality(Settings.map_quality())
	_on_view_changed()


func world_size() -> Vector2:
	return Vector2(world.width, world.height) * SCALE


func province_world_pos(p: int) -> Vector2:
	return world.p_center[p] * SCALE


# --- Камера: перспектива с наклоном при приближении ---------------------------
# Плоскость карты (единицы мира) под перспективной камерой: центр экрана смотрит
# на camera.position, масштаб в центре — camera.zoom (как у плоской карты), наклон
# от вертикали растёт с приближением (tilt()). Камера южнее точки взгляда и
# смотрит на север. Шейдер карты считает ту же проекцию для каждого пикселя
# (shaders/map.gdshader, cam_*), фишки и стрелки — через world_to_screen.
const TILT_MAX := deg_to_rad(40.0)
const TILT_Z0 := 1.0          # наклон начинается с этого масштаба
const TILT_Z1 := 4.0          # и доходит до TILT_MAX здесь
const FOV_V := deg_to_rad(34.0)   # угол обзора по вертикали
var tilt_enabled := true


func set_tilt_enabled(v: bool) -> void:
	tilt_enabled = v
	if camera != null:
		_on_view_changed()


## Наклон камеры (рад) при масштабе z: 0 — вид сверху.
func tilt_at(z: float) -> float:
	if not tilt_enabled:
		return 0.0
	var t := clampf((z - TILT_Z0) / (TILT_Z1 - TILT_Z0), 0.0, 1.0)
	return TILT_MAX * t * t * (3.0 - 2.0 * t)


func tilt() -> float:
	return tilt_at(camera.zoom.x) if camera != null else 0.0


## Фокусное расстояние, логических пикселей экрана.
func cam_focal() -> float:
	return get_viewport_rect().size.y * 0.5 / tan(FOV_V * 0.5)


func world_to_screen(p: Vector2) -> Vector2:
	var th := tilt()
	var half := get_viewport_rect().size * 0.5
	var z := camera.zoom.x
	if th <= 0.0:
		return (p - camera.position) * z + half
	var f := cam_focal()
	var d := f / z
	var st := sin(th)
	var ct := cos(th)
	# v = p − C, C = цель + d·(0, sin, cos); глубина — вдоль взгляда (0, −sin, −cos)
	var vx := p.x - camera.position.x
	var vy := p.y - camera.position.y - d * st
	var vz := -d * ct
	# за камерой (далеко на юге) — глубина ограничена: точка уходит вниз за
	# край экрана в своём направлении (линии маршрутов не перечёркивают карту)
	var depth := maxf(-vy * st - vz * ct, d * 0.05)
	var up := -vy * ct + vz * st     # проекция на «верх» экрана (0, −cos, sin)
	return Vector2(half.x + f * vx / depth, half.y - f * up / depth)


func screen_to_world(p: Vector2) -> Vector2:
	var th := tilt()
	var half := get_viewport_rect().size * 0.5
	var z := camera.zoom.x
	if th <= 0.0:
		return (p - half) / z + camera.position
	var sc := p - half
	var f := cam_focal()
	var d := f / z
	var st := sin(th)
	var ct := cos(th)
	var den := maxf(ct + st * sc.y / f, 1e-4)
	var tr := d * ct / den
	return Vector2(camera.position.x + tr * sc.x / f, camera.position.y + d * st + tr * (-st + ct * sc.y / f))


## Масштаб (пикселей экрана на единицу мира) в точке мира: при наклоне вдали мельче.
func local_zoom(p: Vector2) -> float:
	var th := tilt()
	var z := camera.zoom.x
	if th <= 0.0:
		return z
	var d := cam_focal() / z
	var vy := p.y - camera.position.y - d * sin(th)
	var depth := -vy * sin(th) + d * cos(th) * cos(th)
	return z * d / maxf(depth, d * 0.05)


func zoom_level() -> float:
	return camera.zoom.x


func center_on(p: int) -> void:
	camera.position = province_world_pos(p)
	_on_view_changed()


func set_selected(prov: int) -> void:
	mat.set_shader_parameter("selected_id", prov)
	redraw()


static var _ids2_cache: Array = []
static var _ids2_imgs: Array = []   # те же половины как Image (для каймы)


## Половины карты провинций 2× (data/world1936/ids2_*.png.bin) как RG8 —
## грузятся один раз за запуск; пусто — файлов нет.
static func _ids2() -> Array:
	if not _ids2_cache.is_empty():
		return _ids2_cache
	var res: Array = []
	for k in ["w", "e"]:
		var path := "res://data/world1936/ids2_%s.png.bin" % k
		if not FileAccess.file_exists(path):
			return []
		var img := Image.new()
		if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
			return []
		img.convert(Image.FORMAT_RG8)
		_ids2_imgs.append(img)
		res.append(ImageTexture.create_from_image(img))
	_ids2_cache = res
	return res


# --- Кайма границ стран (как на картах жанра) ---------------------------------
# Расстояние до границы двух стран на сетке в четверть карты (C++,
# MeowqCore.border_band, миллисекунды) — при смене владельцев; шейдер
# подмешивает цвет страны у её границы, мягко уходя внутрь.
const BAND_STEP := 4      # пикселей карты на клетку сетки каймы
const BAND_PX := 5        # ширина каймы, клеток сетки (~5·4 пикселя карты)
var band_tex: ImageTexture
static var _id_bytes := PackedByteArray()


## Карта провинций 1× из очищенной 2× (tools/build_ids2x.py: у рек провинция
## своего берега, без осколков) — иначе кайма страны строится по исходной 1×,
## где у рек остались полоски чужих провинций, и у берега темнеет пятно.
func _ids1_from_2x() -> Image:
	if _ids2().is_empty() or _ids2_imgs.size() != 2 or world.width != 5632:
		return null
	var half := world.width   # половина сетки 2× — столько же столбцов, сколько у 1×
	var pad: int = (_ids2_imgs[0] as Image).get_width() - half
	var out := Image.create(world.width, world.height, false, Image.FORMAT_RG8)
	for k in 2:
		var src := (_ids2_imgs[k] as Image).get_region(Rect2i(0 if k == 0 else pad, 0, half, world.height * 2))
		src.resize(half / 2, world.height, Image.INTERPOLATE_NEAREST)
		out.blit_rect(src, Rect2i(0, 0, half / 2, world.height), Vector2i(k * half / 2, 0))
	return out


func _update_band() -> void:
	if Native.core == null or not Native.core.has_method("border_band") or world.id_image == null:
		mat.set_shader_parameter("has_band", false)
		return
	if _id_bytes.size() != world.width * world.height * 3:
		var img := _ids1_from_2x()
		if img == null:
			img = world.id_image.duplicate() as Image
		img.convert(Image.FORMAT_RGB8)
		_id_bytes = img.get_data()
	var bw := world.width / BAND_STEP
	var bh := world.height / BAND_STEP
	var band: PackedByteArray = Native.core.border_band(_id_bytes, world.width, world.height, BAND_STEP, world.p_controller, BAND_PX)
	var bimg := Image.create_from_data(bw, bh, false, Image.FORMAT_L8, band)
	if band_tex == null or band_tex.get_width() != bw:
		band_tex = ImageTexture.create_from_image(bimg)
		mat.set_shader_parameter("band_tex", band_tex)
	else:
		band_tex.update(bimg)
	mat.set_shader_parameter("has_band", true)


static var _sdf_cache: Array = []


## Половины поля расстояний до границ (data/world1936/sdf_*.png.bin), L8 с
## mipmap — один раз за запуск; пусто — файлов нет.
static func _sdf2() -> Array:
	if not _sdf_cache.is_empty():
		return _sdf_cache
	var res: Array = []
	for k in ["w", "e"]:
		var path := "res://data/world1936/sdf_%s.png.bin" % k
		if not FileAccess.file_exists(path):
			return []
		var img := Image.new()
		if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
			return []
		img.convert(Image.FORMAT_L8)
		img.generate_mipmaps()
		res.append(ImageTexture.create_from_image(img))
	_sdf_cache = res
	return res


## Фронты армий игрока на карте: провинция -> [роль, цвет] (роль — биты:
## 1 — наш участок, 2 — чужая сторона линии, 4 — выделено кистью, 8 — цель
## атаки). Текстура обновляется, только если отметки изменились.
func set_front(marks: Dictionary) -> void:
	if front_img == null:
		return
	var h := marks.hash()
	if h == _front_hash:
		return
	_front_hash = h
	front_img.fill(Color(0, 0, 0, 0))
	for p in marks:
		var m: Array = marks[p]
		var c: Color = m[1]
		c.a = int(m[0]) / 255.0
		front_img.set_pixel(int(p) % 64, int(p) / 64, c)
	front_tex.update(front_img)
	mat.set_shader_parameter("front_on", not marks.is_empty())
	redraw()


func set_highlight_nation(n: int) -> void:
	mat.set_shader_parameter("highlight_nation", n)
	redraw()


## Перерисовать карту в ближайшем кадре.
func redraw() -> void:
	_dirty = true


## Разрешение буфера карты: доля пикселей экрана (0.5–1); 0 — авто: после
## каждой полной перерисовки подстраивается так, чтобы карта рисовалась на
## видеокарте за ~AUTO_TARGET_MS (масштаб разрешения — самое действенное
## средство против нагрузки и нагрева ГП на телефоне).
const AUTO_TARGET_MS := 14.0
var res_auto := false
var _auto_pending := false     # последняя перерисовка — полная, замер ещё не учтён
var last_cost_ms := 0.0        # оценка цены полной перерисовки карты (для нижней строки)


func set_res_scale(s: float) -> void:
	res_auto = s <= 0.0
	res_scale = 0.75 if res_auto else clampf(s, 0.25, 1.0)
	redraw()


var _base_dt := 0.0          # обычное время кадра без перерисовки карты, с
var _drawn_last := false     # в прошлом кадре карта перерисовывалась полностью


## Подбор разрешения. Где видеокарта отдаёт время отрисовки (Vulkan) — по нему;
## в OpenGL ES (Compatibility) этого замера нет — по времени кадра: сколько кадр
## с полной перерисовкой карты длиннее обычного.
func _auto_adjust(dt: float) -> void:
	var drawn := _drawn_last
	_drawn_last = false
	if not drawn:
		if not _auto_pending:
			_base_dt = dt if _base_dt == 0.0 else lerpf(_base_dt, dt, 0.1)
		return
	if not _auto_pending:
		return
	_auto_pending = false
	var cost := RenderingServer.viewport_get_measured_render_time_gpu(map_vp.get_viewport_rid())
	if cost <= 0.0:
		if _base_dt <= 0.0:
			return
		cost = maxf(0.0, (dt - _base_dt) * 1000.0)
	last_cost_ms = cost
	var old := res_scale
	if cost > AUTO_TARGET_MS * 1.3:
		res_scale = maxf(0.5, res_scale * sqrt(AUTO_TARGET_MS / cost))
	elif cost < AUTO_TARGET_MS * 0.6:
		res_scale = minf(1.0, res_scale * 1.1)
	if absf(res_scale - old) > 0.02:
		redraw()
	else:
		res_scale = old


func _process(dt: float) -> void:
	if res_auto and map_vp != null:
		_auto_adjust(dt)
	if _moving > 0.0:
		_moving -= dt
		if _moving <= 0.0 and _lite_drawn:
			_dirty = true   # остановились — перерисовать в полном качестве
	if map_vp == null:
		return
	if _dirty:
		_dirty = false
		var lite := motion_lite and _moving > 0.0 and (quality > 0 or res_scale > 0.5)
		var was_lite := _lite_drawn
		_lite_drawn = lite
		mat.set_shader_parameter("quality", 0 if lite else quality)
		var rs := 0.5 if lite else res_scale
		var logical := get_viewport_rect().size
		var phys := Vector2(get_window().size)
		var size := Vector2i(maxi(1, int(phys.x * rs)), maxi(1, int(phys.y * rs)))
		var rk := float(size.x) / maxf(1.0, logical.x)  # пикселей буфера на логический
		mat.set_shader_parameter("res_k", rk)
		_cam_uniforms(logical)
		if lite:
			if lite_vp.size != size:
				lite_vp.size = size
			lite_quad.size = Vector2(size)
			lite_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			_lite_cam = camera.position
			_lite_zoom = camera.zoom.x
			_lite_size = Vector2(size)
			lite_sprite.visible = true
			_fading_in = false
		else:
			if map_vp.size != size:
				map_vp.size = size
			quad.size = Vector2(size)
			map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			_full_cam = camera.position
			_full_zoom = camera.zoom.x
			_full_size = Vector2(size)
			_full_tilt = tilt()
			if was_lite:
				_full_alpha = 0.0   # после движения — проявляем новый кадр плавно
				_fading_in = true
			_auto_pending = true
			_drawn_last = true
		redraws += 1
	# прозрачность полного кадра: при движении растворяется, после — проявляется
	# (при наклоне старый кадр сдвигом не совместить с перспективой — сразу)
	if _lite_drawn and _moving > 0.0:
		var fo := FADE_OUT if tilt() <= 0.0 and _full_tilt <= 0.0 else 0.0001
		_full_alpha = maxf(0.0, _full_alpha - dt / fo)
	elif _fading_in:
		_full_alpha = minf(1.0, _full_alpha + dt / FADE_IN)
		if _full_alpha >= 1.0:
			_fading_in = false
	if not motion_lite:
		_full_alpha = 1.0
	if _full_alpha >= 1.0 and not _lite_drawn:
		lite_sprite.visible = false
	view_sprite.modulate.a = _full_alpha
	_place(view_sprite, _full_cam, _full_zoom, _full_size)
	if lite_sprite.visible:
		_place(lite_sprite, _lite_cam, _lite_zoom, _lite_size)


func _cam_uniforms(logical: Vector2) -> void:
	mat.set_shader_parameter("cam_pos", camera.position)
	mat.set_shader_parameter("cam_zoom", camera.zoom.x)
	mat.set_shader_parameter("cam_tilt", tilt())
	mat.set_shader_parameter("cam_f", cam_focal())
	mat.set_shader_parameter("scr_size", logical)


## Показ буфера, нарисованного с камеры (c_b, z_b), при текущей камере: старый
## кадр сдвигается и масштабируется вместе с картой, пока не придёт новый.
func _place(spr: Sprite2D, c_b: Vector2, z_b: float, size: Vector2) -> void:
	var logical := get_viewport_rect().size
	var half := logical * 0.5
	var z_n := camera.zoom.x
	var r := z_n / maxf(1e-6, z_b)
	spr.scale = logical / size * r
	spr.position = half - half * r + (c_b - camera.position) * z_n


## Время отрисовки последнего кадра на видеокарте (мс): карта и весь экран.
func gpu_ms() -> Vector2:
	if map_vp == null:
		return Vector2.ZERO
	return Vector2(RenderingServer.viewport_get_measured_render_time_gpu(map_vp.get_viewport_rid()),
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))


## Качество карты: 0 — низкое, 1 — среднее, 2 — высокое (см. shaders/map.gdshader).
## Высоты вдвое подробнее (горы вблизи): ~40 МБ видеопамяти — грузим только при
## высоком качестве и только раз (assets/map/elev_*.png, tools/etopo.py).
func _load_elev() -> void:
	if _elev_loaded or not _art_ok or quality < 2 or mat == null:
		return
	if not (ResourceLoader.exists(ART_DIR + "elev_w.png") and ResourceLoader.exists(ART_DIR + "elev_e.png")):
		return
	_elev_loaded = true
	mat.set_shader_parameter("elev_w", load(ART_DIR + "elev_w.png"))
	mat.set_shader_parameter("elev_e", load(ART_DIR + "elev_e.png"))
	mat.set_shader_parameter("has_elev", true)


## Сезон для снега в горах: зима северного полушария 0…1, пик ~10 февраля (снег
## копится с запаздыванием), минимум ~10 августа. Перерисовка — при заметной смене.
func set_day(day: int) -> void:
	if mat == null:
		return
	var doy := fmod(float(day), 365.2425)
	var raw := 0.5 + 0.5 * cos(TAU * (doy - 41.0) / 365.2425)
	var w := smoothstep(0.15, 0.85, raw)
	if absf(w - _winter) < 0.03 and _winter >= 0.0:
		return
	_winter = w
	mat.set_shader_parameter("winter", w)
	redraw()


func set_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	_load_elev()
	if mat != null:
		mat.set_shader_parameter("quality", quality)
		redraw()


func set_map_mode(m: int) -> void:
	map_mode = m
	mat.set_shader_parameter("show_occupation", m == MapMode.POLITICAL)
	mat.set_shader_parameter("terrain_mode", m == MapMode.TERRAIN)
	update_palette()
	redraw()


func update_palette() -> void:
	if world == null:
		return
	# политическая карта: перекрашиваем только провинции со сменой владельца
	# (полный проход по всем — при смене режима или первом показе)
	var incremental := map_mode == MapMode.POLITICAL and _pal_mode == MapMode.POLITICAL \
		and _pal_ctrl.size() == world.prov_count
	_pal_mode = map_mode
	if map_mode == MapMode.POLITICAL and _pal_ctrl.size() != world.prov_count:
		_pal_ctrl.resize(world.prov_count)
		_pal_own.resize(world.prov_count)
	var res_at := {}
	var max_res := 0.1
	if map_mode == MapMode.RESOURCES:
		for i in world.res_prov.size():
			res_at[world.res_prov[i]] = i
			var tot := 0.0
			for r in Economy.RES_COUNT:
				tot += world.res_val[i * Economy.RES_COUNT + r] / RES_SCALE[r]
			max_res = maxf(max_res, tot)
	var max_ind := 1
	if map_mode == MapMode.INDUSTRY:
		for p in world.prov_count:
			max_ind = maxi(max_ind, world.p_civ[p] + world.p_mil[p])
	var pc := world.p_controller
	var po := world.p_owner
	var changed := 0
	for p in world.prov_count:
		if incremental:
			if _pal_ctrl[p] == pc[p] and _pal_own[p] == po[p]:
				continue
		changed += 1
		if map_mode == MapMode.POLITICAL:
			_pal_ctrl[p] = pc[p]
			_pal_own[p] = po[p]
		var x := p % 64
		var y := p / 64
		if world.p_land[p] == 0:
			ctrl_img.set_pixel(x, y, Color(0, 0, 0, 0))
			owner_img.set_pixel(x, y, Color(0, 0, 0, 0))
			continue
		var c := world.p_controller[p]
		var o := world.p_owner[p]
		var col: Color = world.nations[c].color
		match map_mode:
			MapMode.TERRAIN:
				col = World.TERRAIN_COLORS[world.p_terrain[p]]
			MapMode.SUPPLY:
				# снабжение игрока: зелёный — хорошо, красный — далеко или мало дорог
				var me := world.player_nation()
				col = Color(0.55, 0.55, 0.52)
				if me >= 0 and world.supply_dist.size() > me and not world.supply_dist[me].is_empty():
					var dist: PackedInt32Array = world.supply_dist[me]
					var h: int = dist[p]
					if h >= 0:
						var reach := 1.0 if h <= 5 else maxf(0.35, 1.0 - (h - 5) * 0.06)
						var v := reach * minf(1.0, world.p_supply_cap[p] / 4.0)
						col = Color(0.85, 0.25, 0.2).lerp(Color(0.3, 0.75, 0.3), v)
					elif world.ally[me * world.nation_count + c] == 1:
						col = Color(0.35, 0.1, 0.1)
			MapMode.FACTIONS:
				var r := Diplomacy.root(world, c)
				var f: int = world.nations[r].faction
				col = world.factions[f].color if f >= 0 else Color(0.62, 0.6, 0.55)
				if world.nations[c].overlord >= 0 and f < 0:
					col = world.nations[r].color
			MapMode.RESOURCES:
				# главный ресурс провинции, насыщенность — по объёму
				col = Color(0.86, 0.84, 0.78)
				if res_at.has(p):
					var i: int = res_at[p]
					var best := 0
					var bv := -1.0
					var tot := 0.0
					for r in Economy.RES_COUNT:
						var v: float = world.res_val[i * Economy.RES_COUNT + r] / RES_SCALE[r]
						tot += v
						if v > bv:
							bv = v
							best = r
					col = Color(0.86, 0.84, 0.78).lerp(RES_COLORS[best], 0.45 + 0.55 * sqrt(tot / max_res))
			MapMode.INDUSTRY:
				var v := float(world.p_civ[p] + world.p_mil[p]) / max_ind
				var mil_share := float(world.p_mil[p]) / maxf(1.0, world.p_civ[p] + world.p_mil[p])
				col = Color(0.85, 0.85, 0.8).lerp(Color(0.85, 0.35, 0.2).lerp(Color(0.3, 0.45, 0.8), 1.0 - mil_share), sqrt(v))
		col.a = (c + 1) / 255.0
		ctrl_img.set_pixel(x, y, col)
		var oc: Color = world.nations[o].color
		oc.a = (o + 1) / 255.0
		owner_img.set_pixel(x, y, oc)
	world.palette_dirty = false
	if changed == 0:
		return   # владельцы не менялись — ни текстуры, ни перерисовки
	ctrl_tex.update(ctrl_img)
	_update_band()
	owner_tex.update(owner_img)
	palette_version += 1
	redraw()




# --- Ввод ----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if camera == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _touches.is_empty():
				_gesture_moved = 0.0
				_gesture_multi = false
			_touches[event.index] = event.position
			if _touches.size() >= 2:
				_gesture_multi = true
				_pinch_dist = _pinch_distance()
			elif paint_mode:
				_paint_last = event.position
				_paint_at(event.position, true)
		else:
			var was_tap: bool = _touches.size() == 1 and not _gesture_multi and _gesture_moved < TAP_SLOP
			_touches.erase(event.index)
			if _touches.size() >= 2:
				_pinch_dist = _pinch_distance()
			if was_tap:
				_tap(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if not _touches.has(event.index):
			return
		var prev: Vector2 = _touches[event.index]
		_touches[event.index] = event.position
		_gesture_moved += (event.position - prev).length()
		if _touches.size() == 1:
			if paint_mode and not _gesture_multi:
				# кисть: провинции вдоль пути пальца (шаг — полрадиуса кисти)
				var seg: Vector2 = event.position - _paint_last
				var steps := maxi(1, ceili(seg.length() / (BRUSH_PX * 0.5)))
				for i in steps:
					_paint_at(_paint_last + seg * float(i + 1) / steps, false)
				_paint_last = event.position
			elif not paint_mode:
				camera.position += screen_to_world(prev) - screen_to_world(event.position)
				_on_view_changed()
		elif _touches.size() >= 2:
			var d := _pinch_distance()
			if _pinch_dist > 0.0:
				_zoom_at(_pinch_center(), d / _pinch_dist)
			_pinch_dist = d
			# двумя пальцами карта и сдвигается (в режиме кисти — только так)
			camera.position += (screen_to_world(prev) - screen_to_world(event.position)) * 0.5
			_on_view_changed()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, 1.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / 1.15)
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
	elif event is InputEventPanGesture:
		camera.position += event.delta * 8.0 / camera.zoom.x
		_wheel = true
		_on_view_changed()


func _pinch_distance() -> float:
	var pts: Array = _touches.values()
	return (pts[0] - pts[1]).length() if pts.size() >= 2 else 0.0


func _pinch_center() -> Vector2:
	var pts: Array = _touches.values()
	return (pts[0] + pts[1]) * 0.5 if pts.size() >= 2 else Vector2.ZERO


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_wheel = true
	var before := screen_to_world(screen_pos)
	camera.zoom = Vector2.ONE * clampf(camera.zoom.x * factor, MIN_ZOOM, MAX_ZOOM)
	camera.force_update_scroll()
	var after := screen_to_world(screen_pos)
	camera.position += before - after
	_on_view_changed()


## Провинции суши под кистью (центр и 8 точек по кругу) → province_painted.
func _paint_at(screen_pos: Vector2, first: bool) -> void:
	var res := PackedInt32Array()
	for k in 9:
		var off := Vector2.ZERO if k == 0 else Vector2.from_angle(TAU * (k - 1) / 8.0) * BRUSH_PX
		var wp := screen_to_world(screen_pos + off) / SCALE
		var p := world.province_at_pixel(wp)
		if p >= 0 and world.p_land[p] == 1 and not res.has(p):
			res.append(p)
	if not res.is_empty() or first:
		province_painted.emit(res, first)


func _tap(screen_pos: Vector2) -> void:
	var wp := screen_to_world(screen_pos) / SCALE
	var p := world.province_at_pixel(wp)
	if p >= 0:
		province_tapped.emit(p)


func _on_view_changed() -> void:
	# не даём увести карту за край экрана, если она шире экрана
	var ws := world_size()
	var half := get_viewport_rect().size * 0.5 / camera.zoom.x
	var lo := Vector2(minf(half.x, ws.x * 0.5), minf(half.y, ws.y * 0.5))
	var hi := Vector2(maxf(ws.x - half.x, ws.x * 0.5), maxf(ws.y - half.y, ws.y * 0.5))
	camera.position = camera.position.clamp(lo, hi)
	# при наклоне верх экрана смотрит дальше на север: не заглядывать за край карты
	if tilt() > 0.0:
		for _i in 2:
			var top := screen_to_world(Vector2(half.x * camera.zoom.x, 0.0))
			if top.y >= 0.0:
				break
			camera.position.y = minf(camera.position.y - top.y, hi.y)
	if not _touches.is_empty() or _wheel:
		_moving = MOTION_SETTLE
	_wheel = false
	view_version += 1
	redraw()
	view_changed.emit()
