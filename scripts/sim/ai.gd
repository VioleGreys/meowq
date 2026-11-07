class_name AIPlanner
extends RefCounted
## Планирование: экономика страны ИИ и военные приказы для группы дивизий.
## plan()/plan_military() только читают мир и возвращают приказы — поэтому
## планы всех стран ИИ и всех армий игрока считаются параллельно, а
## применяются потом в главном потоке. Константы скриптов здесь не читаются.


static func plan(world: World, nid: int, rng: RandomNumberGenerator) -> Dictionary:
	var nat: World.Nation = world.nations[nid]
	var result := {"orders": [], "train": 0, "build": nat.build_mode, "war": -1, "fronts": PackedInt32Array()}
	if not nat.alive:
		return result
	var my_divs := world.divisions_of(nid)
	var at_war := not nat.at_war.is_empty()

	# --- Экономика: сколько дивизий заказать (шаблоны выбираются в главном потоке)
	# размер армии — от промышленности (сколько она может вооружить) и территории
	# потолок — по населению (примерно как могли содержать страны в 1939–41 гг.)
	var cap := 4.0 + nat.population * 1.3
	var target_divs := int(minf(6.0 + nat.mil * 2.5 + nat.civ * 0.3, cap) * (1.4 if at_war else 1.0))
	var pending := my_divs.size() + nat.training.size()
	while pending < target_divs and result["train"] < 3 and nat.manpower > 10.0 * (result["train"] + 1):
		result["train"] += 1
		pending += 1
	if at_war or nat.mil < nat.civ * 0.7:
		result["build"] = "mil"
	else:
		result["build"] = "civ"

	# --- Старые случайные войны — только для процедурного мира без дипломатии
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

	# осторожность наступления по идеологии: демократии атакуют только с большим перевесом
	var ratio := 1.3
	match nat.ideology:
		"democracy":
			ratio = 2.2
		"authoritarian":
			ratio = 1.7
	var mil := plan_military(world, nid, my_divs, {"mode": "auto", "ratio": ratio}, rng)
	result["orders"] = mil["orders"]
	return result


## Военный план для набора дивизий одной страны.
## opts: mode — "auto" (ИИ: наступать, если идёт война), "hold" (держать фронт),
##       "attack" (наступать); enemy — номер страны или -1 (все противники);
##       objective — провинция-цель наступления (-1 — нет);
##       fronts — Dictionary допустимых провинций фронта (пусто — весь фронт).
## Возвращает {"orders": [[id дивизии, путь]], "fronts": пары (наша, чужая)}.
static func plan_military(world: World, nid: int, divs: Array, opts: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var result := {"orders": [], "fronts": PackedInt32Array()}
	var nat: World.Nation = world.nations[nid]
	var mode: String = opts.get("mode", "auto")
	var enemy: int = opts.get("enemy", -1)
	var objective: int = opts.get("objective", -1)
	var allowed: Dictionary = opts.get("fronts", {})

	# локальные ссылки на массивы мира — без конкуренции потоков за refcount
	var ctrl := world.p_controller
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var war := world.war
	var ally := world.ally
	var nc := world.nation_count
	var def_tab := world.p_def_mult
	var vp := world.p_vp
	var prov_divs := world.prov_divs

	var at_war := false
	for e in nat.at_war:
		if enemy < 0 or e == enemy or (ally.size() > 0 and ally[enemy * nc + e] == 1):
			at_war = true
			break
	var attack_allowed := at_war and (mode == "attack" or mode == "auto")

	# фронт: наши провинции у противника (или у выбранной страны до войны)
	var fronts := {}
	var targets := {}
	for p in world.prov_count:
		if ctrl[p] != nid:
			continue
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				continue
			var c := ctrl[q]
			if c < 0 or c == nid:
				continue
			var hostile := war[nid * nc + c] == 1
			var matches := enemy < 0 or c == enemy or (ally.size() > 0 and ally[enemy * nc + c] == 1)
			if at_war:
				if hostile and matches:
					fronts[p] = true
					targets[q] = true
					result["fronts"].append(p)
					result["fronts"].append(q)
			elif matches and (enemy >= 0 or mode == "auto") and (ally.size() == 0 or ally[nid * nc + c] == 0):
				fronts[p] = true
				result["fronts"].append(p)
				result["fronts"].append(q)
	if not allowed.is_empty():
		for f in fronts.keys():
			if not allowed.has(f):
				fronts.erase(f)
		for t in targets.keys():
			var near := false
			for k in range(a_start[t], a_start[t + 1]):
				if allowed.has(a_list[k]):
					near = true
					break
			if not near:
				targets.erase(t)
		var fp := PackedInt32Array()
		for i in range(0, result["fronts"].size(), 2):
			if allowed.has(result["fronts"][i]):
				fp.append(result["fronts"][i])
				fp.append(result["fronts"][i + 1])
		result["fronts"] = fp
	if fronts.is_empty():
		if mode == "auto":
			fronts[nat.capital] = true
		else:
			return result
	# в войну столица и крупные порты (узлы снабжения) всегда под охраной
	if mode == "auto" and at_war and ctrl[nat.capital] == nid:
		fronts[nat.capital] = true
		var coastal := world.p_coastal
		for p in world.prov_count:
			if ctrl[p] == nid and coastal[p] == 1 and vp[p] >= 5 and world.p_owner[p] == nid:
				fronts[p] = true

	var idle: Array = []
	for d in divs:
		if d.alive and d.path.is_empty() and not d.in_battle and d.transit_days <= 0 and d.reserved_until < world.day and d.inv_plan < 0:
			idle.append(d)
	if idle.is_empty():
		return result

	# расстояние до цели наступления (по суше, без учёта владельца)
	var obj_dist := PackedInt32Array()
	if objective >= 0:
		obj_dist.resize(world.prov_count)
		obj_dist.fill(1 << 20)
		obj_dist[objective] = 0
		var queue := PackedInt32Array([objective])
		var head := 0
		while head < queue.size():
			var p := queue[head]
			head += 1
			for k in range(a_start[p], a_start[p + 1]):
				var q := a_list[k]
				if land[q] == 1 and obj_dist[q] > obj_dist[p] + 1:
					obj_dist[q] = obj_dist[p] + 1
					queue.append(q)

	var in_group := {}
	for d in divs:
		in_group[d.id] = true
	var used := {}
	if attack_allowed:
		# Атакуем слабые вражеские провинции превосходящими силами; при цели —
		# в первую очередь те, что ближе к ней.
		var target_list: Array = []
		for t in targets:
			var enemy_str := 0.0
			for e in prov_divs[t]:
				if e.owner != nid and war[nid * nc + e.owner] == 1:
					enemy_str += e.strength * (e.org / maxf(1.0, e.max_org)) * (0.4 + 0.6 * e.eq)
			var def_mult: float = 1.0 + def_tab[t]
			var score: float = enemy_str * def_mult - vp[t] * 6.0 + rng.randf() * 20.0
			if objective >= 0:
				score += obj_dist[t] * 25.0
			target_list.append([score, t, enemy_str * def_mult])
		target_list.sort_custom(func(a, b): return a[0] < b[0])
		var ratio: float = opts.get("ratio", 1.15 if objective >= 0 else 1.3)
		var left := {}   # сколько наших дивизий останется в провинции
		for entry in target_list:
			var t: int = entry[1]
			var need: float = entry[2] * ratio
			var group: Array = []
			for k in range(a_start[t], a_start[t + 1]):
				for d in prov_divs[a_list[k]]:
					if d.owner == nid and in_group.has(d.id) and d.path.is_empty() and not d.in_battle \
							and not used.has(d.id) and d.org > d.max_org * 0.6 and d.inv_plan < 0 and d.reserved_until < world.day:
						group.append(d)
			if group.is_empty():
				continue
			# сильнейшие первыми; берём ровно столько, сколько нужно (на пустую — одну)
			group.sort_custom(func(a, b): return a.atk * a.strength > b.atk * b.strength)
			var chosen: Array = []
			var power := 0.0
			for d in group:
				if not left.has(d.prov):
					left[d.prov] = prov_divs[d.prov].size()
				if int(left[d.prov]) <= 1:
					continue   # последняя дивизия участок не бросает
				chosen.append(d)
				left[d.prov] = int(left[d.prov]) - 1
				power += d.strength * (d.atk / 10.0) * (0.4 + 0.6 * d.eq) * (0.5 + 0.5 * d.supply)
				if power > need and (entry[2] <= 0.0 or chosen.size() >= 2):
					break
			if power > need and not chosen.is_empty():
				for d in chosen:
					used[d.id] = true
					result["orders"].append([d.id, PackedInt32Array([t])])
			else:
				for d in chosen:
					left[d.prov] = int(left[d.prov]) + 1

	# Остальных распределяем по фронту: больше — туда, где больше противника.
	var per_front := {}
	for d in divs:
		if d.alive and fronts.has(d.prov):
			per_front[d.prov] = int(per_front.get(d.prov, 0)) + 1
	var weight := {}
	var wsum := 0.0
	for f in fronts:
		var threat := 0.0
		for k in range(a_start[f], a_start[f + 1]):
			var q := a_list[k]
			for e in prov_divs[q]:
				if e.owner != nid and (ally.size() == 0 or ally[nid * nc + e.owner] == 0):
					threat += 1.0 if war[nid * nc + e.owner] == 1 or not at_war else 0.3
		weight[f] = 1.0 + threat + vp[f] * 0.15   # крупные города держим плотнее
		wsum += weight[f]
	var desired := {}
	for f in fronts:
		desired[f] = maxi(1, int(round(divs.size() * weight[f] / wsum)))
	for d in idle:
		if used.has(d.id):
			continue
		if fronts.has(d.prov) and int(per_front.get(d.prov, 0)) <= int(desired[d.prov]) + 1:
			continue
		var goal := {}
		for f in fronts:
			if int(per_front.get(f, 0)) < int(desired[f]) and f != d.prov:
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
	return s + nat.mil * 40.0
