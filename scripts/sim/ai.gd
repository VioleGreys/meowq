class_name AIPlanner
extends RefCounted
## Планирование: экономика страны ИИ и военные приказы для группы дивизий.
## plan()/plan_military() только ЧИТАЮТ мир и возвращают приказы — поэтому
## планы всех стран ИИ и всех армий игрока считаются параллельно, а
## применяются потом в главном потоке.
## Дивизии читаются из снимка (World.snapshot_divisions: плоские массивы dv_* и
## CSR pd_start/pd_list), а не из объектов: так потоки не дерутся за счётчики
## ссылок и масштабируются по ядрам. Приказы — [id дивизии, путь].


static func plan(world: World, nid: int, rng: RandomNumberGenerator) -> Dictionary:
	var nat: World.Nation = world.nations[nid]
	var result := {"orders": [], "train": 0, "build": nat.build_mode, "war": -1, "fronts": PackedInt32Array()}
	if not nat.alive:
		return result
	var owner := world.dv_owner
	var mine := PackedInt32Array()
	for i in owner.size():
		if owner[i] == nid:
			mine.append(i)
	var at_war := not nat.at_war.is_empty()

	# --- Экономика: сколько дивизий заказать (шаблоны выбираются в главном потоке)
	var cap := 4.0 + nat.population * 1.3
	var target_divs := int(minf(6.0 + nat.mil * 2.5 + nat.civ * 0.3, cap) * (1.4 if at_war else 1.0))
	var pending := mine.size() + nat.training.size()
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
	var mil := plan_military(world, nid, mine, {"mode": "auto", "ratio": ratio}, rng)
	result["orders"] = mil["orders"]
	return result


## Военный план для набора дивизий одной страны (индексы в снимке dv_*).
## opts: mode — "auto" (ИИ: наступать, если идёт война), "hold" (держать фронт),
##       "attack" (наступать); enemy — номер страны или -1 (все противники);
##       objective — провинция-цель наступления (-1 — нет);
##       fronts — Dictionary допустимых провинций фронта (пусто — весь фронт);
##       ratio — нужный перевес для атаки.
## Возвращает {"orders": [[id дивизии, путь]], "fronts": пары (наша, чужая)}.
static func plan_military(world: World, nid: int, divs: PackedInt32Array, opts: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
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
	var coastal := world.p_coastal
	var owners := world.p_owner
	var dv_id := world.dv_id
	var dv_owner := world.dv_owner
	var dv_prov := world.dv_prov
	var dv_flags := world.dv_flags
	var dv_org := world.dv_org
	var dv_power := world.dv_power
	var dv_defw := world.dv_defw
	var pd_start := world.pd_start
	var pd_list := world.pd_list
	var capital := nat.capital

	var at_war := false
	for e in nat.at_war:
		if enemy < 0 or e == enemy or (ally.size() > 0 and ally[enemy * nc + e] == 1):
			at_war = true
			break
	var attack_allowed := at_war and (mode == "attack" or mode == "auto")

	# фронт: наши провинции у противника (или у выбранной страны до войны)
	var fronts := {}
	var targets := {}
	var fpairs := PackedInt32Array()
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
					fpairs.append(p)
					fpairs.append(q)
			elif matches and (enemy >= 0 or mode == "auto") and (ally.size() == 0 or ally[nid * nc + c] == 0):
				fronts[p] = true
				fpairs.append(p)
				fpairs.append(q)
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
		for i in range(0, fpairs.size(), 2):
			if allowed.has(fpairs[i]):
				fp.append(fpairs[i])
				fp.append(fpairs[i + 1])
		fpairs = fp
	result["fronts"] = fpairs
	if fronts.is_empty():
		if mode == "auto":
			fronts[capital] = true
		else:
			return result
	# в войну столица и крупные порты (узлы снабжения) всегда под охраной
	if mode == "auto" and at_war and ctrl[capital] == nid:
		fronts[capital] = true
		for p in world.prov_count:
			if ctrl[p] == nid and coastal[p] == 1 and vp[p] >= 5 and owners[p] == nid:
				fronts[p] = true

	var idle := PackedInt32Array()
	var in_group := {}
	for i in divs:
		in_group[i] = true
		if dv_flags[i] & 1 == 1:
			idle.append(i)
	if idle.is_empty():
		return result

	# расстояние до цели наступления (по суше, без учёта владельца)
	var obj_dist := PackedInt32Array()
	if objective >= 0 and Native.core != null:
		obj_dist = Native.core.call("land_dist", a_start, a_list, land, objective)
	elif objective >= 0:
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

	var used := {}
	var orders: Array = []
	if attack_allowed:
		# Атакуем слабые вражеские провинции превосходящими силами; при цели —
		# в первую очередь те, что ближе к ней.
		var target_list: Array = []
		for t in targets:
			var enemy_str := 0.0
			for k in range(pd_start[t], pd_start[t + 1]):
				var e := pd_list[k]
				var eo := dv_owner[e]
				if eo != nid and war[nid * nc + eo] == 1:
					enemy_str += dv_defw[e]
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
				var q := a_list[k]
				for m in range(pd_start[q], pd_start[q + 1]):
					var i := pd_list[m]
					if dv_owner[i] == nid and in_group.has(i) and dv_flags[i] & 1 == 1 \
							and not used.has(i) and dv_org[i] > 0.6:
						group.append(i)
			if group.is_empty():
				continue
			# сильнейшие первыми; берём ровно столько, сколько нужно (на пустую — одну)
			group.sort_custom(func(a, b): return dv_power[a] > dv_power[b])
			var chosen: Array = []
			var power := 0.0
			for i in group:
				var pv := dv_prov[i]
				if not left.has(pv):
					left[pv] = pd_start[pv + 1] - pd_start[pv]
				if int(left[pv]) <= 1:
					continue   # последняя дивизия участок не бросает
				chosen.append(i)
				left[pv] = int(left[pv]) - 1
				power += dv_power[i]
				if power > need and (entry[2] <= 0.0 or chosen.size() >= 2):
					break
			if power > need and not chosen.is_empty():
				for i in chosen:
					used[i] = true
					orders.append([dv_id[i], PackedInt32Array([t])])
			else:
				for i in chosen:
					left[dv_prov[i]] = int(left[dv_prov[i]]) + 1

	# Остальных распределяем по фронту: больше — туда, где больше противника.
	var per_front := {}
	for i in divs:
		var pv := dv_prov[i]
		if dv_flags[i] & 4 == 0 and fronts.has(pv):
			per_front[pv] = int(per_front.get(pv, 0)) + 1
	var weight := {}
	var wsum := 0.0
	for f in fronts:
		var threat := 0.0
		for k in range(a_start[f], a_start[f + 1]):
			var q := a_list[k]
			for m in range(pd_start[q], pd_start[q + 1]):
				var eo := dv_owner[pd_list[m]]
				if eo != nid and (ally.size() == 0 or ally[nid * nc + eo] == 0):
					threat += 1.0 if war[nid * nc + eo] == 1 or not at_war else 0.3
		weight[f] = 1.0 + threat + vp[f] * 0.15   # крупные города держим плотнее
		wsum += weight[f]
	var desired := {}
	for f in fronts:
		desired[f] = maxi(1, int(round(divs.size() * weight[f] / wsum)))
	for i in idle:
		if used.has(i):
			continue
		var pv := dv_prov[i]
		if fronts.has(pv) and int(per_front.get(pv, 0)) <= int(desired[pv]) + 1:
			continue
		var goal := {}
		for f in fronts:
			if int(per_front.get(f, 0)) < int(desired[f]) and f != pv:
				goal[f] = true
		if goal.is_empty():
			continue
		var path := Pathfinder.nearest_goal(world, nid, pv, goal)
		if path.is_empty():
			continue
		var dest := path[path.size() - 1]
		per_front[dest] = int(per_front.get(dest, 0)) + 1
		if fronts.has(pv):
			per_front[pv] = int(per_front.get(pv, 0)) - 1
		orders.append([dv_id[i], path])
	result["orders"] = orders
	return result


static func _power(world: World, nid: int) -> float:
	var s := 0.0
	var owner := world.dv_owner
	var st := world.dv_str
	for i in owner.size():
		if owner[i] == nid:
			s += st[i]
	var nat: World.Nation = world.nations[nid]
	return s + nat.mil * 40.0
