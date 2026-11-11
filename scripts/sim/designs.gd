class_name Designs
extends RefCounted
## Конструктор самолётов (решение пользователя, ноябрь 2026): проект = корпус +
## модули в слотах. Характеристики: атака и защита в воздушном бою,
## манёвренность (всегда входит в силу ×1,5: атака × манёвренность × 1,5),
## координация (доля самолётов крыла, что бьёт согласованно, — от проекта,
## доктрин и электроники), удары по войскам, бомбёжка, удары по флоту, цена.
## Проект с бомбами или торпедой — бомбардировщик (крыло вида 1), иначе
## истребитель (вид 0). Корпуса и модули открываются технологиями.
## Таблицы читаются только из главного потока.

const BASE_COORD := 0.3
const MAX_SAME := 2       # одного модуля в проекте не больше двух
const MAN_MULT := 1.5     # манёвренность входит в атаку и защиту с множителем 1,5

# [id, название, технология, слотов, защита, манёвренность, цена, тяжёлый (бомбоотсеки и турели)]
const HULLS := [
	["light1", "Лёгкий биплан", "", 3, 3.0, 1.15, 1.0, false],
	["light2", "Лёгкий моноплан", "fig1", 4, 4.0, 1.2, 1.1, false],
	["light3", "Скоростной моноплан", "fig3", 4, 5.0, 1.3, 1.25, false],
	["light4", "Высотный истребитель", "fig4", 5, 6.0, 1.35, 1.4, false],
	["med1", "Двухмоторный", "", 4, 7.0, 0.8, 2.0, true],
	["med2", "Двухмоторный скоростной", "bmb2", 5, 9.0, 0.85, 2.3, true],
	["heavy1", "Четырёхмоторный", "bmb3", 6, 13.0, 0.6, 3.6, true],
]

# [id, название, технология, эффекты, только тяжёлый корпус]
const MODS := [
	["mg", "Пулемёты", "", {"atk": 3.0}, false],
	["hmg", "Крупнокалиберные пулемёты", "fig2", {"atk": 5.0, "agi": -0.03, "cost": 0.05}, false],
	["cannon", "Авиапушки", "fig3", {"atk": 8.0, "agi": -0.05, "cost": 0.15}, false],
	["turret", "Оборонительные турели", "bmb1", {"def": 4.0, "agi": -0.05, "cost": 0.1}, true],
	["armor", "Бронеспинка", "", {"def": 2.0, "agi": -0.04, "cost": 0.05}, false],
	["armor2", "Бронирование кабины", "cas3", {"def": 4.0, "agi": -0.08, "cost": 0.1}, false],
	["radio", "Радиостанция", "rad1", {"coord": 0.15, "cost": 0.05}, false],
	["radio2", "УКВ-рация", "rad3", {"coord": 0.25, "cost": 0.1}, false],
	["engine", "Форсированный мотор", "aen1", {"agi": 0.1, "cost": 0.15}, false],
	["engine2", "Двухрядная «звезда»", "aen2", {"agi": 0.15, "cost": 0.25}, false],
	["bombs", "Подвесные бомбы", "", {"ground": 6.0, "agi": -0.1}, false],
	["dive", "Тормозные решётки (пикирование)", "cas2", {"ground": 5.0, "agi": -0.03, "cost": 0.05}, false],
	["bay", "Бомбоотсек", "", {"bomb": 8.0, "cost": 0.2}, true],
	["bay2", "Большой бомбоотсек", "bmb3", {"bomb": 14.0, "agi": -0.05, "cost": 0.4}, true],
	["torpedo", "Авиаторпеда", "nav1", {"naval": 8.0, "agi": -0.08, "cost": 0.15}, false],
]

const STAT_NAMES := {"atk": "атака", "def": "защита", "agi": "манёвренность", "coord": "координация",
	"ground": "удар по войскам", "bomb": "бомбёжка", "naval": "удар по флоту", "cost": "цена"}
const ROLES := ["fighter", "cas", "strat", "naval"]

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


static func mods_for(nat, hull_id: String) -> Array:
	var h := hull(hull_id)
	var res: Array = []
	for m in MODS:
		if has_tech(nat, m[2]) and (not bool(m[4]) or (not h.is_empty() and bool(h[7]))):
			res.append(m[0])
	return res


## Характеристики проекта (без бонусов страны).
static func stats(hull_id: String, mods: Array) -> Dictionary:
	var h := hull(hull_id)
	var s := {"atk": 0.0, "def": 0.0, "agi": 1.0, "coord": BASE_COORD, "ground": 0.0, "bomb": 0.0, "naval": 0.0, "cost": 1.0}
	if h.is_empty():
		return s
	s["def"] = float(h[4])
	s["agi"] = float(h[5])
	s["cost"] = float(h[6])
	for mid in mods:
		var m := module(String(mid))
		if m.is_empty():
			continue
		var eff: Dictionary = m[3]
		for k in eff:
			s[k] = float(s[k]) + float(eff[k])
	s["agi"] = maxf(0.3, float(s["agi"]))
	s["coord"] = clampf(float(s["coord"]), 0.0, 1.0)
	s["kind"] = 1 if float(s["ground"]) + float(s["bomb"]) + float(s["naval"]) > 0.0 else 0
	return s


## Можно ли собрать такой проект стране (корпус, модули, число слотов).
static func valid(nat, hull_id: String, mods: Array) -> bool:
	var h := hull(hull_id)
	if h.is_empty() or not has_tech(nat, h[2]) or mods.size() > int(h[3]):
		return false
	var ok := mods_for(nat, hull_id)
	for m in mods:
		if not ok.has(String(m)) or mods.count(m) > MAX_SAME:
			return false
	return true


## Оценка проекта для роли (автосборка ИИ).
static func score(s: Dictionary, role: String) -> float:
	var agi: float = s["agi"] * MAN_MULT
	match role:
		"fighter":
			if int(s["kind"]) != 0:
				return -1e9
			return (float(s["atk"]) + float(s["def"]) * 0.7) * agi + float(s["coord"]) * 10.0 - float(s["cost"]) * 2.0
		"cas":
			return float(s["ground"]) * 2.0 + float(s["def"]) * agi * 0.4 + float(s["coord"]) * 4.0 - float(s["cost"]) * 2.0
		"strat":
			return float(s["bomb"]) * 2.0 + float(s["def"]) * agi * 0.5 + float(s["coord"]) * 4.0 - float(s["cost"]) * 1.5
		"naval":
			return float(s["naval"]) * 2.0 + float(s["def"]) * agi * 0.4 + float(s["coord"]) * 4.0 - float(s["cost"]) * 2.0
	return 0.0


## Лучший проект для роли по технологиям страны: перебор корпусов, слоты —
## жадно лучшим модулем (повторы разрешены). Возвращает [корпус, модули].
static func auto(nat, role: String) -> Array:
	var best_h := ""
	var best_m: Array = []
	var best_s := -1e18
	for hid in hulls_for(nat):
		var h := hull(hid)
		var mods: Array = []
		var ok := mods_for(nat, hid)
		for slot in int(h[3]):
			var pick := ""
			var ps := score(stats(hid, mods), role) if not mods.is_empty() else -1e18
			for mid in ok:
				if mods.count(mid) >= MAX_SAME:
					continue
				var trial := mods.duplicate()
				trial.append(mid)
				var sc := score(stats(hid, trial), role)
				if sc > ps + 1e-9:
					ps = sc
					pick = mid
			if pick == "":
				break
			mods.append(pick)
		var sc2 := score(stats(hid, mods), role)
		if sc2 > best_s:
			best_s = sc2
			best_h = hid
			best_m = mods
	return [best_h, best_m]


## Записать проект в мир; возвращает его номер (такой же у страны уже есть — его номер).
static func add(world, nid: int, name: String, hull_id: String, mods: Array) -> int:
	for i in world.plane_designs.size():
		var d: Dictionary = world.plane_designs[i]
		if int(d["owner"]) == nid and d["hull"] == hull_id and d["mods"] == mods:
			return i
	var d := stats(hull_id, mods)
	d["owner"] = nid
	d["name"] = name
	d["hull"] = hull_id
	d["mods"] = mods.duplicate()
	d["id"] = world.plane_designs.size()
	world.plane_designs.append(d)
	return int(d["id"])


## Поставить проект в производство (вид — по проекту) и пересчитать цену выпуска.
static func set_production(world, nat, did: int) -> void:
	var d: Dictionary = world.plane_designs[did]
	var k: int = d["kind"]
	nat.air_design[k] = did
	# цена относительно базовой (истребитель 1,0, бомбардировщик 2,0)
	nat.plane_cost[k] = maxf(0.5, float(d["cost"]) / (1.0 if k == 0 else 2.0))


static func role_for_bombers(nat) -> String:
	match Doctrine.pref(nat, "air"):
		"bmb":
			return "strat"
	return "cas"


static func _role_name(role: String) -> String:
	match role:
		"fighter":
			return "Истребитель"
		"cas":
			return "Штурмовик"
		"strat":
			return "Бомбардировщик"
	return "Торпедоносец"


## ИИ (и стартовые проекты игрока): собрать лучшие проекты по нынешним
## технологиям и поставить в производство, если они лучше текущих.
static func ai_update(world, nat) -> void:
	for role in ["fighter", role_for_bombers(nat)]:
		var hm := auto(nat, role)
		if String(hm[0]) == "":
			continue
		var s := stats(hm[0], hm[1])
		var k: int = s["kind"]
		var cur: int = nat.air_design[k]
		if cur >= 0:
			var cd: Dictionary = world.plane_designs[cur]
			if score(stats(cd["hull"], cd["mods"]), role) >= score(s, role) - 1e-9:
				continue
		var nm := "%s %s-%d" % [_role_name(role), nat.tag, world.plane_designs.size()]
		set_production(world, nat, add(world, nat.id, nm, hm[0], hm[1]))


## Проект крыла: свой, иначе нынешний в производстве у владельца.
static func of_wing(world, w) -> Dictionary:
	var did: int = w.design
	if did < 0 or did >= world.plane_designs.size():
		did = world.nations[w.owner].air_design[w.kind]
	if did < 0 or did >= world.plane_designs.size():
		return stats("light1" if w.kind == 0 else "med1", ["mg"] if w.kind == 0 else ["bombs"])
	return world.plane_designs[did]


## Описание характеристик проекта словами.
static func stats_text(s: Dictionary) -> String:
	var parts: Array = []
	parts.append("атака %d" % roundi(float(s["atk"])))
	parts.append("защита %d" % roundi(float(s["def"])))
	parts.append("манёвренность %.2f" % float(s["agi"]))
	parts.append("координация %d%%" % roundi(float(s["coord"]) * 100.0))
	if float(s["ground"]) > 0.0:
		parts.append("удар по войскам %d" % roundi(float(s["ground"])))
	if float(s["bomb"]) > 0.0:
		parts.append("бомбёжка %d" % roundi(float(s["bomb"])))
	if float(s["naval"]) > 0.0:
		parts.append("удар по флоту %d" % roundi(float(s["naval"])))
	parts.append("цена %.2f" % float(s["cost"]))
	return ", ".join(parts)
