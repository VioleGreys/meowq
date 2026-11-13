class_name Military
extends RefCounted
## Военная модель: типы снаряжения, шаблоны дивизий, производственные линии,
## подготовка и пополнение дивизий, боевые множители.
## Константы здесь читаются только из главного потока: всё, что нужно
## параллельным фазам, кэшируется в полях дивизий и в Packed-массивах мира.

# --- Снаряжение ----------------------------------------------------------------
const EQ_INF := 0
const EQ_ART := 1
const EQ_TANK := 2
const EQ_TRUCK := 3
const EQ_AT := 4       # противотанковые пушки (решение пользователя, ноябрь 2026: своё снаряжение)
const EQ_SHIP := 5     # очки судостроения (корабли закладываются из них, см. Forces)
const EQ_FIG := 6      # истребители (самолёты в резерве)
const EQ_BOMB := 7     # бомбардировщики
const EQ_COUNT := 8
const EQ_LAND := 5     # первые 5 типов — снаряжение сухопутных дивизий
const EQ_NAMES := ["Стрелковое оружие", "Артиллерия", "Бронетехника", "Грузовики", "Противотанковые пушки", "Судостроение", "Истребители", "Бомбардировщики"]
const EQ_SHORT := ["Винт.", "Ору.", "Танки", "Груз.", "ПТО", "Суда", "Истр.", "Бомб."]
# Экономика «как в жанре» (решение пользователя, ноябрь 2026): завод даёт
# FACTORY_PTS очков в день × эффективность линии; цена единицы — в очках.
# Батальон — сотни единиц (пехотный: 100 стрелкового на 1000 человек).
# Цены подобраны так, чтобы батальон стоил заводо-дней примерно как прежде
# при эффективности ~55 %; рост эффективности технологиями — сверху.
const EQ_COST := [0.35, 9.0, 5.0, 1.25, 4.0, 3.75, 22.5, 45.0]
const FACTORY_PTS := 4.5
const EFF_START := 0.1      # эффективность новой линии (и нового завода на ней)
const EFF_CAP := 0.5        # потолок эффективности; технологии (бонус prod_eff) поднимают
const EFF_GAIN := 0.03      # рост за день — доля оставшегося до потолка (быстрее в начале)
const EFF_KEEP := 0.4       # завод, переведённый на другое снаряжение, сохраняет долю эффективности
# Сохранения до ноября 2026 г.: во сколько раз больше единиц в новом счёте
# (по прежним 7 типам; ПТО тогда не было — вставляется пятым).
const EQ_UNIT_SCALE_OLD := [10.0, 1.0, 50.0 / 7.5, 5.0, 1.0, 1.0, 1.0]

# --- Батальоны и шаблоны дивизий ------------------------------------------------
# Шаблон — состав из батальонов (как в жанре): характеристики дивизии — сумма
# (люди, снаряжение, атака, оборона) или среднее по людям (организация,
# бронированность, местность), скорость — по самому медленному батальону.
# Составы по умолчанию дают ровно прежние 6 шаблонов. Шаблоны лежат в мире
# (World.templates): 0–5 — общие, дальше — проекты стран (поле owner).
const B_INF := 0
const B_MNT := 1
const B_CAV := 2
const B_ART := 3
const B_MOT := 4
const B_TANK := 5
const B_AT := 6
const BAT_COUNT := 7
# men — тыс. человек; eq — [винт., ору., танки, груз., ПТО] (единиц); terr — множитель на
# местности (равнины, лес, холмы, горы, город, море, пустыня, болота);
# width — ширина фронта батальона (дивизия = сумма; в бою — не шире провинции);
# motor — моторизован (скорость от бонуса «speed» полностью, снабжение ×1,5)
const BATTALIONS := [
	{"name": "Пехотный", "width": 2, "short": "пех.", "icon": "inf", "men": 1.0, "eq": [100.0, 0.0, 0.0, 0.0, 0.0], "atk": 1.0, "def": 1.2, "org": 40.0, "spd": 1.0, "hard": 0.0, "days": 14, "req": "", "motor": false, "armor": 0.0, "pierce": 5.0,
		"terr": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]},
	{"name": "Горнострелковый", "width": 2, "short": "горн.", "icon": "mnt", "men": 1.0, "eq": [110.0, 0.0, 0.0, 0.0, 0.0], "atk": 0.9, "def": 1.2, "org": 45.0, "spd": 1.0, "hard": 0.0, "days": 18, "req": "mnt1", "motor": false, "armor": 0.0, "pierce": 5.0,
		"terr": [1.0, 1.1, 1.35, 1.5, 1.0, 1.0, 0.9, 1.0]},
	{"name": "Кавалерийский", "width": 2, "short": "кав.", "icon": "cav", "men": 1.0, "eq": [80.0, 0.0, 0.0, 0.0, 0.0], "atk": 1.0, "def": 1.0, "org": 50.0, "spd": 1.5, "hard": 0.0, "days": 14, "req": "", "motor": false, "armor": 0.0, "pierce": 3.0,
		"terr": [1.1, 0.8, 0.9, 0.7, 0.8, 1.0, 1.1, 0.7]},
	# артиллерия: 2 батальона к 10 пехотным дают прежнюю «пехоту с артиллерией»;
	# на трудной местности она обуза (значения ниже 1 тянут среднее вниз)
	{"name": "Артиллерийский", "width": 3, "short": "арт.", "icon": "art", "men": 0.5, "eq": [0.0, 12.0, 0.0, 0.0, 0.0], "atk": 3.0, "def": 1.0, "org": 18.0, "spd": 0.9, "hard": 0.0, "days": 18, "req": "", "motor": false, "armor": 0.0, "pierce": 5.0,
		"terr": [1.55, 0.45, 0.45, -0.65, 1.0, 1.0, 1.55, -0.1]},
	{"name": "Моторизованный", "width": 2, "short": "мот.", "icon": "mot", "men": 1.0, "eq": [100.0, 0.0, 0.0, 30.0, 0.0], "atk": 1.1, "def": 1.2, "org": 40.0, "spd": 2.0, "hard": 0.1, "days": 20, "req": "mot1", "motor": true, "armor": 2.0, "pierce": 6.0,
		"terr": [1.1, 0.85, 0.9, 0.75, 0.9, 1.0, 1.1, 0.7]},
	{"name": "Танковый", "width": 2, "short": "танк.", "icon": "arm", "men": 1.0, "eq": [20.0, 0.0, 50.0, 10.0, 0.0], "atk": 3.75, "def": 1.5, "org": 35.0, "spd": 1.8, "hard": 0.7, "days": 30, "req": "armor1", "motor": true, "armor": 10.0, "pierce": 15.0,
		"terr": [1.15, 0.75, 0.75, 0.55, 0.75, 1.0, 1.15, 0.55]},
	# ПТО (решение пользователя, ноябрь 2026): бронебойность дивизии против танков;
	# танковый батальон берёт броню и бронебойность из проекта (TankDesigns)
	{"name": "Противотанковый", "width": 1, "short": "ПТО", "icon": "art", "men": 0.5, "eq": [10.0, 0.0, 0.0, 0.0, 12.0], "atk": 0.6, "def": 1.0, "org": 20.0, "spd": 1.0, "hard": 0.0, "days": 18, "req": "at1", "motor": false, "armor": 0.0, "pierce": 35.0,
		"terr": [1.0, 0.9, 0.9, 0.7, 1.0, 1.0, 1.0, 0.8]},
]
# Роты поддержки (как в жанре, решение пользователя, ноябрь 2026): до
# SUPPORT_MAX на шаблон, ширину фронта не занимают; немного людей и снаряжения,
# каждая — свой бонус дивизии; открываются технологиями (req).
# fx: atk — прибавка к атаке; atk_m, def_m, spd_m, org_m — множители (+доля);
# pierce — бронебойность (идёт в «лучший батальон»); terr — прибавка к
# множителям местности; ent, aa, rec_men, rec_eq, org_rate, sup_w — в таблицу
# шаблонов tpl_sc (ядра: окопы, ПВО, пополнение людей и техники, восстановление
# организации, нагрузка на снабжение).
const SUPPORT_MAX := 5
const SC_K := 6   # tpl_sc на шаблон: [окопы ×, защита от штурмовиков, пополнение людей ×, техники ×, восстановление организации ×, нагрузка снабжения ×]
const SUPPORT := [
	{"id": "eng", "name": "Сапёрная рота", "short": "сап.", "req": "eng1", "men": 0.3, "eq": [30.0, 0.0, 0.0, 0.0, 0.0],
		"fx": {"def_m": 0.06, "ent": 0.5, "terr": [0.0, 0.05, 0.05, 0.05, 0.1, 0.0, 0.0, 0.1]},
		"desc": "Окапывается в полтора раза быстрее и глубже (до 150 %), оборона +6 %, лучше в лесу, горах, городах и болотах."},
	{"id": "rec", "name": "Разведывательная рота", "short": "разв.", "req": "scout1", "men": 0.2, "eq": [30.0, 0.0, 0.0, 5.0, 0.0],
		"fx": {"spd_m": 0.08, "atk_m": 0.05}, "desc": "Скорость +8 %, атака +5 %."},
	{"id": "art", "name": "Артиллерийская батарея", "short": "батар.", "req": "art1", "men": 0.2, "eq": [10.0, 4.0, 0.0, 0.0, 0.0],
		"fx": {"atk": 0.9}, "desc": "Атака +0,9 (треть артиллерийского батальона) — против пехоты."},
	{"id": "at", "name": "Противотанковая батарея", "short": "птб.", "req": "at1", "men": 0.2, "eq": [10.0, 0.0, 0.0, 0.0, 4.0],
		"fx": {"pierce": 35.0}, "desc": "Бронебойность пушки ПТО (35 / 60 / 90 по технологиям) — как у лучшего батальона дивизии."},
	{"id": "aa", "name": "Зенитная батарея", "short": "зен.", "req": "aa1", "men": 0.2, "eq": [10.0, 3.0, 0.0, 0.0, 0.0],
		"fx": {"aa": 0.5, "def_m": 0.02}, "desc": "Вдвое меньше прибавка вражеских штурмовиков в бою против дивизии, оборона +2 %."},
	{"id": "med", "name": "Полевой госпиталь", "short": "госп.", "req": "med1", "men": 0.2, "eq": [10.0, 0.0, 0.0, 2.0, 0.0],
		"fx": {"rec_men": 0.3}, "desc": "Пополнение людьми на 30 % быстрее."},
	{"id": "mnt", "name": "Ремонтная рота", "short": "рем.", "req": "log1", "men": 0.2, "eq": [10.0, 0.0, 0.0, 4.0, 0.0],
		"fx": {"rec_eq": 0.3}, "desc": "Пополнение техникой и оружием на 30 % быстрее."},
	{"id": "sig", "name": "Рота связи", "short": "связь", "req": "rad2", "men": 0.2, "eq": [20.0, 0.0, 0.0, 2.0, 0.0],
		"fx": {"org_rate": 0.3, "org_m": 0.05}, "desc": "Организация +5 %, восстанавливается на 30 % быстрее."},
	{"id": "log", "name": "Тыловая рота", "short": "тыл", "req": "log2", "men": 0.2, "eq": [10.0, 0.0, 0.0, 10.0, 0.0],
		"fx": {"sup_w": -0.2}, "desc": "Нагрузка дивизии на снабжение −20 %."},
]
# ИИ берёт роты в таком порядке (сколько открыто, до SUPPORT_MAX)
const AI_SUPPORT_ORDER := ["eng", "art", "rec", "sig", "med", "aa", "mnt", "log", "at"]
const AT2_PIERCE := 25.0   # «Тяжёлые пушки ПТО» (at2): бронебойность батальона ПТО +25 (60)
const AT3_PIERCE := 55.0   # «Пушки ПТО большой мощности» (at3): +55 (90)
const ARMOR_MAX_W := 0.4   # броня и бронебойность дивизии: 0,4 · лучший батальон + 0,6 · средний
const MAX_BATTALIONS := 15

const T_INF := 0
const T_MNT := 1
const T_CAV := 2
const T_ART := 3
const T_MOT := 4
const T_ARM := 5
# классы для значков и ролей ИИ — совпадают с номерами общих шаблонов
const DEFAULT_TEMPLATES := [
	["Пехотная", "пех.", [10, 0, 0, 0, 0, 0]],
	["Горнострелковая", "горн.", [0, 10, 0, 0, 0, 0]],
	["Кавалерийская", "кав.", [0, 0, 8, 0, 0, 0]],
	["Пехотная с артиллерией", "п+арт", [10, 0, 0, 2, 0, 0]],
	["Моторизованная", "мот.", [0, 0, 0, 0, 10, 0]],
	["Танковая", "танк.", [0, 0, 0, 0, 0, 8]],
]
# Прежнее дерево науки за первые два года давало всем +65 % атаки при +35 %
# обороны, и ход войн подобран под этот перевес наступления. Теперь технологии
# растут понемногу, а перевес заложен в основу.
const BASE_ATK := 1.25
const BASE_SPEED := 0.28   # доля провинции в день для скорости 1.0 на равнине


## Число батальонов типа b в составе (составы из старых сохранений короче — нет ПТО).
static func bat_n(bat: Array, b: int) -> int:
	return int(bat[b]) if b < bat.size() else 0


## Собрать шаблон из состава bat (число батальонов каждого типа).
static func make_template(name: String, short: String, bat_in: Array, owner: int = -1, sup_in: Array = []) -> Dictionary:
	var bat := bat_in.duplicate()
	while bat.size() < BAT_COUNT:
		bat.append(0)
	var men := 0.0
	var eq := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var atk := 0.0
	var def := 0.0
	var org := 0.0
	var hard := 0.0
	var spd := 99.0
	var days := 0
	var terr := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var req: Array = []
	var motor := true
	var total := 0
	var width := 0.0
	for b in BAT_COUNT:
		var c: int = bat_n(bat, b)
		if c <= 0:
			continue
		total += c
		var bt: Dictionary = BATTALIONS[b]
		width += c * float(bt["width"])
		var m: float = c * float(bt["men"])
		men += m
		for k in EQ_LAND:
			eq[k] += c * float(bt["eq"][k])
		atk += c * float(bt["atk"])
		def += c * float(bt["def"])
		org += m * float(bt["org"])
		hard += m * float(bt["hard"])
		for k in 8:
			terr[k] += m * float(bt["terr"][k])
		spd = minf(spd, float(bt["spd"]))
		days = maxi(days, int(bt["days"]))
		if bt["req"] != "" and not req.has(bt["req"]):
			req.append(bt["req"])
		motor = motor and bool(bt["motor"])
	# роты поддержки: люди и снаряжение, бонусы; ширины нет
	var sup: Array = []
	var fx := {"atk_m": 0.0, "def_m": 0.0, "spd_m": 0.0, "org_m": 0.0, "pierce": 0.0}
	var sc := [1.0, 0.0, 1.0, 1.0, 1.0, 1.0]
	var tadd := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var bat_men := men
	for sid in sup_in:
		var sp := support(String(sid))
		if sp.is_empty() or sup.has(sp["id"]) or sup.size() >= SUPPORT_MAX:
			continue
		sup.append(sp["id"])
		men += float(sp["men"])
		for k in EQ_LAND:
			eq[k] += float(sp["eq"][k])
		if sp["req"] != "" and not req.has(sp["req"]):
			req.append(sp["req"])
		var f: Dictionary = sp["fx"]
		atk += float(f.get("atk", 0.0))
		for key in ["atk_m", "def_m", "spd_m", "org_m"]:
			fx[key] = float(fx[key]) + float(f.get(key, 0.0))
		fx["pierce"] = maxf(float(fx["pierce"]), float(f.get("pierce", 0.0)))
		sc[0] += float(f.get("ent", 0.0))
		sc[1] = maxf(float(sc[1]), float(f.get("aa", 0.0)))
		sc[2] += float(f.get("rec_men", 0.0))
		sc[3] += float(f.get("rec_eq", 0.0))
		sc[4] += float(f.get("org_rate", 0.0))
		sc[5] += float(f.get("sup_w", 0.0))
		if f.has("terr"):
			for k in 8:
				tadd[k] += float(f["terr"][k])
	bat_men = maxf(bat_men, 0.01)
	men = maxf(men, 0.01)
	for k in 8:
		terr[k] = clampf(terr[k] / bat_men + tadd[k], 0.3, 2.0)
	return {"name": name, "short": short, "owner": owner, "bat": bat.duplicate(), "men": men, "eq": eq,
		"atk": atk, "def": def, "org": org / bat_men, "hard": hard / bat_men, "spd": spd if total > 0 else 1.0,
		"days": days, "req": req, "motor": motor and total > 0, "terr": terr, "cls": _template_class(bat), "width": width,
		"hidden": false, "sup": sup, "fx": fx, "sc": sc}


## Рота поддержки по id (пусто — нет такой).
static func support(id: String) -> Dictionary:
	for sp in SUPPORT:
		if sp["id"] == id:
			return sp
	return {}


## Роты поддержки шаблона (у шаблонов из старых сохранений поля нет).
static func template_support(t: Dictionary) -> Array:
	return t.get("sup", [])


## Класс шаблона для значка и роли ИИ (номера общих шаблонов T_*).
static func _template_class(bat: Array) -> int:
	var total := 0
	for b in BAT_COUNT:
		total += bat_n(bat, b)
	if int(bat[B_TANK]) > 0:
		return T_ARM
	if int(bat[B_MOT]) * 2 > total:
		return T_MOT
	if int(bat[B_MNT]) * 2 > total:
		return T_MNT
	if int(bat[B_CAV]) * 2 > total:
		return T_CAV
	if int(bat[B_ART]) > 0:
		return T_ART
	return T_INF


static func default_templates() -> Array:
	var res: Array = []
	for d in DEFAULT_TEMPLATES:
		res.append(make_template(d[0], d[1], d[2]))
	return res


static func tpl_count(world: World) -> int:
	return world.templates.size()


static func tpl(world: World, t: int) -> Dictionary:
	return world.templates[t]


## Шаблоны, которые страна может готовить: общие и свои, не скрытые, с технологиями.
static func available_templates(world: World, nat: World.Nation, with_locked := false) -> Array:
	var res: Array = []
	for i in world.templates.size():
		var t: Dictionary = world.templates[i]
		if t["hidden"] or (int(t["owner"]) >= 0 and int(t["owner"]) != nat.id):
			continue
		if with_locked or tech_missing(t, nat) == "":
			res.append(i)
	return res


static func tech_missing(t: Dictionary, nat: World.Nation) -> String:
	for r in t["req"]:
		if not nat.techs.has(r):
			return r
	return ""


static func eq_points(world: World, t: int) -> float:
	var s := 0.0
	var eq: Array = world.templates[t]["eq"]
	for k in EQ_COUNT:
		s += eq[k] * EQ_COST[k]
	return s


## Пересчитать кэш характеристик дивизии (главный поток).
static func refresh_division(world: World, d: World.Division) -> void:
	if world.templates.is_empty():
		build_tables(world)
	var nat: World.Nation = world.nations[d.owner]
	var t: Dictionary = world.templates[d.tpl]
	# общий бонус страны + бонусы родов войск (технологии) по батальонам состава
	var bat: Array = t["bat"]
	# танковые батальоны — по проекту страны в производстве (атака, скорость, броня, пробитие)
	var n_tank := bat_n(bat, B_TANK)
	var td: Dictionary = TankDesigns.of_nation(world, nat) if n_tank > 0 else TankDesigns.FALLBACK
	var tmul: float = float(td["atk"])
	var tank_atk: float = float(BATTALIONS[B_TANK]["atk"])
	var atk_sum: float = t["atk"]
	if n_tank > 0 and tmul != 1.0:
		atk_sum += n_tank * tank_atk * (tmul - 1.0)
	var atk: float = atk_sum * (BASE_ATK + nat.b("attack"))
	var def: float = t["def"] * (1.0 + nat.b("defense"))
	var ba := PackedFloat64Array([nat.b("inf_attack"), nat.b("art_attack"), nat.b("tank_attack")])
	var bd := PackedFloat64Array([nat.b("inf_defense"), nat.b("art_defense"), nat.b("tank_defense")])
	var spd: float = t["spd"]
	for b in BAT_COUNT:
		var c: int = bat_n(bat, b)
		if c <= 0:
			continue
		var kind := 2 if b == B_TANK else (1 if b == B_ART else 0)
		var ab: float = float(BATTALIONS[b]["atk"])
		if b == B_TANK:
			ab = tank_atk * tmul
		atk += c * ab * ba[kind]
		def += c * float(BATTALIONS[b]["def"]) * bd[kind]
	if n_tank > 0 and float(td["speed"]) != 1.0:
		# скорость — по самому медленному батальону; у танков — с множителем проекта
		var s2 := 99.0
		for b in BAT_COUNT:
			if bat_n(bat, b) > 0:
				s2 = minf(s2, float(BATTALIONS[b]["spd"]) * (float(td["speed"]) if b == B_TANK else 1.0))
		spd = s2
	# роты поддержки: множители атаки, обороны, организации, скорости
	var fx: Dictionary = t.get("fx", {})
	d.atk = atk * (1.0 + float(fx.get("atk_m", 0.0)))
	d.def = def * (1.0 + float(fx.get("def_m", 0.0)))
	d.max_org = t["org"] * (1.0 + nat.b("org")) * (1.0 + float(fx.get("org_m", 0.0)))
	var spd_bonus := nat.b("speed") if t["motor"] else nat.b("speed") * 0.3
	d.spd = BASE_SPEED * spd * (1.0 + spd_bonus) * (1.0 + float(fx.get("spd_m", 0.0)))
	d.hard = t["hard"]
	var ap := armor_pierce(nat, bat, td, float(fx.get("pierce", 0.0)))
	d.armor = ap[0]
	d.pierce = ap[1]


## Броня и бронебойность дивизии из состава bat (решение пользователя):
## 0,4 · лучший батальон + 0,6 · среднее по батальонам; танки — по проекту td,
## ПТО — +25 с «Тяжёлыми пушками ПТО». [броня, бронебойность]
static func armor_pierce(nat: World.Nation, bat: Array, td: Dictionary, sup_pierce := 0.0) -> PackedFloat64Array:
	var a_max := 0.0
	var a_sum := 0.0
	var p_max := 0.0
	var p_sum := 0.0
	var cnt := 0
	for b in BAT_COUNT:
		var c: int = bat_n(bat, b)
		if c <= 0:
			continue
		var ar: float = float(BATTALIONS[b]["armor"])
		var pr: float = float(BATTALIONS[b]["pierce"])
		if b == B_TANK:
			ar = float(td["armor"])
			pr = float(td["pierce"])
		elif b == B_AT:
			pr += AT3_PIERCE if nat.techs.has("at3") else (AT2_PIERCE if nat.techs.has("at2") else 0.0)
		a_max = maxf(a_max, ar)
		p_max = maxf(p_max, pr)
		a_sum += c * ar
		p_sum += c * pr
		cnt += c
	if sup_pierce > 0.0:
		# противотанковая батарея — в лучший батальон (как пушка ПТО, с её поколениями)
		p_max = maxf(p_max, sup_pierce + (AT3_PIERCE if nat.techs.has("at3") else (AT2_PIERCE if nat.techs.has("at2") else 0.0)))
	return PackedFloat64Array([ARMOR_MAX_W * a_max + (1.0 - ARMOR_MAX_W) * a_sum / maxf(1.0, cnt),
		ARMOR_MAX_W * p_max + (1.0 - ARMOR_MAX_W) * p_sum / maxf(1.0, cnt)])


## Ширина фронта шаблона (у шаблонов из старых сохранений поля нет — считаем по составу).
static func template_width(t: Dictionary) -> float:
	if t.has("width"):
		return float(t["width"])
	var w := 0.0
	for b in BAT_COUNT:
		w += bat_n(t["bat"], b) * float(BATTALIONS[b]["width"])
	return w


## Таблицы шаблонов в Packed-массивы мира (для параллельных фаз и C++).
## Вызывать после каждого изменения world.templates.
static func build_tables(world: World) -> void:
	if world.templates.is_empty():
		world.templates = default_templates()
	world.tpl_eq = PackedFloat64Array()
	world.tpl_men = PackedFloat64Array()
	world.tpl_terrain = PackedFloat32Array()
	world.tpl_cls = PackedInt32Array()
	world.tpl_motor = PackedInt32Array()
	world.tpl_width = PackedFloat32Array()
	world.tpl_sc = PackedFloat64Array()
	for t in world.templates:
		var sc: Array = t.get("sc", [1.0, 0.0, 1.0, 1.0, 1.0, 1.0])
		for k in SC_K:
			world.tpl_sc.append(float(sc[k]))
		world.tpl_width.append(template_width(t))
		world.tpl_men.append(t["men"])
		for k in EQ_COUNT:
			world.tpl_eq.append(t["eq"][k])
		for k in 8:
			world.tpl_terrain.append(t["terr"][k])
		world.tpl_cls.append(t["cls"])
		world.tpl_motor.append(1 if t["motor"] else 0)


## Новый шаблон страны (или правка своего). Правка меняет дивизии на ходу:
## снаряжение и люди пересчитываются в доли нового состава, излишек — на склад.
## Возвращает номер шаблона или -1. Только между world_lock/unlock.
static func save_template(world: World, nid: int, name: String, bat: Array, edit: int = -1, sup: Array = []) -> int:
	var total := 0
	for b in BAT_COUNT:
		total += bat_n(bat, b)
	if total <= 0 or total > MAX_BATTALIONS:
		return -1
	var short := name.substr(0, 6).to_lower() + "."
	var nt := make_template(name, short, bat, nid, sup)
	if edit >= 0:
		var old: Dictionary = world.templates[edit]
		if int(old["owner"]) != nid:
			return -1
		var nat: World.Nation = world.nations[nid]
		for d in world.divisions:
			if d.alive and d.tpl == edit:
				_convert(nat, d, old, nt)
		world.templates[edit] = nt
	else:
		world.templates.append(nt)
		edit = world.templates.size() - 1
	build_tables(world)
	for d in world.divisions:
		if d.alive and d.tpl == edit:
			refresh_division(world, d)
			d.org = minf(d.org, d.max_org)
	return edit


## Снаряжение и люди дивизии d — в доли нового состава nt (было old): доля
## снаряжения — по стоимости того, что у дивизии уже есть из нового состава
## (одна доля на все типы); недостающее по типу берётся со склада, чего нет и
## на складе — вычитается из доли по стоимости; излишек — на склад; люди сверх состава — в
## призывников. Остальное придёт пополнением.
static func _convert(nat: World.Nation, d: World.Division, old: Dictionary, nt: Dictionary) -> void:
	var have := PackedFloat64Array()
	var got := 0.0
	var full := 0.0
	for k in EQ_LAND:
		var h: float = d.eq * float(old["eq"][k])
		var nk: float = float(nt["eq"][k])
		have.append(h)
		got += minf(h, nk) * float(EQ_COST[k])
		full += nk * float(EQ_COST[k])
	var frac0 := got / full if full > 0.0 else 1.0
	var frac := frac0
	for it in 3:
		# нехватка по типам, которую не покрыл склад, — вычесть её стоимость из доли
		var miss := 0.0
		for k in EQ_LAND:
			miss += maxf(0.0, frac * float(nt["eq"][k]) - have[k] - maxf(0.0, nat.stock[k])) * float(EQ_COST[k])
		frac = clampf(frac0 - (miss / full if full > 0.0 else 0.0), 0.0, 1.0)
	for k in EQ_LAND:
		nat.stock[k] = maxf(0.0, nat.stock[k] + have[k] - frac * float(nt["eq"][k]))
	var men_have: float = d.strength / 100.0 * float(old["men"])
	var s := minf(100.0, 100.0 * men_have / float(nt["men"]))
	nat.manpower += maxf(0.0, men_have - s / 100.0 * float(nt["men"]))
	d.eq = frac
	d.strength = maxf(1.0, s)


const RETRAIN_ORG := 0.5   # после переучивания организация — не выше половины (переформирование)


## Почему дивизию d нельзя переучить в шаблон t ("" — можно).
static func retrain_block(world: World, d: World.Division, t: int) -> String:
	if not d.alive or t < 0 or t >= world.templates.size() or d.tpl == t:
		return "тот же шаблон"
	if d.in_battle:
		return "дивизия в бою"
	if d.transit_days > 0:
		return "дивизия в море"
	var miss := tech_missing(world.templates[t], world.nations[d.owner])
	if miss != "":
		return "нужна технология «%s»" % Tech.get_tech(miss).get("name", miss)
	return ""


## Переучить дивизию в шаблон t (как в жанре — смена шаблона на ходу): состав
## пересчитывается (_convert), недостающее придёт пополнением со склада,
## организация падает до RETRAIN_ORG. Только главный поток (world_lock).
static func retrain(world: World, d: World.Division, t: int) -> bool:
	if retrain_block(world, d, t) != "":
		return false
	var nat: World.Nation = world.nations[d.owner]
	_convert(nat, d, world.templates[d.tpl], world.templates[t])
	d.tpl = t
	Leaders.touch(world, d)   # черты командира зависят от рода войск
	refresh_division(world, d)
	d.org = minf(d.org, d.max_org * RETRAIN_ORG)
	return true


## База шаблона ИИ (без рот поддержки): общий шаблон «… с ротами» → его база.
static func base_of(world: World, t: int) -> int:
	var key := String(world.templates[t].get("key", ""))
	var i := key.find(":")
	return int(key.substr(0, i)) if i > 0 else t


const AI_RETRAIN_SHARE := 0.1   # ИИ переучивает в месяц не больше этой доли дивизий


## ИИ (раз в месяц, вместе с проектами): устаревшие дивизии — на общий шаблон
## той же базы с нынешними ротами поддержки (их снаряжение страна выпускает —
## ai_support). Не в бою, на войне — не у фронта. Склада не хватает — дивизия
## всё равно переучивается, с недокомплектом на стоимость недостающего
## (решение пользователя); дальше — пополнением.
static func ai_retrain(world: World, nat: World.Nation) -> int:
	var sup := ai_support(world, nat)
	if sup.is_empty():
		return 0
	var budget := maxi(1, int(nat.division_count * AI_RETRAIN_SHARE))
	var done := 0
	for d in world.divisions:
		if done >= budget:
			break
		if not d.alive or d.owner != nat.id or d.in_battle or d.transit_days > 0:
			continue
		if not nat.at_war.is_empty() and _at_front(world, d):
			continue   # на войне — только не стоящие у фронта (организация падает)
		var old: Dictionary = world.templates[d.tpl]
		if int(old["owner"]) >= 0:
			continue   # свои шаблоны игрока ИИ не трогает
		var t := with_support(world, base_of(world, d.tpl), sup)
		if t == d.tpl:
			continue
		if retrain(world, d, t):
			done += 1
	return done


static func _at_front(world: World, d: World.Division) -> bool:
	var p := d.prov
	var nc := world.nation_count
	for k in range(world.adj_start[p], world.adj_start[p + 1]):
		var c := world.p_controller[world.adj_list[k]]
		if c >= 0 and world.war[d.owner * nc + c] == 1:
			return true
	return false


## Скрыть свой шаблон из списка (дивизии на нём остаются).
static func hide_template(world: World, nid: int, t: int) -> void:
	if t >= 0 and t < world.templates.size() and int(world.templates[t]["owner"]) == nid:
		world.templates[t]["hidden"] = true


# --- Производство ----------------------------------------------------------------

## Стартовые линии по доктрине/технологиям: доли заводов по типам снаряжения.
static func default_split(nat: World.Nation) -> Array:
	var land: Array
	if nat.techs.has("armor1"):
		land = [0.35, 0.2, 0.3, 0.15, 0.0]
	elif nat.techs.has("mot1"):
		land = [0.45, 0.3, 0.0, 0.25, 0.0]
	else:
		land = [0.6, 0.4, 0.0, 0.0, 0.0]
	if nat.techs.has("at1"):
		land[EQ_AT] = 0.06
		land[EQ_INF] -= 0.06
	# доли флота и авиации — из forces.json (nat.naval_share / air_share)
	var rest := 1.0 - nat.naval_share - nat.air_share
	var res: Array = []
	for k in EQ_LAND:
		res.append(land[k] * rest)
	res.append(nat.naval_share)
	res.append(nat.air_share * 0.6)
	res.append(nat.air_share * 0.4)
	return res


## Разложить свободные заводы по долям (существующие линии не трогаем).
static func assign_free_factories(nat: World.Nation, split: Array) -> void:
	var free := nat.mil - assigned_factories(nat)
	if free <= 0:
		return
	var current := [0, 0, 0, 0, 0, 0, 0, 0]
	for line in nat.lines:
		current[line[0]] += int(line[1])
	var total := nat.mil
	while free > 0:
		var best := 0
		var best_gap := -INF
		for k in EQ_COUNT:
			var gap: float = float(split[k]) * total - current[k]
			if gap > best_gap:
				best_gap = gap
				best = k
		_add_to_line(nat, best, 1)
		current[best] += 1
		free -= 1


static func assigned_factories(nat: World.Nation) -> int:
	var s := 0
	for line in nat.lines:
		s += int(line[1])
	return s


## Потолок эффективности линий страны (технологии «Промышленности» — prod_eff).
static func eff_cap(nat: World.Nation) -> float:
	return clampf(EFF_CAP + nat.b("prod_eff"), EFF_START, 1.0)


## Очков выпуска в день у одного завода линии с эффективностью eff (без нехватки ресурсов).
static func factory_points(nat: World.Nation, eff: float) -> float:
	return FACTORY_PTS * eff * maxf(0.1, 1.0 + nat.b("industry"))


## n заводов на линию eq (n < 0 — снять); новые заводы приходят с эффективностью
## eff_new — линия берёт среднее по заводам.
static func _add_to_line(nat: World.Nation, eq: int, n: int, eff_new: float = EFF_START) -> void:
	for line in nat.lines:
		if line[0] == eq:
			var had := int(line[1])
			line[1] = maxi(0, had + n)
			if n > 0:
				line[2] = (float(line[2]) * had + eff_new * n) / float(had + n)
			return
	if n > 0:
		nat.lines.append([eq, n, eff_new])


static func _line_eff(nat: World.Nation, eq: int) -> float:
	for line in nat.lines:
		if line[0] == eq:
			return float(line[2])
	return EFF_START


## Игрок меняет число заводов на линии; true — получилось.
static func change_line(nat: World.Nation, eq: int, delta: int) -> bool:
	if delta > 0 and assigned_factories(nat) + delta > nat.mil:
		return false
	for line in nat.lines:
		if line[0] == eq and int(line[1]) + delta < 0:
			return false
	_add_to_line(nat, eq, delta)
	return true


## Если заводов стало меньше (оккупация), снимаем их с линий с конца.
static func trim_lines(nat: World.Nation) -> void:
	var excess := assigned_factories(nat) - nat.mil
	var i := nat.lines.size() - 1
	while excess > 0 and i >= 0:
		var take := mini(excess, int(nat.lines[i][1]))
		nat.lines[i][1] = int(nat.lines[i][1]) - take
		excess -= take
		i -= 1


## Дневной выпуск: заводы × FACTORY_PTS × эффективность → очки → единицы
## снаряжения; эффективность растёт к потолку (быстрее в начале).
static func produce(nat: World.Nation) -> void:
	# рейды по торговле бьют не по выпуску, а по морскому импорту (Convoys → res_fill)
	var mult := FACTORY_PTS * maxf(0.1, 1.0 + nat.b("industry"))
	var cap := eff_cap(nat)
	for k in EQ_COUNT:
		nat.daily_output[k] = 0.0
	for line in nat.lines:
		var eq: int = line[0]
		var f: int = line[1]
		if f <= 0:
			continue
		var eff: float = line[2]
		# нехватка ресурсов для того, что выпускает линия (Economy.RES_NEED)
		var units: float = f * mult * eff * Economy.line_mult(nat, eq) / EQ_COST[eq]
		# самолёты: цена выпуска по проекту в производстве (Designs)
		if eq == EQ_TANK:
			units /= nat.tank_cost   # бронетехника: цена по проекту танка (TankDesigns)
		elif eq == EQ_FIG:
			units /= nat.plane_cost[0]
		elif eq == EQ_BOMB:
			units /= nat.plane_cost[1]
		nat.stock[eq] += units
		nat.daily_output[eq] += units
		nat.prod_acc[eq] += units
		line[2] = minf(cap, eff + EFF_GAIN * (cap - eff)) if eff < cap else cap
	# помощь из-за рубежа (черты с aid_eq — в военных заводах при потолке 1936 г.),
	# пока страна воюет: три четверти — стрелковое оружие, четверть — артиллерия
	var aid := nat.b("aid_eq") * FACTORY_PTS * EFF_CAP
	if aid > 0.0 and not nat.at_war.is_empty():
		nat.stock[EQ_INF] += aid * 0.75 / EQ_COST[EQ_INF]
		nat.stock[EQ_ART] += aid * 0.25 / EQ_COST[EQ_ART]


## Пересмотр распределения заводов (раз в месяц, ИИ и игрок с автораспределением).
## Сухопутные линии — по нужде: нехватка в дивизиях + снаряжение для
## дивизий, которые ещё будут сформированы (target_divs), + запас (у воюющих
## и готовящихся к войне больше) — всё за вычетом склада, на PROD_HORIZON
## дней, плюс средний расход. Минимум флота и авиации — доли из forces.json;
## излишек сухопутных заводов — наполовину в запас по доктрине, наполовину
## в авиацию и флот. Линии сдвигаются постепенно (PROD_MOVE в месяц): новые
## заводы на линии разгоняются заново.
const PROD_HORIZON := 90.0
const PROD_MOVE := 0.15
const PROD_BUFFER := 0.3        # запас в мирное время — доля снаряжения армии
const PROD_BUFFER_WAR := 0.6    # на войне и при подготовке к ней
const PROD_SURPLUS_LAND := 0.7  # доля излишка, остающаяся на сухопутных линиях
const PROD_LAND_MIN := 0.6      # сухопутным линиям — не меньше этой доли их места


## Снаряжение армий всех стран одним проходом по плоским массивам дивизий:
## [дивизий по странам, по всему (страна*4 + k), нехватка (страна*4 + k)].
static func land_totals(world: World) -> Array:
	return _land_totals({"d_alive": world.d_alive, "d_owner": world.d_owner, "d_tpl": world.d_tpl,
		"d_eq": world.d_eq, "tpl_eq": world.tpl_eq, "n": world.nation_count})


static func _land_totals(t: Dictionary) -> Array:
	var nc: int = t["n"]
	var cnt := PackedInt32Array()
	cnt.resize(nc)
	var full := PackedFloat64Array()
	full.resize(nc * EQ_LAND)
	var lack := PackedFloat64Array()
	lack.resize(nc * EQ_LAND)
	var alive: PackedByteArray = t["d_alive"]
	var owner: PackedInt32Array = t["d_owner"]
	var tpl: PackedInt32Array = t["d_tpl"]
	var eqf: PackedFloat64Array = t["d_eq"]
	var te: PackedFloat64Array = t["tpl_eq"]
	for i in alive.size():
		if alive[i] == 0:
			continue
		var o := owner[i]
		cnt[o] += 1
		var ti := tpl[i] * EQ_COUNT
		var miss := 1.0 - eqf[i]
		for k in EQ_LAND:
			full[o * EQ_LAND + k] += te[ti + k]
			lack[o * EQ_LAND + k] += te[ti + k] * miss
	return [cnt, full, lack]


static func plan_production(world: World, nat: World.Nation, target_divs: int, prepare_war: bool, totals: Array) -> void:
	var p := plan_prep(world, nat, target_divs, prepare_war)
	if not p.is_empty():
		plan_apply(nat, plan_compute(p, totals))


## Подготовка пересмотра (главный поток): средний расход с прошлого пересмотра
## (склад был + выпуск − склад сейчас) и все входные данные расчёта — копиями,
## чтобы plan_compute мог идти в потоке. Пусто — заводов нет (доли по доктрине).
static func plan_prep(world: World, nat: World.Nation, target_divs: int, prepare_war: bool) -> Dictionary:
	if nat.prod_day >= 0 and world.day > nat.prod_day:
		var days := float(world.day - nat.prod_day)
		for k in EQ_COUNT:
			var used := maxf(0.0, nat.prod_stock[k] + nat.prod_acc[k] - nat.stock[k]) / days
			nat.eq_use[k] = 0.5 * nat.eq_use[k] + 0.5 * used
	nat.prod_day = world.day
	for k in EQ_COUNT:
		nat.prod_stock[k] = nat.stock[k]
		nat.prod_acc[k] = 0.0
	if nat.mil <= 0:
		nat.prod_split = default_split(nat)
		return {}
	# очередь шаблонов ИИ (как ai_template): номера по кругу
	var avail := available_templates(world, nat)
	var sup := ai_support(world, nat)
	var cycle := PackedInt32Array([with_support(world, T_INF, sup), with_support(world, T_INF, sup), with_support(world, T_ART, sup), with_support(world, T_INF, sup)])
	if avail.has(T_MOT):
		cycle.append(with_support(world, T_MOT, sup))
	if avail.has(T_ARM):
		cycle.append(with_support(world, T_ARM, sup))
	return {"id": nat.id, "mil": float(nat.mil), "naval": nat.naval_share, "air": nat.air_share,
		"use": nat.eq_use.duplicate(), "stock": PackedFloat64Array([nat.stock[0], nat.stock[1], nat.stock[2], nat.stock[3], nat.stock[4]]),
		"target": target_divs, "training": nat.training.size(), "trained": nat.trained_count, "cycle": cycle,
		"buffer": PROD_BUFFER_WAR if (not nat.at_war.is_empty() or prepare_war) else PROD_BUFFER,
		"mult": factory_points(nat, 0.5 * (_avg_eff(nat) + eff_cap(nat))),
		"doctrine": PackedFloat64Array(default_split(nat)),
		"tpl_eq": world.tpl_eq.duplicate(), "tpl_motor": world.tpl_motor.duplicate(),
		"cost": PackedFloat64Array([EQ_COST[0], EQ_COST[1], EQ_COST[2] * nat.tank_cost, EQ_COST[3], EQ_COST[4]])}


## Средняя эффективность заводов на линиях (без линий — стартовая).
static func _avg_eff(nat: World.Nation) -> float:
	var s := 0.0
	var f := 0
	for line in nat.lines:
		s += float(line[2]) * int(line[1])
		f += int(line[1])
	return s / f if f > 0 else EFF_START


## Расчёт долей заводов (только данные p и totals — можно в потоке).
## Сухопутные линии — по очередям: средний расход; 1 — пополнение и пехотное
## снаряжение будущих дивизий, 2 — техника моторизованных и танковых, 3 — запас;
## излишек — большая часть в запас по доктрине (сухопутным не меньше
## PROD_LAND_MIN своей доли), остальное — в авиацию и флот.
static func plan_compute(p: Dictionary, totals: Array) -> PackedFloat64Array:
	var id: int = p["id"]
	var tpl_eq: PackedFloat64Array = p["tpl_eq"]
	var tpl_motor: PackedInt32Array = p["tpl_motor"]
	var cycle: PackedInt32Array = p["cycle"]
	var use_in: PackedFloat64Array = p["use"]
	var stock_in: PackedFloat64Array = p["stock"]
	var doctrine: PackedFloat64Array = p["doctrine"]
	var cnt: PackedInt32Array = totals[0]
	var full: PackedFloat64Array = totals[1]
	var lack: PackedFloat64Array = totals[2]
	var fielded := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
	var tiers := [PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0]), PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0]), PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])]
	var t0: PackedFloat64Array = tiers[0]
	var t1: PackedFloat64Array = tiers[1]
	var t2: PackedFloat64Array = tiers[2]
	for k in EQ_LAND:
		fielded[k] = full[id * EQ_LAND + k]
		t0[k] = lack[id * EQ_LAND + k]
	var up := maxi(0, int(p["target"]) - cnt[id] - int(p["training"]))
	var trained: int = p["trained"]
	for i in up:
		var t := cycle[(trained + i) % cycle.size()]
		for k in EQ_LAND:
			if tpl_motor[t] == 1:
				t1[k] += tpl_eq[t * EQ_COUNT + k]
			else:
				t0[k] += tpl_eq[t * EQ_COUNT + k]
	var buffer: float = p["buffer"]
	for k in EQ_LAND:
		t2[k] = buffer * fielded[k]
	tiers = [t0, t1, t2]
	var mult: float = p["mult"]
	var total: float = p["mil"]
	var naval: float = p["naval"]
	var air: float = p["air"]
	var land_cap := total * maxf(0.0, 1.0 - naval - air)
	var split := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var left := land_cap
	var stock := PackedFloat64Array([stock_in[0], stock_in[1], stock_in[2], stock_in[3], stock_in[4]])
	var cost: PackedFloat64Array = p["cost"]   # EQ_COST сухопутных (константы — не из потока)
	var use := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
	var use_sum := 0.0
	for k in EQ_LAND:
		use[k] = use_in[k] * cost[k] / mult
		use_sum += use[k]
	var take := minf(1.0, left / maxf(use_sum, 0.001))
	for k in EQ_LAND:
		split[k] += use[k] * take
	left -= use_sum * take
	for tier in tiers:
		if left <= 0.0:
			break
		var tr: PackedFloat64Array = tier
		var want := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
		var want_sum := 0.0
		for k in EQ_LAND:
			var gap := maxf(0.0, tr[k] - stock[k])
			stock[k] = maxf(0.0, stock[k] - tr[k])
			want[k] = gap / PROD_HORIZON * cost[k] / mult
			want_sum += want[k]
		take = minf(1.0, left / maxf(want_sum, 0.001))
		for k in EQ_LAND:
			split[k] += want[k] * take
		left -= want_sum * take
	var dsum := 0.0
	for k in EQ_LAND:
		dsum += doctrine[k]
	var land_now := land_cap - left
	var keep := maxf(left * PROD_SURPLUS_LAND, land_cap * PROD_LAND_MIN - land_now)
	keep = clampf(keep, 0.0, left)
	for k in EQ_LAND:
		split[k] += keep * (doctrine[k] / dsum if dsum > 0.0 else 1.0 / EQ_LAND)
	var to_air := left - keep
	var air_w := maxf(air, 0.05)
	var aw := air_w / (air_w + naval)
	split[EQ_SHIP] = total * naval + to_air * (1.0 - aw)
	split[EQ_FIG] = total * air * 0.6 + to_air * aw * 0.6
	split[EQ_BOMB] = total * air * 0.4 + to_air * aw * 0.4
	for k in EQ_COUNT:
		split[k] = split[k] / total
	return split


static func plan_apply(nat: World.Nation, split: PackedFloat64Array) -> void:
	nat.prod_split = Array(split)
	_shift_lines(nat, nat.prod_split)


## Упреждение: пересмотры заводов у стран, чья очередь завтра, — в фоне, по
## снимку на сегодня (дивизии — копиями плоских массивов). Завтра Simulation
## применяет готовые доли (prod_job), а если их нет — считает сразу.
static func spec(world: World, jobs: Array) -> void:
	world.prod_job = {}
	var p_list: Array = []
	for nat in world.nations:
		if nat.alive and (not nat.is_player or nat.prod_auto) and not nat.prod_split.is_empty() \
				and (world.day + 1 + nat.id) % 30 == 0:
			var p := plan_prep(world, nat, AIPlanner.target_divisions(nat), not nat.planned_wars.is_empty())
			if not p.is_empty():
				p_list.append(p)
	if p_list.is_empty():
		return
	var snap := {"d_alive": world.d_alive.duplicate(), "d_owner": world.d_owner.duplicate(), "d_tpl": world.d_tpl.duplicate(),
		"d_eq": world.d_eq.duplicate(), "tpl_eq": world.tpl_eq.duplicate(), "n": world.nation_count}
	var out := {}
	world.prod_job = {"day": world.day + 1, "splits": out}
	jobs.append(func():
		var totals := _land_totals(snap)
		for p in p_list:
			out[int(p["id"])] = plan_compute(p, totals))


## Сдвинуть линии к долям split: не больше PROD_MOVE заводов в месяц.
static func _shift_lines(nat: World.Nation, split: Array) -> void:
	var current := [0, 0, 0, 0, 0, 0, 0, 0]
	for line in nat.lines:
		current[line[0]] += int(line[1])
	var budget := maxi(1, int(nat.mil * PROD_MOVE))
	while budget > 0:
		var from := -1
		var to := -1
		var best_over := 0.99
		var best_under := 0.99
		for k in EQ_COUNT:
			var gap: float = float(split[k]) * nat.mil - current[k]
			if -gap > best_over and current[k] > 0:
				best_over = -gap
				from = k
			if gap > best_under:
				best_under = gap
				to = k
		if from < 0 or to < 0:
			break
		var keep := maxf(EFF_START, _line_eff(nat, from) * EFF_KEEP)
		_add_to_line(nat, from, -1)
		_add_to_line(nat, to, 1, keep)
		current[from] -= 1
		current[to] += 1
		budget -= 1


# --- Подготовка и пополнение -------------------------------------------------

static func can_train(world: World, nat: World.Nation, t: int) -> String:
	var tp: Dictionary = world.templates[t]
	var miss := tech_missing(tp, nat)
	if miss != "":
		return "нужна технология «%s»" % Tech.get_tech(miss).get("name", miss)
	if nat.manpower < tp["men"]:
		return "не хватает людей"
	var eq: Array = tp["eq"]
	for k in EQ_COUNT:
		if nat.stock[k] < eq[k]:
			return "не хватает: " + EQ_NAMES[k].to_lower()
	return ""


static func start_training(world: World, nat: World.Nation, t: int) -> bool:
	if can_train(world, nat, t) != "":
		return false
	var tp: Dictionary = world.templates[t]
	var eq: Array = tp["eq"]
	nat.manpower -= tp["men"]
	for k in EQ_COUNT:
		nat.stock[k] -= eq[k]
	nat.training.append([int(tp["days"]), t])
	return true


## Пополнение дивизии за день: люди и снаряжение со склада; нужна связь
## со снабжением.
static func reinforce(world: World, nat: World.Nation, d: World.Division) -> void:
	if d.supply < 0.3 or (d.eq >= 1.0 and d.strength >= 100.0):
		return   # полностью укомплектована — быстрый выход
	var tp: Dictionary = world.templates[d.tpl]
	var eq: Array = tp["eq"]
	var rate := 0.04 * (1.0 + nat.b("reinforce")) * d.supply
	# снаряжение
	if d.eq < 1.0:
		var want := minf(1.0 - d.eq, rate)
		for k in EQ_COUNT:
			if eq[k] > 0:
				want = minf(want, nat.stock[k] / eq[k])
		if want > 0.0:
			for k in EQ_COUNT:
				nat.stock[k] -= eq[k] * want
			d.eq += want
	# люди
	if d.strength < 100.0:
		var add := minf(100.0 - d.strength, rate * 100.0)
		var men: float = add / 100.0 * tp["men"]
		if nat.manpower >= men:
			nat.manpower -= men
			d.strength += add


## Сколько снаряжения нужно, чтобы укомплектовать все дивизии (для ИИ и экрана).
static func shortage(world: World, n: int) -> Array:
	var need := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for d in world.divisions:
		if d.alive and d.owner == n and d.eq < 1.0:
			var eq: Array = world.templates[d.tpl]["eq"]
			for k in EQ_COUNT:
				need[k] += eq[k] * (1.0 - d.eq)
	return need


## Какой шаблон ИИ готовит следующим (детерминированно по номеру).
## Общий шаблон «Пехотная с артиллерией и ПТО» (ИИ при «Противотанковых
## пушках»): заводится при первой надобности — номер не фиксирован (в старых
## сохранениях за 6-м номером могут быть шаблоны игроков).
const AT_TEMPLATE := ["Пехотная с артиллерией и ПТО", "п+пто", [9, 0, 0, 2, 0, 0, 2]]


const AT_NEED_ARMOR := 5.0    # бронебойность пехоты с артиллерией (артиллерия — против пехоты): броня выше — нужны ПТО
static var _ea_day := -1
static var _ea := {}


## Наибольшая броня танковых дивизий противников страны (война или план войны);
## раз в день на страну (по одному проходу дивизий в день).
static func _enemy_armor(world: World, nat: World.Nation) -> float:
	if _ea_day != world.day:
		_ea_day = world.day
		_ea = {}
		for d in world.divisions:
			if d.alive and bat_n(world.templates[d.tpl]["bat"], B_TANK) > 0:
				_ea[d.owner] = maxf(float(_ea.get(d.owner, 0.0)), d.armor)
	var best := 0.0
	for e in nat.at_war:
		best = maxf(best, float(_ea.get(e, 0.0)))
	for e in nat.planned_wars:
		best = maxf(best, float(_ea.get(e, 0.0)))
	return best


static func at_template(world: World) -> int:
	for i in world.templates.size():
		var t: Dictionary = world.templates[i]
		if int(t["owner"]) < 0 and String(t.get("key", "")) == "inf_at":
			return i
	var nt := make_template(AT_TEMPLATE[0], AT_TEMPLATE[1], AT_TEMPLATE[2])
	nt["key"] = "inf_at"
	world.templates.append(nt)
	build_tables(world)
	return world.templates.size() - 1


static func ai_template(world: World, nat: World.Nation, k: int, mountainous: bool) -> int:
	var avail := available_templates(world, nat)
	# с «Противотанковыми пушками» вместо пехоты с артиллерией — с ПТО, если у
	# противника (нынешнего или запланированного) есть танки, которых она не пробивает
	var art: int = at_template(world) if nat.techs.has("at1") and _enemy_armor(world, nat) > AT_NEED_ARMOR else T_ART
	var cycle: Array = [T_INF, T_INF, art, T_INF]
	if avail.has(T_MOT):
		cycle.append(T_MOT)
	if avail.has(T_ARM):
		cycle.append(T_ARM)
	if mountainous and avail.has(T_MNT):
		cycle.append(T_MNT)
	return with_support(world, cycle[k % cycle.size()], ai_support(world, nat))


## Роты поддержки, которые ИИ добавляет в шаблоны: открытые технологиями и
## такие, чьё снаряжение страна выпускает (на каждый нужный тип — линия с
## заводами; решение пользователя), по AI_SUPPORT_ORDER, до SUPPORT_MAX;
## противотанковая — только против танков.
static func ai_support(world: World, nat: World.Nation) -> Array:
	var res: Array = []
	for id in AI_SUPPORT_ORDER:
		if res.size() >= SUPPORT_MAX:
			break
		var sp := support(id)
		if sp["req"] != "" and not nat.techs.has(sp["req"]):
			continue
		if not _produces(nat, sp["eq"]):
			continue
		if id == "at" and _enemy_armor(world, nat) <= AT_NEED_ARMOR:
			continue
		res.append(id)
	return res


## Выпускает ли страна все типы снаряжения eq (на каждый — линия с заводами).
static func _produces(nat: World.Nation, eq: Array) -> bool:
	for k in eq.size():
		if float(eq[k]) <= 0.0:
			continue
		var ok := false
		for line in nat.lines:
			if int(line[0]) == k and int(line[1]) > 0:
				ok = true
				break
		if not ok:
			return false
	return true


## Общий шаблон base с ротами sup (ИИ): заводится при первой надобности,
## скрыт из списка игрока; без рот — сам base.
static func with_support(world: World, base: int, sup: Array) -> int:
	if sup.is_empty():
		return base
	var key := "%d:%s" % [base, ",".join(sup)]
	for i in world.templates.size():
		var t: Dictionary = world.templates[i]
		if int(t["owner"]) < 0 and String(t.get("key", "")) == key:
			return i
	var b: Dictionary = world.templates[base]
	var nt := make_template(String(b["name"]) + " с ротами", b["short"], b["bat"], -1, sup)
	nt["key"] = key
	nt["hidden"] = true
	if b.has("key"):
		nt["base_key"] = b["key"]
	world.templates.append(nt)
	build_tables(world)
	return world.templates.size() - 1


## Боевая сила стороны: [сила, средняя бронированность]. Только поля дивизий и
## переданная таблица местности — можно вызывать из потоков.
static func side_power(divs: Array, terr: int, tmul: PackedFloat32Array, defending: bool) -> Array:
	var power := 0.0
	var hard := 0.0
	var wsum := 0.0
	for d in divs:
		var w: float = d.strength / 100.0
		var base: float = d.def * (1.0 + 0.3 * d.entrench) if defending else d.atk * (0.5 if d.landing else 1.0)
		power += base * w * (0.4 + 0.6 * d.eq) * World.sup_mult(d.supply) * tmul[d.tpl * 8 + terr]
		hard += d.hard * w
		wsum += w
	return [power, hard / maxf(wsum, 0.01)]


## Сохранение до ноября 2026 г. (7 типов снаряжения, прежний счёт единиц):
## ПТО — пятым типом, склады и выпуск — в новые единицы (EQ_UNIT_SCALE_OLD),
## линии судов и самолётов сдвигаются на номер, эффективность — к новому
## потолку, шаблоны пересобираются из составов.
static func migrate_eq8(world: World) -> void:
	for nat in world.nations:
		if nat.stock.size() != 7:
			continue
		nat.stock = _old_eq8(nat.stock) as PackedFloat32Array
		nat.daily_output = _old_eq8(nat.daily_output) as PackedFloat32Array
		nat.prod_acc = PackedFloat64Array(_old_eq8(nat.prod_acc))
		nat.prod_stock = PackedFloat64Array(_old_eq8(nat.prod_stock))
		nat.eq_use = PackedFloat64Array(_old_eq8(nat.eq_use))
		var cap := eff_cap(nat)
		for line in nat.lines:
			if int(line[0]) >= EQ_AT:
				line[0] = int(line[0]) + 1
			line[2] = clampf(float(line[2]) * cap, EFF_START, cap)
		if nat.prod_split.size() == 7:
			nat.prod_split.insert(EQ_AT, 0.0)
		nat.tank_heavy = nat.tank_design >= 0 and nat.tank_design < world.tank_designs.size() \
			and String(world.tank_designs[nat.tank_design]["hull"]).begins_with("heavy")
	for p in world.dep_stock:
		var ds: PackedFloat64Array = world.dep_stock[p]
		if ds.size() == 4:
			var nd := PackedFloat64Array()
			for k in 4:
				nd.append(ds[k] * float(EQ_UNIT_SCALE_OLD[k]))
			nd.append(0.0)
			world.dep_stock[p] = nd
	for i in world.templates.size():
		var t: Dictionary = world.templates[i]
		var nt := make_template(t["name"], t["short"], t["bat"], int(t["owner"]), template_support(t))
		nt["hidden"] = bool(t.get("hidden", false))
		world.templates[i] = nt
	build_tables(world)


static func _old_eq8(a: Variant) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for k in 7:
		var v: float = float(a[k]) * float(EQ_UNIT_SCALE_OLD[k])
		if k == EQ_AT:
			out.append(0.0)
		out.append(v)
	return out
