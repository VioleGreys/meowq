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
const EQ_SHIP := 4     # очки судостроения (корабли закладываются из них, см. Forces)
const EQ_FIG := 5      # истребители (самолёты в резерве)
const EQ_BOMB := 6     # бомбардировщики
const EQ_COUNT := 7
const EQ_LAND := 4     # первые 4 типа — снаряжение сухопутных дивизий
const EQ_NAMES := ["Стрелковое оружие", "Артиллерия", "Бронетехника", "Грузовики", "Судостроение", "Истребители", "Бомбардировщики"]
const EQ_SHORT := ["Винт.", "Ору.", "Танки", "Груз.", "Суда", "Истр.", "Бомб."]
# цена единицы в «очках производства»; один военный завод даёт 1 очко в день
const EQ_COST := [1.0, 3.5, 12.0, 2.5, 1.0, 6.0, 12.0]

# --- Шаблоны дивизий -------------------------------------------------------------
const T_INF := 0
const T_MNT := 1
const T_CAV := 2
const T_ART := 3
const T_MOT := 4
const T_ARM := 5
# men — тыс. человек; eq — [винт., ору., танки, груз.]; spd — множитель скорости;
# hard — бронированность (снижает урон от атакующих без танков)
const TEMPLATES := [
	{"name": "Пехотная", "short": "пех.", "men": 10.0, "eq": [100, 12, 0, 0, 0, 0, 0], "atk": 10.0, "def": 12.0, "org": 40.0, "spd": 1.0, "hard": 0.0, "days": 14, "req": ""},
	{"name": "Горнострелковая", "short": "горн.", "men": 10.0, "eq": [110, 6, 0, 0, 0, 0, 0], "atk": 9.0, "def": 12.0, "org": 45.0, "spd": 1.0, "hard": 0.0, "days": 18, "req": "mnt1"},
	{"name": "Кавалерийская", "short": "кав.", "men": 8.0, "eq": [80, 0, 0, 0, 0, 0, 0], "atk": 8.0, "def": 8.0, "org": 50.0, "spd": 1.5, "hard": 0.0, "days": 14, "req": ""},
	{"name": "Пехотная с артиллерией", "short": "п+арт", "men": 11.0, "eq": [100, 36, 0, 0, 0, 0, 0], "atk": 16.0, "def": 14.0, "org": 38.0, "spd": 0.9, "hard": 0.0, "days": 18, "req": ""},
	{"name": "Моторизованная", "short": "мот.", "men": 10.0, "eq": [100, 12, 0, 60, 0, 0, 0], "atk": 11.0, "def": 12.0, "org": 40.0, "spd": 2.0, "hard": 0.1, "days": 20, "req": "mot1"},
	{"name": "Танковая", "short": "танк.", "men": 8.0, "eq": [40, 0, 60, 40, 0, 0, 0], "atk": 30.0, "def": 12.0, "org": 35.0, "spd": 1.8, "hard": 0.7, "days": 30, "req": "armor1"},
]
const BASE_SPEED := 0.28   # доля провинции в день для скорости 1.0 на равнине

# Множитель атаки/обороны шаблона на местности (индексы World.T_*):
# равнины, лес, холмы, горы, город, море, пустыня, болота
const TERRAIN_MULT := [
	[1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0],      # пехота
	[1.0, 1.1, 1.35, 1.5, 1.0, 1.0, 0.9, 1.0],     # горные
	[1.1, 0.8, 0.9, 0.7, 0.8, 1.0, 1.1, 0.7],      # кавалерия
	[1.05, 0.95, 0.95, 0.85, 1.0, 1.0, 1.05, 0.9], # пехота с артиллерией
	[1.1, 0.85, 0.9, 0.75, 0.9, 1.0, 1.1, 0.7],    # моторизованная
	[1.15, 0.75, 0.75, 0.55, 0.75, 1.0, 1.15, 0.55], # танковая
]


static func tpl_count() -> int:
	return TEMPLATES.size()


static func tpl(t: int) -> Dictionary:
	return TEMPLATES[t]


static func available_templates(nat: World.Nation) -> Array:
	var res: Array = []
	for i in TEMPLATES.size():
		var req: String = TEMPLATES[i]["req"]
		if req == "" or nat.techs.has(req):
			res.append(i)
	return res


static func eq_points(t: int) -> float:
	var s := 0.0
	var eq: Array = TEMPLATES[t]["eq"]
	for k in EQ_COUNT:
		s += eq[k] * EQ_COST[k]
	return s


## Пересчитать кэш характеристик дивизии (главный поток).
static func refresh_division(world: World, d: World.Division) -> void:
	var nat: World.Nation = world.nations[d.owner]
	var t: Dictionary = TEMPLATES[d.tpl]
	d.atk = t["atk"] * (1.0 + nat.b("attack"))
	d.def = t["def"] * (1.0 + nat.b("defense"))
	d.max_org = t["org"] * (1.0 + nat.b("org"))
	var spd_bonus := nat.b("speed") if d.tpl >= T_MOT else nat.b("speed") * 0.3
	d.spd = BASE_SPEED * t["spd"] * (1.0 + spd_bonus)
	d.hard = t["hard"]


## Таблица множителей местности в Packed-массив мира (для параллельных фаз).
static func build_tables(world: World) -> void:
	world.tpl_terrain = PackedFloat32Array()
	for t in TEMPLATES.size():
		for k in 8:
			world.tpl_terrain.append(TERRAIN_MULT[t][k])


# --- Производство ----------------------------------------------------------------

## Стартовые линии по доктрине/технологиям: доли заводов по типам снаряжения.
static func default_split(nat: World.Nation) -> Array:
	var land: Array
	if nat.techs.has("armor1"):
		land = [0.45, 0.2, 0.2, 0.15]
	elif nat.techs.has("mot1"):
		land = [0.55, 0.25, 0.0, 0.2]
	else:
		land = [0.7, 0.3, 0.0, 0.0]
	# доли флота и авиации — из forces.json (nat.naval_share / air_share)
	var rest := 1.0 - nat.naval_share - nat.air_share
	var res: Array = []
	for k in 4:
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
	var current := [0, 0, 0, 0, 0, 0, 0]
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


static func _add_to_line(nat: World.Nation, eq: int, n: int) -> void:
	for line in nat.lines:
		if line[0] == eq:
			line[1] = maxi(0, int(line[1]) + n)
			if n > 0:
				# новые заводы разгоняются с нуля — эффективность линии чуть падает
				line[2] = maxf(0.3, float(line[2]) - 0.5 * n / maxf(1.0, float(line[1])))
			return
	if n > 0:
		nat.lines.append([eq, n, 0.3])


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


## Дневной выпуск: очки -> единицы снаряжения; эффективность растёт до 100%.
static func produce(nat: World.Nation) -> void:
	# рейды подлодок по торговле снижают выпуск (Forces.trade_penalty)
	var mult := (1.0 + nat.b("industry")) * (1.0 - nat.trade_penalty)
	for k in EQ_COUNT:
		nat.daily_output[k] = 0.0
	for line in nat.lines:
		var eq: int = line[0]
		var f: int = line[1]
		if f <= 0:
			continue
		var eff: float = line[2]
		var units: float = f * mult * eff / EQ_COST[eq]
		nat.stock[eq] += units
		nat.daily_output[eq] += units
		line[2] = minf(1.0, eff + 0.01)


# --- Подготовка и пополнение -------------------------------------------------

static func can_train(nat: World.Nation, t: int) -> String:
	var tp: Dictionary = TEMPLATES[t]
	if tp["req"] != "" and not nat.techs.has(tp["req"]):
		return "нужна технология «%s»" % Tech.get_tech(tp["req"]).get("name", tp["req"])
	if nat.manpower < tp["men"]:
		return "не хватает людей"
	var eq: Array = tp["eq"]
	for k in EQ_COUNT:
		if nat.stock[k] < eq[k]:
			return "не хватает: " + EQ_NAMES[k].to_lower()
	return ""


static func start_training(nat: World.Nation, t: int) -> bool:
	if can_train(nat, t) != "":
		return false
	var tp: Dictionary = TEMPLATES[t]
	var eq: Array = tp["eq"]
	nat.manpower -= tp["men"]
	for k in EQ_COUNT:
		nat.stock[k] -= eq[k]
	nat.training.append([int(tp["days"]), t])
	return true


## Пополнение дивизии за день: люди и снаряжение со склада; нужна связь
## со снабжением.
static func reinforce(nat: World.Nation, d: World.Division) -> void:
	if d.supply < 0.3 or (d.eq >= 1.0 and d.strength >= 100.0):
		return   # полностью укомплектована — быстрый выход
	var tp: Dictionary = TEMPLATES[d.tpl]
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
	var need := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for d in world.divisions:
		if d.alive and d.owner == n and d.eq < 1.0:
			var eq: Array = TEMPLATES[d.tpl]["eq"]
			for k in EQ_COUNT:
				need[k] += eq[k] * (1.0 - d.eq)
	return need


## Какой шаблон ИИ готовит следующим (детерминированно по номеру).
static func ai_template(nat: World.Nation, k: int, mountainous: bool) -> int:
	var avail := available_templates(nat)
	var cycle: Array = [T_INF, T_INF, T_ART, T_INF]
	if avail.has(T_MOT):
		cycle.append(T_MOT)
	if avail.has(T_ARM):
		cycle.append(T_ARM)
	if mountainous and avail.has(T_MNT):
		cycle.append(T_MNT)
	return cycle[k % cycle.size()]


## Боевая сила стороны: [сила, средняя бронированность]. Только поля дивизий и
## переданная таблица местности — можно вызывать из потоков.
static func side_power(divs: Array, terr: int, tmul: PackedFloat32Array, defending: bool) -> Array:
	var power := 0.0
	var hard := 0.0
	var wsum := 0.0
	for d in divs:
		var w: float = d.strength / 100.0
		var base: float = d.def * (1.0 + 0.3 * d.entrench) if defending else d.atk * (0.5 if d.landing else 1.0)
		power += base * w * (0.4 + 0.6 * d.eq) * (0.5 + 0.5 * d.supply) * tmul[d.tpl * 8 + terr]
		hard += d.hard * w
		wsum += w
	return [power, hard / maxf(wsum, 0.01)]
