class_name Settings
extends RefCounted
## Настройки игрока на устройстве (user://settings.cfg).

const PATH := "user://settings.cfg"
const QUALITY_NAMES := ["Низкое", "Среднее", "Высокое"]
const RES_SCALES := [0.5, 0.75, 1.0, 0.0]   # 0 — авто
const RES_NAMES := ["50%", "75%", "100%", "Авто"]
const FPS_CAPS := [30, 60, 0]
const FPS_NAMES := ["30", "60", "Без огр."]

static var _cfg: ConfigFile = null


static func _load() -> ConfigFile:
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(PATH)   # нет файла — пустые настройки
	return _cfg


## Уровень графики (решение пользователя, ноябрь 2026): три готовых набора,
## «Своя» (-1) — после ручной правки отдельной настройки. По умолчанию —
## «Средняя» на всех устройствах (лёгкая карта стандартная).
const GRAPHICS_NAMES := ["Низкая", "Средняя", "Высокая"]
## Что включает каждый уровень: качество, разрешение (индекс RES_SCALES),
## ограничение кадров (индекс FPS_CAPS), упрощение при движении, лёгкая карта, наклон.
const PRESETS := [
	{"map_quality": 0, "map_res": 1, "fps_cap": 0, "motion_lite": true, "phone_map": true, "map_tilt": false},
	{"map_quality": 1, "map_res": 3, "fps_cap": 1, "motion_lite": true, "phone_map": true, "map_tilt": true},
	{"map_quality": 2, "map_res": 2, "fps_cap": 2, "motion_lite": false, "phone_map": false, "map_tilt": true},
]
const DEFAULT_LEVEL := 1


static func graphics_level() -> int:
	return clampi(int(_load().get_value("graphics", "level", DEFAULT_LEVEL)), -1, 2)


## Выбрать готовый уровень (отдельные настройки берутся из набора).
static func set_graphics_level(l: int) -> void:
	_load().set_value("graphics", "level", clampi(l, 0, 2))
	_cfg.save(PATH)


## Значение графической настройки: из набора уровня или своё («Своя»).
static func _gfx(key: String):
	var l := graphics_level()
	if l >= 0:
		return PRESETS[l][key]
	return _load().get_value("graphics", key, PRESETS[DEFAULT_LEVEL][key])


## Ручная правка одной настройки: уровень становится «Своя», остальные
## сохраняются такими, какими были в наборе.
static func _set_gfx(key: String, v) -> void:
	var l := graphics_level()
	if l >= 0:
		for k in PRESETS[l]:
			_load().set_value("graphics", k, PRESETS[l][k])
		_cfg.set_value("graphics", "level", -1)
	_load().set_value("graphics", key, v)
	_cfg.save(PATH)


static func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.split("=")[1]
	return ""


## Качество карты: 0 — низкое, 1 — среднее, 2 — высокое; для замеров: -- --quality=0|1|2.
static func map_quality() -> int:
	if _arg("quality") != "":
		return clampi(int(_arg("quality")), 0, 2)
	return clampi(int(_gfx("map_quality")), 0, 2)


static func set_map_quality(q: int) -> void:
	_set_gfx("map_quality", clampi(q, 0, 2))


## Разрешение карты (доля пикселей экрана): 0 — 50%, 1 — 75%, 2 — 100%,
## 3 — авто (подбирается по времени отрисовки); для замеров: -- --mapres=0|1|2|3.
static func map_res() -> int:
	if _arg("mapres") != "":
		return clampi(int(_arg("mapres")), 0, 3)
	return clampi(int(_gfx("map_res")), 0, 3)


static func set_map_res(r: int) -> void:
	_set_gfx("map_res", clampi(r, 0, 3))


## Упрощать карту, пока её двигают (быстрее сдвиг на слабом телефоне).
static func motion_lite() -> bool:
	return bool(_gfx("motion_lite"))


static func set_motion_lite(v: bool) -> void:
	_set_gfx("motion_lite", v)


## Лёгкая карта (map_phone.gdshader): из заготовок, политика по соседям 2×2 —
## кадр карты в разы дешевле полного шейдера; для замеров: -- --phonemap=0|1.
static func phone_map() -> bool:
	if _arg("phonemap") != "":
		return _arg("phonemap") == "1"
	return bool(_gfx("phone_map"))


static func set_phone_map(v: bool) -> void:
	_set_gfx("phone_map", v)


## Наклон камеры при приближении (перспектива, как в стратегиях жанра).
static func map_tilt() -> bool:
	return bool(_gfx("map_tilt"))


static func set_map_tilt(v: bool) -> void:
	_set_gfx("map_tilt", v)


## Ограничение кадров: 0 — 30, 1 — 60, 2 — без ограничения (по частоте экрана).
## На экранах 90–120 Гц лишние кадры только греют телефон.
static func fps_cap() -> int:
	return clampi(int(_gfx("fps_cap")), 0, 2)


static func set_fps_cap(i: int) -> void:
	_set_gfx("fps_cap", clampi(i, 0, 2))
	apply_fps_cap()


static func apply_fps_cap() -> void:
	Engine.max_fps = FPS_CAPS[clampi(fps_cap(), 0, 2)]


## Звук нажатия кнопок (по умолчанию включён).
static func ui_sound() -> bool:
	return bool(_load().get_value("audio", "ui_sound", true))


static func set_ui_sound(v: bool) -> void:
	_load().set_value("audio", "ui_sound", v)
	_cfg.save(PATH)


## Строка замеров внизу экрана (FPS, тик, кадр) — для разработки, по умолчанию скрыта.
static func show_perf() -> bool:
	for a in OS.get_cmdline_user_args():
		if a == "--perf":
			return true
	return bool(_load().get_value("debug", "show_perf", false))


static func set_show_perf(v: bool) -> void:
	_load().set_value("debug", "show_perf", v)
	_cfg.save(PATH)


## Автосохранение: раз в 5 минут игры, при выходе в меню и сворачивании.
static func autosave() -> bool:
	return bool(_load().get_value("game", "autosave", true))


static func set_autosave(v: bool) -> void:
	_load().set_value("game", "autosave", v)
	_cfg.save(PATH)


## Предел кэша заготовок карты на устройстве (решение пользователя: 500 МБ по
## умолчанию, можно больше), МБ. Ближние масштабы рисуются заранее там, куда
## смотрит игрок, и хранятся в user://bake; старые вытесняются.
const BAKE_CACHE_MB := [500, 1000, 2000]
const BAKE_CACHE_NAMES := ["500 МБ", "1 ГБ", "2 ГБ"]


static func bake_cache() -> int:
	return clampi(int(_load().get_value("graphics", "bake_cache", 0)), 0, 2)


static func set_bake_cache(i: int) -> void:
	_load().set_value("graphics", "bake_cache", clampi(i, 0, 2))
	_cfg.save(PATH)
