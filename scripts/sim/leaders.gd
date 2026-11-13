class_name Leaders
extends RefCounted
## Командиры (как в жанре, ноябрь 2026, просьба пользователя): генерал ведёт
## армию до ARMY_MAX дивизий, маршал — группу армий до FRONT_MAX армий. Навыки
## 1…STAT_MAX: атака, оборона, планирование, манёвр. Генерал даёт своим дивизиям
## полный бонус навыков, маршал — MARSHAL_K от своего всем дивизиям группы
## (множители перемножаются). Опыт — за дни боя дивизий; уровень (до LEVEL_MAX)
## прибавляет единицу случайному навыку.
##
## Бонусы — множители по слотам дивизий (кэш World.ld_*), их кладут поверх
## действующих атаки, обороны и скорости (World.d_*_eff, после Climate.daily) и
## прибавки плана (после k_plan) в главном потоке — ядра GDScript и C++ не
## меняются, совпадение бит в бит сохраняется.
##
## Игрок: армии (World.ArmyGroup.general) и группы армий (World.ArmyFront.marshal)
## назначает сам; дивизии вне армии — без бонуса. ИИ: виртуальные армии
## (Division.lead — генерал, Commander.boss — маршал) закреплены: новая дивизия
## идёт в армию с местом, иначе — новая армия под свободным или нанятым за ПВ
## генералом (ai_assign, _assign).

const ARMY_MAX := 24
const FRONT_MAX := 4
const ATK_K := 0.025       # атака +2,5 % за единицу навыка
const DEF_K := 0.025       # оборона +2,5 %
const PLAN_K := 0.10       # скорость планирования +10 %
const MAN_K := 0.02        # скорость движения +2 %
const MARSHAL_K := 0.5     # доля навыков маршала для всех дивизий группы
const COST_GEN := 10.0     # наём генерала, командный ресурс (КР, Politics)
const COST_MAR := 25.0     # наём маршала, КР
const XP_LEVEL := 30.0     # опыт на следующий уровень × уровень (день боя всей армии — 1)
const LEVEL_MAX := 5
const STAT_MAX := 7
const STAT_NAMES := ["атака", "оборона", "планирование", "манёвр"]
# Черты: [название, классы шаблонов (пусто — все), атака, оборона, план, скорость].
# Прибавки складываются с навыками; у маршала — × MARSHAL_K. Исторические —
# из commanders.json, остальные получают черту на уровнях TRAIT_LEVELS.
const TRAITS := {
	"panzer": ["Танкист", [Military.T_ARM, Military.T_MOT], 0.10, 0.0, 0.0, 0.05],
	"infantry": ["Пехотный командир", [Military.T_INF, Military.T_ART], 0.0, 0.08, 0.0, 0.0],
	"mountain": ["Горный стрелок", [Military.T_MNT], 0.10, 0.10, 0.0, 0.0],
	"cavalry": ["Кавалерист", [Military.T_CAV], 0.08, 0.0, 0.0, 0.06],
	"assault": ["Мастер штурма", [], 0.05, 0.0, 0.0, 0.0],
	"defender": ["Мастер обороны", [], 0.0, 0.06, 0.0, 0.0],
	"planner": ["Штабист", [], 0.0, 0.0, 0.25, 0.0],
	"swift": ["Стремительный", [], 0.0, 0.0, 0.0, 0.06],
}
const TRAIT_LEVELS := [3, 5]     # на этих уровнях — очко черты (берётся за КР)
const TRAIT_COST := 20.0         # взять черту, командный ресурс

## Способности командиров (как в жанре, значения свои): за КР на несколько дней,
## одна за раз, повтор той же — после перезарядки. Генерал — своей армии,
## маршал — всей группе армий. [название, КР, дней, перезарядка, атака, оборона, скорость, план]
const ABILITIES := {
	"fast_plan": ["Быстрое планирование", 15.0, 14, 30, 0.0, 0.0, 0.0, 1.0],
	"assault": ["Стремительная атака", 20.0, 10, 30, 0.10, -0.10, 0.05, 0.0],
	"desperate": ["Отчаянная защита", 20.0, 10, 30, -0.20, 0.20, 0.0, 0.0],
}
const ABILITY_ORDER := ["fast_plan", "assault", "desperate"]

## Опыт дивизий (0…1): растёт в боях, пополнение разбавляет его новобранцами.
## Уровни: [порог, название, атака и оборона].
const DIV_LEVELS := [[0.0, "Новобранцы", -0.25], [0.1, "Начинающие", 0.0], [0.3, "Опытные", 0.25],
	[0.5, "Профессионалы", 0.50], [0.75, "Ветераны", 0.75]]
const DIV_XP_NEW := 0.15         # новая дивизия после подготовки — «Начинающие»
const DIV_XP_DRILL := 0.002      # учения: вне боя опыт ниже DIV_XP_NEW подтягивается к нему за день
const DIV_XP_FRESH := 0.05       # опыт пополнения (новобранцы)
const DIV_XP_DAY := 0.006        # за день боя (× прибавка опыта: поддержка войны, советники)


# --- Стартовые командиры ------------------------------------------------------

static func init(world: World, dir: String) -> void:
	world.commanders = []
	world.lead_ver += 1
	var data := {}
	var path := dir + "/commanders.json"
	if FileAccess.file_exists(path):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(j) == TYPE_DICTIONARY:
			data = j
	var counts := PackedInt32Array()
	counts.resize(world.nation_count)
	for d in world.divisions:
		if d.alive:
			counts[d.owner] += 1
	for nat in world.nations:
		if not nat.alive:
			continue
		var lst: Array = data.get(world.nation_tags[nat.id], [])
		var gens := 0
		var mars := 0
		for e in lst:
			var c := _add(world, nat.id, str(e[0]), str(e[1]) == "m", int(e[2]), int(e[3]), int(e[4]), int(e[5]))
			for k in range(6, e.size()):   # дата появления и/или список черт
				if typeof(e[k]) == TYPE_ARRAY:
					for t in e[k]:
						if TRAITS.has(str(t)):
							c.traits.append(str(t))
				else:
					c.from_day = world.day_of(str(e[k]))
			if c.from_day <= world.day:
				if c.marshal:
					mars += 1
				else:
					gens += 1
		var need_g := ceili(counts[nat.id] / float(ARMY_MAX))
		while gens < need_g:
			_add_generic(world, nat.id, false)
			gens += 1
		var need_m := ceili(need_g / float(FRONT_MAX)) if need_g >= 2 else 0
		while mars < need_m:
			_add_generic(world, nat.id, true)
			mars += 1
	for nat in world.nations:
		if nat.alive and not nat.is_player:
			ai_assign(world, nat)


static func _add(world: World, owner: int, nm: String, marshal: bool, a: int, d: int, p: int, m: int) -> World.Commander:
	var c := World.Commander.new()
	c.id = world.commanders.size()
	c.owner = owner
	c.name = nm
	c.marshal = marshal
	c.atk = clampi(a, 1, STAT_MAX)
	c.def = clampi(d, 1, STAT_MAX)
	c.plan = clampi(p, 1, STAT_MAX)
	c.man = clampi(m, 1, STAT_MAX)
	c.level = clampi(1 + (c.atk + c.def + c.plan + c.man - 4) / 3, 1, LEVEL_MAX)
	c.from_day = world.day
	world.commanders.append(c)
	return c


## Безымянный командир: навыки по 1 и ещё два очка (детерминированно по номеру).
static func _add_generic(world: World, owner: int, marshal: bool) -> World.Commander:
	var n := 1
	for c in world.commanders:
		if c.owner == owner and c.marshal == marshal:
			n += 1
	var rng := Parallel.rng(world.seed_value, owner * 100 + n, 7100 + int(marshal))
	var st := [1, 1, 1, 1]
	for k in 2:
		st[rng.randi() % 4] += 1
	return _add(world, owner, "%s %d" % ["Маршал" if marshal else "Генерал", n], marshal, st[0], st[1], st[2], st[3])


# --- Запросы ------------------------------------------------------------------

static func available(world: World, c: World.Commander) -> bool:
	return c.alive and world.day >= c.from_day and world.nations[c.owner].alive


static func of_nation(world: World, owner: int, marshal: bool) -> Array:
	var res: Array = []
	for c in world.commanders:
		if c.owner == owner and c.marshal == marshal and available(world, c):
			res.append(c)
	return res


## Свободные (без армии или группы) — лучшие первыми.
static func free_of(world: World, owner: int, marshal: bool) -> Array:
	var res: Array = []
	for c in of_nation(world, owner, marshal):
		if c.army < 0:
			res.append(c)
	res.sort_custom(_better)
	return res


static func _better(a: World.Commander, b: World.Commander) -> bool:
	var sa := a.atk + a.def + a.plan + a.man
	var sb := b.atk + b.def + b.plan + b.man
	if sa != sb:
		return sa > sb
	return a.id < b.id


static func stats_text(c: World.Commander) -> String:
	var t := "ур. %d · ат %d · об %d · пл %d · ман %d" % [c.level, c.atk, c.def, c.plan, c.man]
	if not c.traits.is_empty():
		t += " · " + traits_text(c)
	return t


static func traits_text(c: World.Commander) -> String:
	var parts: Array = []
	for id in c.traits:
		parts.append(TRAITS[id][0])
	return ", ".join(parts)


## Что дают черты, коротко: «Танкист: танки и мотопехота атака +10 %, скорость +5 %».
static func trait_help(id: String) -> String:
	var t: Array = TRAITS[id]
	var who := "все"
	if not (t[1] as Array).is_empty():
		var nm: Array = []
		for c in t[1]:
			nm.append(["пехота", "горные", "кавалерия", "артиллерия", "мотопехота", "танки"][int(c)])
		who = " и ".join(nm)
	var fx: Array = []
	for k in 4:
		var v: float = t[2 + k]
		if v > 0.0:
			fx.append("%s +%d %%" % [["атака", "оборона", "план", "скорость"][k], roundi(v * 100.0)])
	return "%s (%s): %s" % [t[0], who, ", ".join(fx)]


## Бонус навыков в тексте: «атака +7,5 %, оборона +5 %…» (k — доля, у маршала MARSHAL_K).
static func bonus_text(c: World.Commander, k: float = 1.0) -> String:
	return "атака +%s %%, оборона +%s %%, план +%d %%, скорость +%s %%" % [
		_pct(ATK_K * c.atk * k), _pct(DEF_K * c.def * k), roundi(PLAN_K * c.plan * k * 100.0), _pct(MAN_K * c.man * k)]


static func _pct(v: float) -> String:
	var s := "%.1f" % (v * 100.0)
	if s.ends_with(".0"):
		s = s.substr(0, s.length() - 2)
	return s.replace(".", ",")


static func armies_of_front(world: World, f: World.ArmyFront) -> Array:
	var res: Array = []
	for g in world.groups:
		if g.alive and g.front == f.id:
			res.append(g)
	return res


# --- Назначения игрока --------------------------------------------------------

## Генерал армии (cid -1 — снять). Генерал другой армии уходит из неё.
static func set_general(world: World, g: World.ArmyGroup, cid: int) -> void:
	if g.general >= 0:
		world.commanders[g.general].army = -1
	g.general = -1
	if cid >= 0:
		var c: World.Commander = world.commanders[cid]
		if c.army >= 0 and c.army != g.id:
			world.groups[c.army].general = -1
		c.army = g.id
		g.general = cid
	world.lead_ver += 1


static func set_marshal(world: World, f: World.ArmyFront, cid: int) -> void:
	if f.marshal >= 0:
		world.commanders[f.marshal].army = -1
	f.marshal = -1
	if cid >= 0:
		var c: World.Commander = world.commanders[cid]
		if c.army >= 0 and c.army != f.id:
			world.fronts[c.army].marshal = -1
		c.army = f.id
		f.marshal = cid
	world.lead_ver += 1


## Лучший свободный генерал — новой армии (если есть).
static func auto_general(world: World, g: World.ArmyGroup) -> void:
	var free := free_of(world, g.owner, false)
	if not free.is_empty():
		set_general(world, g, free[0].id)


const FRONT_COLORS := [Color(0.95, 0.85, 0.55), Color(0.6, 0.85, 0.75), Color(0.85, 0.7, 0.9), Color(0.9, 0.65, 0.55)]


static func create_front(world: World, owner: int, armies: Array) -> World.ArmyFront:
	var f := World.ArmyFront.new()
	f.id = world.fronts.size()
	f.owner = owner
	var n := 1
	for o in world.fronts:
		if o.owner == owner:
			n += 1
	f.name = "Группа армий %d" % n
	f.color = FRONT_COLORS[(n - 1) % FRONT_COLORS.size()]
	world.fronts.append(f)
	for g in armies:
		if armies_of_front(world, f).size() >= FRONT_MAX:
			break
		g.front = f.id
	var free := free_of(world, owner, true)
	if not free.is_empty():
		set_marshal(world, f, free[0].id)
	world.lead_ver += 1
	return f


## Армия в группу (fid -1 — выйти). Пусто — сделано, иначе причина.
static func join_front(world: World, g: World.ArmyGroup, fid: int) -> String:
	if fid >= 0:
		var f: World.ArmyFront = world.fronts[fid]
		if g.front != fid and armies_of_front(world, f).size() >= FRONT_MAX:
			return "в группе уже %d армии" % FRONT_MAX
	g.front = fid
	world.lead_ver += 1
	return ""


static func disband_front(world: World, f: World.ArmyFront) -> void:
	for g in armies_of_front(world, f):
		g.front = -1
	set_marshal(world, f, -1)
	f.alive = false
	world.lead_ver += 1


## Общий приказ группы — всем её армиям.
static func front_order(world: World, f: World.ArmyFront, mode: String, enemy: int, objective: int) -> void:
	for g in armies_of_front(world, f):
		g.mode = mode
		g.enemy = enemy
		g.objective = objective


## Наём за командный ресурс. Пусто — нанят, иначе причина.
static func hire(world: World, nat: World.Nation, marshal: bool) -> String:
	var why := Politics.spend_cp(world, nat, COST_MAR if marshal else COST_GEN)
	if why != "":
		return why
	var c := _add_generic(world, nat.id, marshal)
	if nat.is_player:
		world.log_event("Назначен новый командир: %s (%s)" % [c.name, stats_text(c)])
	return ""


# --- ИИ -----------------------------------------------------------------------

## ИИ (решение пользователя): дивизия закреплена за своим генералом, его не
## переназначают. Новая дивизия (и раз в месяц — оставшиеся без генерала) идёт в
## армию с местом (сперва самую полную); места нет — новая армия под свободным
## генералом, иначе нанятым за ПВ. Генерал новой армии так же закрепляется за
## маршалом, у которого меньше FRONT_MAX армий (или за свободным/нанятым).
static func ai_assign(world: World, nat: World.Nation) -> void:
	refresh(world)
	_assign(world, nat, [])


static func _assign(world: World, nat: World.Nation, only: Array) -> void:
	var cmd: Array = world.commanders
	var cnt := {}       # генерал -> дивизий
	var todo: Array = []
	var rear: Array = []
	var owner := world.d_owner
	var alive := world.d_alive
	var divs: Array = world.divisions
	for i in mini(alive.size(), divs.size()):
		if alive[i] == 0 or owner[i] != nat.id:
			continue
		var d: World.Division = divs[i]
		var g := d._lead
		if g >= 0 and (g >= cmd.size() or cmd[g].owner != nat.id or not available(world, cmd[g])):
			g = -1
		if g >= 0:
			cnt[g] = int(cnt.get(g, 0)) + 1
		elif only.is_empty():
			if d.plan > 0.0 or d.in_battle:
				todo.append(d)
			else:
				rear.append(d)
	todo.append_array(rear)
	if not only.is_empty():
		todo = only
	if todo.is_empty():
		return
	var subs := {}      # маршал -> армий (генералов с дивизиями)
	for g in cnt:
		var b: int = cmd[g].boss
		if b >= 0:
			subs[b] = int(subs.get(b, 0)) + 1
	var player := _players(world)
	var mults := {}
	for d in todo:
		var best := -1
		for g in cnt:
			var k: int = cnt[g]
			if k < ARMY_MAX and (best < 0 or k > int(cnt[best]) or (k == int(cnt[best]) and g < best)):
				best = g
		if best < 0:
			best = _new_general(world, nat, cnt)
			if best < 0:
				d._lead = -1
				continue   # некого поставить — до найма
			cnt[best] = 0
			_attach(world, nat, cmd[best], cnt, subs)
		cnt[best] = int(cnt[best]) + 1
		d._lead = best   # без lead_ver: бонусы — точечно
		_entry(world, d.slot, d, player, mults)


## Свободный генерал (без дивизий) или нанятый; -1 — нет.
static func _new_general(world: World, nat: World.Nation, cnt: Dictionary) -> int:
	var free: Array = []
	for c in of_nation(world, nat.id, false):
		if not cnt.has(c.id):
			free.append(c)
	if free.is_empty() and Politics.can_pay_cp(world, nat, COST_GEN + 20.0) == "" and hire(world, nat, false) == "":
		free.append(world.commanders[world.commanders.size() - 1])
	if free.is_empty():
		return -1
	free.sort_custom(_better)
	return free[0].id


## Генерал новой армии — под маршала с местом (самого занятого), свободного или нанятого.
static func _attach(world: World, nat: World.Nation, c: World.Commander, cnt: Dictionary, subs: Dictionary) -> void:
	if c.boss >= 0 and int(subs.get(c.boss, 0)) < FRONT_MAX and available(world, world.commanders[c.boss]):
		subs[c.boss] = int(subs.get(c.boss, 0)) + 1
		return
	c.boss = -1
	var best := -1
	for m in subs:
		var k: int = subs[m]
		if k < FRONT_MAX and (best < 0 or k > int(subs[best]) or (k == int(subs[best]) and m < best)):
			best = m
	if best < 0:
		var free: Array = []
		for m in of_nation(world, nat.id, true):
			if not subs.has(m.id):
				free.append(m)
		if free.is_empty() and cnt.size() >= 2 and Politics.can_pay_cp(world, nat, COST_MAR + 20.0) == "" and hire(world, nat, true) == "":
			free.append(world.commanders[world.commanders.size() - 1])
		if free.is_empty():
			return
		free.sort_custom(_better)
		best = free[0].id
	c.boss = best
	subs[best] = int(subs.get(best, 0)) + 1


# --- День ---------------------------------------------------------------------

## Бонусы по слотам (плотные массивы World.ld_*, уплотняются вместе с d_*):
## полный пересчёт при смене назначений игрока или навыков (lead_ver), новые
## дивизии — дозапись без бонуса, ИИ — точечно по своей стране (ai_assign).
static func refresh(world: World) -> void:
	var n := world.d_id.size()
	var cur := world.ld_ver == world.lead_ver
	if cur and world.ld_gen.size() == n:
		return
	var from := world.ld_gen.size() if cur and world.ld_gen.size() < n else 0
	for arr in ["ld_gen", "ld_mar"]:
		var a: PackedInt32Array = world.get(arr)
		a.resize(n)
		for i in range(from, n):
			a[i] = -1
		world.set(arr, a)
	for arr in ["ld_atk", "ld_def", "ld_spd", "ld_plan"]:
		var a: PackedFloat64Array = world.get(arr)
		a.resize(n)
		for i in range(from, n):
			a[i] = 1.0
		world.set(arr, a)
	world.ld_ver = world.lead_ver
	if from > 0:
		# новые дивизии ИИ — сразу в армию с местом или в новую армию
		var by := {}
		var own := world.d_owner
		var al := world.d_alive
		var dv: Array = world.divisions
		for i in range(from, mini(n, dv.size())):
			if al[i] == 1 and not world.nations[own[i]].is_player:
				if not by.has(own[i]):
					by[own[i]] = []
				by[own[i]].append(dv[i])
		var keys := by.keys()
		keys.sort()
		for o in keys:
			_assign(world, world.nations[o], by[o])
		return
	var player := _players(world)
	var mults := {}
	var divs: Array = world.divisions
	var alive := world.d_alive
	for i in mini(n, divs.size()):
		if alive[i] == 1:
			_entry(world, i, divs[i], player, mults)


## Род войск дивизии сменился (переучивание) — пересчитать её множители.
static func touch(world: World, d: World.Division) -> void:
	if world.ld_ver != world.lead_ver or d.slot >= world.ld_gen.size():
		return
	_entry(world, d.slot, d, _players(world), {})


static func _players(world: World) -> PackedByteArray:
	var player := PackedByteArray()
	player.resize(world.nation_count)
	for nat in world.nations:
		player[nat.id] = 1 if nat.is_player else 0
	return player


## Генерал и маршал дивизии в слоте i и их множители — в World.ld_*.
static func _entry(world: World, i: int, d: World.Division, player: PackedByteArray, mults: Dictionary) -> void:
	var cmd: Array = world.commanders
	var o := world.d_owner[i]
	var g := -1
	var m := -1
	var grp := d._group
	if grp >= 0:
		var a: World.ArmyGroup = world.groups[grp]
		if a.alive:
			g = a.general
			if a.front >= 0 and world.fronts[a.front].alive:
				m = world.fronts[a.front].marshal
	elif d._lead >= 0 and d._lead < cmd.size() and player[o] == 0:
		g = d._lead
		m = cmd[g].boss
	var cls := 0
	var tp := world.d_tpl[i]
	if tp >= 0 and tp < world.tpl_cls.size():
		cls = world.tpl_cls[tp]
	var key := ((g + 1) * 65536 + m + 1) * 8 + cls
	var mv: Variant = mults.get(key)
	if mv == null:
		var gg := g
		var mm_ := m
		if gg >= 0 and (cmd[gg].owner != o or not available(world, cmd[gg])):
			gg = -1
		if mm_ >= 0 and (cmd[mm_].owner != o or not available(world, cmd[mm_])):
			mm_ = -1
		mv = _mults(cmd, gg, mm_, cls)
		mults[key] = mv
	var mm: Array = mv
	world.ld_gen[i] = mm[4]
	world.ld_mar[i] = mm[5]
	world.ld_atk[i] = mm[0]
	world.ld_def[i] = mm[1]
	world.ld_spd[i] = mm[2]
	world.ld_plan[i] = mm[3]


static func _mults(cmd: Array, g: int, m: int, cls: int = 0) -> Array:
	var r := [1.0, 1.0, 1.0, 1.0]
	if g >= 0:
		_apply(r, cmd[g], cls, 1.0)
	if m >= 0:
		_apply(r, cmd[m], cls, MARSHAL_K)
	return [r[0], r[1], r[2], r[3], g, m]


## Множители командира c (доля k) для класса шаблона cls: [атака, оборона, скорость, план].
static func _apply(r: Array, c: World.Commander, cls: int, k: float) -> void:
	var a := ATK_K * c.atk
	var d := DEF_K * c.def
	var s := MAN_K * c.man
	var p := PLAN_K * c.plan
	for id in c.traits:
		var t: Array = TRAITS[id]
		var only: Array = t[1]
		if only.is_empty() or only.has(cls):
			a += float(t[2])
			d += float(t[3])
			p += float(t[4])
			s += float(t[5])
	r[0] *= 1.0 + a * k
	r[1] *= 1.0 + d * k
	r[2] *= 1.0 + s * k
	r[3] *= 1.0 + p * k


## После Climate.daily: множители на действующие атаку, оборону, скорость
## (командиры, их способности, опыт дивизий); опыт за бои командирам и дивизиям.
static func daily(world: World) -> void:
	refresh(world)
	var ae := world.d_atk_eff
	var de := world.d_def_eff
	var se := world.d_spd_eff
	var n := ae.size()
	if de.size() != n or se.size() != n or world.ld_gen.size() < n:
		return
	_fit_xp(world)
	var gen := world.ld_gen
	var mar := world.ld_mar
	var la := world.ld_atk
	var ldf := world.ld_def
	var ls := world.ld_spd
	var bt := world.d_battle
	var alive := world.d_alive
	var own := world.d_owner
	var dx := world.d_xp
	var act := active_mults(world)
	# прибавка опыта дивизий по странам: поддержка войны и советники
	var gain := PackedFloat64Array()
	gain.resize(world.nation_count)
	for nat in world.nations:
		gain[nat.id] = DIV_XP_DAY * maxf(0.0, 1.0 + nat.b("xp_div"))
	var xp := {}
	for s in n:
		if alive[s] == 0:
			continue
		var x := dx[s]
		var lv := div_bonus(x)
		if bt[s] != 0:
			dx[s] = minf(1.0, x + gain[own[s]])
		elif x < DIV_XP_NEW:
			dx[s] = minf(DIV_XP_NEW, x + DIV_XP_DRILL)
		var g := gen[s]
		var m := mar[s]
		var ka := 1.0 + lv
		var kd := 1.0 + lv
		var ks := 1.0
		if g >= 0 or m >= 0:
			ka *= la[s]
			kd *= ldf[s]
			ks *= ls[s]
			if not act.is_empty():
				var ag: Variant = act.get(g) if g >= 0 else null
				var am: Variant = act.get(m) if m >= 0 else null
				if am != null and ag != null and cmd_ability(world, g) == cmd_ability(world, m):
					am = null   # одна и та же способность генерала и маршала — один раз
				for v in [ag, am]:
					if v != null:
						ka *= 1.0 + float(v[0])
						kd *= 1.0 + float(v[1])
						ks *= 1.0 + float(v[2])
			if bt[s] != 0:
				if g >= 0:
					xp[g] = float(xp.get(g, 0.0)) + 1.0 / ARMY_MAX
				if m >= 0:
					xp[m] = float(xp.get(m, 0.0)) + 1.0 / (ARMY_MAX * FRONT_MAX)
		if ka != 1.0:
			ae[s] *= ka
		if kd != 1.0:
			de[s] *= kd
		if ks != 1.0:
			se[s] *= ks
	world.d_atk_eff = ae
	world.d_def_eff = de
	world.d_spd_eff = se
	world.d_xp = dx
	var ids := xp.keys()
	ids.sort()
	for cid in ids:
		_gain(world, world.commanders[cid], minf(1.0, xp[cid]))
	if world.day % AI_ABILITY_DAYS == 0:
		ai_abilities(world)


## Массив опыта по числу дивизий (сохранения без него — всем «Начинающие»).
static func _fit_xp(world: World) -> void:
	var n := world.d_id.size()
	if world.d_xp.size() == n:
		return
	var dx := world.d_xp
	var from := dx.size()
	dx.resize(n)
	for i in range(from, n):
		dx[i] = DIV_XP_NEW
	world.d_xp = dx


## Прибавка к атаке и обороне от опыта дивизии.
static func div_bonus(x: float) -> float:
	if x >= 0.5:
		return 0.75 if x >= 0.75 else 0.50
	if x >= 0.1:
		return 0.25 if x >= 0.3 else 0.0
	return -0.25


static func div_level(x: float) -> String:
	var r := ""
	for lv in DIV_LEVELS:
		if x >= float(lv[0]):
			r = lv[1]
	return r


## Пополнение разбавляет опыт: средний по людям, новые — DIV_XP_FRESH.
static func dilute(world: World, old_str: PackedFloat64Array) -> void:
	_fit_xp(world)
	var st := world.d_str
	var dx := world.d_xp
	var n := mini(mini(st.size(), old_str.size()), dx.size())
	for i in n:
		var o := old_str[i]
		var nw := st[i]
		if nw > o and nw > 0.0:
			dx[i] = (dx[i] * o + DIV_XP_FRESH * (nw - o)) / nw
	world.d_xp = dx


# --- Способности командиров ------------------------------------------------------

const AI_ABILITY_DAYS := 5


static func cmd_ability(world: World, cid: int) -> String:
	var c: World.Commander = world.commanders[cid]
	return c.ability if c.ability_until >= world.day else ""


## Действующие способности: id командира -> [атака, оборона, скорость, план].
static func active_mults(world: World) -> Dictionary:
	var r := {}
	for c in world.commanders:
		if c.alive and c.ability != "" and c.ability_until >= world.day:
			var a: Array = ABILITIES[c.ability]
			r[c.id] = [a[4], a[5], a[6], a[7]]
	return r


static func ability_block(world: World, c: World.Commander, id: String) -> String:
	if not ABILITIES.has(id):
		return "нет такой способности"
	if c.ability != "" and c.ability_until >= world.day:
		return "уже действует «%s» (ещё %d дн.)" % [ABILITIES[c.ability][0], c.ability_until - world.day + 1]
	var ready := int(c.ability_cd.get(id, -1))
	if world.day < ready:
		return "снова через %d дн." % (ready - world.day)
	var cost: float = ABILITIES[id][1]
	var nat: World.Nation = world.nations[c.owner]
	if nat.command_power < cost:
		return "нужно %d КР (есть %d)" % [int(cost), int(nat.command_power)]
	return ""


## Применить способность (платят все, и ИИ: иначе исторический ИИ держал бы их всегда).
static func use_ability(world: World, c: World.Commander, id: String) -> String:
	var why := ability_block(world, c, id)
	if why != "":
		return why
	var a: Array = ABILITIES[id]
	world.nations[c.owner].command_power -= float(a[1])
	c.ability = id
	c.ability_until = world.day + int(a[2]) - 1
	c.ability_cd[id] = world.day + int(a[3])
	if world.nations[c.owner].is_player:
		world.log_event("%s: «%s» на %d дн." % [c.name, a[0], int(a[2])])
	return ""


static func ability_text(id: String) -> String:
	var a: Array = ABILITIES[id]
	var fx: Array = []
	for k in 4:
		var v: float = a[4 + k]
		if v != 0.0:
			fx.append("%s %+d %%" % [["атака", "оборона", "скорость", "планирование"][k], roundi(v * 100.0)])
	return "%s: %s на %d дн., %d КР, повтор через %d дн." % [a[0], ", ".join(fx), int(a[2]), int(a[1]), int(a[3])]


## ИИ: раз в AI_ABILITY_DAYS дней — по положению дивизий командира: много
## наступающих в бою — «Стремительная атака», много обороняющихся — «Отчаянная
## защита», войска стоят на войне без боёв и с малым планом — «Быстрое планирование».
static func ai_abilities(world: World) -> void:
	var gen := world.ld_gen
	var mar := world.ld_mar
	var bt := world.d_battle
	var nx := world.d_next
	var al := world.d_alive
	var pl := world.d_plan
	var n := mini(mini(gen.size(), bt.size()), al.size())
	var cnt := {}   # командир -> [наступают в бою, обороняются в бою, ждут без плана]
	for s in n:
		if al[s] == 0:
			continue
		for c in [gen[s], mar[s]]:
			if c < 0:
				continue
			if not cnt.has(c):
				cnt[c] = [0, 0, 0]
			var e: Array = cnt[c]
			if bt[s] != 0:
				e[0 if nx[s] >= 0 else 1] += 1
			elif nx[s] < 0 and pl[s] < 0.5:
				e[2] += 1
	var ids := cnt.keys()
	ids.sort()
	for cid in ids:
		var c: World.Commander = world.commanders[cid]
		var nat: World.Nation = world.nations[c.owner]
		if nat.is_player or not c.alive or nat.at_war.is_empty():
			continue
		var e: Array = cnt[cid]
		var k := 2 if c.marshal else 1   # маршалу — порог выше (вся группа)
		var want := ""
		if e[0] >= 4 * k and e[0] >= e[1]:
			want = "assault"
		elif e[1] >= 4 * k and e[1] > e[0]:
			want = "desperate"
		elif e[2] >= 8 * k and e[0] + e[1] < 3:
			want = "fast_plan"
		if want != "" and nat.command_power >= float(ABILITIES[want][1]) + 10.0:
			use_ability(world, c, want)


# --- Черты за командный ресурс -------------------------------------------------

static func trait_block(world: World, c: World.Commander, id: String) -> String:
	if not TRAITS.has(id):
		return "нет такой черты"
	if c.traits.has(id):
		return "уже есть"
	if c.trait_points <= 0:
		return "нет очка черты (даётся на %s уровне)" % " и ".join(TRAIT_LEVELS.map(func(l): return "%d-м" % l))
	var nat: World.Nation = world.nations[c.owner]
	if nat.command_power < TRAIT_COST:
		return "нужно %d КР (есть %d)" % [int(TRAIT_COST), int(nat.command_power)]
	return ""


static func take_trait(world: World, c: World.Commander, id: String) -> String:
	var why := trait_block(world, c, id)
	if why != "":
		return why
	world.nations[c.owner].command_power -= TRAIT_COST
	c.trait_points -= 1
	c.traits.append(id)
	_retouch(world, c)
	if world.nations[c.owner].is_player:
		world.log_event("%s: черта «%s»" % [c.name, TRAITS[id][0]])
	return ""


## ИИ: очки черт — в случайную черту, когда хватает КР (раз в месяц, Politics).
static func ai_traits(world: World, nat: World.Nation) -> void:
	for c in world.commanders:
		if c.owner != nat.id or not c.alive or c.trait_points <= 0:
			continue
		var free: Array = []
		for id in TRAITS:
			if not c.traits.has(id):
				free.append(id)
		if free.is_empty() or nat.command_power < TRAIT_COST + 10.0:
			continue
		var rng := Parallel.rng(world.seed_value, world.day, 7300 + c.id)
		take_trait(world, c, free[rng.randi() % free.size()])


## Навыки или черты командира изменились — пересчитать кэш его дивизий.
static func _retouch(world: World, c: World.Commander) -> void:
	refresh(world)
	var player := _players(world)
	var mults := {}
	var gen := world.ld_gen
	var mar := world.ld_mar
	var divs: Array = world.divisions
	for s in mini(gen.size(), divs.size()):
		if (gen[s] == c.id or mar[s] == c.id) and world.d_alive[s] == 1:
			_entry(world, s, divs[s], player, mults)


static func _gain(world: World, c: World.Commander, v: float) -> void:
	if c.level >= LEVEL_MAX:
		return
	# прибавка опыта: поддержка войны и военные советники (Politics)
	c.xp += v * maxf(0.0, 1.0 + world.nations[c.owner].b("xp_lead"))
	var need := XP_LEVEL * c.level
	if c.xp < need:
		return
	c.xp -= need
	c.level += 1
	var opts: Array = []
	for k in 4:
		if [c.atk, c.def, c.plan, c.man][k] < STAT_MAX:
			opts.append(k)
	if not opts.is_empty():
		var rng := Parallel.rng(world.seed_value, world.day, 7200 + c.id)
		match int(opts[rng.randi() % opts.size()]):
			0: c.atk += 1
			1: c.def += 1
			2: c.plan += 1
			3: c.man += 1
	if TRAIT_LEVELS.has(c.level) and c.traits.size() + c.trait_points < TRAITS.size():
		c.trait_points += 1   # черту выбирают за командный ресурс (take_trait / ai_traits)
	# новые навыки — только дивизиям этого командира
	_retouch(world, c)
	if world.nations[c.owner].is_player:
		world.log_event("%s: уровень %d (%s)%s" % [c.name, c.level, stats_text(c),
			" — можно взять черту за %d КР" % int(TRAIT_COST) if c.trait_points > 0 else ""])


## После k_plan: прибавку плана за день — × бонус планирования командиров.
static func plan_bonus(world: World, old: PackedFloat64Array) -> void:
	var pl := world.d_plan
	var lp := world.ld_plan
	var own := world.d_owner
	# скорость планирования страны: поддержка войны и советники (Politics)
	var nk := PackedFloat64Array()
	nk.resize(world.nation_count)
	for nat in world.nations:
		nk[nat.id] = maxf(0.0, 1.0 + nat.b("plan_speed"))
	var act := active_mults(world)
	var gen := world.ld_gen
	var mar := world.ld_mar
	var n := mini(mini(mini(pl.size(), old.size()), lp.size()), own.size())
	for s in n:
		if pl[s] > old[s]:
			var k := nk[own[s]] * (lp[s] if lp[s] > 1.0 else 1.0)
			if not act.is_empty():
				# «Быстрое планирование» генерала или маршала (один раз, если у обоих)
				var a := 0.0
				for c in [gen[s], mar[s]]:
					if c >= 0 and act.has(c):
						a = maxf(a, float(act[c][3]))
				k *= 1.0 + a
			if k != 1.0:
				pl[s] = minf(1.0, old[s] + (pl[s] - old[s]) * k)
	world.d_plan = pl
