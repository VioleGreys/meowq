class_name Doctrine
extends RefCounted
## Доктрины — боевой опыт (решение пользователя, ноябрь 2026): опыт армии,
## флота и авиации копится только в боях (Simulation._phase_combat,
## Forces.daily_navy, Forces.daily_air) и тратится на ступени школ. В каждом
## роде сил страна выбирает одну школу; ИИ всегда берёт историческую
## (`doctrine` в nations.json, иначе `default_pref`). Кто воюет раньше —
## раньше получает доктрины; кто воюет больше — догоняет и обгоняет.
## Таблицы читаются только из главного потока.

const BRANCHES := ["land", "navy", "air"]
const BRANCH_NAMES := ["Армия", "Флот", "Авиация"]
const BRANCH_GEN := ["армии", "флота", "авиации"]
const COSTS := {"land": [30.0, 60.0, 100.0, 140.0, 180.0], "navy": [40.0, 70.0, 100.0, 140.0], "air": [40.0, 70.0, 100.0, 140.0]}
const XP_MAX := 250.0
# опыт за день боёв: армия — за каждую дивизию в сражении, авиация — за крыло
# в бою или на задании, флот — за соединение в морском бою или в рейде
const LAND_PER_DIV := 0.04
const LAND_CAP := 3.0
const AIR_PER_WING := 0.03
const AIR_CAP := 0.6
const NAVY_PER_FLEET := 0.15
const NAVY_PER_RAID := 0.04
const NAVY_CAP := 0.8

# школы: ступени [id, название, бонусы, пояснение] — по порядку изучения
const SCHOOLS := [
	{"id": "mob", "branch": "land", "name": "Подвижная война", "steps": [
		["l_mob1", "Танковые соединения", {"tank_attack": 0.05}, "Танки собраны в дивизии, а не розданы пехоте."],
		["l_mob2", "Взаимодействие с авиацией", {"air_cas": 0.05, "speed": 0.02}, "Самолёты расчищают путь наступающим колоннам."],
		["l_mob3", "Прорыв и охват", {"attack": 0.04, "tank_attack": 0.03}, "Удар в узком месте и выход в тыл, не оглядываясь на фланги."],
		["l_mob4", "Боевые группы", {"org": 0.04, "speed": 0.03}, "Сводные отряды под задачу дня."],
		["l_mob5", "Подвижная оборона", {"tank_defense": 0.05, "defense": 0.02}, "Танковые резервы срезают чужие прорывы контрударами."],
	]},
	{"id": "fire", "branch": "land", "name": "Огневое превосходство", "steps": [
		["l_fire1", "Огневой вал", {"art_attack": 0.05}, "Пехота идёт за стеной разрывов."],
		["l_fire2", "Корректировка огня", {"art_attack": 0.03, "air_cas": 0.03}, "Наблюдатели в цепях и в воздухе."],
		["l_fire3", "Сосредоточение батарей", {"art_attack": 0.05}, "Огонь многих дивизионов по одной цели."],
		["l_fire4", "Бережение людей", {"reinforce": 0.10, "defense": 0.02}, "Снаряды вместо жизней."],
		["l_fire5", "Огонь по вызову", {"attack": 0.03, "art_defense": 0.04}, "Командир роты вызывает огонь по радио."],
	]},
	{"id": "meth", "branch": "land", "name": "Методичный бой", "steps": [
		["l_meth1", "Сплошной фронт", {"defense": 0.03}, "Без разрывов в линии — противнику некуда просочиться."],
		["l_meth2", "Планирование операций", {"org": 0.04}, "Каждый шаг расписан штабом заранее."],
		["l_meth3", "Эшелонированная оборона", {"inf_defense": 0.03, "defense": 0.01}, "Несколько полос обороны одна за другой."],
		["l_meth4", "Подготовленное наступление", {"attack": 0.03, "art_attack": 0.03}, "Удар только после разведки и подвоза."],
		["l_meth5", "Резервы командования", {"org": 0.04, "reinforce": 0.06}, "Свежие дивизии в руках командующего."],
	]},
	{"id": "mass", "branch": "land", "name": "Массированный удар", "steps": [
		["l_mass1", "Массовые армии", {"manpower": 0.10}, "Кадры для развёртывания миллионов."],
		["l_mass2", "Глубокий бой", {"attack": 0.03}, "Удар сразу на всю глубину обороны."],
		["l_mass3", "Эшелоны развития успеха", {"inf_attack": 0.04, "speed": 0.02}, "Второй эшелон входит в пробитую брешь."],
		["l_mass4", "Ударные армии", {"attack": 0.03, "reinforce": 0.06}, "Армии прорыва с усиленной артиллерией."],
		["l_mass5", "Операции на окружение", {"attack": 0.03, "tank_attack": 0.03}, "Встречные удары смыкаются в тылу врага."],
	]},
	{"id": "bb", "branch": "navy", "name": "Линейный флот", "steps": [
		["n_bb1", "Решающее сражение", {"ship_bb": 0.05}, "Исход войны на море решают линейные силы."],
		["n_bb2", "Линия баталии", {"ship_cr": 0.05}, "Крейсеры разведывают и прикрывают линию."],
		["n_bb3", "Ночной бой", {"naval": 0.03}, "Торпедные атаки и прожекторы в темноте."],
		["n_bb4", "Прикрытие соединения", {"ship_bb": 0.05, "ship_dd": 0.03}, "Эсминцы и зенитки вокруг линкоров."],
	]},
	{"id": "car", "branch": "navy", "name": "Авианосные соединения", "steps": [
		["n_car1", "Авианосец в разведке", {"air_naval": 0.05}, "Палубная авиация — глаза флота."],
		["n_car2", "Ударные авиагруппы", {"air_naval": 0.05, "naval": 0.02}, "Авиация бьёт раньше, чем дойдут орудия."],
		["n_car3", "Авианосные соединения", {"naval": 0.03}, "Несколько авианосцев в одном ударе."],
		["n_car4", "Оперативные группы", {"air_naval": 0.06}, "Авианосцы, линкоры охранения и снабжение в море."],
	]},
	{"id": "raid", "branch": "navy", "name": "Война на коммуникациях", "steps": [
		["n_raid1", "Крейсерская война", {"ship_ss": 0.05, "sub_raid": 0.05}, "Удары по торговле вместо генерального сражения."],
		["n_raid2", "Рейдеры в океане", {"sub_raid": 0.06}, "Одиночные корабли на путях конвоев."],
		["n_raid3", "Групповые атаки лодок", {"ship_ss": 0.05}, "Лодки собираются у найденного конвоя."],
		["n_raid4", "Блокада морских путей", {"sub_raid": 0.06, "ship_dd": 0.03}, "Минные постановки и охота у чужих портов."],
	]},
	{"id": "fig", "branch": "air", "name": "Господство в воздухе", "steps": [
		["a_fig1", "Воздушный бой за небо", {"air_fighter": 0.05}, "Сначала уничтожить чужую авиацию."],
		["a_fig2", "Наведение с земли", {"air_def": 0.05, "air_coord": 0.1}, "Посты и пункты управления ведут истребители к цели."],
		["a_fig3", "Свободная охота", {"air_fighter": 0.05}, "Пары истребителей ищут противника сами."],
		["a_fig4", "Оборона империи", {"air_fighter": 0.04, "air_def": 0.05}, "Сплошная система ПВО страны."],
	]},
	{"id": "cas", "branch": "air", "name": "Поддержка войск", "steps": [
		["a_cas1", "Авиация над полем боя", {"air_cas": 0.05}, "Самолёты работают на передний край."],
		["a_cas2", "Авианаводчики", {"air_cas": 0.05, "air_coord": 0.1}, "Офицер связи с рацией в передовых частях."],
		["a_cas3", "Изоляция поля боя", {"air_cas": 0.04, "air_fighter": 0.02}, "Удары по мостам и дорогам за линией фронта."],
		["a_cas4", "Воздушные армии", {"air_cas": 0.05}, "Вся авиация фронта под одним командованием."],
	]},
	{"id": "bmb", "branch": "air", "name": "Стратегические удары", "steps": [
		["a_bmb1", "Воздушное наступление", {"air_bomb": 0.05}, "Война выигрывается ударами по тылу врага."],
		["a_bmb2", "Удары по промышленности", {"air_bomb": 0.05}, "Цели — заводы, электростанции, нефть."],
		["a_bmb3", "Ночные налёты", {"air_bomb": 0.05, "air_def": 0.02, "air_coord": 0.05}, "Темнота укрывает бомбардировщики."],
		["a_bmb4", "Сплошные бомбардировки", {"air_bomb": 0.06}, "Сотни машин в одном налёте."],
	]},
]

static var _step := {}     # id -> {"school", "n", "name", "bonus", "desc", "branch"}
static var _school := {}   # id школы -> запись SCHOOLS


static func _ensure() -> void:
	if not _step.is_empty():
		return
	for s in SCHOOLS:
		_school[s["id"]] = s
		var steps: Array = s["steps"]
		for i in steps.size():
			var r: Array = steps[i]
			_step[r[0]] = {"id": r[0], "school": s["id"], "branch": s["branch"], "n": i, "name": r[1], "bonus": r[2], "desc": r[3]}


static func branch_index(branch: String) -> int:
	return BRANCHES.find(branch)


static func get_step(id: String) -> Dictionary:
	_ensure()
	return _step.get(id, {})


static func get_school(id: String) -> Dictionary:
	_ensure()
	return _school.get(id, {})


static func schools_of(branch: String) -> Array:
	var res: Array = []
	for s in SCHOOLS:
		if s["branch"] == branch:
			res.append(s)
	return res


static func cost(branch: String, n: int) -> float:
	var c: Array = COSTS[branch]
	return float(c[clampi(n, 0, c.size() - 1)])


## Историческая школа страны в роде сил (её всегда берёт ИИ).
static func pref(nat, branch: String) -> String:
	var p: String = nat.doctrine_pref.get(branch, "")
	return p if get_school(p).get("branch", "") == branch else default_pref(nat, branch)


## Без данных в nations.json: коммунисты — массированный удар, остальные —
## методичный бой; флот — война на коммуникациях; авиация — поддержка войск.
static func default_pref(nat, branch: String) -> String:
	match branch:
		"land":
			return "mass" if nat.ideology == "communism" else "meth"
		"navy":
			return "raid"
	return "cas"


## Выбранная школа (по первой принятой ступени); "" — ещё не выбрана.
static func school_of(nat, branch: String) -> String:
	for s in schools_of(branch):
		if nat.doctrines.has(s["steps"][0][0]):
			return s["id"]
	return ""


## Сколько ступеней школы принято.
static func steps_done(nat, school: String) -> int:
	var c := 0
	for r in get_school(school).get("steps", []):
		if nat.doctrines.has(r[0]):
			c += 1
	return c


## Можно ли принять ступень сейчас (школа своя или ещё не выбрана, предыдущая
## ступень принята); опыт проверяет can_buy.
static func can_take(nat, id: String) -> bool:
	var st := get_step(id)
	if st.is_empty() or nat.doctrines.has(id):
		return false
	var sc := school_of(nat, st["branch"])
	if sc != "" and sc != st["school"]:
		return false
	return steps_done(nat, st["school"]) == int(st["n"])


static func can_buy(nat, id: String) -> bool:
	var st := get_step(id)
	return can_take(nat, id) and nat.xp[branch_index(st["branch"])] >= cost(st["branch"], int(st["n"]))


static func buy(nat, id: String) -> bool:
	if not can_buy(nat, id):
		return false
	var st := get_step(id)
	nat.xp[branch_index(st["branch"])] -= cost(st["branch"], int(st["n"]))
	nat.doctrines[id] = true
	var bon: Dictionary = st["bonus"]
	for k in bon:
		nat.bonus[k] = float(nat.bonus.get(k, 0.0)) + float(bon[k])
		if not Tech.ECON_KEYS.has(k):
			nat.stats_dirty = true
	return true


## Начислить опыт роду сил (главный поток).
## Прибавку ускоряют поддержка войны и военные советники (Politics: xp_land / xp_navy / xp_air).
const XP_KEYS := ["xp_land", "xp_navy", "xp_air"]


static func gain(nat, b: int, amount: float) -> void:
	if amount > 0.0:
		nat.xp[b] = minf(XP_MAX, nat.xp[b] + amount * maxf(0.0, 1.0 + nat.b(XP_KEYS[b])))


## Следующая ступень школы, которую ИИ берёт в роде сил.
static func ai_next(nat, branch: String) -> String:
	var sc := school_of(nat, branch)
	if sc == "":
		sc = pref(nat, branch)
	var steps: Array = get_school(sc)["steps"]
	var n := steps_done(nat, sc)
	return steps[n][0] if n < steps.size() else ""


## ИИ: принять доступные ступени исторической школы (раз в день, после боёв).
static func ai_daily(world) -> void:
	for nat in world.nations:
		if not nat.alive or nat.is_player:
			continue
		for b in BRANCHES.size():
			if nat.xp[b] < cost(BRANCHES[b], 0):
				continue
			var id := ai_next(nat, BRANCHES[b])
			if id != "" and buy(nat, id):
				if nat.major:
					world.log_event("%s: доктрина «%s»" % [nat.name, get_step(id)["name"]])


## Эффект ступени словами.
static func effect_text(st: Dictionary) -> String:
	var parts: Array = []
	var bon: Dictionary = st["bonus"]
	for k in bon:
		parts.append("%s +%d%%" % [Tech.BONUS_NAMES.get(k, k), roundi(float(bon[k]) * 100.0)])
	return "; ".join(parts)
