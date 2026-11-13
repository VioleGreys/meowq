class_name TankDesigns
extends RefCounted
## Конструктор танков (решение пользователя, ноябрь 2026): проект = шасси +
## модули в слотах. Характеристики проекта: броня, бронебойность (лучшая из
## пушек и пулемётов), атака (множитель атаки танкового батальона, 1,0 —
## лёгкий танк 1936 г.), скорость (множитель скорости батальона), цена
## (множитель цены бронетехники). Проект в производстве у страны
## (Nation.tank_design) — у всех её танковых батальонов. Шасси и модули
## открываются технологиями. Таблицы читаются только из главного потока.

const MAX_SAME := 2   # одного модуля в проекте не больше двух
const MAX_GUNS := 1   # пушка в башне одна

# [id, название, технология, слотов, броня, скорость, цена, атака]
const HULLS := [
	["light1", "Лёгкое шасси", "armor1", 3, 10.0, 1.0, 1.0, 0.35],
	["light2", "Лёгкое шасси с башней", "lt2", 3, 15.0, 1.0, 1.05, 0.4],
	["med1", "Среднее шасси", "armor2", 4, 30.0, 0.9, 1.3, 0.5],
	["med2", "Среднее шасси с наклонной бронёй", "mt3", 4, 45.0, 0.92, 1.45, 0.55],
	["heavy1", "Тяжёлое шасси", "ht1", 5, 70.0, 0.7, 1.8, 0.6],
	["heavy2", "Тяжёлое шасси прорыва", "ht2", 5, 90.0, 0.65, 2.1, 0.65],
]

# [id, название, технология, эффекты, пушка]
# pierce — бронебойность (у проекта — лучшая из модулей), остальное складывается
const MODS := [
	["mg", "Спаренные пулемёты", "", {"atk": 0.15, "pierce": 5.0}, false],
	["gun20", "Автоматическая пушка 20 мм", "armor1", {"atk": 0.35, "pierce": 15.0, "cost": 0.05}, true],
	["gun37", "Противотанковая пушка 37–47 мм", "lt2", {"atk": 0.4, "pierce": 35.0, "cost": 0.08}, true],
	["gun75s", "Короткоствольная пушка 75 мм", "armor2", {"atk": 0.6, "pierce": 30.0, "cost": 0.12}, true],
	["gun75l", "Длинноствольная пушка 75 мм", "mt2", {"atk": 0.55, "pierce": 70.0, "cost": 0.2}, true],
	["gun88", "Тяжёлая пушка 85–88 мм", "ht2", {"atk": 0.6, "pierce": 100.0, "speed": -0.05, "cost": 0.3}, true],
	["armor", "Дополнительная броня", "", {"armor": 6.0, "speed": -0.05, "cost": 0.08}, false],
	["armor2", "Наклонные листы и экраны", "mt3", {"armor": 12.0, "speed": -0.04, "cost": 0.12}, false],
	["radio", "Радиостанция", "lt2", {"atk": 0.1, "cost": 0.04}, false],
	["engine", "Танковый двигатель", "ten1", {"speed": 0.1, "cost": 0.06}, false],
	["tracks", "Широкие гусеницы", "ten2", {"speed": 0.06, "cost": 0.04}, false],
]

const STAT_NAMES := {"armor": "броня", "pierce": "бронебойность", "atk": "атака", "speed": "скорость", "cost": "цена"}
# без проекта (страна без танков, старое сохранение): лёгкий танк 1936 г.
const FALLBACK := {"armor": 10.0, "pierce": 15.0, "atk": 1.0, "speed": 1.0, "cost": 1.0}

static var _hull := {}
static var _mod := {}


static func _ensure() -> void:
	if not _hull.is_empty():
		return
	for h in HULLS:
		_hull[h[0]] = h
	for m in MODS:
		_mod[m[0]] = m


static func hull(id: String) -> Array:
	_ensure()
	return _hull.get(id, [])


static func module(id: String) -> Array:
	_ensure()
	return _mod.get(id, [])


static func has_tech(nat, req: String) -> bool:
	return req == "" or nat.techs.has(req)


static func hulls_for(nat) -> Array:
	var res: Array = []
	for h in HULLS:
		if has_tech(nat, h[2]):
			res.append(h[0])
	return res


static func mods_for(nat) -> Array:
	var res: Array = []
	for m in MODS:
		if has_tech(nat, m[2]):
			res.append(m[0])
	return res


static func is_gun(mid: String) -> bool:
	var m := module(mid)
	return not m.is_empty() and bool(m[4])


## Характеристики проекта (без бонусов страны).
static func stats(hull_id: String, mods: Array) -> Dictionary:
	var h := hull(hull_id)
	if h.is_empty():
		return FALLBACK.duplicate()
	var s := {"armor": float(h[4]), "pierce": 0.0, "atk": float(h[7]), "speed": float(h[5]), "cost": float(h[6])}
	for mid in mods:
		var m := module(String(mid))
		if m.is_empty():
			continue
		var eff: Dictionary = m[3]
		for k in eff:
			if k == "pierce":
				s["pierce"] = maxf(float(s["pierce"]), float(eff[k]))
			else:
				s[k] = float(s[k]) + float(eff[k])
	s["speed"] = maxf(0.3, float(s["speed"]))
	return s


## Можно ли собрать такой проект стране (шасси, модули, слоты, одна пушка).
static func valid(nat, hull_id: String, mods: Array) -> bool:
	var h := hull(hull_id)
	if h.is_empty() or not has_tech(nat, h[2]) or mods.size() > int(h[3]):
		return false
	var ok := mods_for(nat)
	var guns := 0
	for m in mods:
		if not ok.has(String(m)) or mods.count(m) > MAX_SAME:
			return false
		if is_gun(String(m)):
			guns += 1
	return guns <= MAX_GUNS


## Оценка проекта (автосборка ИИ): атака, пробитие и броня против цены.
static func score(s: Dictionary) -> float:
	return float(s["atk"]) * 10.0 + float(s["pierce"]) * 0.08 + float(s["armor"]) * 0.08 \
		+ float(s["speed"]) * 3.0 - float(s["cost"]) * 4.0


## Лучший проект по технологиям страны: перебор шасси, слоты — жадно лучшим
## модулем. Возвращает [шасси, модули].
static func auto(nat) -> Array:
	_ensure()
	var best_h := ""
	var best_m: Array = []
	var best_s := -1e18
	var ok := mods_for(nat)
	for hid in hulls_for(nat):
		var h := hull(hid)
		var mods: Array = []
		for slot in int(h[3]):
			var pick := ""
			var ps := score(stats(hid, mods)) if not mods.is_empty() else -1e18
			for mid in ok:
				var trial := mods.duplicate()
				trial.append(mid)
				if not valid(nat, hid, trial):
					continue
				var sc := score(stats(hid, trial))
				if sc > ps + 1e-9:
					ps = sc
					pick = mid
			if pick == "":
				break
			mods.append(pick)
		var sc2 := score(stats(hid, mods))
		if sc2 > best_s:
			best_s = sc2
			best_h = hid
			best_m = mods
	return [best_h, best_m]


## Записать проект в мир; возвращает его номер (такой же у страны уже есть — его номер).
static func add(world, nid: int, name: String, hull_id: String, mods: Array) -> int:
	for i in world.tank_designs.size():
		var d: Dictionary = world.tank_designs[i]
		if int(d["owner"]) == nid and d["hull"] == hull_id and d["mods"] == mods:
			return i
	var d := stats(hull_id, mods)
	d["owner"] = nid
	d["name"] = name
	d["hull"] = hull_id
	d["mods"] = mods.duplicate()
	d["id"] = world.tank_designs.size()
	world.tank_designs.append(d)
	return int(d["id"])


## Проект в производстве у страны (или запасной — лёгкий танк 1936 г.).
static func of_nation(world, nat) -> Dictionary:
	var did: int = nat.tank_design
	if did < 0 or did >= world.tank_designs.size():
		return FALLBACK
	return world.tank_designs[did]


## Поставить проект в производство: цена бронетехники и характеристики всех
## танковых батальонов страны (дивизии пересчитываются).
static func set_production(world, nat, did: int) -> void:
	nat.tank_design = did
	nat.tank_cost = maxf(0.5, float(world.tank_designs[did]["cost"]))
	nat.tank_heavy = String(world.tank_designs[did]["hull"]).begins_with("heavy")
	for d in world.divisions:
		if d.alive and d.owner == nat.id and Military.bat_n(world.templates[d.tpl]["bat"], Military.B_TANK) > 0:
			Military.refresh_division(world, d)


## ИИ (и стартовый проект игрока): лучший проект по нынешним технологиям —
## в производство, если он лучше текущего.
static func ai_update(world, nat) -> void:
	if nat.tank_techs == nat.techs.size() and nat.tank_design >= 0:
		return
	nat.tank_techs = nat.techs.size()
	var hm := auto(nat)
	if String(hm[0]) == "":
		return
	var s := stats(hm[0], hm[1])
	if nat.tank_design >= 0:
		var cd: Dictionary = world.tank_designs[nat.tank_design]
		if score(stats(cd["hull"], cd["mods"])) >= score(s) - 1e-9:
			return
	var nm := "%s %s-%d" % [String(hull(hm[0])[1]).get_slice(" ", 0), nat.tag, world.tank_designs.size()]
	set_production(world, nat, add(world, nat.id, nm, hm[0], hm[1]))


## Описание характеристик проекта словами.
static func stats_text(s: Dictionary) -> String:
	return "броня %d, бронебойность %d, атака ×%.2f, скорость ×%.2f, цена ×%.2f" % [
		roundi(float(s["armor"])), roundi(float(s["pierce"])), float(s["atk"]), float(s["speed"]), float(s["cost"])]
