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
	# (перевес — настоящий, оценка сил как в бою; прежние 1,3 / 1,7 / 2,2 были под
	# оценку без обороны и окопов защитника)
	var ratio := 1.2
	match nat.ideology:
		"democracy":
			ratio = 1.8
		"authoritarian":
			ratio = 1.4
	# черты с ключом caution — наступать только при большем перевесе
	ratio *= 1.0 + maxf(0.0, nat.b("caution"))
	var opts := {"mode": "auto", "ratio": ratio}
	# план наступления: цели атаки ближе к текущей вехе — первыми, у направления
	# удара — больше дивизий (Simulation._offensive_step двигает вехи)
	var obj := offensive_objective(world, nat)
	if obj >= 0:
		opts["objective"] = obj
	var lim := war_limit_fronts(world, nat)
	if not lim.is_empty():
		opts["fronts"] = lim
	return military_args(world, nid, mine, opts)


## Рубеж операций (эффект war_limit: [код страны Natural Earth, рамки [запад,
## юг, восток, север]]): фронт ИИ — все наши провинции, кроме взятых на этих
## землях вне рамок (Ставка ограничивала японские операции в Китае районами:
## 1937 г. — Северный Китай и низовья Янцзы, 1938-й — до Уханя и Кантон).
## Цель атаки — у допустимого участка, так что за рамку фронт заходит не
## дальше чем на провинцию. Пусто — ограничения нет.
static func war_limit_fronts(world: World, nat: World.Nation) -> Dictionary:
	if nat.war_limit.is_empty():
		return {}
	var code: String = nat.war_limit[0]
	var boxes: Array = nat.war_limit[1]
	var out := {}
	var ctrl := world.p_controller
	var land := world.p_land
	for p in world.prov_count:
		if ctrl[p] != nat.id or land[p] == 0:
			continue
		if world.p_adm0[p] == code:
			var ll: Vector2 = world.p_lonlat[p]
			var inside := false
			for b in boxes:
				if ll.x >= float(b[0]) and ll.y >= float(b[1]) and ll.x <= float(b[2]) and ll.y <= float(b[3]):
					inside = true
					break
			if not inside:
				continue
		out[p] = true
	return out


## Текущая веха плана наступления страны (-1 — плана нет или война с целью не идёт).
static func offensive_objective(world: World, nat: World.Nation) -> int:
	if nat.offensive.is_empty():
		return -1
	var tgt: int = nat.offensive[0]
	if not world.is_at_war(nat.id, tgt):
		return -1
	var route: PackedInt32Array = nat.offensive[1]
	var i: int = nat.offensive[2]
	return route[i] if i < route.size() else -1


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
	var atklim: PackedByteArray = tb.get("atklim", PackedByteArray())
	var atk_base := nid * prov_count if atklim.size() == nc * prov_count else -1
	var holdt: PackedByteArray = tb.get("hold", PackedByteArray())
	var hold_base := nid * prov_count if holdt.size() == nc * prov_count else -1
	var has_cap := supcap.size() == prov_count
	# снабжение дивизий и климат (акклиматизация страны) — для выбора целей атаки
	var dv_sup: PackedFloat64Array = tb.get("dv_sup", PackedFloat64Array())
	var has_sup := dv_sup.size() == dv_owner.size()
	var p_hot: PackedFloat32Array = tb.get("p_hot", PackedFloat32Array())
	var p_cold: PackedFloat32Array = tb.get("p_cold", PackedFloat32Array())
	var n_hot: PackedFloat64Array = tb.get("n_hot", PackedFloat64Array())
	var n_cold: PackedFloat64Array = tb.get("n_cold", PackedFloat64Array())
	var has_clim := p_hot.size() == prov_count and p_cold.size() == prov_count and n_hot.size() > nid and n_cold.size() > nid

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
	# союзная провинция у нашего врага — тоже участок нашего фронта (бой на союзной
	# земле, как в жанре); дивизий туда — лишь сколько союзник сам не закрывает
	# (угроза минус его дивизии на участке): Германия помогает Италии и на Балканах,
	# а не подпирает всей массой Румынию (иначе СССР падал в 1942 г.)
	var ally_front := {}
	for p in prov_count:
		var own_p := ctrl[p] == nid
		if not own_p and not (at_war and ctrl[p] >= 0 and ally.size() > 0 and ally[nid * nc + ctrl[p]] == 1):
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
					if not own_p:
						ally_front[p] = true
					if (nohit.is_empty() or nohit[nid * nc + c] == 0) and (atk_base < 0 or atklim[atk_base + q] == 0):
						targets[q] = true
					fpairs.append(p)
					fpairs.append(q)
			elif own_p and matches and (enemy >= 0 or mode == "auto") and (ally.size() == 0 or ally[nid * nc + c] == 0):
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
			var pocketed := 0
			for k in range(pd_start[t], pd_start[t + 1]):
				var e := pd_list[k]
				var eo := dv_owner[e]
				if eo != nid and war[nid * nc + eo] == 1:
					# снабжение врага: голодающие и окружённые слабее (как в бою)
					var es := 1.0
					if has_sup:
						es = _sup_mult(dv_sup[e])
						if dv_sup[e] < SUP_EXH:
							pocketed += 1
					enemy_str += dv_defw[e] * es
			# местность и укрепления — как в бою: атака × (1 − 0,6 × оборона провинции)
			var def_mult: float = 1.0 / maxf(0.1, 1.0 - 0.6 * def_tab[t])
			# климат: неакклиматизированные атакуют слабее — нужен больший перевес
			var clim := 0.0
			if has_clim:
				clim = minf(1.0, p_hot[t] * (1.0 - minf(1.0, n_hot[nid])) + p_cold[t] * (1.0 - minf(1.0, n_cold[nid])))
			var climf := 1.0 - CLIM_ATK * clim
			var score: float = enemy_str * def_mult * SCORE_STR - vp[t] * 6.0 + rng.randf() * 20.0 + clim * 30.0 - float(pocketed) * 12.0
			if objective >= 0:
				score += obj_dist[t] * 25.0
			# охват: цель, которую можно атаковать с нескольких наших участков, важнее
			var dirs := 0
			var hostile_n := 0
			var closing := 0
			var sup_sum := 0.0
			var sup_n := 0
			for k in range(a_start[t], a_start[t + 1]):
				var q := a_list[k]
				if fronts.has(q):
					dirs += 1
					if has_sup:
						for m in range(pd_start[q], pd_start[q + 1]):
							if dv_owner[pd_list[m]] == nid:
								sup_sum += dv_sup[pd_list[m]]
								sup_n += 1
				elif land[q] == 1 and ctrl[q] >= 0 and war[nid * nc + ctrl[q]] == 1:
					hostile_n += 1
					# котёл: взяв t, замкнём кольцо вокруг вражеской провинции q
					var open := 0
					for m in range(a_start[q], a_start[q + 1]):
						var r := a_list[m]
						if r != t and land[r] == 1 and ctrl[r] >= 0 and war[nid * nc + ctrl[r]] == 1:
							open += 1
					if open == 0:
						closing += 1
			# помощь соседнему бою: враг в цели уже ведёт бой с нами (атакует наш участок
			# или обороняется от нашей атаки) — удар туда важнее
			var engaged := false
			for k in range(pd_start[t], pd_start[t + 1]):
				var e2 := pd_list[k]
				if dv_owner[e2] != nid and war[nid * nc + dv_owner[e2]] == 1 and dv_flags[e2] & 2 != 0:
					engaged = true
					break
			if engaged:
				score -= SUPPORT_BONUS
			if dirs > 1:
				score -= float(dirs - 1) * 15.0
			score -= float(closing) * 25.0
			# удар — со снабжённых участков
			if sup_n > 0:
				score += (1.0 - minf(1.0, sup_sum / float(sup_n))) * 40.0
			# выступ: цель окружена врагом, а бьём с одной стороны — риск котла
			var risk := 1.0
			if dirs == 1 and hostile_n >= 3:
				score += float(hostile_n - 2) * 15.0
				risk = 1.3
			target_list.append([score, t, enemy_str * def_mult * risk / climf, dirs])
		# порядок однозначный (при равенстве — номер провинции): так же сортирует C++
		target_list.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		for j in mini(3, target_list.size()):
			main_axis[int(target_list[j][1])] = true
		var left := {}   # сколько наших дивизий останется в провинции
		for entry in target_list:
			var t: int = entry[1]
			var need: float = entry[2] * ratio
			# направление главного удара к цели наступления — сил с запасом (AXIS_COMMIT)
			var commit: float = need * AXIS_COMMIT if objective >= 0 and main_axis.has(t) else need
			# осторожная страна не лезет в пустую провинцию-выступ (котёл)
			if float(entry[2]) <= 0.0 and ratio >= 4.0 and int(entry[3]) < 2:
				continue
			var breach := objective >= 0 and float(entry[2]) <= 0.0 and main_axis.has(t)
			var group: Array = []
			for k in range(a_start[t], a_start[t + 1]):
				var q := a_list[k]
				for m in range(pd_start[q], pd_start[q + 1]):
					var i := pd_list[m]
					# истощённые (снабжение < SUP_EXH) в атаку не идут (решение пользователя)
					if dv_owner[i] == nid and in_group.has(i) and dv_flags[i] & 1 == 1 \
							and not used.has(i) and dv_org[i] > 0.6 and (not has_sup or dv_sup[i] >= SUP_EXH):
						group.append(i)
			if group.is_empty():
				continue
			# плохое снабжение группы (в среднем < SUP_BAD) — атака лишь с двойным перевесом
			if has_sup:
				var gs := 0.0
				for i in group:
					gs += dv_sup[i]
				if gs / float(group.size()) < SUP_BAD:
					need *= LOW_SUP_RATIO
					commit = maxf(commit, need)
			# сильнейшие первыми; берём ровно столько, сколько нужно (на пустую — одну)
			group.sort_custom(func(a, b): return dv_power[a] > dv_power[b] or (dv_power[a] == dv_power[b] and a < b))
			var chosen: Array = []
			var power := 0.0
			for i in group:
				var pv := dv_prov[i]
				if not left.has(pv):
					left[pv] = pd_start[pv + 1] - pd_start[pv]
				# последняя дивизия участок не бросает — кроме прорыва: пустая провинция на
				# направлении удара к цели наступления (участок заполнится в следующий раз)
				if int(left[pv]) <= 1 and not (breach and int(left[pv]) == 1):
					continue
				chosen.append(i)
				left[pv] = int(left[pv]) - 1
				power += dv_power[i]
				if power > commit and (entry[2] <= 0.0 or chosen.size() >= 2):
					break
			if power > need and not chosen.is_empty():
				for i in chosen:
					used[i] = true
					orders.append([i, PackedInt32Array([t])])
			else:
				for i in chosen:
					left[dv_prov[i]] = int(left[dv_prov[i]]) + 1

	# Отход с передовой (решение пользователя; так же ai.cpp): организация <
	# REGROUP_ORG (10 %) — в соседний тыл, даже последняя на участке, и на фронт не
	# идёт, пока не восстановится; < ROTATE_ORG (30 %) — ротация, если на участке
	# остаётся кто-то из наших (смена на марше восстанавливает организацию);
	# резерв, ещё не вызванный в бой (не «в бою»), уходит из провинции, которую не
	# удержать: атакующих сильнее обороны в ESCAPE_RATIO раз.
	var rotated: Array = []
	var ours_left := {}
	var hopeless := {}
	if at_war:
		for i in idle:
			if used.has(i):
				continue
			var pv := dv_prov[i]
			if not fronts.has(pv):
				continue
			var o: float = dv_org[i]
			if not ours_left.has(pv):
				var cnt := 0
				for m in range(pd_start[pv], pd_start[pv + 1]):
					if dv_owner[pd_list[m]] == nid:
						cnt += 1
				ours_left[pv] = cnt
			var go := false
			if o < REGROUP_ORG:
				go = true
			elif o < ROTATE_ORG:
				go = int(ours_left[pv]) > 1
			else:
				if not hopeless.has(pv):
					hopeless[pv] = _hopeless(tb, nid, pv)
				go = hopeless[pv]
			if not go:
				continue
			var rear := -1
			for k in range(a_start[pv], a_start[pv + 1]):
				var q := a_list[k]
				if land[q] == 1 and (ctrl[q] == nid or (ctrl[q] >= 0 and ally.size() > 0 and ally[nid * nc + ctrl[q]] == 1)) and not fronts.has(q):
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
	var ally_need := {}
	var wsum := 0.0
	var axis_front := {}   # к цели наступления: участки главного удара — до ёмкости снабжения
	for f in fronts:
		var threat := 0.0
		for k in range(a_start[f], a_start[f + 1]):
			var q := a_list[k]
			for m in range(pd_start[q], pd_start[q + 1]):
				var eo := dv_owner[pd_list[m]]
				if eo != nid and (ally.size() == 0 or ally[nid * nc + eo] == 0):
					threat += 1.0 if war[nid * nc + eo] == 1 or not at_war else 0.3
		if ally_front.has(f):
			# союзный участок — вне общего раздела армии: нужда = угроза − дивизии союзников
			var allyc := 0
			for m in range(pd_start[f], pd_start[f + 1]):
				var o2 := dv_owner[pd_list[m]]
				if o2 != nid and ally.size() > 0 and ally[nid * nc + o2] == 1:
					allyc += 1
			ally_need[f] = threat - float(allyc)
			weight[f] = 0.0
			continue
		weight[f] = 1.0 + threat + vp[f] * 0.15   # крупные города держим плотнее
		# участки у направления главного удара — плотнее (в пределах снабжения)
		if not main_axis.is_empty():
			for k in range(a_start[f], a_start[f + 1]):
				if main_axis.has(a_list[k]):
					weight[f] = float(weight[f]) + 3.0
					if objective >= 0:
						axis_front[f] = true
					break
		wsum += weight[f]
	var desired := {}
	# план наступления: участкам главного удара — до ёмкости снабжения, прочим —
	# остаток армии (их лишние дивизии уходят к удару)
	var pool := divs.size()
	if has_cap and not axis_front.is_empty():
		for f in axis_front:
			pool -= maxi(1, int(floor(supcap[f])))
		pool = maxi(0, pool)
	for f in fronts:
		if ally_front.has(f):
			desired[f] = maxi(0, int(ceil(float(ally_need[f]))))
			if has_cap:
				desired[f] = mini(int(desired[f]), maxi(1, int(floor(supcap[f]))))
			continue
		desired[f] = maxi(1, int(round(pool * weight[f] / wsum))) if wsum > 0.0 else 1
		# не больше, чем провинция прокормит (снабжение по узлам районов)
		if has_cap:
			desired[f] = mini(int(desired[f]), maxi(1, int(floor(supcap[f]))))
			# план наступления: участки главного удара заполняем до ёмкости снабжения
			if axis_front.has(f):
				desired[f] = maxi(1, int(floor(supcap[f])))
		# гарнизон (эффект hold): не меньше заданного, и сверх ёмкости снабжения
		if hold_base >= 0 and holdt[hold_base + f] > 0:
			desired[f] = maxi(int(desired[f]), int(holdt[hold_base + f]))
	# Пустой участок фронта (в том числе оставленный уходящей дивизией): туда идёт
	# ближайшая свободная дивизия — из тыла или лишняя на участке сверх нужного;
	# поиск по своей земле на FILL_DEPTH переходов (решение пользователя).
	if at_war:
		for f in fronts:
			if int(per_front.get(f, 0)) > 0 or ally_front.has(f):
				continue
			var fpar := {f: -1}
			var fdep := {f: 0}
			var fq: Array = [f]
			var head := 0
			var found := -1
			var fdiv := -1
			while head < fq.size():
				var x: int = fq[head]
				head += 1
				if x != f:
					var spare: bool = not fronts.has(x) or int(per_front.get(x, 0)) > maxi(1, int(desired[x]))
					if spare:
						for m in range(pd_start[x], pd_start[x + 1]):
							var i := pd_list[m]
							if dv_owner[i] == nid and in_group.has(i) and dv_flags[i] & 1 == 1 and not used.has(i) and dv_org[i] >= REGROUP_ORG:
								fdiv = i
								break
					if fdiv >= 0:
						found = x
						break
				if int(fdep[x]) >= FILL_DEPTH:
					continue
				for k in range(a_start[x], a_start[x + 1]):
					var y := a_list[k]
					if fpar.has(y) or land[y] == 0 or (ctrl[y] != nid and (ctrl[y] < 0 or ally.size() == 0 or ally[nid * nc + ctrl[y]] == 0)):
						continue
					fpar[y] = x
					fdep[y] = int(fdep[x]) + 1
					fq.append(y)
			if fdiv < 0:
				continue
			var path := PackedInt32Array()
			var cur: int = fpar[found]
			while cur != -1:
				path.append(cur)
				cur = fpar[cur]
			used[fdiv] = true
			orders.append([fdiv, path])
			per_front[f] = 1
			if fronts.has(found):
				per_front[found] = int(per_front.get(found, 0)) - 1
	for i in idle:
		if used.has(i):
			continue
		if dv_org[i] < REGROUP_ORG:
			continue   # перегруппировка — на фронт не идёт
		var pv := dv_prov[i]
		if fronts.has(pv) and int(per_front.get(pv, 0)) <= int(desired[pv]) + 1:
			continue
		var goal := {}
		# план наступления: пока участки удара не заполнены — только к ним
		for f in axis_front:
			if int(per_front.get(f, 0)) < int(desired[f]) and f != pv:
				goal[f] = true
		if goal.is_empty():
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
	# отходят в ближайшую нашу тыловую провинцию с запасом снабжения (сначала —
	# вторая линия у фронта; заполнена — глубже: иначе сотни дивизий стоят в
	# одной провинции без снабжения, как СССР осенью 1941 г.).
	if has_cap:
		var reserve := {}
		var rcount := {}
		for q in prov_count:
			if land[q] == 1 and ctrl[q] == nid and not fronts.has(q):
				reserve[q] = true
				var cnt := 0
				for m in range(pd_start[q], pd_start[q + 1]):
					if dv_owner[pd_list[m]] == nid:
						cnt += 1
				rcount[q] = cnt
		# цели — тыловые провинции с запасом; заполненная выбывает
		var goal := {}
		for q in reserve:
			if int(rcount[q]) < maxi(1, int(floor(supcap[q]))):
				goal[q] = true
		for i in idle:
			if used.has(i):
				continue
			var pv := dv_prov[i]
			var cap_pv := maxi(1, int(floor(supcap[pv])))
			# фронт — по счёту участка; тыл — по числу наших дивизий в провинции
			if (fronts.has(pv) and int(per_front.get(pv, 0)) <= cap_pv) or (not fronts.has(pv) and (not reserve.has(pv) or int(rcount[pv]) <= cap_pv)):
				continue
			if goal.is_empty():
				break
			var path := _nearest(tb, nid, pv, goal)
			if path.is_empty():
				continue
			var dest := path[path.size() - 1]
			rcount[dest] = int(rcount[dest]) + 1
			if int(rcount[dest]) >= maxi(1, int(floor(supcap[dest]))):
				goal.erase(dest)
			if fronts.has(pv):
				per_front[pv] = int(per_front.get(pv, 0)) - 1
			else:
				rcount[pv] = int(rcount[pv]) - 1
				if int(rcount[pv]) < cap_pv:
					goal[pv] = true
			used[i] = true
			orders.append([i, path])
	result["orders"] = orders
	return result


const SUP_BAD := 0.5     # как World.SUP_BAD / SUP_EXH (константы скрипта мира из потоков не читаем)
const SUP_EXH := 0.25
const CLIM_ATK := 0.25   # как Climate: атака × (1 − 0,25 × неакклиматизированность)
const REGROUP_ORG := 0.1    # ниже — с фронта в тыл (даже последняя) и не на фронт (решение пользователя)
const ROTATE_ORG := 0.3     # ниже — ротация, если на участке остаётся кто-то из наших
const ESCAPE_RATIO := 3.0   # резерв уходит, если атакующих сильнее обороны во столько раз
const FILL_DEPTH := 6        # пустой участок фронта: свободную дивизию ищем на столько переходов
const SUPPORT_BONUS := 20.0 # цель, где враг уже ведёт бой с нами, — важнее
const LOW_SUP_RATIO := 2.0  # перевес для атаки группой с плохим снабжением (решение пользователя)
const SCORE_STR := 5.0  # сила обороны в очереди целей (оценка — в единицах боя, веса очереди — прежние)
const AXIS_COMMIT := 2.0 # к цели наступления (план, группа с целью): на лучшие цели — вдвое больше нужного


## Провинция, которую не удержать: наши в ней уже в бою, а сила атакующих (враги
## в бою в соседних провинциях) больше обороны (с местностью) в ESCAPE_RATIO раз.
static func _hopeless(tb: Dictionary, nid: int, pv: int) -> bool:
	var pd_start: PackedInt32Array = tb["pd_start"]
	var pd_list: PackedInt32Array = tb["pd_list"]
	var dv_owner: PackedInt32Array = tb["dv_owner"]
	var dv_flags: PackedInt32Array = tb["dv_flags"]
	var dv_defw: PackedFloat32Array = tb["dv_defw"]
	var dv_power: PackedFloat32Array = tb["dv_power"]
	var a_start: PackedInt32Array = tb["adj_start"]
	var a_list: PackedInt32Array = tb["adj_list"]
	var war: PackedByteArray = tb["war"]
	var def_tab: PackedFloat32Array = tb["def"]
	var nc: int = tb["nc"]
	var fighting := false
	var ours := 0.0
	for m in range(pd_start[pv], pd_start[pv + 1]):
		var e := pd_list[m]
		if dv_owner[e] != nid:
			continue
		if dv_flags[e] & 2 != 0:
			fighting = true
		ours += dv_defw[e]
	var theirs := 0.0
	if fighting:
		for k in range(a_start[pv], a_start[pv + 1]):
			var q := a_list[k]
			for m in range(pd_start[q], pd_start[q + 1]):
				var e := pd_list[m]
				var eo := dv_owner[e]
				if eo != nid and war[nid * nc + eo] == 1 and dv_flags[e] & 2 != 0:
					theirs += dv_power[e]
	var dm: float = 1.0 / maxf(0.1, 1.0 - 0.6 * def_tab[pv])
	return fighting and theirs > ESCAPE_RATIO * ours * dm


static func _sup_mult(sv: float) -> float:
	return 1.0 if sv >= SUP_BAD else (0.75 if sv >= SUP_EXH else 0.5)


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
		"war": world.war, "ally": world.ally, "pass": world.pass_table(), "nc": world.nation_count, "def": world.p_def_mult, "vp": world.vp_ai(),
		"coastal": world.p_coastal, "owner": world.p_owner, "dv_id": world.dv_id, "dv_owner": world.dv_owner,
		"dv_prov": world.dv_prov, "dv_flags": world.dv_flags, "dv_org": world.dv_org, "dv_power": world.dv_power,
		"dv_defw": world.dv_defw, "pd_start": world.pd_start, "pd_list": world.pd_list, "supcap": world.p_supcap,
		"nohit": no_attack_table(world), "atklim": attack_limit_table(world), "hold": hold_table(world), "dv_sup": world.d_sup, "p_hot": world.p_hot, "p_cold": world.p_cold,
		"n_hot": world.n_hot, "n_cold": world.n_cold}


## Провинции, которые ИИ страны не атакует (эффект attack_limit: земли adm0 вне
## рамок; и рубеж операций war_limit — чтобы не обойти его с соседней земли, как
## Япония из Индокитая на Куньмин): nc×prov_count, 1 — не цель; пусто — запретов
## нет. Фронт там держится.
static func attack_limit_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	var pc := world.prov_count
	for nat in world.nations:
		if nat.is_player or not nat.alive:
			continue
		var lims: Array = []
		if not nat.attack_limit.is_empty():
			lims.append(nat.attack_limit)
		if not nat.war_limit.is_empty():
			lims.append([[nat.war_limit[0]], nat.war_limit[1], []])
		if not lims.is_empty() and t.is_empty():
			t.resize(world.nation_count * pc)
		for lim in lims:
			_attack_limit_fill(world, t, nat.id, lim)
	return t


static func _attack_limit_fill(world: World, t: PackedByteArray, nid: int, lim: Array) -> void:
	var pc := world.prov_count
	var codes: Array = lim[0]
	var boxes: Array = lim[1]
	var excl: Array = lim[2] if lim.size() > 2 else []
	var base: int = nid * pc
	for p in pc:
		if not codes.has(world.p_adm0[p]):
			continue
		var ll: Vector2 = world.p_lonlat[p]
		var inside := boxes.is_empty()
		for b in boxes:
			if ll.x >= float(b[0]) and ll.y >= float(b[1]) and ll.x <= float(b[2]) and ll.y <= float(b[3]):
				inside = true
				break
		# except — не атаковать и внутри рамок (Ленинград: блокада, а не штурм)
		for b in excl:
			if ll.x >= float(b[0]) and ll.y >= float(b[1]) and ll.x <= float(b[2]) and ll.y <= float(b[3]):
				inside = false
				break
		if not inside:
			t[base + p] = 1


## Гарнизоны (Nation.hold): nc×prov_count — не меньше дивизий на участке фронта;
## пусто — гарнизонов нет.
static func hold_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	var pc := world.prov_count
	for nat in world.nations:
		if nat.hold.is_empty() or nat.is_player or not nat.alive:
			continue
		if t.is_empty():
			t.resize(world.nation_count * pc)
		for hp in nat.hold:
			t[nat.id * pc + int(hp)] = clampi(int(nat.hold[hp]), 0, 255)
	return t


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
	var war: PackedByteArray = t.get("pass", t["war"])   # можно войти: своя, союзная (вражеская — ниже)
	var hostile: PackedByteArray = t["war"]   # через вражескую — нет: переброска не захват (пустую Тулу брали в обход attack_limit)
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
			if c != nation and (c < 0 or war[nation * nc + c] == 0 or hostile[nation * nc + c] == 1):
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
