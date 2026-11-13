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
const COST_GEN := 25.0     # наём генерала, ПВ
const COST_MAR := 50.0     # наём маршала
const XP_LEVEL := 30.0     # опыт на следующий уровень × уровень (день боя всей армии — 1)
const LEVEL_MAX := 5
const STAT_MAX := 7
const STAT_NAMES := ["атака", "оборона", "планирование", "манёвр"]


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
			if e.size() > 6:
				c.from_day = world.day_of(str(e[6]))
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
	return "ур. %d · ат %d · об %d · пл %d · ман %d" % [c.level, c.atk, c.def, c.plan, c.man]


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


## Наём за ПВ. Пусто — нанят, иначе причина.
static func hire(world: World, nat: World.Nation, marshal: bool) -> String:
	var why := Politics.spend(world, nat, COST_MAR if marshal else COST_GEN)
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
	if free.is_empty() and Politics.can_pay(world, nat, COST_GEN + 50.0) == "" and hire(world, nat, false) == "":
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
		if free.is_empty() and cnt.size() >= 2 and Politics.can_pay(world, nat, COST_MAR + 50.0) == "" and hire(world, nat, true) == "":
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
	var key := (g + 1) * 65536 + m + 1
	var mv: Variant = mults.get(key)
	if mv == null:
		var gg := g
		var mm_ := m
		if gg >= 0 and (cmd[gg].owner != o or not available(world, cmd[gg])):
			gg = -1
		if mm_ >= 0 and (cmd[mm_].owner != o or not available(world, cmd[mm_])):
			mm_ = -1
		mv = _mults(cmd, gg, mm_)
		mults[key] = mv
	var mm: Array = mv
	world.ld_gen[i] = mm[4]
	world.ld_mar[i] = mm[5]
	world.ld_atk[i] = mm[0]
	world.ld_def[i] = mm[1]
	world.ld_spd[i] = mm[2]
	world.ld_plan[i] = mm[3]


static func _mults(cmd: Array, g: int, m: int) -> Array:
	var a_ := 1.0
	var d_ := 1.0
	var s_ := 1.0
	var p_ := 1.0
	if g >= 0:
		var c: World.Commander = cmd[g]
		a_ *= 1.0 + ATK_K * c.atk
		d_ *= 1.0 + DEF_K * c.def
		s_ *= 1.0 + MAN_K * c.man
		p_ *= 1.0 + PLAN_K * c.plan
	if m >= 0:
		var c: World.Commander = cmd[m]
		a_ *= 1.0 + ATK_K * c.atk * MARSHAL_K
		d_ *= 1.0 + DEF_K * c.def * MARSHAL_K
		s_ *= 1.0 + MAN_K * c.man * MARSHAL_K
		p_ *= 1.0 + PLAN_K * c.plan * MARSHAL_K
	return [a_, d_, s_, p_, g, m]


## После Climate.daily: множители на действующие атаку, оборону, скорость; опыт за бои.
static func daily(world: World) -> void:
	refresh(world)
	var ae := world.d_atk_eff
	var de := world.d_def_eff
	var se := world.d_spd_eff
	var n := ae.size()
	if de.size() != n or se.size() != n or world.ld_gen.size() < n:
		return
	var gen := world.ld_gen
	var mar := world.ld_mar
	var la := world.ld_atk
	var ldf := world.ld_def
	var ls := world.ld_spd
	var bt := world.d_battle
	var alive := world.d_alive
	var xp := {}
	for s in n:
		var g := gen[s]
		var m := mar[s]
		if (g < 0 and m < 0) or alive[s] == 0:
			continue
		ae[s] *= la[s]
		de[s] *= ldf[s]
		se[s] *= ls[s]
		if bt[s] != 0:
			if g >= 0:
				xp[g] = float(xp.get(g, 0.0)) + 1.0 / ARMY_MAX
			if m >= 0:
				xp[m] = float(xp.get(m, 0.0)) + 1.0 / (ARMY_MAX * FRONT_MAX)
	world.d_atk_eff = ae
	world.d_def_eff = de
	world.d_spd_eff = se
	var ids := xp.keys()
	ids.sort()
	for cid in ids:
		_gain(world, world.commanders[cid], minf(1.0, xp[cid]))


static func _gain(world: World, c: World.Commander, v: float) -> void:
	if c.level >= LEVEL_MAX:
		return
	c.xp += v
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
	# новые навыки — только дивизиям этого командира
	refresh(world)
	var player := _players(world)
	var mults := {}
	var gen := world.ld_gen
	var mar := world.ld_mar
	var divs: Array = world.divisions
	for s in mini(gen.size(), divs.size()):
		if (gen[s] == c.id or mar[s] == c.id) and world.d_alive[s] == 1:
			_entry(world, s, divs[s], player, mults)
	if world.nations[c.owner].is_player:
		world.log_event("%s: уровень %d (%s)" % [c.name, c.level, stats_text(c)])


## После k_plan: прибавку плана за день — × бонус планирования командиров.
static func plan_bonus(world: World, old: PackedFloat64Array) -> void:
	var pl := world.d_plan
	var lp := world.ld_plan
	var n := mini(mini(pl.size(), old.size()), lp.size())
	for s in n:
		if lp[s] > 1.0 and pl[s] > old[s]:
			pl[s] = minf(1.0, pl[s] + (pl[s] - old[s]) * (lp[s] - 1.0))
	world.d_plan = pl
