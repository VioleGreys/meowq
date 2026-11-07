class_name Simulation
extends RefCounted
## Дневной тик. Каждая тяжёлая фаза устроена как «параллельно посчитать ->
## последовательно применить», поэтому результат детерминирован и не зависит
## от числа ядер, а сама работа распределяется по WorkerThreadPool.

const DIV_EQUIP_COST := 100.0
const DIV_MANPOWER_COST := 10.0
const DIV_TRAIN_DAYS := 14
const FACTORY_COST := 45.0
const MAX_FACTORIES := 12
const AI_PERIOD := 3

var world: World
var last_tick_usec := 0
var phase_usec := {}


func _init(w: World) -> void:
	world = w
	refresh_income()


## Пересчитать доход всех стран без начисления (для интерфейса до первого тика).
func refresh_income() -> void:
	world.refresh_stats()
	var all := world.compute_all_income()
	for nat in world.nations:
		var r: Array = all[nat.id]
		nat.civ = r[0]
		nat.mil = r[1]
		nat.province_count = r[3]
		nat.daily_equipment = nat.mil * 0.4 * (1.0 + nat.b("industry"))
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))
		nat.daily_research = (1.0 + nat.civ * 0.05) * (1.0 + nat.b("research"))


func tick() -> void:
	if world.game_over != "":
		return
	var t0 := Time.get_ticks_usec()
	world.day += 1
	world.rebuild_prov_divs()
	world.refresh_stats()
	_timed("экономика", _phase_economy)
	_timed("ИИ", _phase_ai)
	var battles := _collect_battles()
	_timed("движение", _phase_movement.bind(battles))
	_timed("бои", _phase_combat.bind(battles))
	_phase_recovery()
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
		nat.daily_equipment = nat.mil * 0.4 * (1.0 + nat.b("industry"))
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))
		nat.daily_research = (1.0 + nat.civ * 0.05) * (1.0 + nat.b("research"))
		nat.equipment += nat.daily_equipment
		nat.manpower += nat.daily_manpower

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
		nat.build_progress += nat.civ * 0.12 * (1.0 + nat.b("construction"))
		if nat.build_progress >= FACTORY_COST:
			if _place_factory(i, nat.build_mode):
				nat.build_progress -= FACTORY_COST
			else:
				nat.build_progress = FACTORY_COST

		# подготовка дивизий
		var still: Array = []
		for days_left in nat.training:
			if days_left <= 1:
				var spawn := nat.capital if world.p_controller[nat.capital] == i else _any_province(i)
				if spawn >= 0:
					world.spawn_division(i, spawn)
					if nat.is_player:
						world.log_event("Новая дивизия готова: %s" % world.p_name[spawn])
			else:
				still.append(days_left - 1)
		nat.training = still


func _place_factory(nid: int, mode: String) -> bool:
	var best := -1
	var best_score := INF
	for p in world.prov_count:
		if world.p_owner[p] != nid or world.p_controller[p] != nid:
			continue
		var total := world.p_civ[p] + world.p_mil[p]
		if total >= MAX_FACTORIES:
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


func _any_province(nid: int) -> int:
	for p in world.prov_count:
		if world.p_controller[p] == nid and world.p_owner[p] == nid:
			return p
	for p in world.prov_count:
		if world.p_controller[p] == nid:
			return p
	return -1


func train_division(nid: int) -> bool:
	var nat: World.Nation = world.nations[nid]
	if nat.equipment < DIV_EQUIP_COST or nat.manpower < DIV_MANPOWER_COST:
		return false
	nat.equipment -= DIV_EQUIP_COST
	nat.manpower -= DIV_MANPOWER_COST
	nat.training.append(DIV_TRAIN_DAYS)
	return true


# --- ИИ: план каждой страны — отдельная задача ------------------------------

func _phase_ai() -> void:
	var planners: Array = []
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % AI_PERIOD == 0:
			planners.append(nat.id)
	if planners.is_empty():
		return
	var plans: Array = []
	plans.resize(planners.size())
	var day := world.day
	var seed_value := world.seed_value
	var task := func(i: int) -> void:
		var nid: int = planners[i]
		plans[i] = AIPlanner.plan(world, nid, Parallel.rng(seed_value, day, nid))
	Parallel.run(planners.size(), task, "ai")

	var by_id := {}
	for d in world.divisions:
		by_id[d.id] = d
	for i in planners.size():
		var nid: int = planners[i]
		var nat: World.Nation = world.nations[nid]
		var plan: Dictionary = plans[i]
		for k in plan["train"]:
			train_division(nid)
		nat.build_mode = plan["build"]
		if nat.current_research == "":
			# выбор науки — в главном потоке: константы Tech.LIST общие для всех
			var av := Tech.available(nat)
			if not av.is_empty():
				av.sort_custom(func(a, b): return a["cost"] < b["cost"])
				nat.current_research = av[mini(av.size() - 1, (world.day + nid) % 2)]["id"]
		if plan["war"] >= 0:
			world.declare_war(nid, plan["war"])
		for order in plan["orders"]:
			var d = by_id.get(order[0])
			if d != null and d.alive:
				d.path = order[1]
				d.progress = 0.0


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
		if d.path.is_empty():
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
		if not d.path.is_empty() and not world.has_enemies(d.owner, d.path[0]):
			movers.append(d)
	if movers.is_empty():
		return
	var results: Array = []
	results.resize(movers.size())
	var task := func(i: int) -> void:
		var d: World.Division = movers[i]
		var t := d.path[0]
		var speed: float = world.division_speed(d.owner) * world.p_move_mult[t]
		var org_factor := 0.5 + 0.5 * clampf(d.org / world.division_max_org(d.owner), 0.0, 1.0)
		results[i] = d.progress + speed * org_factor
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
		var c := world.p_controller[t]
		if c != d.owner and world.is_at_war(d.owner, c):
			_capture(t, d.owner)


func _capture(p: int, nid: int) -> void:
	var prev := world.p_controller[p]
	# освобождение своей провинции возвращает её владельцу-союзнику
	world.p_controller[p] = nid
	world.palette_dirty = true
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
		var att_power := 0.0
		for a in attackers:
			att_power += world.division_attack(a.owner) * a.strength / 100.0
		var def_power := 0.0
		for e in defenders:
			def_power += world.division_defense(e.owner) * e.strength / 100.0
		att_power *= rng.randf_range(0.8, 1.2) * (1.0 - terrain_def * 0.6)
		def_power *= rng.randf_range(0.8, 1.2)
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
		if not d.alive:
			continue
		var max_org := world.division_max_org(d.owner)
		if not d.in_battle:
			var rate := 0.06 if d.path.is_empty() else 0.03
			d.org = minf(max_org, d.org + max_org * rate)
			if d.strength < 100.0 and world.p_controller[d.prov] == d.owner:
				var nat: World.Nation = world.nations[d.owner]
				var want := minf(100.0 - d.strength, 2.0 * (1.0 + nat.b("reinforce")))
				var can := minf(want, minf(nat.equipment, nat.manpower * 10.0))
				if can > 0.0:
					d.strength += can
					nat.equipment -= can
					nat.manpower -= can * 0.1


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
		if not nat.alive or nat.at_war.is_empty() or total[nat.id] == 0:
			continue
		var ratio := float(held[nat.id]) / float(total[nat.id])
		var capital_lost: bool = world.p_controller[nat.capital] != nat.id
		if ratio < 0.25 or (capital_lost and ratio < 0.45):
			_capitulate(nat.id)

	var alive := 0
	var player := world.player_nation()
	for nat in world.nations:
		if nat.alive:
			alive += 1
	if player >= 0:
		if not world.nations[player].alive:
			world.game_over = "defeat"
		elif alive == 1:
			world.game_over = "victory"


func _capitulate(nid: int) -> void:
	var nat: World.Nation = world.nations[nid]
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
	for p in world.prov_count:
		if world.p_owner[p] == nid:
			if world.p_controller[p] == nid:
				world.p_controller[p] = winner
			world.p_owner[p] = world.p_controller[p]
		elif world.p_controller[p] == nid:
			world.p_controller[p] = world.p_owner[p]
	for d in world.divisions:
		if d.owner == nid:
			d.alive = false
	world.end_wars_of(nid)
	nat.alive = false
	nat.training.clear()
	_fix_capitals()
	world.palette_dirty = true
	world.log_event("%s капитулирует перед %s!" % [nat.name, world.nations[winner].name])
	world.rebuild_prov_divs()


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
