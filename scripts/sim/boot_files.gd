class_name BootFiles
extends RefCounted
## Файлы запуска, которые готовятся рабочими потоками (ImgPrefetch,
## ResourceLoader): картинки мира и карты, map.json и nations.json, картинки
## окон; чтение графики карты и дорог. Отдельно от MapView, MapLoader и Hud —
## маленький скрипт без зависимостей: стартовая сцена (scripts/boot.gd) ставит
## задачи ещё до сборки скриптов игры (~1 с на ПК, на телефоне в разы
## дольше), и всё это идёт одновременно со сборкой.

const WORLD_DIR := "res://data/world1936"
const ART_DIR := "res://assets/map/"
const ART_FILES := {"color_w": "colormap_w.webp", "color_e": "colormap_e.webp", "normal_w": "normal_w.png", "normal_e": "normal_e.png"}
const ROAD_HALVES := 8
## Графика карты в APK (tools/pack_art.gd, при сборке): .ctex формата ETC2,
## сжатый zstd. Godot кладёт .ctex в APK без сжатия (4 × 40 МБ), а сжатые они
## ~60 МБ на все четыре; assets/map в APK не входит (export_presets.cfg).
## Заголовок: ART_PACK_MAGIC, размер .ctex, ширина и высота исходной картинки (u32).
const ART_PACK_DIR := "res://data/art/"
const ART_PACK_MAGIC := "MQZ1"


## Картинки окон, которые нужны до главного меню (Hud._ready и меню; список —
## по замеру, ноябрь 2026). Нет в списке — грузится на месте, как раньше.
const UI_START := ["sheet.png", "card.png", "card_pressed.png", "tb_leather.jpg", "tb_paper.jpg",
	"tb_tag.png", "tb_tag_on.png", "spine_shadow.png", "spine_focus.png", "spine_army.png",
	"spine_navy.png", "spine_production.png", "spine_research.png", "spine_build.png",
	"spine_diplomacy.png", "spine_all.png", "spine_mapmode.png", "spine_menu.png", "ic_card.png",
	"ic_button.png", "ic_button_pressed.png", "dossier_right.png", "clipboard_clip.png",
	"dossier_spread.png", "dossier_label.png", "paperclip.png", "sheet_crumpled.png",
	"stamp_top_secret.png", "ev_board.png", "ev_sheet_shadow.png", "ev_sheet.png", "ev_clip.png"]
const UI_DIR := "res://assets/ui/"


## Всё при запуске (стартовая сцена).
static func prefetch_all() -> void:
	prefetch_world()
	prefetch_map(true, true)
	for n in UI_START:
		var p: String = UI_DIR + n
		if ResourceLoader.exists(p):
			ResourceLoader.load_threaded_request(p)


## Картинки мира и разбор map.json, nations.json (MapLoader.load_world).
static func prefetch_world(dir: String = WORLD_DIR) -> void:
	ImgPrefetch.json_file(dir + "/map.json")
	ImgPrefetch.json_file(dir + "/nations.json")
	ImgPrefetch.file(dir + "/provinces.png.bin")
	ImgPrefetch.file(dir + "/relief.png.bin")
	ImgPrefetch.file(dir + "/terrain.jpg.bin")
	ImgPrefetch.file(dir + "/detail.png.bin", -1, true)


## Картинки карты (MapView.setup). Поля и карта 2× — только если их ещё нет в
## кэше MapView (ids2, sdf).
static func prefetch_map(ids2: bool, sdf: bool) -> void:
	var d := WORLD_DIR + "/"
	if ids2:
		for k in ["w", "e"]:
			ImgPrefetch.file(d + "ids2_%s.png.bin" % k, Image.FORMAT_RG8)
	if sdf:
		for k in ["w", "e"]:
			ImgPrefetch.file(d + "sdf_%s.png.bin" % k, Image.FORMAT_L8, true)
	ImgPrefetch.file(d + "cover.png.bin", Image.FORMAT_RGBA8, true)
	ImgPrefetch.file(d + "rivers.png.bin", Image.FORMAT_RGBA8, true)
	for k in ["color_w", "color_e", "normal_w", "normal_e"]:
		var src: String = ART_DIR + ART_FILES[k]
		ImgPrefetch.run("art:" + src, ctex_read.bind(art_src(src)))
	ImgPrefetch.file(d + "sprites.png.bin")
	ImgPrefetch.file(d + "road_tex.png.bin")
	ImgPrefetch.file(d + "water.png.bin")
	ImgPrefetch.run("roads", roads_build)


## Файл с данными текстуры src: .ctex импорта (ПК) или упакованный (APK); "" — нет.
static func art_src(src: String) -> String:
	var p := ctex_path(src)
	if p != "":
		return p
	var z := ART_PACK_DIR + src.get_file() + ".etc2.zst"
	return z if OS.has_feature("etc2") and FileAccess.file_exists(z) else ""


## Файл .ctex, который выбрал бы движок: первый path.<формат> из .import,
## поддержанный устройством (ResourceFormatImporter), — и который есть в сборке.
static func ctex_path(src: String) -> String:
	var cf := ConfigFile.new()
	if not FileAccess.file_exists(src + ".import") or cf.load(src + ".import") != OK or not cf.has_section("remap"):
		return ""
	for key in cf.get_section_keys("remap"):
		var kp := str(cf.get_value("remap", key))
		if key.begins_with("path.") and OS.has_feature(key.get_slice(".", 1)) and FileAccess.file_exists(kp):
			return kp
	var p := str(cf.get_value("remap", "path", ""))
	return p if p != "" and FileAccess.file_exists(p) else ""


## Байты .ctex (упакованный — распаковать).
static func ctex_bytes(path: String) -> PackedByteArray:
	var buf := FileAccess.get_file_as_bytes(path)
	if buf.size() < 16 or buf.slice(0, 4).get_string_from_ascii() != ART_PACK_MAGIC:
		return buf
	return buf.slice(16).decompress(buf.decode_u32(4), FileAccess.COMPRESSION_ZSTD)


## Разбор .ctex (CompressedTexture2D::load_image_from_file, DATA_FORMAT_IMAGE);
## можно в рабочем потоке. null — нет файла или не тот формат.
static func ctex_read(path: String) -> Image:
	if path == "":
		return null
	var b := ctex_bytes(path)
	# GST2, версия, ширина, высота, флаги, предел mip, 3 запасных — 36 байт
	if b.size() < 52 or b.slice(0, 4).get_string_from_ascii() != "GST2":
		return null
	if b.decode_u32(36) != 0:  # DATA_FORMAT_IMAGE: сырые данные (сжатие в видеопамяти)
		return null
	var w := b.decode_u16(40)
	var h := b.decode_u16(42)
	var mips := b.decode_u32(44)
	var fmt := b.decode_u32(48)
	if w == 0 or h == 0 or fmt >= Image.FORMAT_MAX:
		return null
	var img := Image.create_from_data(w, h, mips > 0, fmt as Image.Format, b.slice(52))
	return img if img != null and not img.is_empty() else null


## Разделы дорог одной картинкой: 3 + 2·ROAD_HALVES разделов один под другим,
## по rr строк (по наибольшему номеру провинции в файле). Только данные файла —
## при запуске рабочим потоком (prefetch_map): разбор ~0,75 МБ JSON и
## запись пикселей занимали главный поток ~70 мс на ПК. null — файла нет.
static func roads_build() -> Image:
	var path := "res://data/world1936/roads.json"
	if not FileAccess.file_exists(path):
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return null
	var q: float = float((data as Dictionary).get("q", 8.0))
	var prov: Dictionary = (data as Dictionary).get("prov", {})
	var top := 0
	for key in prov:
		top = maxi(top, int(key))
	var rr := top / 64 + 1
	var ns := 3 + 2 * ROAD_HALVES
	var img := Image.create(64, rr * ns, false, Image.FORMAT_RGBA8)
	for key in prov:
		var p := int(key)
		if p < 0:
			continue
		var v: Dictionary = prov[key]
		var c: Array = v["c"]
		var hs: Array = v["h"]
		var x := p % 64
		var y := p / 64
		img.set_pixel(x, y, road_pt(float(c[0]), float(c[1]), q))
		var n := mini(hs.size(), ROAD_HALVES)
		var tb := 0
		var fb := 0
		for i in n:
			var h: Array = hs[i]
			tb |= (int(h[0]) & 3) << (2 * i)
			fb |= (int(h[1]) & 1) << i
			img.set_pixel(x, (2 + 2 * i) * rr + y, road_pt(float(h[2]), float(h[3]), q))
			img.set_pixel(x, (3 + 2 * i) * rr + y, road_pt(float(h[4]), float(h[5]), q))
		img.set_pixel(x, rr + y, Color8(n | (int(v.get("t", 0)) & 48), tb & 255, (tb >> 8) & 255, fb))
		var pr: Array = v.get("p", [0, 0])
		img.set_pixel(x, (2 + 2 * ROAD_HALVES) * rr + y, Color8(int(pr[0]), int(pr[1]), 0, 0))
	return img


static func road_pt(x: float, y: float, q: float) -> Color:
	var ix := clampi(int(round(x * q)), 0, 65535)
	var iy := clampi(int(round(y * q)), 0, 65535)
	return Color8(ix & 255, ix >> 8, iy & 255, iy >> 8)
