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
const BAT_COUNT := 6
# men — тыс. человек; eq — [винт., ору., танки, груз.]; terr — множитель на
# местности (равнины, лес, холмы, горы, город, море, пустыня, болота);
# motor — моторизован (скорость от бонуса «speed» полностью, снабжение ×1,5)
const BATTALIONS := [
	{"name": "Пехотный", "short": "пех.", "icon": "inf", "men": 1.0, "eq": [10.0, 1.2, 0.0, 0.0], "atk": 1.0, "def": 1.2, "org": 40.0, "spd": 1.0, "hard": 0.0, "days": 14, "req": "", "motor": false,
		"terr": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]},
	{"name": "Горнострелковый", "short": "горн.", "icon": "mnt", "men": 1.0, "eq": [11.0, 0.6, 0.0, 0.0], "atk": 0.9, "def": 1.2, "org": 45.0, "spd": 1.0, "hard": 0.0, "days": 18, "req": "mnt1", "motor": false,
		"terr": [1.0, 1.1, 1.35, 1.5, 1.0, 1.0, 0.9, 1.0]},
	{"name": "Кавалерийский", "short": "кав.", "icon": "cav", "men": 1.0, "eq": [10.0, 0.0, 0.0, 0.0], "atk": 1.0, "def": 1.0, "org": 50.0, "spd": 1.5, "hard": 0.0, "days": 14, "req": "", "motor": false,
		"terr": [1.1, 0.8, 0.9, 0.7, 0.8, 1.0, 1.1, 0.7]},
	# артиллерия: 2 батальона к 10 пехотным дают прежнюю «пехоту с артиллерией»;
	# на трудной местности она обуза (значения ниже 1 тянут среднее вниз)
	{"name": "Артиллерийский", "short": "арт.", "icon": "art", "men": 0.5, "eq": [0.0, 12.0, 0.0, 0.0], "atk": 3.0, "def": 1.0, "org": 18.0, "spd": 0.9, "hard": 0.0, "days": 18, "req": "", "motor": false,
		"terr": [1.55, 0.45, 0.45, -0.65, 1.0, 1.0, 1.55, -0.1]},
	{"name": "Моторизованный", "short": "мот.", "icon": "mot", "men": 1.0, "eq": [10.0, 1.2, 0.0, 6.0], "atk": 1.1, "def": 1.2, "org": 40.0, "spd": 2.0, "hard": 0.1, "days": 20, "req": "mot1", "motor": true,
		"terr": [1.1, 0.85, 0.9, 0.75, 0.9, 1.0, 1.1, 0.7]},
	{"name": "Танковый", "short": "танк.", "icon": "arm", "men": 1.0, "eq": [5.0, 0.0, 7.5, 5.0], "atk": 3.75, "def": 1.5, "org": 35.0, "spd": 1.8, "hard": 0.7, "days": 30, "req": "armor1", "motor": true,
		"terr": [1.15, 0.75, 0.75, 0.55, 0.75, 1.0, 1.15, 0.55]},
]
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
const BASE_SPEED := 0.28   # доля провинции в день для скорости 1.0 на равнине


## Собрать шаблон из состава bat (число батальонов каждого типа).
static func make_template(name: String, short: String, bat: Array, owner: int = -1) -> Dictionary:
	var men := 0.0
	var eq := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
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
	for b in BAT_COUNT:
		var c: int = int(bat[b])
		if c <= 0:
			continue
		total += c
		var bt: Dictionary = BATTALIONS[b]
		var m: float = c * float(bt["men"])
		men += m
		for k in 4:
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
	men = maxf(men, 0.01)
	for k in 8:
		terr[k] = clampf(terr[k] / men, 0.3, 2.0)
	return {"name": name, "short": short, "owner": owner, "bat": bat.duplicate(), "men": men, "eq": eq,
		"atk": atk, "def": def, "org": org / men, "hard": hard / men, "spd": spd if total > 0 else 1.0,
		"days": days, "req": req, "motor": motor and total > 0, "terr": terr, "cls": _template_class(bat),
		"hidden": false}


## Класс шаблона для значка и роли ИИ (номера общих шаблонов T_*).
static func _template_class(bat: Array) -> int:
	var total := 0
	for b in BAT_COUNT:
		total += int(bat[b])
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
	d.atk = t["atk"] * (1.0 + nat.b("attack"))
	d.def = t["def"] * (1.0 + nat.b("defense"))
	d.max_org = t["org"] * (1.0 + nat.b("org"))
	var spd_bonus := nat.b("speed") if t["motor"] else nat.b("speed") * 0.3
	d.spd = BASE_SPEED * t["spd"] * (1.0 + spd_bonus)
	d.hard = t["hard"]


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
	for t in world.templates:
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
static func save_template(world: World, nid: int, name: String, bat: Array, edit: int = -1) -> int:
	var total := 0
	for b in BAT_COUNT:
		total += int(bat[b])
	if total <= 0 or total > MAX_BATTALIONS:
		return -1
	var short := name.substr(0, 6).to_lower() + "."
	var nt := make_template(name, short, bat, nid)
	if edit >= 0:
		var old: Dictionary = world.templates[edit]
		if int(old["owner"]) != nid:
			return -1
		var nat: World.Nation = world.nations[nid]
		for d in world.divisions:
			if d.alive and d.tpl == edit:
				var frac := 1.0
				for k in EQ_LAND:
					var have: float = d.eq * float(old["eq"][k])
					if float(nt["eq"][k]) > 0.0:
						frac = minf(frac, have / float(nt["eq"][k]))
				for k in EQ_LAND:
					nat.stock[k] += maxf(0.0, d.eq * float(old["eq"][k]) - frac * float(nt["eq"][k]))
				var men_have: float = d.strength / 100.0 * float(old["men"])
				var s := minf(100.0, 100.0 * men_have / float(nt["men"]))
				nat.manpower += maxf(0.0, men_have - s / 100.0 * float(nt["men"]))
				d.eq = frac
				d.strength = maxf(1.0, s)
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


## Скрыть свой шаблон из списка (дивизии на нём остаются).
static func hide_template(world: World, nid: int, t: int) -> void:
	if t >= 0 and t < world.templates.size() and int(world.templates[t]["owner"]) == nid:
		world.templates[t]["hidden"] = true


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
		# нехватка ресурсов для того, что выпускает линия (Economy.RES_NEED)
		var units: float = f * mult * eff * Economy.line_mult(nat, eq) / EQ_COST[eq]
		nat.stock[eq] += units
		nat.daily_output[eq] += units
		nat.prod_acc[eq] += units
		line[2] = minf(1.0, eff + 0.01)


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
	var nc := world.nation_count
	var cnt := PackedInt32Array()
	cnt.resize(nc)
	var full := PackedFloat64Array()
	full.resize(nc * EQ_LAND)
	var lack := PackedFloat64Array()
	lack.resize(nc * EQ_LAND)
	var alive := world.d_alive
	var owner := world.d_owner
	var tpl := world.d_tpl
	var eqf := world.d_eq
	var te := world.tpl_eq
	for i in alive.size():
		if alive[i] == 0:
			continue
		var o := owner[i]
		cnt[o] += 1
		var t := tpl[i] * EQ_COUNT
		var miss := 1.0 - eqf[i]
		for k in EQ_LAND:
			full[o * EQ_LAND + k] += te[t + k]
			lack[o * EQ_LAND + k] += te[t + k] * miss
	return [cnt, full, lack]


static func plan_production(world: World, nat: World.Nation, target_divs: int, prepare_war: bool, totals: Array) -> void:
	# средний расход с прошлого пересмотра: склад был + выпуск − склад сейчас
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
		return
	# нужда сухопутных войск по очередям: 1 — пополнение и пехотное снаряжение
	# будущих дивизий (без него не сформировать ни одной), 2 — техника для
	# моторизованных и танковых, 3 — запас (у воюющих и готовящихся больше)
	var fielded := [0.0, 0.0, 0.0, 0.0]
	var tiers := [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
	var divs: int = totals[0][nat.id]
	for k in EQ_LAND:
		fielded[k] = totals[1][nat.id * EQ_LAND + k]
		tiers[0][k] = totals[2][nat.id * EQ_LAND + k]
	var up := maxi(0, target_divs - divs - nat.training.size())
	for i in up:
		var t := ai_template(world, nat, nat.trained_count + i, false)
		var tt: Dictionary = world.templates[t]
		var ti := 1 if tt["motor"] else 0
		for k in EQ_LAND:
			tiers[ti][k] += float(tt["eq"][k])
	var buffer := PROD_BUFFER_WAR if (not nat.at_war.is_empty() or prepare_war) else PROD_BUFFER
	for k in EQ_LAND:
		tiers[2][k] = buffer * fielded[k]
	var mult := maxf(0.1, (1.0 + nat.b("industry")) * (1.0 - nat.trade_penalty))
	var total := float(nat.mil)
	var land_cap := total * maxf(0.0, 1.0 - nat.naval_share - nat.air_share)
	var split := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	# средний расход — в первую очередь
	var left := land_cap
	var stock := [0.0, 0.0, 0.0, 0.0]
	for k in EQ_LAND:
		stock[k] = nat.stock[k]
	var use := [0.0, 0.0, 0.0, 0.0]
	var use_sum := 0.0
	for k in EQ_LAND:
		use[k] = nat.eq_use[k] * EQ_COST[k] / mult
		use_sum += use[k]
	var take := minf(1.0, left / maxf(use_sum, 0.001))
	for k in EQ_LAND:
		split[k] += use[k] * take
	left -= use_sum * take
	for tier in tiers:
		if left <= 0.0:
			break
		var want := [0.0, 0.0, 0.0, 0.0]
		var want_sum := 0.0
		for k in EQ_LAND:
			var gap := maxf(0.0, float(tier[k]) - stock[k])
			stock[k] = maxf(0.0, stock[k] - float(tier[k]))
			want[k] = gap / PROD_HORIZON * EQ_COST[k] / mult
			want_sum += want[k]
		take = minf(1.0, left / maxf(want_sum, 0.001))
		for k in EQ_LAND:
			split[k] += want[k] * take
		left -= want_sum * take
	# излишек: большая часть — в запас по доктрине (сухопутным линиям не
	# меньше PROD_LAND_MIN своей доли), остальное — в авиацию и флот
	var doctrine := default_split(nat)
	var dsum := 0.0
	for k in EQ_LAND:
		dsum += float(doctrine[k])
	var land_now := land_cap - left
	var keep := maxf(left * PROD_SURPLUS_LAND, land_cap * PROD_LAND_MIN - land_now)
	keep = clampf(keep, 0.0, left)
	for k in EQ_LAND:
		split[k] += keep * (float(doctrine[k]) / dsum if dsum > 0.0 else 0.25)
	var to_air := left - keep
	var ship_w := nat.naval_share
	var air_w := maxf(nat.air_share, 0.05)
	var aw := air_w / (air_w + ship_w)
	split[EQ_SHIP] = total * nat.naval_share + to_air * (1.0 - aw)
	split[EQ_FIG] = total * nat.air_share * 0.6 + to_air * aw * 0.6
	split[EQ_BOMB] = total * nat.air_share * 0.4 + to_air * aw * 0.4
	for k in EQ_COUNT:
		split[k] = split[k] / total
	nat.prod_split = split
	_shift_lines(nat, split)


## Сдвинуть линии к долям split: не больше PROD_MOVE заводов в месяц.
static func _shift_lines(nat: World.Nation, split: Array) -> void:
	var current := [0, 0, 0, 0, 0, 0, 0]
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
		_add_to_line(nat, from, -1)
		_add_to_line(nat, to, 1)
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
	var need := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for d in world.divisions:
		if d.alive and d.owner == n and d.eq < 1.0:
			var eq: Array = world.templates[d.tpl]["eq"]
			for k in EQ_COUNT:
				need[k] += eq[k] * (1.0 - d.eq)
	return need


## Какой шаблон ИИ готовит следующим (детерминированно по номеру).
static func ai_template(world: World, nat: World.Nation, k: int, mountainous: bool) -> int:
	var avail := available_templates(world, nat)
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
