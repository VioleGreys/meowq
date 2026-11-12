class_name AIPlanner
extends RefCounted
## Планирование: экономика страны ИИ и военные приказы для группы дивизий.
## plan()/plan_military() только ЧИТАЮТ мир и возвращают приказы — поэтому
## планы всех стран ИИ и всех армий игрока считаются параллельно, а
## применяются потом в главном потоке.
## Дивизии читаются из снимка (World.k_snapshot: плоские массивы dv_* и
## CSR pd_start/pd_list), а не из объектов: так потоки не дерутся за счётчики
## ссылок и масштабируются по ядрам. Приказы — [id дивизии, путь].


## Экономика страны ИИ (главный поток): сколько дивизий заказать, что строить,
## случайная война (только процедурный мир). Военный план — military_args/plan_job.
static func plan_economy(world: World, nid: int, rng: RandomNumberGenerator, mine: int) -> Dictionary:
	var nat: World.Nation = world.nations[nid]
	var result := {"train": 0, "build": nat.build_mode, "war": -1}
	if not nat.alive or nat.capitulated:
		return result
	var at_war := not nat.at_war.is_empty()

	# --- Экономика: сколько дивизий заказать (шаблоны выбираются в главном потоке)
	# потолок армии по населению; закон о призыве (бонус conscription) поднимает его
	var target_divs := target_divisions(nat)
	var pending := mine + nat.training.size()
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
	return result


## Сколько дивизий страна ИИ хочет держать: от заводов, не больше потолка
## по населению (закон о призыве — бонус conscription), на войне больше;
## условия будущих событий фокусов («армия больше в N раз») — prep_divs.
static func target_divisions(nat: World.Nation) -> int:
	var cap := (4.0 + nat.population * 1.3) * (1.0 + nat.b("conscription"))
	var t := int(minf(6.0 + nat.mil * 2.5 + nat.civ * 0.3, cap) * (1.4 if not nat.at_war.is_empty() else 1.0))
	return maxi(t, mini(nat.prep_divs, int(cap * 1.5)))


## Аргументы военного плана всех дивизий страны ИИ (главный поток).
static func nation_args(world: World, nid: int, mine: PackedInt32Array) -> Array:
	var nat: World.Nation = world.nations[nid]
	# осторожность наступления по идеологии: демократии атакуют только с большим перевесом
	var ratio := 1.3
	match nat.ideology:
		"democracy":
			ratio = 2.2
		"authoritarian":
			ratio = 1.7
	# черты с ключом caution — наступать только при большем перевесе
	ratio *= 1.0 + maxf(0.0, nat.b("caution"))
	return military_args(world, nid, mine, {"mode": "auto", "ratio": ratio})


## Аргументы plan_job из opts (главный поток): всё, что план читает у страны.
static func military_args(world: World, nid: int, divs: PackedInt32Array, opts: Dictionary) -> Array:
	var nat: World.Nation = world.nations[nid]
	var objective: int = opts.get("objective", -1)
	var allowed: Dictionary = opts.get("fronts", {})
	return [nid, divs, ["auto", "hold", "attack"].find(opts.get("mode", "auto")), int(opts.get("enemy", -1)), objective,
		PackedInt32Array(allowed.keys()), float(opts.get("ratio", 1.15 if objective >= 0 else 1.3)), nat.capital,
		PackedInt32Array(nat.at_war.keys())]


## Военный план (для тестов и разовых вызовов): таблицы берутся из мира сейчас.
static func plan_military(world: World, nid: int, divs: PackedInt32Array, opts: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	return plan_job(ai_tables(world), military_args(world, nid, divs, opts), rng)


## Военный план по готовым таблицам и аргументам. Читает только их — поэтому
## может считаться в рабочем потоке, пока главный поток продолжает день.
static func plan_job(t: Dictionary, args: Array, rng: RandomNumberGenerator) -> Dictionary:
	var native: Object = Native.core
	if native != null:
		# тот же алгоритм в C++ (native/src/ai.cpp)
		return native.call("plan_military", t, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], rng)
	return _plan(t, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], rng)


## Военный план для набора дивизий одной страны (индексы в снимке dv_*).
## mode: 0 — авто (ИИ: наступать, если идёт война), 1 — держать фронт, 2 — наступать;
## enemy — номер страны или -1 (все противники); objective — провинция-цель
## наступления (-1 — нет); allowed_list — допустимые провинции фронта (пусто —
## весь фронт); ratio — нужный перевес для атаки; enemies — с кем страна воюет.
## Возвращает {"orders": [[индекс в снимке (слот), путь]], "fronts": пары (наша, чужая)}.
static func _plan(tb: Dictionary, nid: int, divs: PackedInt32Array, mode_i: int, enemy: int, objective: int,
		allowed_list: PackedInt32Array, ratio: float, capital: int, enemies: PackedInt32Array,
		rng: RandomNumberGenerator) -> Dictionary:
	var result := {"orders": [], "fronts": PackedInt32Array()}
	# без литерала-массива: константы скрипта из потоков не читаем
	var mode := "auto"
	if mode_i == 1:
		mode = "hold"
	elif mode_i == 2:
		mode = "attack"
	var allowed := {}
	for p in allowed_list:
		allowed[p] = true

	# локальные ссылки на массивы мира — без конкуренции потоков за refcount
	var ctrl: PackedInt32Array = tb["ctrl"]
	var land: PackedByteArray = tb["land"]
	var a_start: PackedInt32Array = tb["adj_start"]
	var a_list: PackedInt32Array = tb["adj_list"]
	var war: PackedByteArray = tb["war"]
	var ally: PackedByteArray = tb["ally"]
	var nc: int = tb["nc"]
	var def_tab: PackedFloat32Array = tb["def"]
	var vp: PackedInt32Array = tb["vp"]
	var coastal: PackedByteArray = tb["coastal"]
	var owners: PackedInt32Array = tb["owner"]
	var dv_owner: PackedInt32Array = tb["dv_owner"]
	var dv_prov: PackedInt32Array = tb["dv_prov"]
	var dv_flags: PackedInt32Array = tb["dv_flags"]
	var dv_org: PackedFloat32Array = tb["dv_org"]
	var dv_power: PackedFloat32Array = tb["dv_power"]
	var dv_defw: PackedFloat32Array = tb["dv_defw"]
	var pd_start: PackedInt32Array = tb["pd_start"]
	var pd_list: PackedInt32Array = tb["pd_list"]
	var supcap: PackedFloat32Array = tb.get("supcap", PackedFloat32Array())
	var nohit: PackedByteArray = tb.get("nohit", PackedByteArray())
	var prov_count := land.size()
	var has_cap := supcap.size() == prov_count

	var at_war := false
	for e in enemies:
		if enemy < 0 or e == enemy or (ally.size() > 0 and ally[enemy * nc + e] == 1):
			at_war = true
			break
	var attack_allowed := at_war and (mode == "attack" or mode == "auto")

	# фронт: наши провинции у противника (или у выбранной страны до войны)
	var fronts := {}
	var targets := {}
	var fpairs := PackedInt32Array()
	for p in prov_count:
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
					if nohit.is_empty() or nohit[nid * nc + c] == 0:
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
		for p in prov_count:
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
	if objective >= 0:
		obj_dist.resize(prov_count)
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
	# направление главного удара: лучшие цели атаки (AXIS_N), к ним стягиваем силы
	var main_axis := {}
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
			# охват: цель, которую можно атаковать с нескольких наших участков, важнее
			var dirs := 0
			for k in range(a_start[t], a_start[t + 1]):
				if fronts.has(a_list[k]):
					dirs += 1
			if dirs > 1:
				score -= float(dirs - 1) * 15.0
			target_list.append([score, t, enemy_str * def_mult, dirs])
		# порядок однозначный (при равенстве — номер провинции): так же сортирует C++
		target_list.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		for j in mini(3, target_list.size()):
			main_axis[int(target_list[j][1])] = true
		var left := {}   # сколько наших дивизий останется в провинции
		for entry in target_list:
			var t: int = entry[1]
			var need: float = entry[2] * ratio
			# осторожная страна не лезет в пустую провинцию-выступ (котёл)
			if float(entry[2]) <= 0.0 and ratio >= 4.0 and int(entry[3]) < 2:
				continue
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
			group.sort_custom(func(a, b): return dv_power[a] > dv_power[b] or (dv_power[a] == dv_power[b] and a < b))
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
					orders.append([i, PackedInt32Array([t])])
			else:
				for i in chosen:
					left[dv_prov[i]] = int(left[dv_prov[i]]) + 1

	# Ротация: измотанные дивизии (организация < 30 %) на передовой отходят на
	# соседнюю тыловую провинцию, если на участке остаётся кто-то из наших.
	var rotated: Array = []
	var ours_left := {}
	if at_war:
		for i in idle:
			if used.has(i) or dv_org[i] >= 0.3:
				continue
			var pv := dv_prov[i]
			if not fronts.has(pv):
				continue
			if not ours_left.has(pv):
				var cnt := 0
				for m in range(pd_start[pv], pd_start[pv + 1]):
					if dv_owner[pd_list[m]] == nid:
						cnt += 1
				ours_left[pv] = cnt
			if int(ours_left[pv]) <= 1:
				continue
			var rear := -1
			for k in range(a_start[pv], a_start[pv + 1]):
				var q := a_list[k]
				if land[q] == 1 and ctrl[q] == nid and not fronts.has(q):
					rear = q
					break
			if rear < 0:
				continue
			used[i] = true
			ours_left[pv] = int(ours_left[pv]) - 1
			rotated.append(i)
			orders.append([i, PackedInt32Array([rear])])

	# Остальных распределяем по фронту: больше — туда, где больше противника.
	var per_front := {}
	for i in divs:
		var pv := dv_prov[i]
		if dv_flags[i] & 4 == 0 and fronts.has(pv):
			per_front[pv] = int(per_front.get(pv, 0)) + 1
	for i in rotated:
		per_front[dv_prov[i]] = int(per_front.get(dv_prov[i], 0)) - 1
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
		# участки у направления главного удара — плотнее (в пределах снабжения)
		if not main_axis.is_empty():
			for k in range(a_start[f], a_start[f + 1]):
				if main_axis.has(a_list[k]):
					weight[f] = float(weight[f]) + 3.0
					break
		wsum += weight[f]
	var desired := {}
	for f in fronts:
		desired[f] = maxi(1, int(round(divs.size() * weight[f] / wsum)))
		# не больше, чем провинция прокормит (снабжение по узлам районов)
		if has_cap:
			desired[f] = mini(int(desired[f]), maxi(1, int(floor(supcap[f]))))
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
		var path := _nearest(tb, nid, pv, goal)
		if path.is_empty():
			continue
		var dest := path[path.size() - 1]
		per_front[dest] = int(per_front.get(dest, 0)) + 1
		if fronts.has(pv):
			per_front[pv] = int(per_front.get(pv, 0)) - 1
		used[i] = true
		orders.append([i, path])
	# Перегруз: лишние дивизии из провинции фронта, которую снабжение не тянет,
	# отходят во вторую линию — ближайшую нашу провинцию у фронта с запасом снабжения.
	if has_cap:
		var reserve := {}
		var rcount := {}
		for f in fronts:
			for k in range(a_start[f], a_start[f + 1]):
				var q := a_list[k]
				if land[q] == 1 and ctrl[q] == nid and not fronts.has(q) and not reserve.has(q):
					reserve[q] = true
					var cnt := 0
					for m in range(pd_start[q], pd_start[q + 1]):
						if dv_owner[pd_list[m]] == nid:
							cnt += 1
					rcount[q] = cnt
		for i in idle:
			if used.has(i):
				continue
			var pv := dv_prov[i]
			if not fronts.has(pv) or int(per_front.get(pv, 0)) <= maxi(1, int(floor(supcap[pv]))):
				continue
			var goal := {}
			for q in reserve:
				if int(rcount[q]) < maxi(1, int(floor(supcap[q]))):
					goal[q] = true
			if goal.is_empty():
				break
			var path := _nearest(tb, nid, pv, goal)
			if path.is_empty():
				continue
			var dest := path[path.size() - 1]
			rcount[dest] = int(rcount[dest]) + 1
			per_front[pv] = int(per_front.get(pv, 0)) - 1
			used[i] = true
			orders.append([i, path])
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


## Таблицы мира для нативного планировщика (одни на всю пачку заданий ИИ).
static func ai_tables(world: World) -> Dictionary:
	return {"ctrl": world.p_controller, "land": world.p_land, "adj_start": world.adj_start, "adj_list": world.adj_list,
		"war": world.war, "ally": world.ally, "nc": world.nation_count, "def": world.p_def_mult, "vp": world.vp_ai(),
		"coastal": world.p_coastal, "owner": world.p_owner, "dv_id": world.dv_id, "dv_owner": world.dv_owner,
		"dv_prov": world.dv_prov, "dv_flags": world.dv_flags, "dv_org": world.dv_org, "dv_power": world.dv_power,
		"dv_defw": world.dv_defw, "pd_start": world.pd_start, "pd_list": world.pd_list, "supcap": world.p_supcap,
		"nohit": no_attack_table(world)}


## Пары «воюем, но ИИ не наступает» (Nation.no_attack, только у ИИ): nc×nc;
## пусто — запретов нет.
static func no_attack_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	var nc := world.nation_count
	for nat in world.nations:
		if nat.no_attack.is_empty() or nat.is_player:
			continue
		if t.is_empty():
			t.resize(nc * nc)
		for o in nat.no_attack:
			t[nat.id * nc + int(o)] = 1
	return t


## Путь к ближайшей провинции из goal по таблицам (как Pathfinder.nearest_goal).
static func _nearest(t: Dictionary, nation: int, from: int, goal: Dictionary) -> PackedInt32Array:
	if goal.has(from):
		return PackedInt32Array()
	var land: PackedByteArray = t["land"]
	var ctrl: PackedInt32Array = t["ctrl"]
	var war: PackedByteArray = t["war"]
	var nc: int = t["nc"]
	var a_start: PackedInt32Array = t["adj_start"]
	var a_list: PackedInt32Array = t["adj_list"]
	var parent := PackedInt32Array()
	parent.resize(land.size())
	parent.fill(-1)
	parent[from] = from
	var queue := PackedInt32Array([from])
	var head := 0
	var found := -1
	while head < queue.size():
		var p := queue[head]
		head += 1
		if goal.has(p):
			found = p
			break
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if parent[q] >= 0 or land[q] == 0:
				continue
			var c := ctrl[q]
			if c != nation and (c < 0 or war[nation * nc + c] == 0):
				continue
			parent[q] = p
			queue.append(q)
	if found < 0:
		return PackedInt32Array()
	var path := PackedInt32Array()
	var cur := found
	while cur != from:
		path.append(cur)
		cur = parent[cur]
	path.reverse()
	return path
