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


## Качество карты: 0 — низкое, 1 — среднее, 2 — высокое. По умолчанию на
## телефоне — среднее, на ПК — высокое.
static func map_quality() -> int:
	for a in OS.get_cmdline_user_args():   # для замеров: -- --quality=0|1|2
		if a.begins_with("--quality="):
			return clampi(int(a.split("=")[1]), 0, 2)
	var def := 1 if OS.has_feature("mobile") else 2
	return int(_load().get_value("graphics", "map_quality", def))


static func set_map_quality(q: int) -> void:
	_load().set_value("graphics", "map_quality", clampi(q, 0, 2))
	_cfg.save(PATH)


## Разрешение карты (доля пикселей экрана): 0 — 50%, 1 — 75%, 2 — 100%,
## 3 — авто (подбирается по времени отрисовки). По умолчанию: телефон — авто, ПК — 100%.
static func map_res() -> int:
	for a in OS.get_cmdline_user_args():   # для замеров: -- --mapres=0|1|2
		if a.begins_with("--mapres="):
			return clampi(int(a.split("=")[1]), 0, 3)
	var def := 3 if OS.has_feature("mobile") else 2
	return int(_load().get_value("graphics", "map_res", def))


static func set_map_res(r: int) -> void:
	_load().set_value("graphics", "map_res", clampi(r, 0, 3))
	_cfg.save(PATH)


## Упрощать карту, пока её двигают (быстрее сдвиг на слабом телефоне).
## По умолчанию: телефон — да, ПК — нет.
static func motion_lite() -> bool:
	return bool(_load().get_value("graphics", "motion_lite", OS.has_feature("mobile")))


static func set_motion_lite(v: bool) -> void:
	_load().set_value("graphics", "motion_lite", v)
	_cfg.save(PATH)


## Ограничение кадров: 0 — 30, 1 — 60, 2 — без ограничения (по частоте экрана).
## На экранах 90–120 Гц лишние кадры только греют телефон.
static func fps_cap() -> int:
	var def := 1 if OS.has_feature("mobile") else 2
	return int(_load().get_value("graphics", "fps_cap", def))


static func set_fps_cap(i: int) -> void:
	_load().set_value("graphics", "fps_cap", clampi(i, 0, 2))
	_cfg.save(PATH)
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
