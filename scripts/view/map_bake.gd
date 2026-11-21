class_name MapBake
extends Node
## Заготовки неподвижной части карты (решение пользователя, ноябрь 2026: «нарисуем
## и сожмём карту заранее»; APK для дальних масштабов + кэш ближних на телефоне).
##
## До каймы цвет суши линеен по цвету страны: col = S·base + V (map_core.gdshaderinc).
## Тайл заготовки — (V/BK_V, 1 − S/BK_S) в RGBA8, 256² (248 своих пикселей + поля по 4).
## Уровни k = 0…12: масштаб 2^(k/2 − 3) (0.125 … 8) × r_cls пикселей на единицу
## мира; кадр карты берёт два ближайших уровня по масштабу точки (map_baked).
## Источники: пакеты из APK (res://data/bake, уровни ≤ ×1, `--bake_pack`) и кэш
## в user://bake (рисуется здесь, на устройстве, там, куда смотрят; предел —
## Settings.bake_cache). На видеокарте — атлас из CAP мест (холст 16×16 тайлов,
## atlas_vp) и таблица страниц (номер места + 1 на тайл, строки уровней, лето / зима).
## В атлас тайл кладёт видеокарта: маленькая текстура тайла рисуется в холст
## (glTexSubImage3D в слой массива, которым занята видеокарта, на Adreno 619 стоил
## 35–55 мс на тайл — отчёт ноября 2026); в таблицу — через кадр, когда нарисован.

const T := 248                  # своих пикселей тайла
const TS := 256                 # с полями
const PAD := 4
const NLV := 13
const APK_MAX_K := 11           # уровни в APK: до ×5.6 — вся карта (решение пользователя ноябрь 2026; пакеты — AVIF)
const CAP := 256                # мест в атласе (холст AN × AN тайлов)
const AN := 16
const PACK_DIR := "res://data/bake/"
const DL_DIR := "user://bake_dl/"   # докачанные пакеты (BakeDownload; ветка bake-data на GitHub)
const CACHE_ROOT := "user://bake/"
const BAKE_VERSION := 1         # поднять, если заготовки меняются не из шейдера
const SUB := 1 << 29            # ключ тайла пакета (плотность 1) при r_cls ≠ 1 — подмена
const UPLOADS := 24             # тайлов в атлас за кадр (ПК; телефон — uploads)
# версии заготовок, совпадающие по содержанию тайлов (новая метка → прежняя): правка
# только чтения заготовок (<bake-read> в шейдере) пакеты не обесценивает
const VER_SAME := {"54879c7a": "0d3331cc", "3483ed1d": "0d3331cc", "fe593ee6": "0d3331cc", "0be1ef20": "0d3331cc"}   # ноябрь 2026: реки вблизи — линией (вне BAKE_OUT); атлас — холст; массивы шейдера — постоянные индексы; веса границ — раньше в шейдере (живой кадр — тот же до бита)
var uploads := UPLOADS

var view: MapView
var mat: ShaderMaterial         # map_bake.gdshader
var vp: SubViewport
var rect: ColorRect
var world_px := Vector2.ONE     # размер мира, единиц
var r_cls := 1.0                # плотность заготовок (класс разрешения экрана)
var ver := ""                   # хэш шейдера и формата
var pack_stamp := ""            # метка пакетов APK (данные карты при сборке), "" — нет
var atlas: Texture2D            # холст atlas_vp
var atlas_vp: SubViewport
var _up_root: Node2D            # тайлы, которые видеокарта рисует в холст в этом кадре
var _up_mat: ShaderMaterial
var _staged: Array = []         # [key, место, узел] — рисуются в холст; в таблицу — после кадра
var _staged_keys := {}
var _slot_busy := PackedByteArray()
var _up_drawn := false
var page_img: Image
var page_tex: ImageTexture
var _page_dirty := false
# таблица страниц — кольцом текстур: обновляется та, что не нужна кадрам в
# очереди видеокарты (обновление занятой текстуры на Adreno 619 — ожидание
# драйвера, как прежний массив атласа: кадры 300–400 мс в наклоне, отчёт ноября 2026)
const PAGE_RING := 3
var page_ring := true
var _page_texs: Array = []
# текстуры тайлов для холста — пулом: новая текстура на каждый тайл (создать,
# кадром позже удалить) на Adreno 619 подозревается в кадрах 300–450 мс в наклоне
# (отчёт ноября 2026: в них видеокарте — только «в атлас 8»). Пул: та же текстура
# снова — через UP_POOL_K кадров с загрузками (кадры в очереди её уже не читают)
const UP_POOL_K := 4
var up_pool := true
var _up_texs: Array = []
var _up_i := 0
var _probe_nodes: Array = []
var _page_i := 0
var gw := PackedInt32Array()
var gh := PackedInt32Array()
var rows := PackedInt32Array()  # первая строка уровня k (лето; зима — + rows_total)
var rows_total := 0
# сетка пакетов APK (плотность 1) при r_cls ≠ 1: их тайлы — подмена своих, пока те не
# нарисованы (тот же вид, реже пиксели); строки — после своих (лето, зима)
var gw1 := PackedInt32Array()
var gh1 := PackedInt32Array()
var rows1 := PackedInt32Array()
var rows1_total := 0
var sub := false                # тайлы пакетов — подменой (r_cls ≠ 1 и пакеты есть)
var slot_key := PackedInt64Array()
var slot_use := PackedInt64Array()
var key_slot := {}
var frame := 0
var ok := false                 # заготовки можно использовать
var blk := 2                    # тайлов в блоке отрисовки по стороне
# источники на диске: key → [путь, смещение, размер] (пакет) или [путь] (кэш)
var _pack := {}
var _avif: Object = null        # декодер AVIF (MeowqCore.avif_rgba; без C++ — пакеты AVIF не берём)
var _cache := {}                # key → размер файла, байт
var _cache_use := {}            # key → кадр последнего использования
var _cache_total := 0
var _cache_dir := ""
var _jobs := {}                 # key → номер задачи загрузки
var _done: Array = []           # [key, Image] — загружены в потоках
var _mx := Mutex.new()
var _saves: Array = []          # [key, номер задачи] — пишутся в потоках
var _wish := {}                 # key → кадр запроса (нет нигде — нарисовать)
var _pending := {}              # блок, отданный на отрисовку (читать в следующем кадре)
var _ahead := PackedInt64Array()  # впрок (шаг 11): по важности, рисуются, когда запросов нет
var _ahead_i := 0
var ahead_tiles := 0            # нарисовано впрок (для замеров)
# сборка пакетов (--bake_pack): key → байты webp
var packing := false
var _pack_out := {}
var baked_tiles := 0            # для замеров
var loaded_tiles := 0


static func lv_zoom(k: int) -> float:
	return pow(2.0, k * 0.5 - 3.0)


static func key_of(s: int, k: int, tx: int, ty: int) -> int:
	return (s << 28) | (k << 22) | (ty << 11) | tx


static func key_s(key: int) -> int:
	return (key >> 28) & 1


static func key_k(key: int) -> int:
	return (key >> 22) & 63


static func key_ty(key: int) -> int:
	return (key >> 11) & 2047


static func key_tx(key: int) -> int:
	return key & 2047


func setup(v: MapView, shader_params: Dictionary) -> void:
	view = v
	world_px = v.world_size()
	# телефон — по одному тайлу за раз: чтение готового блока с видеокарты ждёт
	# её (блок 2×2 — заметная остановка кадра, отчёт: худший кадр карты 229 мс)
	blk = 1 if Device.mobile() else 4
	uploads = 8 if Device.mobile() else UPLOADS
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map_bake.gdshader")
	for n in shader_params:
		mat.set_shader_parameter(n, shader_params[n])
	vp = SubViewport.new()
	vp.disable_3d = true
	vp.transparent_bg = true
	vp.size = Vector2i(blk * T + 2 * PAD, blk * T + 2 * PAD)
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	rect = ColorRect.new()
	rect.material = mat
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vp.add_child(rect)
	var inc: ShaderInclude = load("res://shaders/map_core.gdshaderinc")
	# версия: код шейдера и формат. Данные карты в неё не входят: на телефоне
	# список и размеры файлов внутри APK читались иначе, чем на ПК, — пакеты
	# отвергались (ноябрь 2026). Пакет помечает сборка своей меткой (данные карты
	# на ПК при сборке, data_stamp) — она же ключ кэша на устройстве
	ver = "%08x" % (hash(bake_code(inc.code) + "|%d|%d|%s" % [BAKE_VERSION, T, str(world_px)]) & 0xffffffff)
	var raw := ver
	ver = VER_SAME.get(ver, ver)
	if OS.get_cmdline_user_args().has("--bakever"):
		# сырой хэш (дописать в VER_SAME при правке вне BAKE_OUT) и итоговая версия
		# (её сверяет tools/build_apk.sh с data/bake/ver.txt — перерисовывать ли пакеты)
		print("BAKEVER %s %s" % [raw, ver])
	pack_stamp = ""
	atlas_vp = SubViewport.new()
	atlas_vp.disable_3d = true
	atlas_vp.transparent_bg = true
	atlas_vp.size = Vector2i(AN * TS, AN * TS)
	atlas_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE   # пустой — один раз
	atlas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(atlas_vp)
	_up_root = Node2D.new()
	atlas_vp.add_child(_up_root)
	_up_mat = ShaderMaterial.new()
	_up_mat.shader = load("res://shaders/bake_upload.gdshader")
	atlas = atlas_vp.get_texture()
	_slot_busy.resize(CAP)
	slot_key.resize(CAP)
	slot_key.fill(-1)
	slot_use.resize(CAP)
	slot_use.fill(0)
	set_r(1.0)


## Код шейдера, от которого зависят тайлы: без чтения заготовок (<bake-read>).
## Пробы стенда (<probe> … </probe>) и подключение лёгкой карты (<phone>) — тоже мимо версии.
static func bake_code(code: String) -> String:
	var a := code.find("// <bake-read>")
	var b := code.find("// </bake-read>")
	if a >= 0 and b > a:
		code = code.substr(0, a) + code.substr(b)
	for tag in ["probe", "phone"]:
		while true:
			a = code.find("// <%s>" % tag)
			b = code.find("// </%s>" % tag)
			if a < 0 or b < a:
				break
			a = code.rfind("\n", a) + 1
			b = code.find("\n", b)
			code = code.substr(0, a) + (code.substr(b + 1) if b >= 0 else "")
	return code


## Плотность заготовок (пикселей на логический пиксель экрана; классы — в
## MapView._bake_sync_r): новый атлас, таблица, кэш своей папкой.
func set_r(r: float) -> void:
	if r == r_cls and not gw.is_empty():
		return
	r_cls = r
	gw.resize(NLV)
	gh.resize(NLV)
	rows.resize(NLV)
	rows_total = 0
	gw1.resize(NLV)
	gh1.resize(NLV)
	rows1.resize(NLV)
	rows1_total = 0
	var wmax := 1
	for k in NLV:
		var z := lv_zoom(k) * r_cls
		gw[k] = ceili(world_px.x * z / T)
		gh[k] = ceili(world_px.y * z / T)
		rows[k] = rows_total
		rows_total += gh[k]
		wmax = maxi(wmax, gw[k])
		gw1[k] = ceili(world_px.x * lv_zoom(k) / T)
		gh1[k] = ceili(world_px.y * lv_zoom(k) / T)
		rows1[k] = rows1_total
		rows1_total += gh1[k]
	slot_key.fill(-1)
	key_slot.clear()
	_unstage()
	_wish.clear()
	_ahead = PackedInt64Array()
	_pending = {}
	_wait_jobs()
	_done.clear()
	for sv in _saves:
		WorkerThreadPool.wait_for_task_completion(sv[1])
	_saves.clear()
	_pack.clear()
	pack_stamp = ""
	_scan_packs()
	sub = r_cls != 1.0 and not _pack.is_empty()
	if sub:
		wmax = maxi(wmax, gw1[NLV - 1])
	page_img = Image.create(wmax, rows_total * 2 + (rows1_total * 2 if sub else 0), false, Image.FORMAT_RG8)
	_page_texs.clear()
	for i in PAGE_RING:
		_page_texs.append(ImageTexture.create_from_image(page_img))
	_page_i = 0
	page_tex = _page_texs[0]
	_cache_dir = CACHE_ROOT + ver + ("-" + pack_stamp if pack_stamp != "" else "") + "_r%d/" % int(round(r_cls * 100.0))
	_scan_cache()
	ok = true


func _exit_tree() -> void:
	_wait_jobs()
	for sv in _saves:
		WorkerThreadPool.wait_for_task_completion(sv[1])
	_saves.clear()


## Забыть тайлы, ещё не легшие в таблицу (новая сетка: места свободны).
func _unstage() -> void:
	for st in _staged:
		(st[2] as Node).queue_free()
	_staged.clear()
	_staged_keys.clear()
	_slot_busy.fill(0)


func _wait_jobs() -> void:
	for k in _jobs:
		WorkerThreadPool.wait_for_task_completion(_jobs[k])
	_jobs.clear()


# --- пакеты APK ---------------------------------------------------------------

## Пакет уровня: из APK, иначе докачанный (BakeDownload); версию и сетку проверяет _scan_packs.
static func pack_path(s: int, k: int) -> String:
	var p := PACK_DIR + "b%d_%d.bin" % [s, k]
	if FileAccess.file_exists(p):
		return p
	return DL_DIR + "b%d_%d.bin" % [s, k]


## Перечитать пакеты (после докачки или удаления): та же плотность, новая таблица.
func reload_packs() -> void:
	var r := r_cls
	gw.clear()
	set_r(r)


func _scan_packs() -> void:
	if _avif == null and ClassDB.class_exists("MeowqCore"):
		_avif = ClassDB.instantiate("MeowqCore")
	for s in 2:
		for k in APK_MAX_K + 1:
			var path := pack_path(s, k)
			if not FileAccess.file_exists(path):
				continue
			var f := FileAccess.open(path, FileAccess.READ)
			if f == null or f.get_buffer(4).get_string_from_ascii() != "MQB1":
				continue
			var pv := f.get_pascal_string()
			var pr := f.get_float()
			var w := f.get_32()
			var h := f.get_32()
			var pv_ok := pv.begins_with(ver + "-") and (pack_stamp == "" or pv == ver + "-" + pack_stamp)
			if not pv_ok or pr != 1.0 or w != gw1[k] or h != gh1[k]:
				push_warning("MapBake: пакет %s от другой версии карты (%s, нужна %s, r %.2f, сетка %d×%d/%d×%d) — не используется" % [
					path, pv, ver, pr, w, h, gw1[k], gh1[k]])
				continue
			var tab := f.get_buffer(w * h * 8)
			if _avif == null and _pack_is_avif(f, tab):
				push_warning("MapBake: пакет %s в AVIF, а ядра C++ нет — не используется" % path)
				continue
			pack_stamp = pv.substr(ver.length() + 1)
			# при своей плотности ≠ 1 — ключи подмены (SUB)
			var bit := 0 if r_cls == 1.0 else SUB
			for i in w * h:
				var off := tab.decode_u32(i * 8)
				var sz := tab.decode_s32(i * 8 + 4)
				var key := key_of(s, k, i % w, i / w) | bit
				if sz > 0:
					_pack[key] = [path, off, sz]
				elif sz < 0:
					var sk := key_of(0, k, i % w, i / w) | bit
					if _pack.has(sk):
						_pack[key] = _pack[sk]


## Тайлы пакета в AVIF (первый непустой: «ftyp» с 4-го байта), а не в WebP («RIFF»)?
static func _pack_is_avif(f: FileAccess, tab: PackedByteArray) -> bool:
	for i in tab.size() / 8:
		if tab.decode_s32(i * 8 + 4) > 0:
			f.seek(tab.decode_u32(i * 8))
			return f.get_buffer(8).slice(4).get_string_from_ascii() == "ftyp"
	return false


static func _is_avif(b: PackedByteArray) -> bool:
	return b.size() > 12 and b[4] == 0x66 and b[5] == 0x74 and b[6] == 0x79 and b[7] == 0x70


# --- кэш на устройстве ------------------------------------------------------------

func _scan_cache() -> void:
	_cache.clear()
	_cache_use.clear()
	_cache_total = 0
	DirAccess.make_dir_recursive_absolute(_cache_dir)
	# заготовки прежних версий карты — удалить
	var root := DirAccess.open(CACHE_ROOT)
	if root != null:
		for d in root.get_directories():
			if not d.begins_with(ver + ("-" + pack_stamp if pack_stamp != "" else "") + "_r"):
				_rm_dir(CACHE_ROOT + d)
	var da := DirAccess.open(_cache_dir)
	if da == null:
		return
	for fn in da.get_files():
		var p := fn.get_basename().split("_")
		if p.size() != 4 or fn.get_extension() != "webp":
			continue
		var key := key_of(int(p[0]), int(p[1]), int(p[2]), int(p[3]))
		var sz := FileAccess.get_size(_cache_dir + fn)
		_cache[key] = sz
		_cache_use[key] = -int(Time.get_unix_time_from_system() - FileAccess.get_modified_time(_cache_dir + fn))
		_cache_total += sz


static func _rm_dir(path: String) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	for fn in da.get_files():
		da.remove(fn)
	DirAccess.remove_absolute(path)


func _cache_file(key: int) -> String:
	return _cache_dir + "%d_%d_%d_%d.webp" % [key_s(key), key_k(key), key_tx(key), key_ty(key)]


func _cache_limit() -> int:
	return int(Settings.BAKE_CACHE_MB[Settings.bake_cache()]) * 1024 * 1024


func cache_evict() -> void:
	var lim := _cache_limit()
	if _cache_total <= lim:
		return
	var keys := _cache.keys()
	keys.sort_custom(func(a, b): return int(_cache_use.get(a, 0)) < int(_cache_use.get(b, 0)))
	for key in keys:
		if _cache_total <= lim * 0.9:
			break
		DirAccess.remove_absolute(_cache_file(key))
		_cache_total -= int(_cache[key])
		_cache.erase(key)
		_cache_use.erase(key)


func cache_mb() -> float:
	return _cache_total / 1048576.0


# --- нужные тайлы --------------------------------------------------------------

## Уровень по масштабу точки (как bake_at в шейдере): [k0, вес k0 + 1].
static func lv_of(zoom: float) -> Vector2:
	var lf := clampf(2.0 * log(maxf(zoom, 1e-4)) / log(2.0) + 6.0, 0.0, 12.0)
	var k0 := mini(floori(lf), 11)
	return Vector2(k0, lf - k0)


## Тайлы для кадра камеры (позиция, масштаб в центре, наклон, фокус, логический
## размер буфера) и сезона. При наклоне масштаб точки зависит только от строки
## экрана — полосами по строкам, в каждой — свои уровни и рамка мира.
func need(cam: Vector2, zoom: float, th: float, f: float, scr: Vector2, s: int) -> PackedInt64Array:
	var keys := {}
	var bands := 1 if th <= 0.0 else 16
	var st := sin(th)
	var ct := cos(th)
	for i in bands:
		var ya := scr.y * i / bands
		var yb := scr.y * (i + 1) / bands
		var za := zoom * (ct + st * (ya - scr.y * 0.5) / f) / ct
		var zb := zoom * (ct + st * (yb - scr.y * 0.5) / f) / ct
		if za <= 0.0 or zb <= 0.0:
			continue
		var r := Rect2(_s2w(Vector2(0, ya), cam, zoom, th, f, scr), Vector2.ZERO)
		for p in [Vector2(scr.x, ya), Vector2(0, yb), Vector2(scr.x, yb)]:
			r = r.expand(_s2w(p, cam, zoom, th, f, scr))
		r = r.grow(14.0 if th > 0.0 else 1.0)   # подъём гор при наклоне
		var la := lv_of(minf(za, zb))
		var lb := lv_of(maxf(za, zb))
		var k_lo := int(la.x) if la.y < 0.999 else int(la.x) + 1
		var k_hi := int(lb.x) + 1 if lb.y > 0.001 else int(lb.x)
		for k in range(k_lo, k_hi + 1):
			_add_rect(keys, s, k, r)
	return PackedInt64Array(keys.keys())


## Тайлы плоского кадра (кэш движения): рамка мира, масштаб.
func need_flat(r: Rect2, zoom: float, s: int) -> PackedInt64Array:
	var keys := {}
	var l := lv_of(zoom)
	if l.y < 0.999:
		_add_rect(keys, s, int(l.x), r.grow(1.0))
	if l.y > 0.001:
		_add_rect(keys, s, int(l.x) + 1, r.grow(1.0))
	return PackedInt64Array(keys.keys())


func _add_rect(keys: Dictionary, s: int, k: int, r: Rect2) -> void:
	var z := lv_zoom(k) * r_cls
	var x0 := clampi(floori(r.position.x * z / T), 0, gw[k] - 1)
	var x1 := clampi(floori(r.end.x * z / T), 0, gw[k] - 1)
	var y0 := clampi(floori(r.position.y * z / T), 0, gh[k] - 1)
	var y1 := clampi(floori(r.end.y * z / T), 0, gh[k] - 1)
	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			keys[key_of(s, k, tx, ty)] = true


func _s2w(p: Vector2, pos: Vector2, z: float, th: float, f: float, scr: Vector2) -> Vector2:
	var sc := p - scr * 0.5
	if th <= 0.0:
		return sc / z + pos
	var d := f / z
	var st := sin(th)
	var ct := cos(th)
	var den := maxf(ct + st * sc.y / f, 1e-4)
	var tr := d * ct / den
	return Vector2(pos.x + tr * sc.x / f, pos.y + d * st + tr * (-st + ct * sc.y / f))


## Все тайлы в атласе? Отмечает их использованными; недостающие — загрузить с
## диска или нарисовать (по порядку запросов: последние — первыми).
## partial — для кадров в движении: хватит самого дальнего уровня сезона s (его
## держим всегда — шейдер берёт его вместо недостающего тайла, мягче, но верно).
func want(keys: PackedInt64Array, partial: bool = false, s: int = 0) -> bool:
	if not ok:
		return false
	if partial:
		want(_base_keys(s))
		var all0 := true
		for key in _base_keys(s):
			if not key_slot.has(key):
				all0 = false
		want(keys)
		return all0
	if keys.size() > CAP * 3 / 4:
		return false   # не помещается в атлас
	var all := true
	for key in keys:
		var sl: int = key_slot.get(key, -1)
		if sl >= 0:
			slot_use[sl] = frame
			continue
		all = false
		if _jobs.has(key) or _staged_keys.has(key):
			continue
		var src: Array = _pack.get(key, [])
		if src.is_empty() and _cache.has(key):
			src = [_cache_file(key)]
			_cache_use[key] = frame
		if src.is_empty():
			_wish[key] = frame
		else:
			_jobs[key] = WorkerThreadPool.add_task(_load_job.bind(key, src))
	return all


## Тайлы уровнем на dk (чётное) ступеней дальше, покрывающие те же места (на
## чётную ступень масштаб ровно вдвое меньше: тайл (tx, ty) — в (tx/2, ty/2)).
func coarse(keys: PackedInt64Array, dk: int) -> PackedInt64Array:
	var out := {}
	var sh := dk / 2
	for key in keys:
		var k := key_k(key) - dk
		if k >= 1:
			out[key_of(key_s(key), k, mini(key_tx(key) >> sh, gw[k] - 1), mini(key_ty(key) >> sh, gh[k] - 1))] = true
	return PackedInt64Array(out.keys())


## Кадр с подменой (MapView._full_soft): каждое место тайлов keys, которых нет в
## атласе, есть в нём уровнем на 1–4 ступени дальше (шейдер bake_at берёт ближний
## из них)? Тогда — использованные тайлы подмены (отмечены), иначе пусто.
func cover(keys: PackedInt64Array) -> PackedInt64Array:
	var out := {}
	var all := true
	for key in keys:
		if key_slot.has(key):
			continue
		var s := key_s(key)
		var k := key_k(key)
		var tx := key_tx(key)
		var ty := key_ty(key)
		var found := false
		if sub:
			# тайлы пакета того же уровня (плотность 1): в атласе — взять; на диске —
			# загрузить (MapView перерисует, когда лягут), пока — дальний уровень
			var sk := _sub_of(s, k, tx, ty)
			if have_quiet(sk):
				for ck in sk:
					out[ck] = true
				continue
			_sub_load(sk)
		for d in range(1, 5):
			var kc := k - d
			if kc < 1:
				break
			var f := lv_zoom(kc) / lv_zoom(k)
			var x0 := mini(floori(tx * f), gw[kc] - 1)
			var x1 := mini(floori((tx + 1) * f - 1e-6), gw[kc] - 1)
			var y0 := mini(floori(ty * f), gh[kc] - 1)
			var y1 := mini(floori((ty + 1) * f - 1e-6), gh[kc] - 1)
			var got := []
			for cy in range(y0, y1 + 1):
				for cx in range(x0, x1 + 1):
					var ck := key_of(s, kc, cx, cy)
					if not key_slot.has(ck):
						got = []
						break
					got.append(ck)
				if got.is_empty():
					break
			if not got.is_empty():
				for ck in got:
					out[ck] = true
				found = true
				break
		if not found:
			all = false
			if not sub:
				break   # подмену из пакета грузить не нужно — дальше смотреть незачем
	if not all:
		return PackedInt64Array()
	var r := PackedInt64Array(out.keys())
	have(r)
	return r


## Тайлы пакета (плотность 1) на месте тайла (s, k, tx, ty) своей плотности.
func _sub_of(s: int, k: int, tx: int, ty: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var f := 1.0 / r_cls
	var x0 := mini(floori(tx * f), gw1[k] - 1)
	var x1 := mini(floori((tx + 1) * f - 1e-6), gw1[k] - 1)
	var y0 := mini(floori(ty * f), gh1[k] - 1)
	var y1 := mini(floori((ty + 1) * f - 1e-6), gh1[k] - 1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			out.append(key_of(s, k, cx, cy) | SUB)
	return out


func have_quiet(keys: PackedInt64Array) -> bool:
	for key in keys:
		if not key_slot.has(key):
			return false
	return true


## Загрузить тайлы пакета (подмену) с диска; рисовать их не нужно — нет в пакете, нет и подмены.
func _sub_load(keys: PackedInt64Array) -> void:
	for key in keys:
		if not key_slot.has(key) and not _jobs.has(key) and not _staged_keys.has(key) and _pack.has(key):
			_jobs[key] = WorkerThreadPool.add_task(_load_job.bind(key, _pack[key]))


## Все тайлы уже в атласе? Отмечает их использованными, недостающие не просит.
func have(keys: PackedInt64Array) -> bool:
	var all := true
	for key in keys:
		var sl: int = key_slot.get(key, -1)
		if sl >= 0:
			slot_use[sl] = frame
		else:
			all = false
	return all


var _base_cache := {}


## Тайлы самого дальнего уровня (весь мир) сезона s.
func _base_keys(s: int) -> PackedInt64Array:
	var ck := s * 100 + int(r_cls * 10.0)
	if not _base_cache.has(ck):
		var out := PackedInt64Array()
		for ty in gh[0]:
			for tx in gw[0]:
				out.append(key_of(s, 0, tx, ty))
		_base_cache[ck] = out
	return _base_cache[ck]


func _load_job(key: int, src: Array) -> void:
	var img := Image.new()
	var bytes: PackedByteArray
	if src.size() == 1:
		bytes = FileAccess.get_file_as_bytes(src[0])
	else:
		var f := FileAccess.open(src[0], FileAccess.READ)
		if f != null:
			f.seek(src[1])
			bytes = f.get_buffer(src[2])
	if _is_avif(bytes):
		var px: PackedByteArray = _avif.avif_rgba(bytes) if _avif != null else PackedByteArray()
		img = Image.create_from_data(TS, TS, false, Image.FORMAT_RGBA8, px) if px.size() == TS * TS * 4 else null
	elif bytes.is_empty() or img.load_webp_from_buffer(bytes) != OK:
		img = null
	elif img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_mx.lock()
	_done.append([key, img])
	_mx.unlock()


## Каждый кадр (после решений кадра карты): загруженное — в атлас, отрисовка
## одного блока заготовок (только когда карта стоит: may_bake — при сдвиге и
## масштабе видеокарта занята кадром), таблица страниц — на видеокарту.
func tick(may_bake: bool = true) -> void:
	if not ok:
		return
	frame += 1
	# нарисованные видеокартой в холст (кадр прошёл) — в таблицу страниц
	if _up_drawn:
		_up_drawn = false
		for st in _staged:
			var sk: int = st[0]
			var ssl: int = st[1]
			_slot_busy[ssl] = 0
			if slot_key[ssl] == sk:
				key_slot[sk] = ssl
				slot_use[ssl] = frame
				_page_set(sk, ssl + 1)
			(st[2] as Node).queue_free()
		_staged.clear()
		_staged_keys.clear()
	# в атлас — не больше UPLOADS тайлов за кадр (256 КБ каждый): без рывка
	_mx.lock()
	var done := _done.slice(0, uploads)
	_done = _done.slice(uploads)
	_mx.unlock()
	var t_up := Time.get_ticks_usec()
	for d in done:
		var key: int = d[0]
		if _jobs.has(key):
			WorkerThreadPool.wait_for_task_completion(_jobs[key])
			_jobs.erase(key)
		if d[1] == null:
			_pack.erase(key)   # битый файл — нарисовать заново
			_cache.erase(key)
			if key & SUB == 0:
				_wish[key] = frame
			continue
		_put(key, d[1])
		loaded_tiles += 1
	if not done.is_empty():
		FrameProf.add("заготовки: в атлас", Time.get_ticks_usec() - t_up)
	if not _saves.is_empty():
		_saves_poll()
	if _warm_n > 0:
		_warm_n -= 1
		if _warm_n == 0:
			_warm_rect.queue_free()
			_warm_rect = null
		_page_flush()
		return
	if packing:
		return
	if _wish.size() > 256:
		# давние запросы (туда уже не смотрят) — забыть
		for k in _wish.keys():
			if int(_wish[k]) < frame - 120:
				_wish.erase(k)
	if not _pending.is_empty():
		var t_rd := Time.get_ticks_usec()
		_read_block()
		if _pending.is_empty():
			FrameProf.add("заготовки: чтение тайла", Time.get_ticks_usec() - t_rd)
	elif not _wish.is_empty() and may_bake:
		_bake_next()
	elif _ahead_i < _ahead.size() and may_bake:
		_bake_ahead()
	_page_flush()


func _page_flush() -> void:
	if _page_dirty:
		_page_dirty = false
		var t_pg := Time.get_ticks_usec()
		if page_ring:
			# следующая в кольце: последний раз её читал кадр PAGE_RING назад
			_page_i = (_page_i + 1) % PAGE_RING
			page_tex = _page_texs[_page_i]
			page_tex.update(page_img)
			view._param("page_tex", page_tex)
		else:
			page_tex.update(page_img)
		FrameProf.add("заготовки: таблица", Time.get_ticks_usec() - t_pg)


## Положить тайл в атлас: место (свободное или давнее), прежний тайл места — из
## таблицы сразу (видеокарта перерисует место в этом кадре), новый — в таблицу
## в следующем тике, после кадра (MapView в этом кадре его ещё не просит).
func _put(key: int, img: Image, free_only := false) -> void:
	if key_slot.has(key) or _staged_keys.has(key):
		return
	var sl := -1
	var best := 1 << 62
	for i in CAP:
		if _slot_busy[i] != 0:
			continue
		if slot_key[i] < 0:
			sl = i
			break
		if free_only:
			continue
		if slot_use[i] < best and slot_use[i] < frame - 1:
			best = slot_use[i]
			sl = i
	if sl < 0:
		return   # всё занято нужным в этом кадре
	var old := slot_key[sl]
	if old >= 0:
		key_slot.erase(old)
		_page_set(old, 0)
	slot_key[sl] = key
	slot_use[sl] = frame
	_slot_busy[sl] = 1
	var spr := Sprite2D.new()
	spr.centered = false
	spr.texture = _up_tex(img)
	spr.material = _up_mat
	spr.position = Vector2((sl % AN) * TS, (sl / AN) * TS)
	_up_root.add_child(spr)
	_staged.append([key, sl, spr])
	MapView.gnote("в атлас", float(TS * TS))
	_staged_keys[key] = true
	atlas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if not RenderingServer.frame_post_draw.is_connected(_on_up_drawn):
		RenderingServer.frame_post_draw.connect(_on_up_drawn, CONNECT_ONE_SHOT)


## Текстура тайла для холста: из пула (up_pool) или новая.
func _up_tex(img: Image) -> ImageTexture:
	if not up_pool:
		return ImageTexture.create_from_image(img)
	var n := maxi(1, uploads) * UP_POOL_K
	var t: ImageTexture
	if _up_texs.size() < n:
		t = ImageTexture.create_from_image(img)
		_up_texs.append(t)
	else:
		t = _up_texs[_up_i]
		if t.get_size() == Vector2(img.get_size()) and t.get_format() == img.get_format():
			t.update(img)
		else:
			t = ImageTexture.create_from_image(img)
			_up_texs[_up_i] = t
	_up_i = (_up_i + 1) % n
	return t


## Проба стенда: n тайлов в холст атласа (как загрузка), не меняя его (сложение
## нуля); прежние пробные — убрать. n = 0 — только убрать.
func probe_put(n: int, img: Image, pool: bool) -> void:
	for nd in _probe_nodes:
		(nd as Node).queue_free()
	_probe_nodes.clear()
	if n <= 0:
		return
	var pm := ShaderMaterial.new()
	pm.shader = load("res://shaders/bake_probe_put.gdshader")
	var up0 := up_pool
	up_pool = pool
	for i in n:
		var spr := Sprite2D.new()
		spr.centered = false
		spr.texture = _up_tex(img)
		spr.material = pm
		spr.position = Vector2((i % AN) * TS, (i / AN) * TS)
		_up_root.add_child(spr)
		_probe_nodes.append(spr)
	up_pool = up0
	MapView.gnote("в атлас", float(n * TS * TS))
	atlas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _on_up_drawn() -> void:
	_up_drawn = true


func _page_set(key: int, v: int) -> void:
	var y := rows[key_k(key)] + key_ty(key) + key_s(key) * rows_total
	if key & SUB:
		y = rows_total * 2 + rows1[key_k(key)] + key_ty(key) + key_s(key) * rows1_total
	page_img.set_pixel(key_tx(key), y, Color8(v & 255, v >> 8, 0, 255))
	_page_dirty = true


## Строка уровня 0 сезона s в таблице страниц (шейдеру — pg_row).
func pg_rows(s: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(NLV)
	for k in NLV:
		out[k] = rows[k] + s * rows_total
	return out


## То же для тайлов пакетов (подмена, шейдеру — pg_row1); −1 — подмены нет.
func pg_rows1(s: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(NLV)
	for k in NLV:
		out[k] = rows_total * 2 + rows1[k] + s * rows1_total if sub else -1
	return out


func _bake_next() -> void:
	# последний запрошенный — первым (то, куда смотрят сейчас)
	var key := -1
	var fr := -1
	for k in _wish:
		if int(_wish[k]) > fr:
			fr = _wish[k]
			key = k
	_wish.erase(key)
	if key_slot.has(key) or _jobs.has(key) or _staged_keys.has(key) or _pack.has(key) or _cache.has(key):
		return
	var s := key_s(key)
	var k := key_k(key)
	var tx0 := key_tx(key) - key_tx(key) % blk
	var ty0 := key_ty(key) - key_ty(key) % blk
	bake_block(s, k, tx0, ty0)


## Впрок (шаг 11): тайлы, которые понадобятся при приближении, отдалении и сдвиге
## от вида (центр cam, масштаб zoom, логический размер scr), — по важности; рисуются
## по одному блоку за кадр, когда карта стоит и запросов вида нет, — в кэш на диске
## (в атлас — только в свободные слои: нужное не вытеснять). Иначе после
## приближения кадры живые (~300 мс на llvmpipe), пока тайлы не дорисуются.
func plan_ahead(cam: Vector2, zoom: float, scr: Vector2, s: int) -> void:
	_ahead = PackedInt64Array()
	_ahead_i = 0
	if not ok or zoom <= 0.0:
		return
	var l := lv_of(zoom)
	var k0 := int(l.x)
	var half := scr * 0.5 / zoom
	var view := Rect2(cam - half, half * 2.0)
	var mid := Rect2(cam - half * 0.6, half * 1.2)
	# [уровень, рамка]: приближение ×1.4 где угодно на экране, отдаление ×1.4,
	# сдвиг на четверть экрана, приближение ×2 к середине, отдаление ×2
	var groups := [[k0 + 2, view], [k0 - 1, view.grow_individual(half.x, half.y, half.x, half.y)],
		[k0, view.grow_individual(half.x * 0.5, half.y * 0.5, half.x * 0.5, half.y * 0.5)],
		[k0 + 1, view.grow_individual(half.x * 0.5, half.y * 0.5, half.x * 0.5, half.y * 0.5)],
		[k0 + 3, mid], [k0 - 2, view.grow_individual(half.x * 3.0, half.y * 3.0, half.x * 3.0, half.y * 3.0)]]
	var lm := lv_of(MapView.MAX_ZOOM)   # ближе предела приближения — не нужно
	var kmax := int(lm.x) + (1 if lm.y > 0.001 else 0)
	var seen := {}
	for g in groups:
		var k: int = g[0]
		if k < 0 or k > kmax:
			continue
		var keys := {}
		_add_rect(keys, s, k, g[1])
		var z := lv_zoom(k) * r_cls
		var c := cam * z / T
		var list: Array = []
		for key in keys:
			if seen.has(key) or key_slot.has(key) or _pack.has(key) or _cache.has(key):
				continue
			seen[key] = true
			var d := Vector2(key_tx(key) + 0.5, key_ty(key) + 0.5).distance_squared_to(c)
			list.append([d, key])
		list.sort()   # от середины к краям
		for e in list:
			_ahead.append(e[1])
		if _ahead.size() >= CAP * 3:
			break


func _bake_ahead() -> void:
	while _ahead_i < _ahead.size():
		var key := _ahead[_ahead_i]
		_ahead_i += 1
		if key_slot.has(key) or _jobs.has(key) or _staged_keys.has(key) or _pack.has(key) or _cache.has(key):
			continue
		var k := key_k(key)
		bake_block(key_s(key), k, key_tx(key) - key_tx(key) % blk, key_ty(key) - key_ty(key) % blk)
		_pending["ahead"] = true
		return


## Нарисовать блок тайлов (до blk × blk) уровня k сезона s с тайла (tx0, ty0).
func bake_block(s: int, k: int, tx0: int, ty0: int) -> void:
	var nx := mini(blk, gw[k] - tx0)
	var ny := mini(blk, gh[k] - ty0)
	var size := Vector2(nx * T + 2 * PAD, ny * T + 2 * PAD)
	var z := lv_zoom(k)
	var zr := z * r_cls
	var cam := (Vector2(tx0 * T - PAD, ty0 * T - PAD) + size * 0.5) / zr
	mat.set_shader_parameter("quality", 2)
	mat.set_shader_parameter("res_k", r_cls)
	mat.set_shader_parameter("buf_size", size)
	mat.set_shader_parameter("scr_size", size / r_cls)
	mat.set_shader_parameter("cam_pos", cam)
	mat.set_shader_parameter("cam_zoom", z)
	mat.set_shader_parameter("cam_tilt", 0.0)
	mat.set_shader_parameter("torus_n", Vector2.ZERO)
	mat.set_shader_parameter("winter", float(s))
	rect.position = Vector2.ZERO
	rect.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	MapView.gnote("тайлы рисуются", size.x * size.y)
	_pending = {"s": s, "k": k, "tx": tx0, "ty": ty0, "nx": nx, "ny": ny, "f": frame, "drawn": false}
	# читать — только после настоящей отрисовки кадра (в режиме «не рисовать без
	# изменений» кадр может и не рисоваться: в буфере — прежний блок)
	RenderingServer.frame_post_draw.connect(_on_drawn, CONNECT_ONE_SHOT)


func _on_drawn() -> void:
	if not _pending.is_empty():
		_pending["drawn"] = true


## Прогрев шейдеров при загрузке (на телефоне первая компиляция — рывок до
## полсекунды): заготовка и кадр с заготовками — по квадрату 2×2 в буфере блока.
var _warm_rect: ColorRect
var _warm_n := 0


func warm(baked: ShaderMaterial) -> void:
	_warm_rect = ColorRect.new()
	_warm_rect.material = baked
	_warm_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warm_rect.position = Vector2(4, 0)
	_warm_rect.size = Vector2(2, 2)
	vp.add_child(_warm_rect)
	rect.size = Vector2(2, 2)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_warm_n = 3


func _read_block() -> void:
	if _pending.is_empty() or frame <= int(_pending["f"]) or not _pending["drawn"]:
		return
	var p := _pending
	_pending = {}
	var img := vp.get_texture().get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	for j in int(p["ny"]):
		for i in int(p["nx"]):
			var key := key_of(p["s"], p["k"], int(p["tx"]) + i, int(p["ty"]) + j)
			var t := img.get_region(Rect2i(i * T, j * T, TS, TS))
			baked_tiles += 1
			if packing:
				_pack_out[key] = t.save_webp_to_buffer(false)
				continue
			if p.get("ahead", false):
				ahead_tiles += 1
				if not _cache.has(key):
					_put(key, t, true)
					_save(key, t)
				continue
			_put(key, t)
			_save(key, t)


func _save(key: int, t: Image) -> void:
	var path := _cache_file(key)
	_cache[key] = 0
	_cache_use[key] = frame
	# с потерями (q 0.9, альфа без потерь — так кодирует Godot): в среднем ~2.8
	# уровня цвета, в ~3.5 раза меньше файла без потерь (q 0.95 — на 19 % больше
	# при 2.4 уровня; на глаз не отличить, ui.md) — в предел кэша влезает больше
	# карты; кодируется даже быстрее, чем без потерь (~12 мс на ПК)
	var task := WorkerThreadPool.add_task(func():
		t.save_webp(path, true, 0.9))
	_saves.append([key, task])


## Записанные файлы кэша: размер в учёт, лишнее — вытеснить.
func _saves_poll() -> void:
	var left: Array = []
	var any := false
	for sv in _saves:
		if not WorkerThreadPool.is_task_completed(sv[1]):
			left.append(sv)
			continue
		WorkerThreadPool.wait_for_task_completion(sv[1])
		var key: int = sv[0]
		if _cache.has(key):
			var sz := FileAccess.get_size(_cache_file(key))
			_cache[key] = sz
			_cache_total += sz
			any = true
	_saves = left
	if any:
		cache_evict()


# --- сборка пакетов для APK (--bake_pack) ------------------------------------------

## Метка данных карты (сборка на ПК): размеры файлов data/world1936/*.bin и графики.
static func data_stamp() -> String:
	var sig := ""
	for dir in ["res://data/world1936/", "res://assets/map/"]:
		var da := DirAccess.open(dir)
		if da == null:
			continue
		var fs := da.get_files()
		fs.sort()
		for fn in fs:
			if fn.ends_with(".bin") or fn.ends_with(".webp") or fn.ends_with(".png"):
				sig += "|%s:%d" % [fn, FileAccess.get_size(dir + fn)]
	return "%08x" % (hash(sig) & 0xffffffff)


## Оценка объёма (--bake_sample): случайные блоки уровней levels обоих сезонов
## в пакеты-выборки (остальные тайлы — пустые записи); сжать tools/bake_compress.py.
func sample_packs(out_dir: String, levels: Array, blocks: int) -> void:
	packing = true
	DirAccess.make_dir_recursive_absolute(out_dir)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1936
	for k in levels:
		var pos: Array = []
		for i in blocks:
			pos.append(Vector2i(rng.randi_range(0, (gw[k] - 1) / blk) * blk, rng.randi_range(0, (gh[k] - 1) / blk) * blk))
		var summer := {}
		for s in 2:
			_pack_out.clear()
			for p in pos:
				bake_block(s, k, p.x, p.y)
				while not _pending["drawn"]:
					await get_tree().process_frame
				await get_tree().process_frame
				frame += 2
				_read_block()
			var f := FileAccess.open(out_dir.path_join("b%d_%d.bin" % [s, k]), FileAccess.WRITE)
			f.store_buffer("MQB1".to_ascii_buffer())
			f.store_pascal_string("sample")
			f.store_float(r_cls)
			f.store_32(gw[k])
			f.store_32(gh[k])
			var tab_pos := f.get_position()
			var tab := PackedByteArray()
			tab.resize(gw[k] * gh[k] * 8)
			f.store_buffer(tab)
			var n := 0
			var same := 0
			for key in _pack_out:
				var i := key_ty(key) * gw[k] + key_tx(key)
				var b: PackedByteArray = _pack_out[key]
				var sk := key_of(0, k, key_tx(key), key_ty(key))
				if s == 1 and summer.has(sk) and summer[sk] == b:
					tab.encode_s32(i * 8 + 4, -1)
					same += 1
					continue
				tab.encode_u32(i * 8, f.get_position())
				tab.encode_s32(i * 8 + 4, b.size())
				f.store_buffer(b)
				n += 1
			f.seek(tab_pos)
			f.store_buffer(tab)
			f.close()
			print("sample: k=%d s=%d тайлов %d (как летом %d) из %d×%d" % [k, s, n, same, gw[k], gh[k]])
			if s == 0:
				summer = _pack_out.duplicate()
	packing = false


## Нарисовать все тайлы уровней 0…APK_MAX_K обоих сезонов и записать пакеты
## (зима: тайлы, совпавшие с летом, — ссылкой на летний).
## levels — какие уровни (пусто — все до APK_MAX_K): сборка по уровню за раз —
## без потерь ближние уровни занимают гигабайты (×5.6 — ~2 ГБ), сжимаются сразу.
func build_packs(out_dir: String, levels: Array = []) -> void:
	packing = true
	DirAccess.make_dir_recursive_absolute(out_dir)
	var t0 := Time.get_ticks_msec()
	var total := 0
	var stamp := ver + "-" + data_stamp()
	if levels.is_empty():
		levels = range(APK_MAX_K + 1)
	for k in levels:
		var summer := {}   # key лета → хэш байтов (зима, совпавшая с летом, — ссылкой)
		for s in 2:
			# пишется по ходу (ближние уровни — сотни МБ: в памяти не держим)
			var path := out_dir.path_join("b%d_%d.bin" % [s, k])
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_buffer("MQB1".to_ascii_buffer())
			f.store_pascal_string(stamp)
			f.store_float(r_cls)
			f.store_32(gw[k])
			f.store_32(gh[k])
			var tab_pos := f.get_position()
			var tab := PackedByteArray()
			tab.resize(gw[k] * gh[k] * 8)
			f.store_buffer(tab)
			var same := 0
			for ty0 in range(0, gh[k], blk):
				for tx0 in range(0, gw[k], blk):
					_pack_out.clear()
					bake_block(s, k, tx0, ty0)
					while not _pending["drawn"]:
						await get_tree().process_frame
					await get_tree().process_frame
					frame += 2
					_read_block()
					for key in _pack_out:
						var b: PackedByteArray = _pack_out[key]
						var tx := key_tx(key)
						var ty := key_ty(key)
						var i := ty * gw[k] + tx
						var hb := hash(b)
						var sk := key_of(0, k, tx, ty)
						if s == 0:
							summer[sk] = hb
						elif summer.get(sk, -1) == hb:
							tab.encode_u32(i * 8, 0)
							tab.encode_s32(i * 8 + 4, -1)
							same += 1
							continue
						tab.encode_u32(i * 8, f.get_position())
						tab.encode_s32(i * 8 + 4, b.size())
						f.store_buffer(b)
			_pack_out.clear()
			f.seek(tab_pos)
			f.store_buffer(tab)
			f.seek_end()
			total += f.get_length()
			print("bake: уровень %d сезон %d — %d×%d тайлов, %.1f МБ (как летом: %d), %.0f с" % [k, s, gw[k], gh[k],
				f.get_length() / 1048576.0, same, (Time.get_ticks_msec() - t0) / 1000.0])
			f.close()
	print("bake: всего %.1f МБ за %.0f с" % [total / 1048576.0, (Time.get_ticks_msec() - t0) / 1000.0])
	packing = false
