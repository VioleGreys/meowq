class_name Occupation
extends RefCounted
## Чужие земли под нашей властью (решение пользователя, ноябрь 2026): занятые
## в войне (владелец — противник) и присоединённые на мирных переговорах
## (p_from — прежний владелец). Территория — пара «кто держит × чья земля».
##
## У провинции две шкалы: сопротивление (старт 10 %, растёт без гарнизона,
## гасится гарнизоном) и принятие (растёт по законам территории). Отдача
## заводов, фабрик и ресурсов = доля закона + принятие × мягкость закона
## (без интеграции — не выше 70 % этой прибавки), минус половина
## сопротивления. 100 % — только мягкие законы, полное принятие и интеграция.
## Жёсткие законы сразу дают больше (и больше людей), но поднимают
## сопротивление и сбивают принятие. Гарнизон — отдельные единицы на
## территории (люди и пехотное снаряжение), не воюют на фронте; нужное число —
## по провинциям и населению. Сильное сопротивление выбивает гарнизон.
## Интеграция (только присоединённые земли) стоит гражданских фабрик и
## ускоряет принятие. При мягких законах бывают события сотрудничества.

const STEP := 5                # пересчёт раз в 5 дней
const RESIST_START := 10.0
const RESIST_GAIN := 0.08      # % в день без гарнизона (× закон)
const RESIST_SUPPRESS := 0.12  # % в день при полном гарнизоне
const COMPLY_GAIN := 0.06      # % в день (× закон × (1 − сопротивление))
const INTEG_GAIN := 0.04       # % в день от интеграции
const NO_INTEG := 0.7          # без интеграции прибавка от принятия — не больше 70 %
const RESIST_YIELD := 0.5      # сопротивление 100 % отнимает половину отдачи
const GARR_MP := 1.0           # тыс. человек на единицу гарнизона
const GARR_EQ := 20.0          # пехотного снаряжения на единицу
const GARR_LOSS := 0.004       # доля гарнизона в день при сопротивлении 100 % (с 40 %)
const INTEG_PER := 20          # интеграция: гражданская фабрика на 20 провинций (не меньше 1)
const EVENT_CHANCE := 0.03     # шанс события сотрудничества за пересчёт
const EVENT_COMPLY := 8.0

const LAWS := [
	{"name": "Мягкое управление", "take": 0.30, "mp": 0.05, "soft": 1.0, "resist": 0.6, "comply": 1.0,
		"desc": "Отдача 30 %, принятие растёт быстрее всего и может дать до 100 %"},
	{"name": "Гражданская администрация", "take": 0.35, "mp": 0.10, "soft": 0.75, "resist": 1.0, "comply": 0.6,
		"desc": "Отдача 35 %, принятие растёт умеренно"},
	{"name": "Военная администрация", "take": 0.45, "mp": 0.25, "soft": 0.4, "resist": 1.5, "comply": 0.25,
		"desc": "Отдача 45 %, призыв 25 %, сопротивление ×1,5, принятие медленно"},
	{"name": "Жёсткие реквизиции", "take": 0.60, "mp": 0.40, "soft": 0.0, "resist": 2.2, "comply": -0.8,
		"desc": "Отдача 60 %, призыв 40 %, сопротивление ×2,2, принятие падает"},
]


static func tkey(c: int, k: int) -> int:
	return c * 4096 + k


## Ключ территории провинции или −1 (своя земля, союзник, море).
static func key_of(world: World, p: int) -> int:
	var o := world.p_owner[p]
	var c := world.p_controller[p]
	if c < 0 or o < 0 or world.p_land[p] == 0:
		return -1
	if c != o:
		var nc := world.nation_count
		if world.ally.size() == nc * nc and world.ally[c * nc + o] == 1:
			return -1
		if world.cores.has(p * 4096 + c):
			return -1   # своя национальная земля: сопротивления нет
		return tkey(c, o)
	if p < world.p_from.size():
		var f := world.p_from[p]
		if f >= 0 and f != c:
			return tkey(c, f)
	return -1


static func law_of(world: World, k: int) -> int:
	if world.occ_law.has(k):
		return world.occ_law[k]
	var c := k / 4096
	var nat: World.Nation = world.nations[c]
	if nat.is_player:
		return 1
	return 2 if nat.ideology == "fascism" or nat.ideology == "communism" else 1


static func _ensure(world: World) -> void:
	var pc := world.prov_count
	if world.p_resist.size() != pc:
		world.p_resist.resize(pc)
		world.p_resist.fill(-1.0)
		world.p_comply.resize(pc)
		world.p_comply.fill(0.0)
	if world.p_from.size() != pc:
		world.p_from.resize(pc)
		world.p_from.fill(-1)
	if world.p_yield.size() != pc:
		world.p_yield.resize(pc)
		world.p_yield.fill(1.0)
		world.p_yield_mp.resize(pc)
		world.p_yield_mp.fill(1.0)


## Земли перешли победителю по миру: прежний владелец запоминается.
static func on_annex(world: World, provs: PackedInt32Array, to: int, from: int) -> void:
	_ensure(world)
	for p in provs:
		if Claims.is_core(world, to, p):
			# национальная земля сразу интегрирована: часть страны, без сопротивления
			world.p_from[p] = -1
			world.p_resist[p] = -1.0
			world.p_comply[p] = 0.0
			world.p_yield[p] = 1.0
			world.p_yield_mp[p] = 1.0
			continue
		var f := world.p_from[p]
		world.p_from[p] = from if f < 0 else f
		if world.p_from[p] == to:
			world.p_from[p] = -1
		elif world.p_resist[p] < 0.0:
			world.p_resist[p] = RESIST_START
			world.p_comply[p] = 0.0


## Раз в день (главный поток): пересчёт шкал раз в STEP дней.
static func daily(world: World) -> void:
	_ensure(world)
	if world.day % STEP == 0 or world.occ_stats.is_empty() and world.day % STEP == 1:
		step(world)


static func step(world: World) -> void:
	_ensure(world)
	var pc := world.prov_count
	var kp := PackedInt32Array()
	kp.resize(pc)
	var need := {}
	var provs := PackedInt32Array()
	for p in pc:
		var k := key_of(world, p)
		kp[p] = k
		if k < 0:
			if world.p_resist[p] >= 0.0:
				world.p_resist[p] = -1.0
				world.p_comply[p] = 0.0
			world.p_yield[p] = 1.0
			world.p_yield_mp[p] = 1.0
			continue
		if world.p_resist[p] < 0.0:
			world.p_resist[p] = RESIST_START
			world.p_comply[p] = 0.0
		need[k] = float(need.get(k, 0.0)) + 0.5 + float(world.p_population[p]) / 2000.0
		provs.append(p)
	var stats := {}
	for p in provs:
		var k := kp[p]
		var law: Dictionary = LAWS[law_of(world, k)]
		var cover := minf(1.0, float(world.occ_garrison.get(k, 0.0)) / maxf(0.1, float(need[k])))
		var integ := world.occ_integrate.has(k) and world.p_owner[p] == world.p_controller[p]
		var r := world.p_resist[p]
		var cm := world.p_comply[p]
		# черты и фокусы: оккупант гасит сопротивление (occ_resist < 0) и
		# поднимает принятие (occ_comply); владелец земли (изгнанник, партизаны)
		# разгоняет сопротивление (resistance) и сбивает принятие
		var nc_: World.Nation = world.nations[k / 4096]
		var no_: World.Nation = world.nations[k % 4096]
		var rk := maxf(0.0, 1.0 + nc_.b("occ_resist") + no_.b("resistance"))
		var dr := RESIST_GAIN * float(law["resist"]) * rk * (1.0 - cover) * (1.0 - 0.7 * cm / 100.0) - RESIST_SUPPRESS * cover
		r = clampf(r + dr * STEP, 0.0, 100.0)
		var lc: float = law["comply"]
		var dc := COMPLY_GAIN * lc * ((1.0 - r / 100.0) if lc > 0.0 else 1.0)
		if lc > 0.0:
			dc *= maxf(0.0, 1.0 + nc_.b("occ_comply") - 0.5 * no_.b("resistance"))
		if integ:
			dc += INTEG_GAIN
		cm = clampf(cm + dc * STEP, 0.0, 100.0)
		world.p_resist[p] = r
		world.p_comply[p] = cm
		var soft := float(law["soft"]) * cm / 100.0 * (1.0 if integ else NO_INTEG)
		var keep := 1.0 - RESIST_YIELD * r / 100.0
		var take: float = law["take"]
		var mp: float = law["mp"]
		world.p_yield[p] = (take + (1.0 - take) * soft) * keep
		world.p_yield_mp[p] = (mp + (1.0 - mp) * soft) * keep
		if not stats.has(k):
			stats[k] = [0, 0.0, 0.0, 0.0, 0]
		var s: Array = stats[k]
		s[0] += 1
		s[1] += r
		s[2] += cm
		s[3] += world.p_yield[p]
		if world.p_owner[p] == world.p_controller[p]:
			s[4] += 1   # присоединённых (не занятых в войне)
	# гарнизон: потери от сопротивления; территории без земли распускаются
	var gks: Array = world.occ_garrison.keys()
	gks.sort()
	for k in gks:
		var c: int = k / 4096
		if not stats.has(k):
			world.nations[c].manpower += float(world.occ_garrison[k]) * GARR_MP
			world.occ_garrison.erase(k)
			continue
		var avg_r: float = float(stats[k][1]) / float(stats[k][0])
		if avg_r > 40.0:
			var g: float = world.occ_garrison[k]
			world.occ_garrison[k] = maxf(0.0, g - g * GARR_LOSS * (avg_r - 40.0) / 60.0 * STEP)
	for k in world.occ_integrate.keys():
		if not stats.has(k) or int(stats[k][4]) == 0:
			world.occ_integrate.erase(k)
	world.occ_need = need
	world.occ_stats = stats
	world.occ_provs = provs
	_events(world)
	_ai(world)


## События сотрудничества: при мягких законах и среднем принятии.
static func _events(world: World) -> void:
	var rng := Parallel.rng(world.seed_value, world.day, 4242)
	var ks: Array = world.occ_stats.keys()
	ks.sort()
	for k in ks:
		var s: Array = world.occ_stats[k]
		var cm: float = float(s[2]) / float(s[0])
		if law_of(world, k) > 1 or cm < 20.0 or cm > 95.0 or rng.randf() >= EVENT_CHANCE:
			continue
		for p in world.occ_provs:
			if key_of(world, p) == k:
				world.p_comply[p] = minf(100.0, world.p_comply[p] + EVENT_COMPLY)
		var c: int = k / 4096
		if world.nations[c].is_player:
			world.log_event("Земли страны %s: местные власти идут на сотрудничество (+%d%% принятия)" % [world.nations[k % 4096].name, int(EVENT_COMPLY)])


## ИИ: гарнизон по нужде, если есть люди и снаряжение; интеграция в мирное время.
static func _ai(world: World) -> void:
	var ks: Array = world.occ_stats.keys()
	ks.sort()
	for k in ks:
		var c: int = k / 4096
		var nat: World.Nation = world.nations[c]
		if nat.is_player or not nat.alive:
			continue
		var need: float = ceilf(float(world.occ_need[k]))
		if float(world.occ_garrison.get(k, 0.0)) < need * 0.9:
			set_garrison(world, k, need)
		if int(world.occ_stats[k][4]) > 0 and nat.at_war.is_empty() and nat.civ > 20 and not world.occ_integrate.has(k):
			world.occ_integrate[k] = true


## Игрок меняет закон территории: стоит ПВ. Пусто — сделано, иначе причина.
static func set_law(world: World, k: int, law: int) -> String:
	var nat: World.Nation = world.nations[k / 4096]
	var why := Politics.spend(world, nat, Politics.COST_OCC_LAW) if nat.is_player else ""
	if why != "":
		return why
	world.occ_law[k] = law
	return ""


## Разовый сдвиг шкал (эффекты фокусов «resist» / «comply») на землях стран
## owners, занятых чужими: сопротивление или принятие ± v.
static func shift(world: World, owners: Dictionary, v: float, resist: bool) -> void:
	_ensure(world)
	for p in world.prov_count:
		var k := key_of(world, p)
		if k < 0 or not owners.has(k % 4096):
			continue
		if world.p_resist[p] < 0.0:
			world.p_resist[p] = RESIST_START
			world.p_comply[p] = 0.0
		if resist:
			world.p_resist[p] = clampf(world.p_resist[p] + v, 0.0, 100.0)
		else:
			world.p_comply[p] = clampf(world.p_comply[p] + v, 0.0, 100.0)


## Гарнизон территории: набор стоит людей и пехотного снаряжения, роспуск
## возвращает людей. Набирается сколько хватает.
static func set_garrison(world: World, k: int, units: float) -> void:
	var c: int = k / 4096
	var nat: World.Nation = world.nations[c]
	var cur: float = world.occ_garrison.get(k, 0.0)
	units = maxf(0.0, floorf(units))
	if units > cur:
		var add := units - cur
		add = minf(add, floorf(maxf(0.0, nat.manpower - 50.0) / GARR_MP))
		add = minf(add, floorf(nat.stock[Military.EQ_INF] / GARR_EQ))
		if add <= 0.0:
			return
		nat.manpower -= add * GARR_MP
		nat.stock[Military.EQ_INF] -= add * GARR_EQ
		world.occ_garrison[k] = cur + add
	elif units < cur:
		nat.manpower += (cur - units) * GARR_MP
		if units <= 0.0:
			world.occ_garrison.erase(k)
		else:
			world.occ_garrison[k] = units


## Гражданских фабрик на интеграцию территории.
static func integ_cost(world: World, k: int) -> int:
	if not world.occ_stats.has(k):
		return 0
	return maxi(1, int(world.occ_stats[k][4]) / INTEG_PER)


## Доход стран с учётом отдачи чужих земель (results — World.compute_all_income).
## Ядро дохода считает свои земли целиком, занятые — вполсилы (призыв 1/5);
## здесь это заменяется отдачей по законам и шкалам. Плюс плата за интеграцию.
static func adjust_income(world: World, results: Array) -> void:
	if world.occ_provs.is_empty() and world.occ_integrate.is_empty():
		return
	var nc := world.nation_count
	var dciv := PackedFloat64Array()
	dciv.resize(nc)
	var dmil := PackedFloat64Array()
	dmil.resize(nc)
	var dmp := PackedFloat64Array()
	dmp.resize(nc)
	for p in world.occ_provs:
		var c := world.p_controller[p]
		if c < 0 or key_of(world, p) < 0:
			continue
		var own := world.p_owner[p] == c
		var y := world.p_yield[p]
		var ym := world.p_yield_mp[p]
		var civ := world.p_civ[p]
		var mil := world.p_mil[p]
		var mp := world.p_manpower[p]
		dciv[c] += civ * y - float(civ if own else civ / 2)
		dmil[c] += mil * y - float(mil if own else mil / 2)
		dmp[c] += mp * ym - float(mp if own else mp / 5)
	for k in world.occ_integrate:
		dciv[k / 4096] -= integ_cost(world, k)
	for n in nc:
		if dciv[n] == 0.0 and dmil[n] == 0.0 and dmp[n] == 0.0:
			continue
		var r: Array = results[n]
		r[0] = maxi(0, int(r[0]) + roundi(dciv[n]))
		r[1] = maxi(0, int(r[1]) + roundi(dmil[n]))
		r[2] = maxi(0, int(r[2]) + roundi(dmp[n]))


## Средние по территории для интерфейса: [провинций, сопротивление, принятие, отдача, присоединённых].
static func stats(world: World, k: int) -> Array:
	if not world.occ_stats.has(k):
		return [0, 0.0, 0.0, 0.0, 0]
	var s: Array = world.occ_stats[k]
	var n := float(s[0])
	return [s[0], s[1] / n, s[2] / n, s[3] / n, s[4]]


## Территории страны c (ключи), крупные сначала.
static func territories(world: World, c: int) -> Array:
	var r: Array = []
	for k in world.occ_stats:
		if k / 4096 == c:
			r.append(k)
	r.sort_custom(func(a, b): return int(world.occ_stats[a][0]) > int(world.occ_stats[b][0]) if world.occ_stats[a][0] != world.occ_stats[b][0] else a < b)
	return r
