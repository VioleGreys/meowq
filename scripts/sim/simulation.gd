class_name Simulation
extends RefCounted
## Дневной тик. Каждая тяжёлая фаза устроена как «параллельно посчитать ->
## последовательно применить», поэтому результат детерминирован и не зависит
## от числа ядер, а сама работа распределяется по WorkerThreadPool.

const FACTORY_COST := 60.0
const BUILD_RATE := 0.05      # очков стройки в день на гражданскую фабрику
const MAX_FACTORIES := 12
const AI_PERIOD := 3

var world: World
var last_tick_usec := 0
var phase_usec := {}


func _init(w: World) -> void:
	world = w
	refresh_income()
	# процедурный мир и прочие сценарии без линий: доктринные линии и базовый склад
	for nat in world.nations:
		if nat.lines.is_empty() and nat.mil > 0:
			Military.assign_free_factories(nat, Military.default_split(nat))
			if nat.stock[0] == 0.0:
				nat.stock = PackedFloat32Array([300.0, 40.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	if world.ally.size() != world.nation_count * world.nation_count:
		_refresh_sides()
	if world.p_region.size() != world.prov_count:
		Forces._build_regions(world)


## Пересчитать доход всех стран без начисления (для интерфейса до первого тика).
func refresh_income() -> void:
	world.refresh_stats()
	var all := world.compute_all_income()
	for nat in world.nations:
		var r: Array = all[nat.id]
		nat.civ = r[0]
		nat.mil = r[1]
		nat.province_count = r[3]
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))
		nat.daily_research = (1.0 + nat.civ * 0.05) * (1.0 + nat.b("research"))


func tick() -> void:
	if world.game_over != "" or not world.pending_peace.is_empty() or not world.pending_events.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	world.day += 1
	world.rebuild_prov_divs()
	world.refresh_stats()
	# характеристики дивизий меняются только с новыми технологиями
	for d in world.divisions:
		if world.nations[d.owner].stats_dirty:
			Military.refresh_division(world, d)
	for nat in world.nations:
		nat.stats_dirty = false
	_refresh_sides()
	_timed("экономика", _phase_economy)
	_timed("флот", _phase_navy)
	_timed("снабжение", _phase_supply)
	_timed("ИИ", _phase_ai)
	_timed("авиация", Forces.daily_air.bind(world, Parallel.rng(world.seed_value, world.day, 6001)))
	var battles := _collect_battles()
	_timed("движение", _phase_movement.bind(battles))
	_timed("бои", _phase_combat.bind(battles))
	_phase_recovery()
	_phase_diplomacy()
	_check_capitulation()
	last_tick_usec = Time.get_ticks_usec() - t0


func _timed(label: String, fn: Callable) -> void:
	var t := Time.get_ticks_usec()
	fn.call()
	phase_usec[label] = Time.get_ticks_usec() - t


# --- Экономика: доход каждой страны считается в отдельной задаче ------------

func _phase_economy() -> void:
	var n_count := world.nations.size()
	# один проход по всем провинциям дешевле, чем по проходу на каждую страну
	var results := world.compute_all_income()

	for i in n_count:
		var nat: World.Nation = world.nations[i]
		if not nat.alive:
			continue
		var r: Array = results[i]
		nat.civ = r[0]
		nat.mil = r[1]
		nat.province_count = r[3]
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))
		nat.daily_research = (1.0 + nat.civ * 0.05) * (1.0 + nat.b("research"))
		nat.manpower += nat.daily_manpower
		# производство снаряжения: свободные заводы ИИ сам раскладывает по линиям
		Military.trim_lines(nat)
		if not nat.is_player:
			Military.assign_free_factories(nat, Military.default_split(nat))
		Military.produce(nat)

		# наука
		if nat.current_research != "":
			nat.research_points += nat.daily_research
			var tech := Tech.get_tech(nat.current_research)
			if not tech.is_empty() and nat.research_points >= tech["cost"]:
				Tech.complete(nat, nat.current_research)
				if nat.is_player:
					world.log_event("Исследовано: %s" % tech["name"])
				nat.current_research = ""
				nat.research_points = 0.0

		# строительство фабрик
		nat.build_progress += nat.civ * BUILD_RATE * (1.0 + nat.b("construction"))
		if nat.build_progress >= FACTORY_COST:
			if _place_factory(i, nat.build_mode):
				nat.build_progress -= FACTORY_COST
			else:
				nat.build_progress = FACTORY_COST

		# подготовка дивизий
		var still: Array = []
		for entry in nat.training:
			if int(entry[0]) <= 1:
				var spawn := nat.capital if world.p_controller[nat.capital] == i else _any_province(i)
				if spawn >= 0:
					world.spawn_division(i, spawn, int(entry[1]))
					if nat.is_player:
						world.log_event("Готова дивизия (%s): %s" % [Military.tpl(int(entry[1]))["name"].to_lower(), world.p_name[spawn]])
			else:
				still.append([int(entry[0]) - 1, int(entry[1])])
		nat.training = still


func _place_factory(nid: int, mode: String) -> bool:
	var best := -1
	var best_score := INF
	for p in world.prov_count:
		if world.p_owner[p] != nid or world.p_controller[p] != nid:
			continue
		var total := world.p_civ[p] + world.p_mil[p]
		if total >= factory_slots(world, p):
			continue
		var score := float(total) - (2.0 if world.p_terrain[p] == World.T_URBAN else 0.0) + float(p % 7) * 0.01
		if score < best_score:
			best_score = score
			best = p
	if best < 0:
		return false
	if mode == "civ":
		world.p_civ[best] += 1
	else:
		world.p_mil[best] += 1
	return true


## Сколько заводов помещается в провинции: зависит от населения (рабочие руки).
static func factory_slots(world: World, p: int) -> int:
	var pop := world.p_population[p] if world.p_population.size() > p else 0
	if pop <= 0:
		return MAX_FACTORIES
	return clampi(1 + pop / 250, 1, MAX_FACTORIES)


func _any_province(nid: int) -> int:
	for p in world.prov_count:
		if world.p_controller[p] == nid and world.p_owner[p] == nid:
			return p
	for p in world.prov_count:
		if world.p_controller[p] == nid:
			return p
	return -1


func train_division(nid: int, tpl: int = Military.T_INF) -> bool:
	return Military.start_training(world.nations[nid], tpl)


## Матрица «одна сторона» для параллельных фаз (фракции и сюзерены меняются редко,
## но пересчёт дешёвый: nation_count^2).
func _refresh_sides() -> void:
	var nc := world.nation_count
	# ключ стороны: фракция сюзерена или сам сюзерен (см. Diplomacy.same_side)
	var key := PackedInt32Array()
	key.resize(nc)
	for a in nc:
		var r := Diplomacy.root(world, a)
		var f: int = world.nations[r].faction
		key[a] = f if f >= 0 else 10000 + r
	var ally := PackedByteArray()
	ally.resize(nc * nc)
	for a in nc:
		for b in nc:
			ally[a * nc + b] = 1 if key[a] == key[b] else 0
	world.ally = ally


# --- Снабжение: сеть каждой стороны считается в отдельной задаче -----------

## Узлы снабжения: столица и порты (прибрежные города). Сеть стороны — все
## провинции под её контролем; расстояние в переходах от ближайшего узла.
## Вне сети — окружение: дивизия не пополняется и теряет силы.
func _phase_supply() -> void:
	var nc := world.nation_count
	# стороны: представитель — наименьший номер союзной страны
	var rep := PackedInt32Array()
	rep.resize(nc)
	var reps: Array = []
	for a in nc:
		rep[a] = a
		for b in a:
			if world.ally[a * nc + b] == 1:
				rep[a] = rep[b]
				break
		if rep[a] == a and world.nations[a].alive:
			reps.append(a)
	var hubs: Array = []
	hubs.resize(reps.size())
	var rep_index := {}
	for i in reps.size():
		hubs[i] = PackedInt32Array()
		rep_index[reps[i]] = i
	var ctl := world.p_controller
	var coastal := world.p_coastal
	var vp := world.p_vp
	for nat in world.nations:
		if nat.alive and ctl[nat.capital] == nat.id and rep_index.has(rep[nat.id]):
			hubs[rep_index[rep[nat.id]]].append(nat.capital)
	for p in world.prov_count:
		var c := ctl[p]
		if c >= 0 and coastal[p] == 1 and vp[p] >= 3 and rep_index.has(rep[c]) and not Forces.port_blockaded(world, c, p):
			hubs[rep_index[rep[c]]].append(p)
	# плацдармы высадок временно работают как порты
	for p in world.beachheads.keys():
		if world.beachheads[p] < world.day:
			world.beachheads.erase(p)
			continue
		var c := ctl[p]
		if c >= 0 and rep_index.has(rep[c]):
			hubs[rep_index[rep[c]]].append(p)
	var results: Array = []
	results.resize(reps.size())
	var task := func(i: int) -> void:
		var r: int = reps[i]
		var ctrl := world.p_controller
		var land := world.p_land
		var ally := world.ally
		var a_start := world.adj_start
		var a_list := world.adj_list
		var dist := PackedInt32Array()
		dist.resize(world.prov_count)
		dist.fill(-1)
		var queue: PackedInt32Array = hubs[i]
		for h in queue:
			dist[h] = 0
		var head := 0
		while head < queue.size():
			var p := queue[head]
			head += 1
			for k in range(a_start[p], a_start[p + 1]):
				var q := a_list[k]
				if dist[q] >= 0 or land[q] == 0:
					continue
				var c := ctrl[q]
				if c < 0 or ally[r * nc + c] == 0:
					continue
				dist[q] = dist[p] + 1
				queue.append(q)
		results[i] = dist
	Parallel.run(reps.size(), task, "supply", 4)
	world.supply_dist.resize(nc)
	for a in nc:
		var idx := reps.find(rep[a])
		world.supply_dist[a] = results[idx] if idx >= 0 else PackedInt32Array()
	# нагрузка на провинции и итоговое снабжение каждой дивизии
	var demand := PackedFloat32Array()
	demand.resize(world.prov_count)
	for d in world.divisions:
		if d.alive:
			demand[d.prov] += 1.5 if d.tpl >= Military.T_MOT else 1.0
	var caps := world.p_supply_cap
	var sd: Array = world.supply_dist
	for d in world.divisions:
		if not d.alive:
			continue
		var dist: PackedInt32Array = sd[d.owner]
		var h: int = dist[d.prov] if not dist.is_empty() else -1
		if h < 0:
			d.supply = 0.0
			continue
		var reach := 1.0 if h <= 5 else maxf(0.35, 1.0 - (h - 5) * 0.06)
		var cap := minf(1.0, caps[d.prov] / maxf(1.0, demand[d.prov]))
		d.supply = reach * cap


# --- ИИ: план каждой страны — отдельная задача ------------------------------

func _phase_ai() -> void:
	# задания: страны ИИ (раз в AI_PERIOD дней) и армии игрока (через день)
	var jobs: Array = []
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % AI_PERIOD == 0:
			jobs.append({"nation": nat.id})
	if world.day % 2 == 0:
		jobs.append_array(_group_jobs())
	if jobs.is_empty():
		return
	var plans: Array = []
	plans.resize(jobs.size())
	var day := world.day
	var seed_value := world.seed_value
	var task := func(i: int) -> void:
		var job: Dictionary = jobs[i]
		if job.has("nation"):
			var nid: int = job["nation"]
			plans[i] = AIPlanner.plan(world, nid, Parallel.rng(seed_value, day, nid))
		else:
			plans[i] = AIPlanner.plan_military(world, job["owner"], job["divs"], job["opts"],
				Parallel.rng(seed_value, day, 5000 + int(job["group"])))
	Parallel.run(jobs.size(), task, "ai")

	var by_id := {}
	for d in world.divisions:
		by_id[d.id] = d
	for i in jobs.size():
		var plan: Dictionary = plans[i]
		var job: Dictionary = jobs[i]
		if job.has("group"):
			var g: World.ArmyGroup = world.groups[job["group"]]
			g.front_pairs = plan["fronts"]
		else:
			var nid: int = job["nation"]
			var nat: World.Nation = world.nations[nid]
			_ai_train(nat, int(plan["train"]))
			nat.build_mode = plan["build"]
			if nat.current_research == "":
				# выбор науки — в главном потоке: константы Tech.LIST общие для всех
				var av := Tech.available(nat)
				if not av.is_empty():
					av.sort_custom(func(a, b): return a["cost"] < b["cost"])
					nat.current_research = av[mini(av.size() - 1, (world.day + nid) % 2)]["id"]
			if plan["war"] >= 0:
				Diplomacy.declare_war(world, nid, plan["war"])
		for order in plan["orders"]:
			var d = by_id.get(order[0])
			if d != null and d.alive:
				d.path = order[1]
				d.progress = 0.0


func _phase_navy() -> void:
	Forces.daily_navy(world, Parallel.rng(world.seed_value, world.day, 6000))
	Forces.daily_plans(world)
	Forces.daily_transit(world)
	# решения ИИ по флоту, авиации и высадкам — раз в 5 дней на страну
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % 5 == 0:
			Forces.ai_fleets(world, nat.id)
			Forces.ai_air(world, nat.id)
			if (world.day + nat.id) % 10 == 0:
				Forces.ai_invasion(world, nat.id, Parallel.rng(world.seed_value, world.day, 6100 + nat.id))


func _ai_train(nat: World.Nation, count: int) -> void:
	var mountainous := false
	for p in world.prov_count:
		if world.p_owner[p] == nat.id and world.p_terrain[p] == World.T_MOUNTAIN:
			mountainous = true
			break
	for k in count:
		var t := Military.ai_template(nat, nat.trained_count, mountainous)
		if Military.start_training(nat, t) or (t != Military.T_INF and Military.start_training(nat, Military.T_INF)):
			nat.trained_count += 1
		else:
			break


## Задания для армий игрока. Если несколько армий воюют против одной страны,
## её фронт делится между ними на участки вдоль линии фронта.
func _group_jobs() -> Array:
	var jobs: Array = []
	var by_key := {}
	for g in world.groups:
		if not g.alive:
			continue
		var divs: Array = []
		for d in world.divisions:
			if d.alive and d.group == g.id:
				divs.append(d)
		if divs.is_empty():
			continue
		var key := "%d:%d" % [g.owner, g.enemy]
		if not by_key.has(key):
			by_key[key] = []
		by_key[key].append(g.id)
		jobs.append({"group": g.id, "owner": g.owner, "divs": divs,
			"opts": {"mode": g.mode, "enemy": g.enemy, "objective": g.objective}})
	for key in by_key:
		var ids: Array = by_key[key]
		if ids.size() < 2:
			continue
		var g0: World.ArmyGroup = world.groups[ids[0]]
		var segs := _split_front(g0.owner, g0.enemy, ids.size())
		for job in jobs:
			var k := ids.find(job["group"])
			if k >= 0 and k < segs.size():
				job["opts"]["fronts"] = segs[k]
	return jobs


func _split_front(owner: int, enemy: int, parts: int) -> Array:
	var provs: Array = []
	for p in world.prov_count:
		if world.p_controller[p] != owner:
			continue
		for q in world.p_adj[p]:
			var c := world.p_controller[q]
			if world.p_land[q] == 1 and c >= 0 and c != owner and (enemy < 0 or c == enemy or world.ally[enemy * world.nation_count + c] == 1) \
					and (world.is_at_war(owner, c) or enemy >= 0):
				provs.append(p)
				break
	if provs.is_empty():
		return []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in provs:
		lo = lo.min(world.p_center[p])
		hi = hi.max(world.p_center[p])
	var vertical := (hi.y - lo.y) >= (hi.x - lo.x)
	provs.sort_custom(func(a, b):
		return world.p_center[a].y < world.p_center[b].y if vertical else world.p_center[a].x < world.p_center[b].x)
	var segs: Array = []
	for i in parts:
		var seg := {}
		var from := i * provs.size() / parts
		var to := (i + 1) * provs.size() / parts
		for j in range(from, maxi(to, from + 1)):
			seg[provs[mini(j, provs.size() - 1)]] = true
		segs.append(seg)
	return segs


# --- Армии игрока -------------------------------------------------------------

const GROUP_COLORS := [Color(0.95, 0.75, 0.2), Color(0.3, 0.8, 0.95), Color(0.9, 0.4, 0.85),
	Color(0.5, 0.9, 0.4), Color(1.0, 0.5, 0.3), Color(0.75, 0.75, 1.0)]


func create_group(owner: int, divs: Array) -> World.ArmyGroup:
	var g := World.ArmyGroup.new()
	g.id = world.groups.size()
	g.owner = owner
	var n := 1
	for o in world.groups:
		if o.owner == owner:
			n += 1
	g.name = "%d-я армия" % n
	g.color = GROUP_COLORS[(n - 1) % GROUP_COLORS.size()]
	world.groups.append(g)
	for d in divs:
		d.group = g.id
	return g


func disband_group(g: World.ArmyGroup) -> void:
	g.alive = false
	g.front_pairs = PackedInt32Array()
	for d in world.divisions:
		if d.group == g.id:
			d.group = -1


func order_move(d: World.Division, to: int) -> bool:
	if d.prov == to:
		d.path = PackedInt32Array()
		return true
	var path := Pathfinder.find_path(world, d.owner, d.prov, to)
	if path.is_empty():
		return false
	if d.path.is_empty() or d.path[0] != path[0]:
		d.progress = 0.0
	d.path = path
	return true


# --- Бои и движение ----------------------------------------------------------

## province -> Array[Division] атакующих
func _collect_battles() -> Dictionary:
	var battles := {}
	for d in world.divisions:
		d.in_battle = false
	for d in world.divisions:
		if d.path.is_empty() or d.transit_days > 0:
			continue
		var t: int = d.path[0]
		if not world.can_enter(d.owner, t):
			d.path = PackedInt32Array()
			d.progress = 0.0
			continue
		if world.has_enemies(d.owner, t):
			if not battles.has(t):
				battles[t] = []
			battles[t].append(d)
	return battles


func _phase_movement(battles: Dictionary) -> void:
	var movers: Array = []
	for d in world.divisions:
		if d.transit_days <= 0 and not d.path.is_empty() and not world.has_enemies(d.owner, d.path[0]):
			movers.append(d)
	if movers.is_empty():
		return
	var results: Array = []
	results.resize(movers.size())
	var task := func(i: int) -> void:
		var d: World.Division = movers[i]
		var t := d.path[0]
		var speed: float = d.spd * world.p_move_mult[t]
		var org_factor := 0.5 + 0.5 * clampf(d.org / maxf(1.0, d.max_org), 0.0, 1.0)
		# без снабжения войска еле ползут
		results[i] = d.progress + speed * org_factor * (0.5 + 0.5 * d.supply)
	Parallel.run(movers.size(), task, "move", 96)

	# применение — строго по порядку, чтобы не было гонок за провинцию
	for i in movers.size():
		var d: World.Division = movers[i]
		var t := d.path[0]
		d.progress = results[i]
		if d.progress < 1.0:
			continue
		if not world.can_enter(d.owner, t) or world.has_enemies(d.owner, t):
			d.progress = 0.99
			continue
		world.prov_divs[d.prov].erase(d)
		d.prov = t
		world.prov_divs[t].append(d)
		d.path.remove_at(0)
		d.progress = 0.0
		if d.landing:
			d.landing = false
			world.beachheads[t] = world.day + 60
		var c := world.p_controller[t]
		if c != d.owner and world.is_at_war(d.owner, c):
			_capture(t, d.owner)


func _capture(p: int, nid: int) -> void:
	var prev := world.p_controller[p]
	# освобождение своей провинции возвращает её владельцу-союзнику
	world.p_controller[p] = nid
	world.palette_dirty = true
	world.nations[nid].war_activity_day = world.day
	if prev >= 0:
		world.nations[prev].war_activity_day = world.day
	if world.p_vp[p] >= 5 and (world.nations[nid].is_player or world.nations[prev].is_player):
		world.log_event("%s захватывает %s" % [world.nations[nid].name, world.p_name[p]])


func _phase_combat(battles: Dictionary) -> void:
	var provs: Array = battles.keys()
	if provs.is_empty():
		return
	var results: Array = []
	results.resize(provs.size())
	var day := world.day
	var seed_value := world.seed_value
	var task := func(i: int) -> void:
		var p: int = provs[i]
		var attackers: Array = battles[p]
		var att_owner: int = attackers[0].owner
		var defenders: Array = []
		for e in world.prov_divs[p]:
			if e.alive and world.is_at_war(att_owner, e.owner):
				defenders.append(e)
		if defenders.is_empty():
			results[i] = []
			return
		var rng := Parallel.rng(seed_value, day, p)
		var terrain_def: float = world.p_def_mult[p]
		var terr: int = world.p_terrain[p]
		var tmul := world.tpl_terrain
		# сила стороны: атака/оборона шаблона x сила x укомплектованность x
		# снабжение x местность; бронированность — доля танков
		var sa: Array = Military.side_power(attackers, terr, tmul, false)
		var sd: Array = Military.side_power(defenders, terr, tmul, true)
		var reg: int = world.p_region[p]
		var nc2: int = world.nation_count
		var cas := world.cas_mult
		var att_power: float = sa[0] * cas[reg * nc2 + att_owner]
		var att_hard: float = sa[1]
		var def_power: float = sd[0] * cas[reg * nc2 + defenders[0].owner]
		var def_hard: float = sd[1]
		att_power *= rng.randf_range(0.8, 1.2) * (1.0 - terrain_def * 0.6)
		def_power *= rng.randf_range(0.8, 1.2)
		# броня гасит урон, если у противника мало своей брони (нечем пробивать)
		att_power *= 1.0 - def_hard * 0.6 * (1.0 - att_hard)
		def_power *= 1.0 - att_hard * 0.6 * (1.0 - def_hard)
		var deltas: Array = []
		var to_def := att_power / defenders.size()
		var to_att := def_power / attackers.size()
		for e in defenders:
			deltas.append([e, to_def * 0.55, to_def * 0.12])
		for a in attackers:
			deltas.append([a, to_att * 0.5, to_att * 0.10])
		results[i] = deltas
	Parallel.run(provs.size(), task, "combat", 12)

	for i in provs.size():
		var deltas: Array = results[i]
		for dl in deltas:
			var d: World.Division = dl[0]
			d.in_battle = true
			d.org = maxf(0.0, d.org - dl[1])
			d.strength = maxf(0.0, d.strength - dl[2])
			d.eq = maxf(0.0, d.eq - dl[2] / 100.0 * 0.9)   # потери техники
	# последствия: разбитые атакующие останавливаются, защитники отступают
	for i in provs.size():
		var p: int = provs[i]
		for a in battles[p]:
			if a.org <= 0.5 or a.strength <= 5.0:
				a.path = PackedInt32Array()
				a.progress = 0.0
				if a.strength <= 5.0:
					_destroy(a, "разбита")
		var att_owner: int = battles[p][0].owner
		for e in world.prov_divs[p].duplicate():
			if not e.alive or not world.is_at_war(att_owner, e.owner):
				continue
			if e.org <= 0.5 or e.strength <= 5.0:
				_retreat(e)


func _retreat(d: World.Division) -> void:
	var best := -1
	var best_score := -INF
	for q in world.p_adj[d.prov]:  # главный поток — можно без CSR
		if world.p_land[q] == 0 or world.p_controller[q] != d.owner or world.has_enemies(d.owner, q):
			continue
		var score := float(world.prov_divs[q].size()) + float(q % 5) * 0.01
		if score > best_score:
			best_score = score
			best = q
	if best < 0 or d.strength <= 5.0:
		_destroy(d, "окружена и уничтожена" if best < 0 else "разбита")
		return
	world.prov_divs[d.prov].erase(d)
	d.prov = best
	world.prov_divs[best].append(d)
	d.path = PackedInt32Array()
	d.progress = 0.0


func _destroy(d: World.Division, why: String) -> void:
	if not d.alive:
		return
	d.alive = false
	world.prov_divs[d.prov].erase(d)
	if world.nations[d.owner].is_player:
		world.log_event("Наша дивизия %s: %s" % [why, world.p_name[d.prov]])


func _phase_recovery() -> void:
	for d in world.divisions:
		if not d.alive or d.transit_days > 0:
			continue
		var nat: World.Nation = world.nations[d.owner]
		if d.supply <= 0.0:
			# окружение: организация не восстанавливается, части тают
			d.org = maxf(0.0, d.org - d.max_org * 0.02)
			d.strength = maxf(0.0, d.strength - 0.6)
			d.eq = maxf(0.0, d.eq - 0.004)
			if d.strength <= 5.0:
				_destroy(d, "погибла в окружении")
			continue
		d.entrench = minf(1.0, d.entrench + 0.05) if d.path.is_empty() else 0.0
		if not d.in_battle:
			var rate := 0.06 if d.path.is_empty() else 0.03
			d.org = minf(d.max_org, d.org + d.max_org * rate * (0.3 + 0.7 * d.supply))
			if world.p_controller[d.prov] == d.owner or world.ally[d.owner * world.nation_count + world.p_controller[d.prov]] == 1:
				Military.reinforce(nat, d)


# --- Капитуляция -------------------------------------------------------------

func _check_capitulation() -> void:
	var total := PackedInt32Array()
	var held := PackedInt32Array()
	total.resize(world.nations.size())
	held.resize(world.nations.size())
	for p in world.prov_count:
		var o := world.p_owner[p]
		if o < 0:
			continue
		total[o] += world.p_vp[p]
		if world.p_controller[p] == o:
			held[o] += world.p_vp[p]
	for nat in world.nations:
		if not nat.alive or nat.at_war.is_empty() or total[nat.id] == 0 or _peace_pending(nat.id):
			continue
		var ratio := float(held[nat.id]) / float(total[nat.id])
		if ratio < 0.3:
			_capitulate(nat.id)
		elif world.p_controller[nat.capital] != nat.id:
			_move_capital(nat)

	var alive := 0
	var player := world.player_nation()
	for nat in world.nations:
		if nat.alive:
			alive += 1
	if player >= 0:
		if not world.nations[player].alive or world.nations[player].overlord >= 0:
			world.game_over = "defeat"
		else:
			var rivals := 0
			for nat in world.nations:
				if nat.alive and not Diplomacy.same_side(world, player, nat.id):
					rivals += 1
			if rivals == 0:
				world.game_over = "victory"


func _capitulate(nid: int) -> void:
	# главный победитель — тот, кто держит больше всего наших провинций
	var occ := {}
	for p in world.prov_count:
		if world.p_owner[p] == nid and world.p_controller[p] != nid:
			occ[world.p_controller[p]] = int(occ.get(world.p_controller[p], 0)) + world.p_vp[p] + 1
	var winner := -1
	var best := -1
	for k in occ:
		if occ[k] > best:
			best = occ[k]
			winner = k
	if winner < 0:
		return
	var w_root := Diplomacy.root(world, winner)
	if History.capitulation_hook(world, nid, w_root, Parallel.rng(world.seed_value, world.day, 8888)):
		_fix_capitals()
		return
	if world.nations[w_root].is_player:
		# условия мира выбирает игрок: тик ставится на паузу до решения
		for pp in world.pending_peace:
			if pp[0] == nid:
				return
		world.pending_peace.append([nid, w_root])
		return
	Diplomacy.make_peace(world, nid, winner, Diplomacy.ai_peace_mode(world, w_root))
	_fix_capitals()


func resolve_event(option: int) -> void:
	if world.pending_events.is_empty():
		return
	var id: String = world.pending_events.pop_front()
	History.choose_option(world, id, option, Parallel.rng(world.seed_value, world.day, 9999))
	_fix_capitals()


func resolve_peace(mode: String) -> void:
	if world.pending_peace.is_empty():
		return
	var pp: Array = world.pending_peace.pop_front()
	Diplomacy.make_peace(world, pp[0], pp[1], mode)
	_fix_capitals()


func _phase_diplomacy() -> void:
	if not world.diplomacy:
		return
	Diplomacy.daily(world)
	History.daily(world, Parallel.rng(world.seed_value, world.day, 7777))
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % 7 == 0:
			Diplomacy.ai_turn(world, nat.id, Parallel.rng(world.seed_value, world.day, 1000 + nat.id))


func _fix_capitals() -> void:
	for nat in world.nations:
		if not nat.alive or world.p_owner[nat.capital] == nat.id:
			continue
		var best := -1
		for p in world.prov_count:
			if world.p_owner[p] == nat.id and (best < 0 or world.p_vp[p] > world.p_vp[best]):
				best = p
		if best >= 0:
			nat.capital = best
		else:
			nat.alive = false


## Столица захвачена — правительство переезжает в крупнейший свободный город.
func _move_capital(nat: World.Nation) -> void:
	var best := -1
	for p in world.prov_count:
		if world.p_owner[p] == nat.id and world.p_controller[p] == nat.id:
			if best < 0 or world.p_vp[p] > world.p_vp[best]:
				best = p
	if best < 0:
		return
	var old := nat.capital
	nat.capital = best
	world.log_event("%s: столица захвачена (%s), правительство переезжает в %s" % [nat.name, world.p_name[old], world.p_name[best]])


func _peace_pending(nid: int) -> bool:
	for pp in world.pending_peace:
		if pp[0] == nid:
			return true
	return false
