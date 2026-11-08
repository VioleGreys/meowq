class_name Settings
extends RefCounted
## Настройки игрока на устройстве (user://settings.cfg).

const PATH := "user://settings.cfg"
const QUALITY_NAMES := ["Низкое", "Среднее", "Высокое"]
const RES_SCALES := [0.5, 0.75, 1.0]
const RES_NAMES := ["50%", "75%", "100%"]

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


## Разрешение карты (доля пикселей экрана): 0 — 50%, 1 — 75%, 2 — 100%.
## По умолчанию на телефоне — 75%, на ПК — 100%.
static func map_res() -> int:
	for a in OS.get_cmdline_user_args():   # для замеров: -- --mapres=0|1|2
		if a.begins_with("--mapres="):
			return clampi(int(a.split("=")[1]), 0, 2)
	var def := 1 if OS.has_feature("mobile") else 2
	return int(_load().get_value("graphics", "map_res", def))


static func set_map_res(r: int) -> void:
	_load().set_value("graphics", "map_res", clampi(r, 0, 2))
	_cfg.save(PATH)


## Упрощать карту, пока её двигают (быстрее сдвиг на слабом телефоне).
## По умолчанию: телефон — да, ПК — нет.
static func motion_lite() -> bool:
	return bool(_load().get_value("graphics", "motion_lite", OS.has_feature("mobile")))


static func set_motion_lite(v: bool) -> void:
	_load().set_value("graphics", "motion_lite", v)
	_cfg.save(PATH)
