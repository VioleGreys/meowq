class_name ShipDesigns
extends RefCounted
## Конструктор кораблей (решение пользователя, ноябрь 2026): проект = корпус +
## модули в слотах. Три категории: подлодки, крейсеры (все надводные боевые
## корабли — корпуса от эсминца до линкора) и авианосцы. Категорию задаёт
## корпус. Характеристики: огонь (по кораблям), живучесть (сколько урона
## выдерживает корабль), ПЛО, ПВО, авиагруппа (удар палубной авиации),
## рейды (удар подлодок по торговле), скрытность (подлодки), цена в очках
## судостроения. Корпуса и модули открываются технологиями.
## Таблицы читаются только из главного потока.

const KIND_SS := 0
const KIND_CR := 1
const KIND_CV := 2
const KIND_NAMES := ["Подлодки", "Крейсеры", "Авианосцы"]
const KIND_ONE := ["подлодка", "крейсер", "авианосец"]
const MAX_SAME := 2       # одного модуля в проекте не больше двух
const SIZE_NAMES := ["малый", "средний", "большой"]

# род кораблей для качества по технологиям (World.n_ship: страна × 5)
const FAM_BB := 0
const FAM_CR := 1
const FAM_DD := 2
const FAM_SS := 3
const FAM_CV := 4
const FAMS := 5

# [id, название, категория, технология, слотов, размер (0..2), род, базовые
#  характеристики, цена, очередь потерь (сначала гибнут меньшие номера)]
const HULLS := [
	["ss_s", "Малая подлодка", 0, "", 2, 0, 3, {"atk": 0.3, "def": 0.8, "raid": 0.3, "stealth": 0.4}, 70.0, 0],
	["ss_m", "Средняя подлодка", 0, "", 3, 0, 3, {"atk": 0.4, "def": 1.2, "raid": 0.4, "stealth": 0.3}, 110.0, 0],
	["ss_o", "Океанская подлодка", 0, "ss2", 4, 0, 3, {"atk": 0.5, "def": 1.4, "raid": 0.6, "stealth": 0.3}, 150.0, 0],
	["de", "Эскортный корабль", 1, "dd3", 2, 0, 2, {"atk": 0.1, "def": 0.8, "asw": 0.5, "aa": 0.1}, 60.0, 0],
	["dd", "Эсминец", 1, "", 3, 0, 2, {"atk": 0.3, "def": 1.0, "asw": 0.2, "aa": 0.1}, 110.0, 0],
	["dd2", "Большой эсминец", 1, "dd2", 4, 0, 2, {"atk": 0.4, "def": 1.3, "asw": 0.2, "aa": 0.2}, 160.0, 0],
	["cl", "Лёгкий крейсер", 1, "", 4, 1, 1, {"atk": 1.2, "def": 4.0, "asw": 0.2, "aa": 0.3}, 650.0, 1],
	["ca", "Тяжёлый крейсер", 1, "cr2", 5, 1, 1, {"atk": 1.5, "def": 5.5, "aa": 0.4}, 950.0, 1],
	["bb", "Линкор", 1, "", 5, 2, 0, {"atk": 3.0, "def": 10.0, "aa": 0.4}, 2600.0, 2],
	["bb2", "Быстроходный линкор", 1, "bb1", 6, 2, 0, {"atk": 3.5, "def": 11.0, "aa": 0.6}, 3200.0, 2],
	["cvl", "Лёгкий авианосец", 2, "", 3, 1, 4, {"atk": 0.1, "def": 3.0, "aa": 0.3, "air": 1.0}, 800.0, 2],
	["cv", "Авианосец", 2, "", 4, 2, 4, {"atk": 0.2, "def": 6.0, "aa": 0.4, "air": 2.0}, 1700.0, 3],
	["cv2", "Ударный авианосец", 2, "cv2", 5, 2, 4, {"atk": 0.2, "def": 7.0, "aa": 0.6, "air": 2.5}, 2300.0, 3],
]

# [id, название, категории, технология, эффекты, цена, размер от, размер до]
const MODS := [
	["torp", "Торпедные аппараты", [0], "", {"atk": 0.4, "raid": 0.3}, 10.0, 0, 0],
	["torp2", "Неконтактные торпеды", [0], "ss3", {"atk": 0.6, "raid": 0.4}, 20.0, 0, 0],
	["deck", "Палубное орудие", [0], "", {"raid": 0.3, "stealth": -0.05}, 5.0, 0, 0],
	["mines", "Мины", [0], "ss1", {"raid": 0.4}, 10.0, 0, 0],
	["batt", "Аккумуляторы большой ёмкости", [0], "ss2", {"stealth": 0.1}, 10.0, 0, 0],
	["snork", "Шноркель", [0], "ss4", {"stealth": 0.15, "raid": 0.2}, 20.0, 0, 0],
	["guns", "Универсальные орудия", [1], "", {"atk": 0.4, "aa": 0.1}, 10.0, 0, 1],
	["torps", "Торпедные аппараты", [1], "", {"atk": 0.4}, 10.0, 0, 1],
	["dc0", "Глубинные бомбы", [1], "", {"asw": 0.2}, 5.0, 0, 1],
	["sonar", "Гидролокатор", [1], "asw1", {"asw": 0.3}, 10.0, 0, 1],
	["dc", "Бомбомёты", [1], "asw2", {"asw": 0.4}, 10.0, 0, 1],
	["gun6", "Шестидюймовая башня", [1], "", {"atk": 1.2}, 80.0, 1, 1],
	["gun8", "Восьмидюймовая башня", [1], "cr2", {"atk": 1.8}, 140.0, 1, 1],
	["main", "Башня главного калибра", [1], "", {"atk": 3.0}, 300.0, 2, 2],
	["main2", "Главный калибр нового образца", [1], "bb2", {"atk": 4.0}, 400.0, 2, 2],
	["belt", "Броневой пояс", [1], "", {"def": 1.5}, 60.0, 1, 2],
	["plane", "Катапультный самолёт", [1], "", {"atk": 0.2, "asw": 0.1}, 20.0, 1, 2],
	["wing", "Авиагруппа истребителей и разведчиков", [2], "", {"air": 1.0, "aa": 0.3}, 70.0, 1, 2],
	["torpw", "Палубные торпедоносцы", [2], "nav1", {"air": 2.0}, 110.0, 1, 2],
	["divew", "Палубные пикировщики", [2], "nav3", {"air": 2.5, "asw": 0.2}, 140.0, 1, 2],
	["armdeck", "Бронированная полётная палуба", [2], "cv1", {"def": 2.0, "air": -0.3}, 120.0, 1, 2],
	["hangar", "Расширенный ангар", [2], "cv3", {"air": 1.0}, 60.0, 2, 2],
	["aa", "Зенитные автоматы", [1, 2], "", {"aa": 0.3}, 15.0, 0, 2],
	["aa2", "Зенитки с наведением по локатору", [1, 2], "dd4", {"aa": 0.6}, 30.0, 0, 2],
	["radar", "Корабельный радар", [1, 2], "rdr3", {"atk": 0.2, "aa": 0.2, "asw": 0.1}, 30.0, 0, 2],
]

const STAT_NAMES := {"atk": "огонь", "def": "живучесть", "asw": "ПЛО", "aa": "ПВО", "air": "авиагруппа",
	"raid": "рейды", "stealth": "скрытность", "cost": "цена"}
const KEYS := ["atk", "def", "asw", "aa", "air", "raid", "stealth"]
# роли ИИ (и «основные» проекты страны для событий истории): категория и размер корпуса
const ROLES := ["escort", "cruiser", "capital", "sub", "carrier"]
const ROLE_KIND := [1, 1, 1, 0, 2]
const ROLE_SIZE := [0, 1, 2, -1, -1]
const ROLE_NAMES := ["Эсминец", "Крейсер", "Линкор", "Подлодка", "Авианосец"]
const ROLE_PLURAL := ["эсминцы", "крейсеры", "линкоры", "подлодки", "авианосцы"]
# ключи событий истории (forces.json, focuses.json): bb/cr/dd/ss/cv -> роль
const ROLE_OF_KEY := {"dd": 0, "cr": 1, "bb": 2, "ss": 3, "cv": 4}

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


## Подходит ли модуль корпусу (категория и размер), без учёта технологий.
static func fits(m: Array, h: Array) -> bool:
	return not h.is_empty() and (m[2] as Array).has(int(h[2])) and int(h[5]) >= int(m[6]) and int(h[5]) <= int(m[7])


static func mods_for(nat, hull_id: String) -> Array:
	var h := hull(hull_id)
	var res: Array = []
	for m in MODS:
		if has_tech(nat, m[3]) and fits(m, h):
			res.append(m[0])
	return res


## Характеристики проекта (без бонусов страны).
static func stats(hull_id: String, mods: Array) -> Dictionary:
	var h := hull(hull_id)
	var s := {"atk": 0.0, "def": 0.0, "asw": 0.0, "aa": 0.0, "air": 0.0, "raid": 0.0, "stealth": 0.0, "cost": 0.0,
		"kind": 1, "size": 0, "fam": FAM_DD, "prio": 0}
	if h.is_empty():
		return s
	var base: Dictionary = h[7]
	for k in base:
		s[k] = float(base[k])
	s["cost"] = float(h[8])
	s["kind"] = int(h[2])
	s["size"] = int(h[5])
	s["fam"] = int(h[6])
	s["prio"] = int(h[9])
	for mid in mods:
		var m := module(String(mid))
		if m.is_empty():
			continue
		var eff: Dictionary = m[4]
		for k in eff:
			s[k] = float(s[k]) + float(eff[k])
		s["cost"] = float(s["cost"]) + float(m[5])
	for k in KEYS:
		s[k] = maxf(0.0, float(s[k]))
	s["stealth"] = minf(0.8, float(s["stealth"]))
	s["def"] = maxf(0.3, float(s["def"]))
	s["power"] = power_of(s)
	return s


## Боевая сила корабля (для господства на море, оценок ИИ, шкалы сил):
## огонь, удар авиагруппы и живучесть пополам, ПЛО и ПВО — четвертью.
static func power_of(s: Dictionary) -> float:
	return (float(s["atk"]) + float(s["air"]) + float(s["def"])) * 0.5 + (float(s["asw"]) + float(s["aa"])) * 0.25


static func valid(nat, hull_id: String, mods: Array) -> bool:
	var h := hull(hull_id)
	if h.is_empty() or not has_tech(nat, h[3]) or mods.size() > int(h[4]):
		return false
	var ok := mods_for(nat, hull_id)
	for m in mods:
		if not ok.has(String(m)) or mods.count(m) > MAX_SAME:
			return false
	return true


## Роль проекта (для сравнения с «основным» проектом страны).
static func role_of(s: Dictionary) -> int:
	match int(s["kind"]):
		0:
			return 3
		2:
			return 4
	return clampi(int(s["size"]), 0, 2)


## Оценка проекта для роли (автосборка ИИ).
static func score(s: Dictionary, role: int) -> float:
	var atk: float = s["atk"]
	var df: float = s["def"]
	var asw: float = s["asw"]
	var aa: float = s["aa"]
	var c: float = s["cost"]
	match role:
		0:
			return atk + asw * 2.0 + aa * 0.5 + df * 0.5 - c * 0.003
		1:
			return atk * 1.5 + df * 0.5 + aa * 0.5 + asw * 0.3 - c * 0.001
		2:
			return atk + df * 0.6 + aa * 0.4 - c * 0.0005
		3:
			return float(s["raid"]) * 2.0 + atk + float(s["stealth"]) * 3.0 + df * 0.3 - c * 0.005
		4:
			return float(s["air"]) * 1.5 + df * 0.3 + aa * 0.5 - c * 0.0005
	return 0.0


static func hull_fits_role(h: Array, role: int) -> bool:
	return int(h[2]) == ROLE_KIND[role] and (ROLE_SIZE[role] < 0 or int(h[5]) == ROLE_SIZE[role])


## Лучший проект роли по технологиям страны: перебор корпусов, слоты — жадно
## лучшим модулем. Возвращает [корпус, модули] (корпус "" — нечего строить).
static func auto(nat, role: int) -> Array:
	_ensure()
	var best_h := ""
	var best_m: Array = []
	var best_s := -1e18
	for h in HULLS:
		if not hull_fits_role(h, role) or not has_tech(nat, h[3]):
			continue
		var hid: String = h[0]
		var ok := mods_for(nat, hid)
		var mods: Array = []
		var cur := score(stats(hid, mods), role)
		for slot in int(h[4]):
			var pick := ""
			var ps := cur
			for mid in ok:
				if mods.count(mid) >= MAX_SAME:
					continue
				var tm := mods.duplicate()
				tm.append(mid)
				var sc := score(stats(hid, tm), role)
				if sc > ps + 1e-9:
					ps = sc
					pick = mid
			if pick == "":
				break
			mods.append(pick)
			cur = ps
		if cur > best_s:
			best_s = cur
			best_h = hid
			best_m = mods
	return [best_h, best_m]


## Записать проект в мир; такой же у страны уже есть — его номер.
static func add(world, nid: int, name: String, hull_id: String, mods: Array) -> int:
	for i in world.ship_designs.size():
		var d: Dictionary = world.ship_designs[i]
		if int(d["owner"]) == nid and d["hull"] == hull_id and d["mods"] == mods:
			return i
	var d := stats(hull_id, mods)
	d["owner"] = nid
	d["name"] = name
	d["hull"] = hull_id
	d["mods"] = mods.duplicate()
	d["id"] = world.ship_designs.size()
	world.ship_designs.append(d)
	return int(d["id"])


static func _auto_name(world, nat, role: int) -> String:
	var base := "%s обр. %d г." % [ROLE_NAMES[role], world.year_of()]
	var n := 1
	for d in world.ship_designs:
		if int(d["owner"]) == nat.id and String(d["name"]).begins_with(base):
			n += 1
	return base if n == 1 else "%s (%d)" % [base, n]


## ИИ (и стартовые проекты игрока): собрать лучшие проекты ролей по нынешним
## технологиям; лучше прежнего — становится основным проектом роли.
static func ai_update(world, nat) -> void:
	if nat.ship_techs == nat.techs.size() and nat.ship_role[0] >= 0:
		return
	nat.ship_techs = nat.techs.size()
	for role in ROLES.size():
		var hm := auto(nat, role)
		if String(hm[0]) == "":
			continue
		var s := stats(hm[0], hm[1])
		var cur: int = nat.ship_role[role]
		if cur >= 0 and cur < world.ship_designs.size():
			var cd: Dictionary = world.ship_designs[cur]
			if score(stats(cd["hull"], cd["mods"]), role) >= score(s, role) - 1e-9:
				continue
		nat.ship_role[role] = add(world, nat.id, _auto_name(world, nat, role), hm[0], hm[1])


## Описание характеристик словами.
static func stats_text(s: Dictionary) -> String:
	var parts: Array = []
	for k in ["atk", "air", "def", "asw", "aa", "raid"]:
		if float(s[k]) > 0.0:
			parts.append("%s %s" % [STAT_NAMES[k], _num(float(s[k]))])
	if float(s["stealth"]) > 0.0:
		parts.append("скрытность %d%%" % roundi(float(s["stealth"]) * 100.0))
	parts.append("цена %d" % roundi(float(s["cost"])))
	return ", ".join(parts)


static func _num(v: float) -> String:
	return ("%.1f" % v).replace(".0", "") if v >= 1.0 else "%.2f" % v
