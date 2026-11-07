class_name AIPlanner
extends RefCounted
## ИИ страны. plan() только читает мир и возвращает план — поэтому планы всех
## стран считаются параллельно, а применяются потом в главном потоке.


static func plan(world: World, nid: int, rng: RandomNumberGenerator) -> Dictionary:
	var nat: World.Nation = world.nations[nid]
	var result := {"orders": [], "train": 0, "build": nat.build_mode, "research": "", "war": -1}
	if not nat.alive:
		return result
	var my_divs := world.divisions_of(nid)
	var at_war := not nat.at_war.is_empty()

	# --- Экономика ---------------------------------------------------------
	var target_divs := 5 + nat.province_count / 3 + (6 if at_war else 0)
	var pending := my_divs.size() + nat.training.size()
	var eq := nat.equipment
	var mp := nat.manpower
	while pending < target_divs and eq >= Simulation.DIV_EQUIP_COST and mp >= Simulation.DIV_MANPOWER_COST and result["train"] < 3:
		result["train"] += 1
		pending += 1
		eq -= Simulation.DIV_EQUIP_COST
		mp -= Simulation.DIV_MANPOWER_COST
	if at_war or nat.mil < nat.civ * 0.7:
		result["build"] = "mil"
	else:
		result["build"] = "civ"

	# --- Объявление войны --------------------------------------------------
	if world.ai_wars and not world.diplomacy and not at_war and world.day > 45 and rng.randf() < 0.06:
		var my_power := _power(world, nid)
		var best := -1
		var best_ratio := 1.35
		for other in world.neighbours_of_nation(nid):
			if not world.nations[other].alive:
				continue
			var ratio := my_power / maxf(1.0, _power(world, other))
			if world.nations[other].is_player:
				ratio *= 0.9
			if ratio > best_ratio:
				best_ratio = ratio
				best = other
		result["war"] = best

	# --- Военные приказы ---------------------------------------------------
	var idle: Array = []
	for d in my_divs:
		if d.path.is_empty() and not d.in_battle:
			idle.append(d)
	if idle.is_empty():
		return result

	var max_org := world.division_max_org(nid)
	# локальные ссылки на массивы мира — без конкуренции потоков за refcount
	var ctrl := world.p_controller
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var war := world.war
	var nc := world.nation_count
	var org_cap := world.n_org
	var def_tab := world.p_def_mult
	var vp := world.p_vp
	var prov_divs := world.prov_divs
	var fronts := {}      # своя провинция -> true (граничит с врагом / соседом)
	var targets := {}     # вражеская провинция -> true
	for p in world.prov_count:
		if ctrl[p] != nid:
			continue
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				continue
			var c := ctrl[q]
			if at_war and c >= 0 and c != nid and war[nid * nc + c] == 1:
				fronts[p] = true
				targets[q] = true
			elif not at_war and c != nid:
				fronts[p] = true
	if fronts.is_empty():
		fronts[nat.capital] = true

	var used := {}
	if at_war:
		# Атакуем слабые вражеские провинции превосходящими силами.
		var target_list: Array = []
		for t in targets:
			var enemy_str := 0.0
			for e in prov_divs[t]:
				if e.owner != nid and war[nid * nc + e.owner] == 1:
					enemy_str += e.strength * (e.org / maxf(1.0, org_cap[e.owner]))
			var def_mult: float = 1.0 + def_tab[t]
			target_list.append([enemy_str * def_mult - vp[t] * 6.0 + rng.randf() * 20.0, t, enemy_str * def_mult])
		target_list.sort_custom(func(a, b): return a[0] < b[0])
		for entry in target_list:
			var t: int = entry[1]
			var need: float = entry[2] * 1.3
			var group: Array = []
			var power := 0.0
			for k in range(a_start[t], a_start[t + 1]):
				for d in prov_divs[a_list[k]]:
					if d.owner == nid and d.path.is_empty() and not d.in_battle and not used.has(d.id) and d.org > max_org * 0.6:
						group.append(d)
						power += d.strength
			# оставляем хотя бы одну дивизию на месте, если на участке их мало
			if power > need and not group.is_empty():
				for d in group:
					if prov_divs[d.prov].size() > 1 or entry[2] <= 0.0:
						used[d.id] = true
						result["orders"].append([d.id, PackedInt32Array([t])])

	# Остальных распределяем по фронту.
	var per_front := {}
	for d in my_divs:
		if fronts.has(d.prov):
			per_front[d.prov] = int(per_front.get(d.prov, 0)) + 1
	var desired := maxi(1, int(ceil(float(my_divs.size()) / fronts.size())))
	for d in idle:
		if used.has(d.id):
			continue
		if fronts.has(d.prov) and int(per_front.get(d.prov, 0)) <= desired + 1:
			continue
		var goal := {}
		for f in fronts:
			if int(per_front.get(f, 0)) < desired and f != d.prov:
				goal[f] = true
		if goal.is_empty():
			continue
		var path := Pathfinder.nearest_goal(world, nid, d.prov, goal)
		if path.is_empty():
			continue
		var dest := path[path.size() - 1]
		per_front[dest] = int(per_front.get(dest, 0)) + 1
		if fronts.has(d.prov):
			per_front[d.prov] = int(per_front.get(d.prov, 0)) - 1
		result["orders"].append([d.id, path])
	return result


static func _power(world: World, nid: int) -> float:
	var s := 0.0
	for d in world.divisions:
		if d.alive and d.owner == nid:
			s += d.strength
	var nat: World.Nation = world.nations[nid]
	return s + nat.mil * 40.0 + nat.equipment * 0.3
