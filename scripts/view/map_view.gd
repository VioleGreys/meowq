class_name MapView
extends Node2D
## Карта: спрайт с шейдером провинций, камера и сенсорное управление
## (перетаскивание — сдвиг, два пальца — масштаб, касание — выбор).

signal province_tapped(prov: int)
signal view_changed

const SCALE := 2.0
const MIN_ZOOM := 0.1
const MAX_ZOOM := 8.0   # было 5: постройки вблизи как в жанре (дом ~25 пикс. экрана)
const TAP_SLOP := 14.0

enum MapMode { POLITICAL, TERRAIN, INDUSTRY, FACTIONS, SUPPLY, RESOURCES }
## Цвета ресурсов на карте: нефть, сталь, алюминий, каучук, вольфрам, хром.
## Масштаб для сравнения ресурсов между собой (≈ мировой итог / 100).
const RES_SCALE := [2.6, 5.3, 3.2, 1.4, 0.5, 1.3]
const RES_COLORS := [Color(0.18, 0.15, 0.12), Color(0.36, 0.45, 0.58), Color(0.72, 0.8, 0.86),
	Color(0.25, 0.6, 0.3), Color(0.55, 0.35, 0.7), Color(0.85, 0.55, 0.2)]

var world: World
var quad: ColorRect            # прямоугольник во весь буфер: шейдер сам считает проекцию камеры
var camera: Camera2D
var mat: ShaderMaterial
var ctrl_img: Image
var owner_img: Image
# палитры провинций — одной текстурой (шейдеру на телефоне не хватает текстурных
# блоков: не больше 8 текстур, см. shaders/map.gdshader): разделы по _pal_rows строк —
# 0 контролёр, 1 владелец, 2 область, 3 фронт
var pal_img: Image
var pal_tex: ImageTexture
var _pal_rows := 1
const ART_DIR := "res://assets/map/"
const ART_FILES := {"color_w": "colormap_w.webp", "color_e": "colormap_e.webp", "normal_w": "normal_w.png", "normal_e": "normal_e.png"}
const ART_PAD := 32.0   # перекрытие половин (tools/build_map_art.py PAD)
var front_img: Image          # фронты армий игрока: rgb — цвет армии, a — роль (раздел 3 палитры pal_tex)
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
var snap_vp: SubViewport
var cmats: Array = []          # шейдер карты для двух буферов кэша движения
# заготовки неподвижной части (MapBake): те же кадры шейдером map_baked — когда
# все нужные тайлы в атласе; иначе — живым (mat, cmats), тайлы готовятся фоном
var mat_b: ShaderMaterial
var cmats_b: Array = []
var bake: MapBake
var _bake_off := false
var _full_baked := false       # кадр экрана нарисован с заготовками (частичные — так же)
var _screen_keys := PackedInt64Array()
var _bake_still := 0           # кадров подряд, когда карта стоит
var baked_draws := 0           # для замеров: кадров и полос с заготовками
var live_draws := 0
var dmat: ShaderMaterial       # вывод кэша на экран (map_motion.gdshader)
var cache_rect: ColorRect
var snap_sprite: Sprite2D
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
var _full_q := -1
var res_scale := 1.0
var _dirty := true
# Пока карту двигают, она рисуется упрощённо (низкое качество, 50%), а через
# MOTION_SETTLE после остановки — в выбранном качестве (Settings.map_motion_lite).
const MOTION_SETTLE := 0.15
var quality := 2
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
	if _band_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_band_task)
		_band_task = -1
	_band_pending = PackedInt32Array()
	_band_again = false
	world = w
	_pal_ctrl.clear()
	_pal_own.clear()
	_pal_mode = -1
	for c in get_children():
		c.queue_free()
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map.gdshader")
	cmats = []   # тот же шейдер для двух буферов кэша движения (свои параметры камеры)
	for i in 2:
		var cm := ShaderMaterial.new()
		cm.shader = mat.shader
		cmats.append(cm)
	mat_b = ShaderMaterial.new()
	mat_b.shader = load("res://shaders/map_baked.gdshader")
	cmats_b = []
	for i in 2:
		var cm := ShaderMaterial.new()
		cm.shader = mat_b.shader
		cmats_b.append(cm)
	bake = MapBake.new()
	add_child(bake)
	bake.setup(self, {})
	_bake_off = "--nobake" in OS.get_cmdline_user_args()
	_full_baked = false
	quad = ColorRect.new()
	quad.material = mat
	quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_vp = SubViewport.new()
	map_vp.disable_3d = true
	map_vp.transparent_bg = false
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# буфер не очищается: после смены владельцев перерисовывается только область
	# изменившихся провинций поверх прежнего кадра (redraw_provs). CLEAR_MODE_NEVER
	# в Compatibility (GLES3) не показывался на экране — ONCE (очистка только при создании)
	map_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
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
	# кэш движения: плоский закольцованный буфер полного качества (вид сверху);
	# при движении экран показывает его проекцию с текущей камерой (map_motion)
	_cb = []
	_cf = 0
	for i in 2:
		var b := CacheBuf.new()
		b.vp = SubViewport.new()
		b.vp.disable_3d = true
		b.vp.transparent_bg = false
		b.vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
		b.vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(b.vp)
		b.cmat = cmats[i]
		b.cmat_b = cmats_b[i]
		_cb.append(b)
	dmat = ShaderMaterial.new()
	dmat.shader = load("res://shaders/map_motion.gdshader")
	cache_rect = ColorRect.new()
	cache_rect.material = dmat
	cache_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cache_rect.visible = false
	layer.add_child(cache_rect)
	_c_build_n = 0
	dmat.set_shader_parameter("cache_tex", _cb[0].vp.get_texture())
	_warm = 3
	view_sprite = Sprite2D.new()
	view_sprite.centered = false
	view_sprite.texture = map_vp.get_texture()
	view_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(view_sprite)
	# снимок прежнего кадра на смену сезона: лежит поверх, пока новый кадр
	# рисуется полосами под ним, потом плавно тает (см. set_day)
	snap_vp = SubViewport.new()
	snap_vp.disable_3d = true
	snap_vp.transparent_bg = false
	snap_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(snap_vp)
	var snap_src := TextureRect.new()
	snap_src.texture = map_vp.get_texture()
	snap_src.mouse_filter = Control.MOUSE_FILTER_IGNORE
	snap_vp.add_child(snap_src)
	snap_sprite = Sprite2D.new()
	snap_sprite.centered = false
	snap_sprite.texture = snap_vp.get_texture()
	snap_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	snap_sprite.visible = false
	layer.add_child(snap_sprite)
	_full_alpha = 1.0
	RenderingServer.viewport_set_measure_render_time(map_vp.get_viewport_rid(), true)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if not get_viewport().size_changed.is_connected(redraw):
		get_viewport().size_changed.connect(redraw)
	set_res_scale(Settings.RES_SCALES[Settings.map_res()])
	Settings.apply_fps_cap()
	motion_lite = Settings.motion_lite()
	tilt_enabled = Settings.map_tilt()
	_param("world_size", Vector2(world.width, world.height) * SCALE)

	var rows := int(ceil(world.prov_count / 64.0))
	_pal_rows = rows
	ctrl_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	owner_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	front_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	pal_img = Image.create(64, rows * 4, false, Image.FORMAT_RGBA8)
	_front_hash = 0
	# области провинций (обводка средней линией): r + g·256 — номер + 1, 0 — нет
	var st_img := Image.create(64, rows, false, Image.FORMAT_RGBA8)
	var has_st := world.p_state.size() == world.prov_count
	# b — класс города провинции для застройки вблизи (шейдер town_d): 3 — столица и
	# от 1 млн (очки победы ≥ 15), 2 — от 400 тыс. (≥ 8), 1 — от 150 тыс. (≥ 4), 0 — нет
	var has_vp := world.p_vp.size() == world.prov_count
	for p in world.prov_count:
		var sv := (world.p_state[p] + 1) if has_st else 0
		var vp: int = world.p_vp[p] if has_vp else 0
		var cls := 3 if vp >= 15 else 2 if vp >= 8 else 1 if vp >= 4 else 0
		st_img.set_pixel(p % 64, p / 64, Color8(sv & 255, (sv >> 8) & 255, cls, 255))
	pal_img.blit_rect(st_img, Rect2i(0, 0, 64, rows), Vector2i(0, 2 * rows))
	pal_tex = ImageTexture.create_from_image(pal_img)
	_param("pal_tex", pal_tex)
	_param("pal_rows", rows)
	_param("front_on", false)
	_param("has_states", has_st)
	# графика карты в полном разрешении (tools/build_map_art.py; импорт Godot со
	# сжатием в видеопамяти): цвет природных зон (a — высоты, tools/etopo.py) и
	# нормали рельефа суши и дна (вдвое подробнее карты, половинами запад/восток с
	# перекрытием ART_PAD) — массивами из двух слоёв, собранными здесь (импорт
	# массивом растягивает слои до 8192²)
	var art := world.width == 5632
	for k in ["color_w", "color_e", "normal_w", "normal_e"]:
		art = art and ResourceLoader.exists(ART_DIR + ART_FILES[k])
	var tex_c: Texture2DArray = null
	var tex_n: Texture2DArray = null
	if art:
		var cw: Texture2D = load(ART_DIR + ART_FILES["color_w"])
		var w2 := float(world.width * 2)
		_param("art_geom", Vector4(w2, w2 * 0.5 - ART_PAD, float(cw.get_width()), float(cw.get_height())))
		tex_c = _layers([cw.get_image(), (load(ART_DIR + ART_FILES["color_e"]) as Texture2D).get_image()])
		tex_n = _layers([(load(ART_DIR + ART_FILES["normal_w"]) as Texture2D).get_image(),
			(load(ART_DIR + ART_FILES["normal_e"]) as Texture2D).get_image()])
		art = tex_c != null and tex_n != null
	if art:
		_param("color_tex", tex_c)
		_param("normal_tex", tex_n)
	_param("has_art", art)
	_param("has_elev", art)
	_winter = -1.0
	_selected = -1
	_front_marks = {}
	strips = 4 if OS.has_feature("mobile") else 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--strips="):
			strips = maxi(1, int(a.get_slice("=", 1)))
	set_day(world.day)
	_param("map_size", Vector2(world.width, world.height))
	# карта провинций для отрисовки вдвое подробнее (tools/build_ids2x.py):
	# границы стран, областей и берег — по векторным контурам, а не лесенкой;
	# без неё — карта 1× в обоих слоях (всё — «запад»)
	var ids := _ids2() if world.width == 5632 else []
	_param("has_ids2", not ids.is_empty())
	_param("id_k", 2.0 if not ids.is_empty() else 1.0)
	if not ids.is_empty():
		var tw: int = (_ids2_imgs[0] as Image).get_width()
		_param("ids_tex", ids[0])
		_param("map_size", Vector2(world.width * 2, world.height * 2))
		_param("ids_half", world.width)
		_param("ids_off", world.width - (tw - world.width))
	else:
		var id1 := world.id_image.duplicate() as Image
		id1.convert(Image.FORMAT_RG8)
		_param("ids_tex", _layers([id1, id1]))
		_param("ids_half", world.width)
		_param("ids_off", 0)
	# плитки: нормали волн (tools/build_water.py) и фактура местности вблизи — массивом
	var wpath := "res://data/world1936/water.png.bin"
	var wimg := Image.new()
	var has_w := FileAccess.file_exists(wpath) and wimg.load_png_from_buffer(FileAccess.get_file_as_bytes(wpath)) == OK
	var has_d := world.detail_image != null
	var dimg: Image = (world.detail_image.duplicate() as Image) if has_d else null
	if not has_w:
		wimg = Image.create(512, 512, false, Image.FORMAT_RGBA8)
		wimg.fill(Color(0.5, 0.5, 1.0))
	if not has_d:
		dimg = Image.create(512, 512, false, Image.FORMAT_RGBA8)
		dimg.fill(Color(0.5, 0.5, 0.5, 0.5))
	# атлас построек и деревьев (tools/render_sprites.gd) — третьим слоем
	var spath := "res://data/world1936/sprites.png.bin"
	var simg := Image.new()
	var has_s := FileAccess.file_exists(spath) and simg.load_png_from_buffer(FileAccess.get_file_as_bytes(spath)) == OK
	# атлас — шесть слоёв 512×512 один под другим (512×3072)
	var slayers: Array = []
	has_s = has_s and simg.get_width() == 512 and simg.get_height() == 3072
	for l in 6:
		var li: Image
		if has_s:
			simg.convert(Image.FORMAT_RGBA8)
			li = simg.get_region(Rect2i(0, l * 512, 512, 512))
		else:
			li = Image.create(512, 512, false, Image.FORMAT_RGBA8)
		slayers.append(li)
	# покрытия дорог и мостов (ambientCG, CC0): брусчатка, грунт, камень — слои 8–10
	var rpath2 := "res://data/world1936/road_tex.png.bin"
	var rimg2 := Image.new()
	var has_rt := FileAccess.file_exists(rpath2) and rimg2.load_png_from_buffer(FileAccess.get_file_as_bytes(rpath2)) == OK \
		and rimg2.get_width() == 512 and rimg2.get_height() == 1536
	for l in 3:
		var li: Image
		if has_rt:
			rimg2.convert(Image.FORMAT_RGBA8)
			li = rimg2.get_region(Rect2i(0, l * 512, 512, 512))
		else:
			li = Image.create(512, 512, false, Image.FORMAT_RGBA8)
			li.fill(Color(0.6, 0.58, 0.54))
		slayers.append(li)
	_param("has_road_tex", has_rt)
	for im: Image in [wimg, dimg] + slayers:
		im.convert(Image.FORMAT_RGBA8)
		if im.get_width() != 512 or im.get_height() != 512:
			im.resize(512, 512, Image.INTERPOLATE_BILINEAR)
		im.generate_mipmaps()
	_param("tile_tex", _layers([wimg, dimg] + slayers))
	_param("has_sprites", has_s)
	_param("has_water", has_w)
	_param("has_detail", has_d)
	# рельеф (relief.png.bin) и поле расстояний до рек (tools/build_rivers.py) —
	# массивом из двух слоёв одного размера; без поля рек — рельеф в обоих
	var rel := world.height_image.duplicate() as Image
	rel.convert(Image.FORMAT_RGBA8)
	var rpath := "res://data/world1936/rivers.png.bin"
	var rimg := Image.new()
	var has_r := world.width == 5632 and FileAccess.file_exists(rpath) \
		and rimg.load_png_from_buffer(FileAccess.get_file_as_bytes(rpath)) == OK \
		and rimg.get_width() == rel.get_width() and rimg.get_height() == rel.get_height()
	if not has_r:
		rimg = rel.duplicate() as Image
	rimg.convert(Image.FORMAT_RGBA8)
	# покров суши (tools/build_cover.py): лес, болото, застройка, рис — третьим слоём
	var cpath := "res://data/world1936/cover.png.bin"
	var cimg := Image.new()
	var has_c := world.width == 5632 and FileAccess.file_exists(cpath) \
		and cimg.load_png_from_buffer(FileAccess.get_file_as_bytes(cpath)) == OK \
		and cimg.get_width() == rel.get_width() and cimg.get_height() == rel.get_height()
	if not has_c:
		cimg = Image.create(rel.get_width(), rel.get_height(), false, Image.FORMAT_RGBA8)
	cimg.convert(Image.FORMAT_RGBA8)
	rel.generate_mipmaps()
	rimg.generate_mipmaps()
	cimg.generate_mipmaps()
	_param("base_tex", _layers([rel, rimg, cimg]))
	_param("has_rivers", has_r)
	_param("has_cover", has_c)
	# поле расстояний до границ провинций (tools/build_sdf.py) — линии границ гладкие
	var sdf := _sdf2() if not ids.is_empty() else []
	_param("has_sdf", not sdf.is_empty())
	if not sdf.is_empty():
		_param("sdf_tex", sdf[0])
		_param("sdf_wd", float(sdf[1]))

	# замеры: -- --mapoff=art,rivers,sdf,... — выключить части шейдера (has_*)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mapoff="):
			for k in arg.split("=")[1].split(","):
				_param("has_" + k, false)
			_bake_off = true
	_bake_push()
	bake.warm(mat_b)
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


var _selected := -1


## Выбор провинции: перерисовать только прежнюю и новую выбранную с их областями
## (обводка области — по границе области).
func set_selected(prov: int) -> void:
	_param("selected_id", prov)
	var old := _selected
	_selected = prov
	if old == prov:
		return
	var sts := {}
	var provs := PackedInt32Array()
	for q in [old, prov]:
		if q >= 0 and q < world.prov_count:
			provs.append(q)
			if world.p_state.size() == world.prov_count and world.p_state[q] >= 0:
				sts[world.p_state[q]] = true
	if not sts.is_empty():
		for p in world.prov_count:
			if sts.has(world.p_state[p]):
				provs.append(p)
	redraw_provs(provs)


static var _ids2_cache: Array = []
static var _ids2_imgs: Array = []   # те же половины как Image (для каймы)


## Половины карты провинций 2× (data/world1936/ids2_*.png.bin) как RG8 —
## грузятся один раз за запуск; [массив из двух слоёв] или пусто — файлов нет.
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
		res.append(img)
	_ids2_imgs = res
	var arr := _layers(res)
	if arr == null:
		return []
	_ids2_cache = [arr]
	return _ids2_cache


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


# Кайма после смены владельцев — в фоновом потоке (на телефоне расчёт по всей
# сетке занимал главный поток десятки мс): область перерисовывается, когда
# кайма готова, — цвет и кайма меняются вместе.
var _band_task := -1
var _band_out := PackedByteArray()
var _band_pending := PackedInt32Array()   # провинции, ждущие перерисовки
var _band_again := false


func _band_job(ctrl: PackedInt32Array) -> void:
	_band_out = Native.core.border_band(_id_bytes, world.width, world.height, BAND_STEP, ctrl, BAND_PX)


func _band_async(provs: PackedInt32Array) -> void:
	_band_pending.append_array(provs)
	if Native.core == null or not Native.core.has_method("border_band") or _id_bytes.size() != world.width * world.height * 3:
		_update_band()
		redraw_provs(_band_pending)
		_band_pending = PackedInt32Array()
		return
	if _band_task >= 0:
		_band_again = true   # посчитаем ещё раз по свежим владельцам, когда этот закончит
		return
	_band_task = WorkerThreadPool.add_task(_band_job.bind(world.p_controller.duplicate()))


func _band_poll() -> void:
	if _band_task < 0 or not WorkerThreadPool.is_task_completed(_band_task):
		return
	WorkerThreadPool.wait_for_task_completion(_band_task)
	_band_task = -1
	var bw := world.width / BAND_STEP
	var bh := world.height / BAND_STEP
	if _band_out.size() == bw * bh:
		var bimg := Image.create_from_data(bw, bh, false, Image.FORMAT_L8, _band_out)
		if band_tex == null or band_tex.get_width() != bw:
			band_tex = ImageTexture.create_from_image(bimg)
			_param("band_tex", band_tex)
		else:
			band_tex.update(bimg)
		_param("has_band", true)
	redraw_provs(_band_pending)
	_band_pending = PackedInt32Array()
	if _band_again:
		_band_again = false
		_band_task = WorkerThreadPool.add_task(_band_job.bind(world.p_controller.duplicate()))


func _update_band() -> void:
	if Native.core == null or not Native.core.has_method("border_band") or world.id_image == null:
		_param("has_band", false)
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
		_param("band_tex", band_tex)
	else:
		band_tex.update(bimg)
	_param("has_band", true)


static var _sdf_cache: Array = []


## Половины поля расстояний до границ (data/world1936/sdf_*.png.bin), L8 с
## mipmap — один раз за запуск: [массив из двух слоёв, ширина слоя]; пусто — файлов нет.
static func _sdf2() -> Array:
	if not _sdf_cache.is_empty():
		return _sdf_cache
	var imgs: Array = []
	for k in ["w", "e"]:
		var path := "res://data/world1936/sdf_%s.png.bin" % k
		if not FileAccess.file_exists(path):
			return []
		var img := Image.new()
		if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
			return []
		img.convert(Image.FORMAT_L8)
		img.generate_mipmaps()
		imgs.append(img)
	var arr := _layers(imgs)
	if arr == null:
		return []
	_sdf_cache = [arr, (imgs[0] as Image).get_width()]
	return _sdf_cache


## Массив текстур из слоёв одного размера и формата (null — не вышло).
static func _layers(imgs: Array) -> Texture2DArray:
	var typed: Array[Image] = []
	for im in imgs:
		typed.append(im)
	var arr := Texture2DArray.new()
	if arr.create_from_images(typed) != OK:
		push_error("Карта: не собрать массив текстур (%d слоёв)" % typed.size())
		return null
	return arr


## Фронты армий игрока на карте: провинция -> [роль, цвет] (роль — биты:
## 1 — наш участок, 2 — чужая сторона линии, 4 — выделено кистью, 8 — цель
## атаки). Текстура обновляется, только если отметки изменились.
var _front_marks := {}


func set_front(marks: Dictionary) -> void:
	if front_img == null:
		return
	var h := marks.hash()
	if h == _front_hash:
		return
	_front_hash = h
	# перерисовать только провинции, чья отметка сменилась (частичная перерисовка)
	var changed := PackedInt32Array()
	for p in _front_marks:
		if not marks.has(p) or str(marks[p]) != str(_front_marks[p]):
			changed.append(int(p))
	for p in marks:
		if not _front_marks.has(p):
			changed.append(int(p))
	var was_on := not _front_marks.is_empty()
	_front_marks = marks.duplicate(true)
	front_img.fill(Color(0, 0, 0, 0))
	for p in marks:
		var m: Array = marks[p]
		var c: Color = m[1]
		c.a = int(m[0]) / 255.0
		front_img.set_pixel(int(p) % 64, int(p) / 64, c)
	_pal_push(3, front_img)
	_param("front_on", not marks.is_empty())
	if was_on != not marks.is_empty() or changed.size() > 400:
		redraw()
	else:
		redraw_provs(changed)


func set_highlight_nation(n: int) -> void:
	_param("highlight_nation", n)
	redraw()


## Перерисовать карту в ближайшем кадре.
## Карта изменилась целиком (режим, качество, палитра без частичной...):
## перерисовать кадр и заново построить кэш движения.
func redraw() -> void:
	_dirty = true
	_cache_reset()


# --- Частичная перерисовка (оптимизация для телефона, ноябрь 2026) -------------
# После смены владельцев (война, ускоренное время) меняются только изменившиеся
# провинции и их окрестность (линии, кайма до BAND_PX·BAND_STEP пикселей карты):
# рисуем только экранную рамку этих провинций поверх прежнего кадра — тот же
# шейдер, та же картинка, в разы меньше пикселей. Целиком — если камера с прошлой
# полной перерисовки сдвинулась или область велика.
const PART_MARGIN := 26.0      # запас вокруг рамки, пикселей карты 1× (кайма 20 + линии)
const PART_MAX := 0.55         # доля буфера, больше — рисуем целиком
var _part_dirty := false
var _part_rect := Rect2()      # область экрана (логические пиксели)
var part_redraws := 0          # для замеров: сколько было частичных перерисовок


## Перерисовать только область провинций provs (если можно; иначе — целиком).
func redraw_provs(provs: PackedInt32Array) -> void:
	if provs.is_empty():
		return
	if world.p_bbox.size() != world.prov_count * 4:
		redraw()
		return
	var x0 := INF
	var y0 := INF
	var x1 := -INF
	var y1 := -INF
	for p in provs:
		x0 = minf(x0, world.p_bbox[p * 4])
		y0 = minf(y0, world.p_bbox[p * 4 + 1])
		x1 = maxf(x1, world.p_bbox[p * 4 + 2])
		y1 = maxf(y1, world.p_bbox[p * 4 + 3])
	# рамка в единицах мира (пиксель карты 1× = SCALE), с запасом
	var a := Vector2(x0 - PART_MARGIN, y0 - PART_MARGIN) * SCALE
	var b := Vector2(x1 + 1.0 + PART_MARGIN, y1 + 1.0 + PART_MARGIN) * SCALE
	_cache_add_rect(Rect2(a, b - a))
	var r := Rect2(world_to_screen(a), Vector2.ZERO)
	for c in [Vector2(b.x, a.y), Vector2(a.x, b.y), b]:
		r = r.expand(world_to_screen(c))
	# при наклоне горы «встают» (параллакс до RELIEF_H единиц мира) — запас вверх и вниз
	var lift := 6.0 * camera.zoom.x * 1.5 if tilt() > 0.0 else 0.0
	r = r.grow_individual(2.0, 2.0 + lift, 2.0, 2.0 + lift)
	if _part_dirty:
		r = r.merge(_part_rect)
	_part_rect = r
	_part_dirty = true


# --- Перерисовка полосами (оптимизация для телефона, ноябрь 2026) -------------
# Полная перерисовка на высоком качестве на Adreno 619 — 100–150 мс одним кадром
# (рывок). Где кадр можно не показывать сразу, рисуем его полосами по одной за
# кадр (тот же шейдер, те же пиксели — частичная перерисовка прямоугольником):
#  - смена сезона (снег) — под снимком прежнего кадра, который потом тает;
#  - кадр в полном качестве после сдвига — скрыт, пока виден упрощённый, и
#    проявляется, когда готовы все полосы.
# На ПК — одной полосой (как раньше); -- --strips=N — для замеров.
var strips := 1
var _strip_i := 0
var _strip_n := 0              # 0 — полос нет
var _strip_hidden := false     # кадр скрыт до последней полосы (после сдвига)
var strip_redraws := 0         # для замеров


## Следующая полоса кадра; если камера или размер с начала сменились — целиком.
func _draw_strip() -> void:
	var logical := get_viewport_rect().size
	var phys := Vector2(get_window().size)
	var size := Vector2i(maxi(1, int(phys.x * res_scale)), maxi(1, int(phys.y * res_scale)))
	var same := _moving <= 0.0 and (_strip_hidden or (not _lite_drawn and _full_alpha >= 1.0 and not _fading_in)) \
		and Vector2(size) == _full_size and map_vp.size == size and _full_q == quality \
		and camera.position == _full_cam and is_equal_approx(camera.zoom.x, _full_zoom) \
		and is_equal_approx(tilt(), _full_tilt)
	if not same:
		_strip_n = 0
		_dirty = true
		return
	var y0 := floori(float(size.y) * _strip_i / _strip_n)
	var y1 := floori(float(size.y) * (_strip_i + 1) / _strip_n)
	if _strip_i == 0:
		_full_baked = _screen_bake(logical, float(size.x) / maxf(1.0, logical.x), -1) == 1
	elif _screen_bake(logical, float(size.x) / maxf(1.0, logical.x), 1 if _full_baked else 0) < 0:
		_strip_n = 0
		_dirty = true
		return
	_use_screen(_full_baked)
	_param("quality", quality)
	_param("res_k", float(size.x) / maxf(1.0, logical.x))
	_param("buf_size", Vector2(size))
	_cam_uniforms(logical)
	quad.position = Vector2(0, y0)
	quad.size = Vector2(size.x, y1 - y0)
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	redraws += 1
	strip_redraws += 1
	_strip_i += 1
	if _strip_i >= _strip_n:
		_strip_n = 0
		if _strip_hidden:
			_strip_hidden = false
			_fading_in = true   # все полосы готовы — проявляем


# --- Кэш движения (решение пользователя, ноябрь 2026) -------------------------
# При сдвиге карта не перерисовывается целиком и не размывается: плоский кадр
# полного качества (вид сверху, тот же шейдер без наклона) лежит в закольцованном
# буфере, привязанном к миру (якорь cam, окно с пикселя n кадра якоря). Сдвиг
# камеры — дорисовка только открывшихся полос; экран показывает проекцию буфера
# текущей камерой (перспектива, подъём гор, дымка — map_motion.gdshader). Без
# наклона и на том же масштабе — пиксель в пиксель с полным кадром; при наклоне
# масштаб буфера — как у нижнего края экрана (дальние линии во время движения
# чуть тоньше). После остановки — точный кадр (полосами, проявляется).
# Буферов два: на экране — готовый, новый (другой масштаб) строится во втором
# мелкими полосами (~четверть экрана за кадр) и подменяет готовый, когда
# достроен; пока строится, готовый показывается и при другом масштабе (до ×2,
# чуть мягче). Строится заранее (карта стоит 3 кадра) и при движении; заново —
# при масштабе дальше CACHE_ZOOM_TOL от нужного при постройке, смене качества,
# сезона, redraw(); смена владельцев — частично (rects).
const CACHE_MAX_SCREENS := 3.2   # пикселей кэша не больше стольких экранов
const CACHE_MARGIN := 0.1        # запас окна на сдвиг (доля большей стороны экрана)
const CACHE_ZOOM_TOL := 1.15     # дальше — строить новый
const CACHE_ZOOM_SOFT := 2.0     # до стольких раз показывать готовый, пока строится новый
const RELIEF_H := 6.0            # как в map.gdshader: высота гор при наклоне, единиц мира


class CacheBuf:
	var vp: SubViewport
	var cmat: ShaderMaterial
	var cmat_b: ShaderMaterial
	var quads: Array = []
	var cam := Vector2.ZERO      # якорь: центр окна при n = 0, мир
	var zoom := 1.0              # логический масштаб кадра
	var zneed := 1.0             # нужный при постройке (zoom меньше, если упёрлись в размер)
	var rk := 1.0                # пикселей буфера на логический
	var n := Vector2i.ZERO       # окно: первый пиксель кадра якоря
	var size := Vector2i.ONE
	var q := -1
	var valid := false
	var queue: Array = []        # прямоугольники кадра якоря к отрисовке в этом кадре
	var rects: Array = []        # мировые рамки к дорисовке (смена владельцев)


var _cb: Array = []              # два буфера
var _cf := 0                     # индекс показываемого
var _c_build_i := 0
var _c_build_n := 0              # постройка второго буфера полосами: 0 — не строится
var _c_zoom_seen := 0.0
var _c_still := 0                # кадров подряд без смены масштаба
var cache_draws := 0             # для замеров: сколько раз рисовался кэш
var _no_cache := "--nocache" in OS.get_cmdline_user_args()   # замеры: полный кадр при движении
var _cache_part := false         # видимое шире окна кэша: под ним — упрощённый кадр


func _cache_front() -> CacheBuf:
	return _cb[_cf]


func _cache_back() -> CacheBuf:
	return _cb[1 - _cf]


## Карта изменилась целиком — оба буфера строить заново.
func _cache_reset() -> void:
	for b in _cb:
		b.valid = false
		b.rects.clear()
	_c_build_n = 0


## Область изменилась (смена владельцев): дорисовать в готовых и строящемся.
func _cache_add_rect(r: Rect2) -> void:
	for i in _cb.size():
		var b: CacheBuf = _cb[i]
		if b.valid or (_c_build_n > 0 and i != _cf):
			b.rects.append(r)


## Пикселей буфера на логический пиксель экрана (как у кадра карты).
func _screen_rk() -> float:
	var logical := get_viewport_rect().size
	var phys := Vector2(get_window().size)
	return float(maxi(1, int(phys.x * res_scale))) / maxf(1.0, logical.x)


## Нужный кэш для текущей камеры → [масштаб, рамка видимого в мире].
func _cache_need() -> Array:
	var vp := get_viewport_rect().size
	var r := Rect2(screen_to_world(Vector2.ZERO), Vector2.ZERO)
	for p in [Vector2(vp.x, 0), Vector2(0, vp.y), vp, Vector2(vp.x * 0.5, 0)]:
		r = r.expand(screen_to_world(p))
	var th := tilt()
	var z := camera.zoom.x
	if th > 0.0:
		z *= 1.0 + tan(th) * vp.y * 0.5 / cam_focal()   # масштаб нижнего края экрана
		r = r.grow(RELIEF_H * 2.5)                       # подъём гор берёт точки ближе к камере
	return [z, r]


func _zoom_ok(zr: float, tol: float) -> bool:
	return zr <= tol and zr >= 1.0 / tol


## Начать строить второй буфер для текущей камеры (полосами, по одной за кадр).
func _cache_build() -> void:
	var b := _cache_back()
	var need := _cache_need()
	var z: float = need[0]
	var r: Rect2 = need[1]
	var rk := _screen_rk()
	var vp := get_viewport_rect().size * rk
	var m := maxf(vp.x, vp.y) * CACHE_MARGIN
	var px := r.size * z * rk + Vector2(m, m) * 2.0
	# не больше CACHE_MAX_SCREENS экранов и 8192 по стороне — иначе мельче
	var k := minf(1.0, sqrt(CACHE_MAX_SCREENS * vp.x * vp.y / maxf(1.0, px.x * px.y)))
	k = minf(k, 8192.0 / maxf(px.x, px.y))
	b.zoom = z * k
	b.zneed = z
	b.rk = rk
	b.size = Vector2i(maxi(8, ceili(px.x * k)), maxi(8, ceili(px.y * k)))
	b.cam = r.get_center()
	b.n = Vector2i.ZERO
	b.q = quality
	b.valid = false
	b.rects.clear()
	b.queue.clear()
	if b.vp.size != b.size:
		b.vp.size = b.size
		# новый буфер ни разу не очищен — без очистки GLES3 его не выводит
		b.vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	# полосы — примерно как полоса кадра экрана (strips на экран)
	var screens := float(b.size.x * b.size.y) / maxf(1.0, vp.x * vp.y)
	_c_build_i = 0
	_c_build_n = maxi(1, ceili(strips * screens)) if strips > 1 else 1


## Рамка мира → прямоугольник кадра якоря буфера (пиксели, целые).
func _cache_px(b: CacheBuf, r: Rect2) -> Rect2:
	var k := b.zoom * b.rk
	var p0 := ((r.position - b.cam) * k + Vector2(b.size) * 0.5).floor()
	var p1 := ((r.end - b.cam) * k + Vector2(b.size) * 0.5).ceil()
	return Rect2(p0, p1 - p0)


## Можно ли показать движение из готового буфера; если видимое вышло за окно —
## сдвинуть окно и дорисовать открывшиеся полосы (в этом же кадре).
func _cache_usable() -> bool:
	if _no_cache:
		return false
	var b := _cache_front()
	if not b.valid or b.q != quality or absf(b.rk - _screen_rk()) > 1e-4:
		return false
	var need := _cache_need()
	if not _zoom_ok(float(need[0]) / b.zneed, CACHE_ZOOM_SOFT):
		return false
	var fp := _cache_px(b, need[1])
	var win := Rect2(Vector2(b.n), Vector2(b.size))
	_cache_part = false
	if win.encloses(fp):
		return true
	# видимое шире окна (отдалили): показывать, пока недостаёт не больше половины
	# окна (края тянутся, пока второй буфер строится), иначе — нет
	if fp.size.x > b.size.x * 1.5 or fp.size.y > b.size.y * 1.5:
		return false
	# новое окно: видимое посередине; видимое шире окна — края кадра вне буфера
	# закрывает упрощённый живой кадр под ним (раньше тянулись крайние пиксели
	# буфера — «размытие по бокам» при отдалении)
	_cache_part = fp.size.x > b.size.x + 1.0 or fp.size.y > b.size.y + 1.0
	var n2 := Vector2i((fp.get_center() - Vector2(b.size) * 0.5).round())
	var d := n2 - b.n
	b.n = n2
	if absi(d.x) >= b.size.x or absi(d.y) >= b.size.y:
		b.queue.append(Rect2(Vector2(n2), Vector2(b.size)))
		return true
	var w := Vector2(b.size)
	if d.x > 0:
		b.queue.append(Rect2(Vector2(n2.x + w.x - d.x, n2.y), Vector2(d.x, w.y)))
	elif d.x < 0:
		b.queue.append(Rect2(Vector2(n2), Vector2(-d.x, w.y)))
	if d.y > 0:
		b.queue.append(Rect2(Vector2(n2.x, n2.y + w.y - d.y), Vector2(w.x, d.y)))
	elif d.y < 0:
		b.queue.append(Rect2(Vector2(n2), Vector2(w.x, -d.y)))
	return true


## Каждый кадр: частичные дорисовки, постройка второго буфера, подмена.
func _cache_tick() -> void:
	if _cb.is_empty():
		return
	var z := camera.zoom.x
	_c_still = _c_still + 1 if z == _c_zoom_seen else 0
	_c_zoom_seen = z
	var f := _cache_front()
	if f.valid:
		for r in f.rects:
			f.queue.append(_cache_px(f, r))
		f.rects.clear()
		if f.q != quality or absf(f.rk - _screen_rk()) > 1e-4:
			f.valid = false
	var zr_f: float = float(_cache_need()[0]) / f.zneed
	if _c_build_n > 0:
		var b := _cache_back()
		var zr: float = float(_cache_need()[0]) / b.zneed
		if not _zoom_ok(zr, CACHE_ZOOM_TOL) or b.q != quality:
			_c_build_n = 0   # масштаб ушёл — строить заново
		else:
			var y0 := floori(float(b.size.y) * _c_build_i / _c_build_n)
			var y1 := floori(float(b.size.y) * (_c_build_i + 1) / _c_build_n)
			b.queue.append(Rect2(Vector2(b.n.x, b.n.y + y0), Vector2(b.size.x, y1 - y0)))
			_c_build_i += 1
			if _c_build_i >= _c_build_n:
				_c_build_n = 0
				b.valid = true
				for r in b.rects:
					b.queue.append(_cache_px(b, r))
				b.rects.clear()
				_cf = 1 - _cf   # готов — показывать его
			return
	# нужен новый: готового нет или масштаб ушёл; строить, когда масштаб устоялся
	# и в этом кадре не рисуется полный кадр карты, или сразу при движении
	var want := not f.valid or not _zoom_ok(zr_f, CACHE_ZOOM_TOL)
	if want and _strip_n == 0 and ((_c_still >= 3 and not _dirty and redraws == _c_redraws0) \
			or _moving > 0.0):
		_cache_build()


## Нарисовать накопленные прямоугольники буферов (окно — закольцованное).
func _cache_flush() -> void:
	if _cb.is_empty():
		return
	if cache_rect.visible:
		_cache_show()
	for b in _cb:
		_cache_draw(b)


func _cache_draw(b: CacheBuf) -> void:
	if b.queue.is_empty():
		return
	var win := Rect2(Vector2(b.n), Vector2(b.size))
	var rects: Array = []
	for r in b.queue:
		var q: Rect2 = (r as Rect2).intersection(win)
		if q.size.x < 1.0 or q.size.y < 1.0:
			continue
		# в буфер: по модулю размера, с разрезом по краю
		var bx := posmod(int(q.position.x), b.size.x)
		var by := posmod(int(q.position.y), b.size.y)
		var w := int(q.size.x)
		var h := int(q.size.y)
		var xs := [[bx, mini(w, b.size.x - bx)]]
		if bx + w > b.size.x:
			xs.append([0, bx + w - b.size.x])
		var ys := [[by, mini(h, b.size.y - by)]]
		if by + h > b.size.y:
			ys.append([0, by + h - b.size.y])
		for xa in xs:
			for ya in ys:
				rects.append(Rect2(xa[0], ya[0], xa[1], ya[1]))
	# заготовки — по рамке мира того, что рисуется в этом кадре
	var use_b := false
	if _bake_ok() and not b.queue.is_empty():
		var u := Rect2()
		for i in b.queue.size():
			var q: Rect2 = (b.queue[i] as Rect2).intersection(win)
			u = q if i == 0 else u.merge(q)
		var kz := b.zoom * b.rk
		var wr := Rect2(b.cam + (u.position - Vector2(b.size) * 0.5) / kz, u.size / kz)
		_bake_sync_r(b.rk)
		use_b = bake.want(bake.need_flat(wr, b.zoom, _season()))
	b.queue.clear()
	if rects.is_empty():
		return
	while b.quads.size() < rects.size():
		var cq := ColorRect.new()
		cq.material = b.cmat
		cq.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.vp.add_child(cq)
		b.quads.append(cq)
	for i in b.quads.size():
		var cq: ColorRect = b.quads[i]
		cq.material = b.cmat_b if use_b else b.cmat
		cq.visible = i < rects.size()
		if cq.visible:
			cq.position = rects[i].position
			cq.size = rects[i].size
	var sz := Vector2(b.size)
	var cm := b.cmat_b if use_b else b.cmat
	if use_b:
		baked_draws += 1
	else:
		live_draws += 1
	cm.set_shader_parameter("quality", b.q)
	cm.set_shader_parameter("res_k", b.rk)
	cm.set_shader_parameter("buf_size", sz)
	cm.set_shader_parameter("scr_size", sz / b.rk)
	cm.set_shader_parameter("cam_pos", b.cam)
	cm.set_shader_parameter("cam_zoom", b.zoom)
	cm.set_shader_parameter("cam_tilt", 0.0)
	cm.set_shader_parameter("cam_f", cam_focal())
	cm.set_shader_parameter("torus_n", Vector2(b.n))
	b.vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	cache_draws += 1


## Вывод готового буфера текущей камерой.
func _cache_show() -> void:
	var b := _cache_front()
	var logical := get_viewport_rect().size
	cache_rect.position = Vector2.ZERO
	cache_rect.size = logical
	dmat.set_shader_parameter("cache_tex", b.vp.get_texture())
	dmat.set_shader_parameter("base_tex", mat.get_shader_parameter("base_tex"))
	dmat.set_shader_parameter("world_size", world_size())
	dmat.set_shader_parameter("cam_pos", camera.position)
	dmat.set_shader_parameter("cam_zoom", camera.zoom.x)
	dmat.set_shader_parameter("cam_tilt", tilt())
	dmat.set_shader_parameter("cam_f", cam_focal())
	dmat.set_shader_parameter("scr_size", logical)
	dmat.set_shader_parameter("c_cam", b.cam)
	dmat.set_shader_parameter("c_zoom", b.zoom)
	dmat.set_shader_parameter("c_rk", b.rk)
	dmat.set_shader_parameter("c_n", Vector2(b.n))
	dmat.set_shader_parameter("c_size", Vector2(b.size))
	dmat.set_shader_parameter("c_exact", tilt() <= 0.0 and is_equal_approx(camera.zoom.x, b.zoom))
	dmat.set_shader_parameter("c_clip", _cache_part and lite_sprite.visible)


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


## Частичная перерисовка _part_rect поверх прежнего полного кадра — только если
## он нарисован с той же камерой и качеством и сейчас на экране целиком.
func _draw_part() -> void:
	var logical := get_viewport_rect().size
	var phys := Vector2(get_window().size)
	var size := Vector2i(maxi(1, int(phys.x * res_scale)), maxi(1, int(phys.y * res_scale)))
	var same := not _lite_drawn and _moving <= 0.0 and _full_alpha >= 1.0 and not _fading_in \
		and Vector2(size) == _full_size and map_vp.size == size and _full_q == quality \
		and camera.position == _full_cam and is_equal_approx(camera.zoom.x, _full_zoom) \
		and is_equal_approx(tilt(), _full_tilt)
	var k := Vector2(size) / logical   # пикселей буфера на логический
	var r := Rect2(_part_rect.position * k, _part_rect.size * k)
	r = r.intersection(Rect2(Vector2.ZERO, Vector2(size)))
	if not same or r.size.x * r.size.y > PART_MAX * size.x * size.y:
		_dirty = true   # кэш движения уже получил эту область (redraw_provs)
		return
	if r.size.x < 1.0 or r.size.y < 1.0:
		return   # область вне экрана — рисовать нечего
	# целые пиксели: края прямоугольника совпадают с пикселями буфера
	var p0 := r.position.floor()
	var p1 := (r.position + r.size).ceil()
	r = Rect2(p0, p1 - p0)
	if _screen_bake(logical, float(size.x) / maxf(1.0, logical.x), 1 if _full_baked else 0) < 0:
		_dirty = true
		return
	_use_screen(_full_baked)
	_param("quality", quality)
	_param("res_k", float(size.x) / maxf(1.0, logical.x))
	_param("buf_size", Vector2(size))
	_cam_uniforms(logical)
	quad.position = r.position
	quad.size = r.size
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	redraws += 1
	part_redraws += 1


func _process(dt: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_map(dt)
	FrameProf.add("карта", Time.get_ticks_usec() - t0)
	# отрисовка движком прошлого кадра на процессоре (команды ГП: экран и буферы карты)
	if map_vp != null:
		var rcpu := RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
		rcpu += RenderingServer.viewport_get_measured_render_time_cpu(map_vp.get_viewport_rid())
		FrameProf.add("отрисовка движком (ЦП)", int(rcpu * 1000.0))


var _warm := 0   # кадров прогрева шейдера вывода кэша
var _c_redraws0 := 0   # перерисовок карты к началу кадра (кэш не строится в кадр с ними)


## Камера сама обновляет вид каждый кадр — движок считает кадр изменённым и
## рисует его заново даже без изменений (режим «не рисовать без изменений»,
## low_processor_usage_mode): обновление камеры — только при её сдвиге.
var _cam_seen := Vector3.INF


func _camera_sync() -> void:
	if camera.is_processing_internal():
		camera.set_process_internal(false)
		camera.set_physics_process_internal(false)
	var k := Vector3(camera.position.x, camera.position.y, camera.zoom.x)
	if k != _cam_seen:
		_cam_seen = k
		camera.force_update_scroll()


func _process_map(dt: float) -> void:
	_c_redraws0 = redraws
	if camera != null:
		_camera_sync()
	Report.frame(dt, redraws - part_redraws, part_redraws)
	if res_auto and map_vp != null:
		_auto_adjust(dt)
	if _moving > 0.0:
		_moving -= dt
		if _moving <= 0.0 and _lite_drawn:
			_dirty = true   # остановились — перерисовать в полном качестве
	if map_vp == null:
		return
	_band_poll()
	_season_tick(dt)
	if _strip_n > 0 and not _dirty:
		_draw_strip()   # частичная — после полос: полосы уже рисуют с новой палитрой
	elif _part_dirty and not _dirty:
		_part_dirty = false
		_draw_part()
	if _dirty:
		_dirty = false
		_part_dirty = false
		_strip_n = 0
		_strip_hidden = false
		# движение: из кэша (всегда, когда он годится), иначе — упрощённо (если
		# включено «упрощать при сдвиге» и есть что упрощать), иначе — как есть
		var use_cache := _moving > 0.0 and _cache_usable()
		var lite := use_cache or (motion_lite and _moving > 0.0 and (quality > 0 or res_scale > 0.5))
		var was_lite := _lite_drawn
		_lite_drawn = lite
		_param("quality", 0 if lite else quality)
		var rs := 0.5 if lite else res_scale
		var logical := get_viewport_rect().size
		var phys := Vector2(get_window().size)
		var size := Vector2i(maxi(1, int(phys.x * rs)), maxi(1, int(phys.y * rs)))
		var rk := float(size.x) / maxf(1.0, logical.x)  # пикселей буфера на логический
		_param("res_k", rk)
		_param("buf_size", Vector2(size))
		_cam_uniforms(logical)
		quad.position = Vector2.ZERO
		if use_cache:
			# движение — из кэша: плоский кадр полного качества, открывшиеся края
			# дорисованы (_cache_usable), проекция с текущей камерой (map_motion)
			cache_rect.visible = true
			_fading_in = false
			if _cache_part:
				# видимое шире буфера (отдаление): края — кадр под кэшем; с заготовками —
				# в полном качестве (дёшево и не отличается от кэша), иначе упрощённый
				var lb := _screen_bake(logical, rk, -1, true) == 1
				lite_quad.material = mat_b if lb else mat
				if lb:
					_param("quality", mini(quality, 1))
				if lite_vp.size != size:
					lite_vp.size = size
				lite_quad.size = Vector2(size)
				lite_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
				_lite_cam = camera.position
				_lite_zoom = camera.zoom.x
				_lite_size = Vector2(size)
				lite_sprite.visible = true
			else:
				lite_sprite.visible = false
				redraws -= 1
		elif lite and _c_build_n > 0 and lite_sprite.visible and was_lite and not cache_rect.visible \
				and _lite_covers(logical):
			redraws -= 1   # кэш строится — прежний упрощённый кадр просто сдвигается
		elif lite:
			cache_rect.visible = false
			# с заготовками упрощённый кадр — среднего качества (неподвижная часть
			# как в полном, дешевле живого низкого); без них — низкое, как было
			var lb2 := _screen_bake(logical, rk, -1, true) == 1
			lite_quad.material = mat_b if lb2 else mat
			if lb2:
				_param("quality", mini(quality, 1))
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
				# новый буфер ни разу не очищен — без очистки GLES3 его не выводит
				map_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
			quad.size = Vector2(size)
			_full_baked = _screen_bake(logical, rk, -1) == 1
			_use_screen(_full_baked)
			map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			_full_cam = camera.position
			_full_zoom = camera.zoom.x
			_full_size = Vector2(size)
			_full_tilt = tilt()
			_full_q = quality
			if was_lite:
				_full_alpha = 0.0   # после движения — проявляем новый кадр плавно
				_fading_in = true
				if strips > 1:
					# кадр скрыт под упрощённым — рисуем его полосами, проявим в конце
					_fading_in = false
					_strip_hidden = true
					_strip_n = strips
					_strip_i = 0
					_draw_strip()
					redraws -= 1   # уже учтено как полоса
			if _strip_n == 0 and not _strip_hidden:
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
	if not motion_lite and not cache_rect.visible:
		_full_alpha = 1.0
	if _full_alpha >= 1.0 and not _lite_drawn:
		lite_sprite.visible = false
		cache_rect.visible = false
	_cache_tick()
	_cache_flush()
	if _full_baked and not _screen_keys.is_empty():
		bake.want(_screen_keys)   # тайлы показанного кадра — не вытеснять
	# рисовать тайлы — когда карта стоит (при сдвиге видеокарта занята кадром)
	# и не трогают экран: касание — скорее всего выбор провинции или сдвиг, кадр с
	# дорисовкой тайла в этот момент дал бы задержку отклика
	_bake_still = _bake_still + 1 if _moving <= 0.0 and not _dirty and _strip_n == 0 \
		and _c_build_n == 0 and not _fading_in and _touches.is_empty() else 0
	var tb := Time.get_ticks_usec()
	bake.tick(_bake_still >= 30)
	FrameProf.add("заготовки", Time.get_ticks_usec() - tb)
	# прогрев: шейдер вывода кэша компилируется при загрузке, а не при первом
	# сдвиге (на телефоне первая компиляция — кадр до полсекунды)
	if _warm > 0:
		_warm -= 1
		cache_rect.visible = _warm > 0
		cache_rect.position = Vector2.ZERO
		cache_rect.size = Vector2(2, 2)
		cache_rect.self_modulate.a = 0.02 if _warm > 0 else 1.0
	if view_sprite.modulate.a != _full_alpha:
		view_sprite.modulate.a = _full_alpha
	_place(view_sprite, _full_cam, _full_zoom, _full_size)
	if lite_sprite.visible:
		_place(lite_sprite, _lite_cam, _lite_zoom, _lite_size)


## Параметр шейдера карты — в оба материала (экран и кэш движения); камеру
## кэш задаёт себе сам перед отрисовкой (_cache_flush).
const _BAKE_OWN := {"quality": 1, "res_k": 1, "buf_size": 1, "scr_size": 1, "cam_pos": 1,
	"cam_zoom": 1, "cam_tilt": 1, "torus_n": 1, "winter": 1}


func _param(name: String, v) -> void:
	mat.set_shader_parameter(name, v)
	mat_b.set_shader_parameter(name, v)
	for cm in cmats:
		cm.set_shader_parameter(name, v)
	for cm in cmats_b:
		cm.set_shader_parameter(name, v)
	if not _BAKE_OWN.has(name):
		bake.mat.set_shader_parameter(name, v)
	elif name == "winter":
		_param("pg_row", bake.pg_rows(1 if float(v) >= 0.5 else 0))


# --- Заготовки (MapBake) -------------------------------------------------------

## Атлас и таблица страниц — шейдеру с заготовками (после смены плотности).
func _bake_push() -> void:
	_param("page_tex", bake.page_tex)
	_param("atlas_tex", bake.atlas)
	_param("bk_r", bake.r_cls)
	_param("pg_row", bake.pg_rows(_season()))


func _season() -> int:
	return 1 if _winter >= 0.5 else 0


func _bake_ok() -> bool:
	return not _bake_off and bake.ok and quality >= 1 and map_mode != MapMode.TERRAIN \
		and world.width == 5632


## Плотность заготовок под пиксели буфера на логический (классы 1 / 1.5 / 2, с запасом).
func _bake_sync_r(rk: float) -> void:
	var r := bake.r_cls
	if rk <= r * 1.25 and (r <= 1.0 or rk >= r / 1.25):
		return
	var nr := 1.0 if rk < 1.25 else (1.5 if rk < 1.75 else 2.0)
	if nr != r:
		bake.set_r(nr)
		_bake_push()


## Кадр экрана (полный, полоса, частичный) с заготовками? baked — каким нарисован
## прежний кадр (для полос и частичных: не смешивать в одном кадре); -1 — любой.
func _screen_bake(logical: Vector2, rk: float, need_mode: int, partial := false) -> int:
	if not _bake_ok():
		return 0
	_bake_sync_r(rk)
	var keys := bake.need(camera.position, camera.zoom.x, tilt(), cam_focal(), logical, _season())
	if partial:
		return 1 if bake.want(keys, true, _season()) else 0
	_screen_keys = keys
	var r := 1 if bake.want(_screen_keys) else 0
	if need_mode == 1 and r == 0:
		return -1   # кадр с заготовками, а тайлов уже нет — перерисовать целиком
	if need_mode == 0:
		return 0
	return r


func _use_screen(baked: bool) -> void:
	quad.material = mat_b if baked else mat
	if baked:
		baked_draws += 1
	else:
		live_draws += 1


func _cam_uniforms(logical: Vector2) -> void:
	_param("torus_n", Vector2.ZERO)
	_param("cam_pos", camera.position)
	_param("cam_zoom", camera.zoom.x)
	_param("cam_tilt", tilt())
	_param("cam_f", cam_focal())
	_param("scr_size", logical)


## Прежний упрощённый кадр, сдвинутый и масштабированный под текущую камеру,
## ещё закрывает экран? (При отдалении он уменьшается — по краям пусто.)
func _lite_covers(logical: Vector2) -> bool:
	if tilt() > 0.0 or _full_tilt > 0.0:
		return false
	var half := logical * 0.5
	var r := camera.zoom.x / maxf(1e-6, _lite_zoom)
	var ps := half - half * r + (_lite_cam - camera.position) * camera.zoom.x
	return ps.x <= 0.5 and ps.y <= 0.5 and ps.x + logical.x * r >= logical.x - 0.5 and ps.y + logical.y * r >= logical.y - 0.5


## Показ буфера, нарисованного с камеры (c_b, z_b), при текущей камере: старый
## кадр сдвигается и масштабируется вместе с картой, пока не придёт новый.
func _place(spr: Sprite2D, c_b: Vector2, z_b: float, size: Vector2) -> void:
	var logical := get_viewport_rect().size
	var half := logical * 0.5
	var z_n := camera.zoom.x
	var r := z_n / maxf(1e-6, z_b)
	# только при изменении: иначе движок считает кадр изменённым и рисует его
	# заново (режим «не рисовать без изменений», low_processor_usage_mode)
	var sc := logical / size * r
	var ps := half - half * r + (c_b - camera.position) * z_n
	if spr.scale != sc:
		spr.scale = sc
	if spr.position != ps:
		spr.position = ps


## Время отрисовки последнего кадра на видеокарте (мс): карта и весь экран.
func gpu_ms() -> Vector2:
	if map_vp == null:
		return Vector2.ZERO
	return Vector2(RenderingServer.viewport_get_measured_render_time_gpu(map_vp.get_viewport_rid()),
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))


## Качество карты: 0 — низкое, 1 — среднее, 2 — высокое (см. shaders/map.gdshader).
## Сезон для снега в горах (решение пользователя): два состояния — зима
## северного полушария с 1 ноября по 30 апреля (winter = 1, в южном шейдер
## меняет местами), иначе лето (0). Карта перерисовывается дважды в год: новый
## кадр рисуется полосами под снимком прежнего, снимок плавно тает за SEASON_FADE.
const SEASON_FADE := 1.5
var _season_step := 0          # 0 — нет; 1 — снят снимок; 2 — полосы; 3 — тает
var _season_w := 0.0


static func winter_of(day: int) -> float:
	var doy := fmod(float(day), 365.2425)   # день 0 — 1 января
	return 1.0 if doy < 120.0 or doy >= 304.0 else 0.0


func set_day(day: int) -> void:
	if mat == null:
		return
	var w := winter_of(day)
	if w == _winter or (_season_step > 0 and w == _season_w):
		return
	var shown := _winter >= 0.0 and not _dirty and _full_alpha >= 1.0 and not _lite_drawn \
		and not _fading_in and _moving <= 0.0 and _strip_n == 0 and map_vp.size.x > 1
	_cache_reset()   # снег другой — кэш движения строить заново
	if not shown:
		_season_end()
		_winter = w
		_param("winter", w)
		redraw()
		return
	# снимок видимого кадра (в этом кадре), сезон — со следующего
	_season_w = w
	_season_step = 1
	snap_vp.size = map_vp.size
	(snap_vp.get_child(0) as TextureRect).size = Vector2(map_vp.size)
	snap_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	snap_sprite.modulate.a = 1.0
	snap_sprite.visible = true
	_snap_cam = _full_cam
	_snap_zoom = _full_zoom
	_snap_size = _full_size


var _snap_cam := Vector2.ZERO
var _snap_zoom := 1.0
var _snap_size := Vector2.ONE


func _season_end() -> void:
	if _season_step == 0:
		return
	if _season_step == 1:
		_winter = _season_w
		_param("winter", _season_w)
		redraw()
	_season_step = 0
	snap_sprite.visible = false
	snap_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


## Шаги смены сезона (из _process карты).
func _season_tick(dt: float) -> void:
	if _season_step == 0:
		return
	if _moving > 0.0 or _lite_drawn:
		_season_end()   # пошёл сдвиг — новый кадр и так рисуется заново
		return
	match _season_step:
		1:
			_winter = _season_w
			_param("winter", _season_w)
			_season_step = 2
			if strips > 1:
				_strip_i = 0
				_strip_n = strips
				_strip_hidden = false
			else:
				redraw()
		2:
			if _strip_n == 0 and not _dirty:
				_season_step = 3
		3:
			snap_sprite.modulate.a = maxf(0.0, snap_sprite.modulate.a - dt / SEASON_FADE)
			if snap_sprite.modulate.a <= 0.0:
				_season_end()
	if snap_sprite.visible:
		_place(snap_sprite, _snap_cam, _snap_zoom, _snap_size)


## Раздел палитры в общую текстуру (0 контролёр, 1 владелец, 2 область, 3 фронт).
func _pal_push(sec: int, img: Image) -> void:
	pal_img.blit_rect(img, Rect2i(0, 0, 64, _pal_rows), Vector2i(0, sec * _pal_rows))
	pal_tex.update(pal_img)


func set_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	if mat != null:
		_param("quality", quality)
		redraw()


func set_map_mode(m: int) -> void:
	map_mode = m
	_param("show_occupation", m == MapMode.POLITICAL)
	_param("terrain_mode", m == MapMode.TERRAIN)
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
	var ch_list := PackedInt32Array()
	for p in world.prov_count:
		if incremental:
			if _pal_ctrl[p] == pc[p] and _pal_own[p] == po[p]:
				continue
		changed += 1
		if incremental:
			ch_list.append(p)
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
	pal_img.blit_rect(ctrl_img, Rect2i(0, 0, 64, _pal_rows), Vector2i(0, 0))
	_pal_push(1, owner_img)
	palette_version += 1
	if incremental:
		_band_async(ch_list)
	else:
		_update_band()
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
		var t0 := Time.get_ticks_usec()
		province_tapped.emit(p)
		FrameProf.add("касание провинции", Time.get_ticks_usec() - t0)


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
	_dirty = true   # сдвиг камеры: кэш движения остаётся
	view_changed.emit()
