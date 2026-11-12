class_name Simulation
extends RefCounted
## Дневной тик. Каждая тяжёлая фаза устроена как «параллельно посчитать ->
## последовательно применить», поэтому результат детерминирован и не зависит
## от числа ядер, а сама работа распределяется по WorkerThreadPool.

const FACTORY_COST := 60.0
const BUILD_RATE := 0.05      # очков стройки в день на гражданскую фабрику
const MAX_FACTORIES := 12
const AI_PERIOD := 3
# Планирование наступления (как в жанре): стоящая на фронте или у будущего фронта
# дивизия копит план (полный — за 20 дней), в наступлении он тает за ~2 недели,
# в тылу — за 2 месяца; полный план — +30 % к атаке.
const PLAN_MAX := 0.3
const PLAN_GAIN := 0.05
const PLAN_ACTIVE := 0.07
const PLAN_REAR := 0.016

var world: World
var last_tick_usec := 0
var phase_usec := {}
var land_totals: Array = []   # Military.land_totals — для пересмотра заводов, раз в 10 дней
var land_totals_day := -100


## fresh = false — мир восстановлен из сохранения (SaveGame): стартовые
## пересчёты не нужны и изменили бы состояние.
func _init(w: World, fresh := true) -> void:
	Native.init()
	world = w
	if not fresh:
		return
	if "--supply=old" in OS.get_cmdline_user_args():
		world.supply_regions = false   # прежняя модель (по удалённости от узлов) — для сравнения
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
	Occupation.adjust_income(world, all)
	Puppets.adjust_income(world, all)
	for nat in world.nations:
		var r: Array = all[nat.id]
		nat.civ = r[0]
		nat.mil = r[1]
		nat.province_count = r[3]
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))


func tick() -> void:
	# события игрока не останавливают ход: пауза ставится при их приходе (main.gd),
	# без ответа в срок вариант выбирается сам (History._answer_overdue)
	if world.game_over != "" or not world.pending_peace.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	world.day += 1
	world.refresh_def_mult()   # зима и укрепления (раз в месяц)
	world.vp_ai()              # таблица очков для ИИ — до фоновых задач
	_timed("подготовка", func():
		var _pt := Time.get_ticks_usec()
		world.rebuild_prov_divs()
		Prof.add("подг:prov_divs", _pt)
		_pt = Time.get_ticks_usec()
		world.refresh_stats()
		Prof.add("подг:refresh_stats", _pt)
		_pt = Time.get_ticks_usec()
		# характеристики дивизий меняются только с новыми технологиями
		var dirty := false
		for nat in world.nations:
			dirty = dirty or nat.stats_dirty
		if dirty:
			# с наукой по слотам «грязные» страны есть почти каждый день —
			# владельца смотрим по плоскому массиву, без обёрток дивизии
			var dn := PackedByteArray()
			dn.resize(world.nation_count)
			for nat in world.nations:
				dn[nat.id] = 1 if nat.stats_dirty else 0
			var own := world.d_owner
			var divs := world.divisions
			for i in divs.size():
				if dn[own[i]] == 1:
					Military.refresh_division(world, divs[i])
		for nat in world.nations:
			nat.stats_dirty = false
		Prof.add("подг:дивизии", _pt)
		_pt = Time.get_ticks_usec()
		_refresh_sides()
		Prof.add("подг:стороны", _pt))
	_timed("политика", Politics.daily.bind(world))
	_timed("оккупация", Occupation.daily.bind(world))
	_timed("экономика", _phase_economy)
	_timed("флот", _phase_navy)
	# авиация конвейером: снимок и расчёт районов в фоне сейчас, применение —
	# перед сухопутными боями (им нужны превосходство и поправки этого дня)
	_timed("авиация:старт", Forces.air_begin.bind(world))
	_timed("снабжение", _phase_supply)
	_timed("ИИ", _phase_ai)
	# в фоне, вместе с планами ИИ, — упреждающие расчёты на завтра (Spec)
	_timed("упреждение", Spec.start.bind(world))
	_timed("авиация", Forces.air_finish.bind(world, Parallel.rng(world.seed_value, world.day, 6001)))
	var battles := {}
	_timed("климат", Climate.daily.bind(world))
	_timed("сбор боёв", func(): battles.merge(_collect_battles()))
	_timed("движение", _phase_movement.bind(battles))
	_timed("бои", _phase_combat.bind(battles))
	_timed("восстановление", _phase_recovery)
	_timed("планирование", _phase_planning)
	_timed("дипломатия", _phase_diplomacy)
	_timed("капитуляции", _check_capitulation)
	_timed("мир", func(): Peace.check_end(world))
	_timed("ИИ:ожидание", _finish_ai)
	# доктрины ИИ — когда фоновых задач уже нет (меняют бонусы стран)
	Doctrine.ai_daily(world)
	last_tick_usec = Time.get_ticks_usec() - t0


func _timed(label: String, fn: Callable) -> void:
	var t := Time.get_ticks_usec()
	fn.call()
	phase_usec[label] = Time.get_ticks_usec() - t


# --- Экономика: доход каждой страны считается в отдельной задаче ------------

func _phase_economy() -> void:
	var n_count := world.nations.size()
	# один проход по всем провинциям дешевле, чем по проходу на каждую страну
	var _pt := Time.get_ticks_usec()
	var results := world.compute_all_income()
	Occupation.adjust_income(world, results)   # отдача чужих земель по законам
	Puppets.adjust_income(world, results)      # отчисления марионеток сюзерену
	Prof.add("эк:доход", _pt)

	_pt = Time.get_ticks_usec()
	Economy.daily(world)
	Prof.add("эк:внешняя экономика", _pt)
	for i in n_count:
		var nat: World.Nation = world.nations[i]
		if not nat.alive:
			continue
		var r: Array = results[i]
		nat.civ = r[0]
		nat.mil = r[1]
		nat.province_count = r[3]
		nat.daily_manpower = r[2] * 0.0014 * (1.0 + nat.b("manpower"))
		nat.manpower += nat.daily_manpower
		# производство снаряжения: свободные заводы ИИ сам раскладывает по линиям
		_pt = Time.get_ticks_usec()
		Military.trim_lines(nat)
		if not nat.is_player or nat.prod_auto:
			# раз в месяц — пересмотр линий по нужде (Military.plan_production)
			if (world.day + nat.id) % 30 == 0 or nat.prod_split.is_empty():
				var _p2 := Time.get_ticks_usec()
				# готовые доли со вчера (упреждение, Spec) или пересмотр сейчас
				var pj: Dictionary = world.prod_job
				var ready: Dictionary = pj.get("splits", {}) if int(pj.get("day", -1)) == world.day else {}
				if ready.has(nat.id):
					Spec.finish(world)
					Military.plan_apply(nat, ready[nat.id])
				else:
					if land_totals.is_empty() or world.day - land_totals_day >= 10:
						land_totals = Military.land_totals(world)
						land_totals_day = world.day
					Military.plan_production(world, nat, AIPlanner.target_divisions(nat), not nat.planned_wars.is_empty(), land_totals)
				Prof.add("эк:план заводов", _p2)
			Military.assign_free_factories(nat, nat.prod_split)
		Military.produce(nat)
		Prof.add("эк:производство", _pt)
		_pt = Time.get_ticks_usec()

		# наука
		if (world.day + nat.id) % 30 == 0 or nat.research.size() < nat.research_slots:
			Tech.fit_slots(nat)
			# ИИ пересобирает проекты самолётов под новые технологии
			if not nat.is_player and (world.day + nat.id) % 30 == 0:
				Designs.ai_update(world, nat)
				ShipDesigns.ai_update(world, nat)
		Prof.add("эк:наука-слоты", _pt)
		_pt = Time.get_ticks_usec()
		for tid in Tech.daily(world, nat):
			if nat.is_player:
				world.log_event("Исследовано: %s — слот науки свободен" % Tech.tech_name(tid))

		# строительство фабрик
		# закупки ресурсов оплачиваются гражданскими заводами, продажи их приносят
		Prof.add("эк:наука-день", _pt)
		_pt = Time.get_ticks_usec()
		var civ_free := maxf(0.0, float(nat.civ) - nat.trade_civ + nat.trade_civ_in)
		# заказы узлов снабжения берут до половины очков стройки (Supply.build)
		nat.build_progress += Supply.build(world, nat, civ_free * BUILD_RATE * (1.0 + nat.b("construction")))
		if nat.build_progress >= FACTORY_COST:
			var bt := Puppets.build_target(world, nat)
			if (bt >= 0 and Puppets.build_in(world, nat, bt)) or _place_factory(i, nat.build_mode):
				nat.build_progress -= FACTORY_COST
			else:
				nat.build_progress = FACTORY_COST

		Prof.add("эк:наука+стройка", _pt)
		_pt = Time.get_ticks_usec()
		# подготовка дивизий
		var still: Array = []
		for entry in nat.training:
			if int(entry[0]) <= 1:
				var spawn := nat.capital if world.p_controller[nat.capital] == i else _any_province(i)
				if spawn >= 0:
					world.spawn_division(i, spawn, int(entry[1]))
					if nat.is_player:
						world.log_event("Готова дивизия (%s): %s" % [Military.tpl(world, int(entry[1]))["name"].to_lower(), world.p_name[spawn]])
			else:
				still.append([int(entry[0]) - 1, int(entry[1])])
		nat.training = still
		Prof.add("эк:подготовка", _pt)


func _place_factory(nid: int, mode: String) -> bool:
	var best := -1
	if Native.core != null:
		best = Native.core.call("place_factory", world.p_owner, world.p_controller, world.p_civ, world.p_mil,
				world.p_population, world.p_terrain, nid, MAX_FACTORIES, World.T_URBAN)
	else:
		var best_score := INF
		var owner := world.p_owner
		var ctrl := world.p_controller
		var civ := world.p_civ
		var mil := world.p_mil
		var terrain := world.p_terrain
		for p in world.prov_count:
			if owner[p] != nid or ctrl[p] != nid:
				continue
			var total := civ[p] + mil[p]
			if total >= factory_slots(world, p):
				continue
			var score := float(total) - (2.0 if terrain[p] == World.T_URBAN else 0.0) + float(p % 7) * 0.01
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
	return Military.start_training(world, world.nations[nid], tpl)


## Матрица «одна сторона» для параллельных фаз (фракции и сюзерены меняются редко,
## но пересчёт дешёвый: nation_count^2).
var _sides_key := PackedInt32Array()


func _refresh_sides() -> void:
	var nc := world.nation_count
	# ключ стороны: фракция сюзерена или сам сюзерен (см. Diplomacy.same_side)
	var key := PackedInt32Array()
	key.resize(nc)
	for a in nc:
		var r := Diplomacy.root(world, a)
		var f: int = world.nations[r].faction
		key[a] = f if f >= 0 else 10000 + r
	# матрица — только когда стороны сменились (союзы меняются редко)
	if key == _sides_key and world.ally.size() == nc * nc:
		return
	_sides_key = key
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
	var _pt0 := Time.get_ticks_usec()
	var nc := world.nation_count
	# стороны: представитель — наименьший номер союзной страны
	var rep := PackedInt32Array()
	rep.resize(nc)
	var reps: Array = []
	var ally0 := world.ally
	for a in nc:
		rep[a] = a
		for b in a:
			if ally0[a * nc + b] == 1:
				rep[a] = rep[b]
				break
		if rep[a] == a and world.nations[a].alive:
			reps.append(a)
	var hubs: Array = []
	hubs.resize(reps.size())
	var rep_index := {}
	for i in reps.size():
		hubs[i] = []   # Array: append без копирования; в Packed — после сбора
		rep_index[reps[i]] = i
	var ctl := world.p_controller
	var _px := Time.get_ticks_usec()
	if world.p_port.size() != world.prov_count or world.port_list.is_empty():
		Forces.refresh_ports(world)
	for nat in world.nations:
		if nat.alive and ctl[nat.capital] == nat.id and rep_index.has(rep[nat.id]):
			hubs[rep_index[rep[nat.id]]].append(nat.capital)
	var port := world.p_port
	var is_land := world.p_land
	var adj_s := world.adj_start
	var adj_l := world.adj_list
	Prof.add("снаб:стороны", _pt0)
	var zf := world.zone_fleets
	var sup_memo := {}
	var plist := world.port_list
	# порт за морем, отрезанный от метрополии (проливом или блокадой пути
	# конвоев: World.p_conv = 0), — не источник: иначе узлы снабжения от него
	# работали в полную силу (Италия в Восточной Африке 1940–41 гг.)
	var pconv := world.p_conv
	var cut_ok := pconv.size() == world.prov_count
	# заморские порты союзника, что сам не воюет (Виши: Джибути, Мадагаскар),
	# не снабжают воюющую сторону — их колонии в блокаде противника стороны
	if cut_ok:
		pconv = pconv.duplicate()
		var al := world.ally
		for nat in world.nations:
			if not nat.alive or not nat.at_war.is_empty() or nat.conv_routes.is_empty() or al.size() != nc * nc:
				continue
			var side_war := false
			for x in nc:
				if x != nat.id and al[nat.id * nc + x] == 1 and not world.nations[x].at_war.is_empty():
					side_war = true
					break
			if not side_war:
				continue
			for rt in nat.conv_routes:
				if int(rt[0]) == 1:
					pconv[int(rt[1])] = 0.0
	# блокада возможна, только если во всех соседних морских зонах есть флоты
	_px = Time.get_ticks_usec()
	if Native.core != null:
		# всё в ядре: открытое море и блокада по господству (флоты зон — один раз)
		var zhf := PackedByteArray()
		zhf.resize(world.prov_count)
		var zidx := PackedInt32Array()
		zidx.resize(world.prov_count)
		zidx.fill(-1)
		var zoff := PackedInt32Array([0])
		var zown := PackedInt32Array()
		var zpow := PackedFloat64Array()
		for z in zf:
			zhf[z] = 1
			zidx[z] = zoff.size() - 1
			for f in zf[z]:
				if f.mission == "port":
					continue
				zown.append(f.owner)
				zpow.append(Forces.combat_power(f))
			zoff.append(zown.size())
		var hub_ok: PackedByteArray = Native.core.call("ports_hub", plist, ctl, adj_s, adj_l, is_land, zhf,
				zidx, zoff, zown, zpow, world.ally, world.war, nc, not world.fleets.is_empty())
		for pi in plist.size():
			var p := plist[pi]
			var c := ctl[p]
			if c >= 0 and rep_index.has(rep[c]) and hub_ok[pi] == 1 and not (cut_ok and pconv[p] <= 0.0):
				hubs[rep_index[rep[c]]].append(p)
	else:
		for pi in plist.size():
			var p := plist[pi]
			var c := ctl[p]
			if c < 0 or not rep_index.has(rep[c]) or (cut_ok and pconv[p] <= 0.0):
				continue
			var open_sea := false
			for k in range(adj_s[p], adj_s[p + 1]):
				var q := adj_l[k]
				if is_land[q] == 0 and not zf.has(q):
					open_sea = true
					break
			if open_sea or not _blockaded(c, p, sup_memo):
				hubs[rep_index[rep[c]]].append(p)
	Prof.add("уз:блокада", _px)
	# плацдармы высадок временно работают как порты
	for p in world.beachheads.keys():
		if world.beachheads[p] < world.day:
			world.beachheads.erase(p)
			continue
		var c := ctl[p]
		if c >= 0 and rep_index.has(rep[c]):
			hubs[rep_index[rep[c]]].append(p)
	Prof.add("снаб:узлы", _pt0)
	for i in reps.size():
		hubs[i] = PackedInt32Array(hubs[i])
	if world.supply_regions:
		# по принципу жанра: узлы районов, железная дорога, подвоз (Supply)
		# номер стороны — номер её ведущей страны (не сдвигается, когда другие
		# страны исчезают: вчерашнее поле подачи остаётся за той же стороной)
		var so := PackedInt32Array()
		so.resize(nc)
		so.fill(-1)
		var srcs: Array = []
		srcs.resize(nc)
		for a in nc:
			srcs[a] = PackedInt32Array()
		for i in reps.size():
			srcs[reps[i]] = hubs[i]
		var caps := PackedInt32Array()
		for a in nc:
			if world.nations[a].alive and rep_index.has(rep[a]):
				so[a] = rep[a]
				caps.append(world.nations[a].capital)
		Supply.regions(world, so, srcs, caps)
		world.sup_args = [so, srcs, caps]   # для упреждения поля на завтра (Supply.spec)
		Supply.ai_daily(world)
		Prof.add("снаб:сети", _pt0)
		return
	var results: Array = []
	results.resize(reps.size())
	var native: Object = Native.core
	var task := func(i: int) -> void:
		var r: int = reps[i]
		if native != null:
			results[i] = native.call("supply_bfs", world.adj_start, world.adj_list, world.p_land,
					world.p_controller, world.ally, nc, r, hubs[i])
			return
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
	# с нативным ядром обход стороны — десятки микросекунд: потоки не нужны
	Parallel.run(reps.size(), task, "supply", 1000 if native != null else 4)
	world.supply_dist.resize(nc)
	for a in nc:
		var idx := reps.find(rep[a])
		world.supply_dist[a] = results[idx] if idx >= 0 else PackedInt32Array()
	Prof.add("снаб:сети", _pt0)
	# нагрузка на провинции и итоговое снабжение каждой дивизии (ядро по массивам)
	var side_of := PackedInt32Array()
	side_of.resize(nc)
	var flat := PackedInt32Array()
	for i in reps.size():
		flat.append_array(results[i])
	for a in nc:
		side_of[a] = reps.find(rep[a])
	world.k_supply(side_of, flat)


## Forces.port_blockaded с памятью господства по (страна, зона) на один проход.
func _blockaded(n: int, p: int, memo: Dictionary) -> bool:
	if world.fleets.is_empty():
		return false
	var any := false
	var land := world.p_land
	var pc := world.prov_count
	for q in world.p_adj[p]:
		if land[q] == 0:
			any = true
			var key: int = n * pc + q
			var sup = memo.get(key)
			if sup == null:
				sup = _zone_supremacy(n, q, memo)
				memo[key] = sup
			if sup >= 0.3:
				return false
	return any


## Forces.supremacy с силами флотов зоны, собранными один раз за проход
## (тот же порядок флотов и сложений — результат до бита тот же).
func _zone_supremacy(n: int, zone: int, memo: Dictionary) -> float:
	var zk := -1 - zone   # ключи зон — отрицательные, ключи (страна, зона) — нет
	var zd = memo.get(zk)
	if zd == null:
		var ow := PackedInt32Array()
		var pw := PackedFloat64Array()
		for f in world.zone_fleets.get(zone, []):
			if f.mission == "port":
				continue
			ow.append(f.owner)
			pw.append(Forces.combat_power(f))
		zd = [ow, pw]
		memo[zk] = zd
	var owners: PackedInt32Array = zd[0]
	var powers: PackedFloat64Array = zd[1]
	var mine := 0.0
	var enemy := 0.0
	var nc := world.nation_count
	var ally := world.ally
	for i in owners.size():
		var o := owners[i]
		if ally[n * nc + o] == 1:
			mine += powers[i]
		elif world.is_at_war(n, o):
			enemy += powers[i]
	if mine + enemy <= 0.0:
		return 0.5
	return mine / (mine + enemy)


# --- ИИ: план каждой страны — отдельная задача ------------------------------

func _phase_ai() -> void:
	# Все страны ИИ и армии игрока планируются одной пачкой раз в AI_PERIOD дней.
	# Экономика — сразу; военные планы считаются в рабочих потоках по замороженным
	# таблицам (снимок дивизий + копии массивов мира), пока главный поток ведёт
	# остальные фазы дня, а приказы применяются в конце дня (_finish_ai).
	if world.day % AI_PERIOD != 0:
		return
	var _pa := Time.get_ticks_usec()
	var jobs: Array = []
	for nat in world.nations:
		if nat.alive and not nat.is_player:
			jobs.append({"nation": nat.id})
			# развёртывание к запланированной фокусами войне: часть армии заранее
			# держит фронт на границе с будущим противником (как армия игрока)
			var x := _staging_enemy(nat)
			if x >= 0:
				jobs.append({"stage_of": nat.id, "enemy": x})
	jobs.append_array(_group_jobs())
	if jobs.is_empty():
		return
	Prof.add("ии:задачи", _pa)
	_pa = Time.get_ticks_usec()
	world.k_snapshot()
	Prof.add("ии:k_snapshot", _pa)
	_pa = Time.get_ticks_usec()
	var day := world.day
	var seed_value := world.seed_value
	# дивизии по странам — один проход вместо прохода на каждую страну
	var by_nation: Array = []
	by_nation.resize(world.nation_count)
	for n in world.nation_count:
		by_nation[n] = []   # Array — ссылочный тип: append без копирования
	var owner := world.d_owner
	for i in owner.size():
		by_nation[owner[i]].append(i)
	for n in world.nation_count:
		by_nation[n] = PackedInt32Array(by_nation[n])
	# дивизии на развёртывание: STAGE_SHARE армии (по id — состав не скачет)
	var staged := {}
	for job in jobs:
		if job.has("stage_of"):
			staged[int(job["stage_of"])] = true
	Prof.add("ии:по странам", _pa)
	_pa = Time.get_ticks_usec()
	for job in jobs:
		var rng: RandomNumberGenerator
		if job.has("stage_of"):
			rng = Parallel.rng(seed_value, day, 7000 + int(job["stage_of"]))
		else:
			rng = Parallel.rng(seed_value, day, job["nation"] if job.has("nation") else 5000 + int(job["group"]))
		job["rng"] = rng
		if job.has("stage_of"):
			var sn: int = job["stage_of"]
			var part := PackedInt32Array()
			for slot in by_nation[sn]:
				if _is_staged(slot):
					part.append(slot)
			var _ps := Time.get_ticks_usec()
			job["args"] = AIPlanner.military_args(world, sn, part, {"mode": "hold", "enemy": int(job["enemy"])})
			Prof.add("ии:развёртывание", _ps)
		elif job.has("group"):
			var _pg := Time.get_ticks_usec()
			var idx := PackedInt32Array()
			for i in world.divisions.size():
				if world.divisions[i].group == job["group"]:
					idx.append(i)
			job["args"] = AIPlanner.military_args(world, job["owner"], idx, job["opts"])
			Prof.add("ии:группы", _pg)
		else:
			var nid: int = job["nation"]
			var nat: World.Nation = world.nations[nid]
			var mine: PackedInt32Array = by_nation[nid]
			var _pe := Time.get_ticks_usec()
			var eco: Dictionary = AIPlanner.plan_economy(world, nid, rng, mine.size())
			Prof.add("ии:экономика", _pe)
			_ai_train(nat, int(eco["train"]))
			nat.build_mode = eco["build"]
			# выбор науки — в главном потоке: таблицы Tech общие для всех
			_pe = Time.get_ticks_usec()
			var fs := Tech.free_slot(nat)
			while fs >= 0:
				var pick := Tech.ai_pick(world, nat)
				if pick == "" or not Tech.start(nat, fs, pick):
					break
				fs = Tech.free_slot(nat)
			Prof.add("ии:наука", _pe)
			if eco["war"] >= 0:
				Diplomacy.declare_war(world, nid, eco["war"])
			if staged.has(nid):
				var rest := PackedInt32Array()
				for slot in mine:
					if not _is_staged(slot):
						rest.append(slot)
				mine = rest
			_pe = Time.get_ticks_usec()
			job["args"] = AIPlanner.nation_args(world, nid, mine)
			Prof.add("ии:nation_args", _pe)
	Prof.add("ии:аргументы", _pa)
	_pa = Time.get_ticks_usec()
	# глубокая копия: часть записей в массивы мира идёт на месте, без
	# копирования при записи, — потоки должны читать замороженное состояние
	var tables := AIPlanner.ai_tables(world).duplicate(true)
	_ai_tables = tables
	Prof.add("ии:таблицы", _pa)
	_ai_jobs = jobs
	_ai_plans = []
	_ai_plans.resize(jobs.size())
	var plans := _ai_plans
	var task := func(i: int) -> void:
		var job: Dictionary = jobs[i]
		plans[i] = AIPlanner.plan_job(tables, job["args"], job["rng"])
	_ai_gid = Parallel.start(jobs.size(), task, "ai", 3)


var _ai_jobs: Array = []
var _ai_tables := {}
var _ai_plans: Array = []
var _ai_gid := -1


## Дождаться военных планов ИИ и применить приказы (конец дня).
const STAGE_SHARE := 6   # из 10: доля армии на развёртывание к запланированной войне


func _is_staged(slot: int) -> bool:
	return world.d_id[slot] % 10 < STAGE_SHARE


## Будущий противник для развёртывания: война из текущего или следующего фокуса,
## ещё не начатая, и есть общая сухопутная граница.
func _staging_enemy(nat: World.Nation) -> int:
	if nat.planned_wars.is_empty():
		return -1
	var keys: Array = nat.planned_wars.keys()
	keys.sort()
	for x in keys:
		var xi: int = x
		if xi < 0 or not world.nations[xi].alive or world.is_at_war(nat.id, xi):
			continue
		var ctrl := world.p_controller
		for p in world.prov_count:
			if ctrl[p] != nat.id:
				continue
			for k in range(world.adj_start[p], world.adj_start[p + 1]):
				if ctrl[world.adj_list[k]] == xi:
					return xi
	return -1


func _finish_ai() -> void:
	Spec.finish(world)
	if _ai_jobs.is_empty():
		return
	Parallel.finish(_ai_gid)
	_ai_gid = -1
	var jobs := _ai_jobs
	_ai_jobs = []
	# приказ — [слот в снимке, путь]; слоты до конца дня не меняются (уплотнение —
	# в начале следующего), но проверяем id: снимок хранит dv_id
	var snap_id: PackedInt32Array = _ai_tables["dv_id"]
	var divs := world.divisions
	var by_id := {}
	for i in jobs.size():
		var plan: Dictionary = _ai_plans[i]
		var job: Dictionary = jobs[i]
		if job.has("group"):
			var g: World.ArmyGroup = world.groups[job["group"]]
			g.front_pairs = plan["fronts"]
		for order in plan["orders"]:
			var slot: int = order[0]
			var d: World.Division = null
			if slot < divs.size() and world.d_id[slot] == snap_id[slot]:
				d = divs[slot]
			else:
				# слоты сдвинулись (аннексия уплотнила массивы) — ищем по id
				if by_id.is_empty():
					for x in divs:
						by_id[x.id] = x
				d = by_id.get(snap_id[slot])
			if d != null and d.alive and d.transit_days <= 0:
				d.path = order[1]
				d.progress = 0.0
	_ai_plans = []


func _phase_navy() -> void:
	_timed("флот:бои", Forces.daily_navy.bind(world, Parallel.rng(world.seed_value, world.day, 6000)))
	_timed("флот:планы", func():
		Forces.daily_plans(world)
		Forces.daily_transit(world))
	# решения ИИ по флоту, авиации и высадкам — раз в 5 дней на страну
	var t := Time.get_ticks_usec()
	var ta := 0
	var ti := 0
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % 10 == 0:
			Forces.ai_fleets(world, nat.id)
			var t2 := Time.get_ticks_usec()
			Forces.ai_air(world, nat.id)
			ta += Time.get_ticks_usec() - t2
			if (world.day + nat.id) % 10 == 0:
				t2 = Time.get_ticks_usec()
				var _pt := Time.get_ticks_usec()
				Forces.ai_invasion(world, nat.id, Parallel.rng(world.seed_value, world.day, 6100 + nat.id))
				Prof.add("высадки:ai_invasion", _pt)
				_pt = Time.get_ticks_usec()
				Forces.ai_transfers(world, nat.id)
				Prof.add("высадки:ai_transfers", _pt)
				ti += Time.get_ticks_usec() - t2
	phase_usec["флот:ИИ"] = Time.get_ticks_usec() - t - ta - ti
	phase_usec["авиа:ИИ"] = ta
	phase_usec["флот:высадки"] = ti


var _mountain := PackedByteArray()
var _mountain_day := -1


func _ai_train(nat: World.Nation, count: int) -> void:
	if count <= 0:
		return
	if _mountain_day != world.day:
		# горы у стран — один проход на день ИИ вместо прохода на страну
		_mountain_day = world.day
		_mountain = PackedByteArray()
		_mountain.resize(world.nation_count)
		var own := world.p_owner
		var ter := world.p_terrain
		for p in world.prov_count:
			if ter[p] == World.T_MOUNTAIN and own[p] >= 0:
				_mountain[own[p]] = 1
	var mountainous := _mountain[nat.id] == 1
	for k in count:
		var t := Military.ai_template(world, nat, nat.trained_count, mountainous)
		if Military.start_training(world, nat, t) or (t != Military.T_INF and Military.start_training(world, nat, Military.T_INF)):
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


## Приказ многим дивизиям сразу: пути — одним обратным поиском от цели
## (Pathfinder.paths_to). Возвращает, скольким дивизиям приказ отдан.
func order_move_many(divs: Array, to: int) -> int:
	if divs.size() < 3:
		var n := 0
		for d in divs:
			if order_move(d, to):
				n += 1
				d.group = -1
		return n
	var srcs := PackedInt32Array()
	var owner := -1
	for d in divs:
		srcs.append(d.prov)
		owner = d.owner
	var paths := Pathfinder.paths_to(world, owner, to, srcs)
	var ok := 0
	for d in divs:
		if d.prov == to:
			d.path = PackedInt32Array()
		elif paths.has(d.prov):
			var path: PackedInt32Array = paths[d.prov]
			if d.path.is_empty() or d.path[0] != path[0]:
				d.progress = 0.0
			d.path = path
		else:
			continue
		d.group = -1   # ручной приказ выводит дивизию из армии
		ok += 1
	return ok


# --- Бои и движение ----------------------------------------------------------

## province -> Array[Division] атакующих. Ядро World.k_march заодно считает
## шаг движения всех идущих дивизий (список — в _movers).
var _movers := PackedInt32Array()


func _collect_battles() -> Dictionary:
	var r := world.k_march()
	var divs := world.divisions
	for i in r[0]:
		var d: World.Division = divs[i]
		d.path = PackedInt32Array()
	var battles := {}
	for i in r[1]:
		var d: World.Division = divs[i]
		var t := world.d_next[i]
		if not battles.has(t):
			battles[t] = []
		battles[t].append(d)
	_movers = r[2]
	return battles


func _phase_movement(_battles: Dictionary) -> void:
	# применение — строго по порядку, чтобы не было гонок за провинцию
	var divs := world.divisions
	for i in _movers:
		if world.d_prog[i] < 1.0:
			continue
		var d: World.Division = divs[i]
		var t := d.path[0]
		if not world.can_enter(d.owner, t) or world.has_enemies(d.owner, t):
			d.progress = 0.99
			continue
		d.prov = t   # список провинции обновляется сам (World.ds_prov)
		d.path = d.path.slice(1)
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
	if prev >= 0 and world.is_at_war(nid, prev):
		Peace.add_score(world, nid, world.p_vp[p] + 1.0)   # вклад в победу
	world.nations[nid].war_activity_day = world.day
	if prev >= 0:
		world.nations[prev].war_activity_day = world.day
	if world.p_vp[p] >= 5 and (world.nations[nid].is_player or world.nations[prev].is_player):
		world.log_event("%s захватывает %s" % [world.nations[nid].name, world.p_name[p]])


func _phase_combat(battles: Dictionary) -> void:
	var provs: Array = battles.keys()
	if provs.is_empty():
		return
	# сражения в плоском виде для ядра World.k_combat
	var pv := PackedInt32Array(provs)
	var att_start := PackedInt32Array([0])
	var att_list := PackedInt32Array()
	var seeds := PackedInt64Array()
	for p in provs:
		for a in battles[p]:
			att_list.append(a.slot)
		att_start.append(att_list.size())
		seeds.append(hash([world.seed_value, world.day, p]))   # как Parallel.rng
	# численность до боя — для вклада в победу (Peace.SCORE_KILL)
	var pre := {}
	for p in provs:
		for a in battles[p]:
			pre[a.slot] = a.strength
		for e in world.divs_in(p):
			if e.alive:
				pre[e.slot] = e.strength
	world.k_combat(pv, att_start, att_list, seeds, PLAN_MAX)
	_combat_score(provs, battles, pre)
	# боевой опыт армии: дивизии-участники сражений за день (Doctrine)
	var engaged := PackedInt32Array()
	engaged.resize(world.nations.size())
	for p in provs:
		var ao: int = battles[p][0].owner
		engaged[ao] += battles[p].size()
		for e in world.divs_in(p):
			if e.alive and world.is_at_war(ao, e.owner):
				engaged[e.owner] += 1
	for n in engaged.size():
		if engaged[n] > 0:
			Doctrine.gain(world.nations[n], 0, minf(Doctrine.LAND_CAP, Doctrine.LAND_PER_DIV * engaged[n]))
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
		for e in world.divs_in(p):
			if not e.alive or not world.is_at_war(att_owner, e.owner):
				continue
			if e.org <= 0.5 or e.strength <= 5.0:
				_retreat(e)


## Вклад в победу: потери стороны делятся между дивизиями противника в бою.
func _combat_score(provs: Array, battles: Dictionary, pre: Dictionary) -> void:
	for p in provs:
		var ao: int = battles[p][0].owner
		var att := {}
		var a_loss := 0.0
		for a in battles[p]:
			a_loss += maxf(0.0, float(pre[a.slot]) - a.strength)
			att[a.owner] = int(att.get(a.owner, 0)) + 1
		var dfn := {}
		var d_loss := 0.0
		for e in world.divs_in(p):
			if pre.has(e.slot) and not att.has(e.owner) and world.is_at_war(ao, e.owner):
				d_loss += maxf(0.0, float(pre[e.slot]) - e.strength)
				dfn[e.owner] = int(dfn.get(e.owner, 0)) + 1
		_share_score(att, d_loss)
		_share_score(dfn, a_loss)


func _share_score(side: Dictionary, loss: float) -> void:
	var n := 0
	for k in side:
		n += int(side[k])
	if n == 0 or loss <= 0.0:
		return
	for k in side:
		Peace.add_score(world, k, loss * Peace.SCORE_KILL * float(side[k]) / float(n))


func _retreat(d: World.Division) -> void:
	var best := -1
	var best_score := -INF
	for q in world.p_adj[d.prov]:  # главный поток — можно без CSR
		if world.p_land[q] == 0 or world.p_controller[q] != d.owner or world.has_enemies(d.owner, q):
			continue
		var score := float(world.divs_count(q)) + float(q % 5) * 0.01
		if score > best_score:
			best_score = score
			best = q
	if best < 0 or d.strength <= 5.0:
		_destroy(d, "окружена и уничтожена" if best < 0 else "разбита")
		return
	d.prov = best
	d.path = PackedInt32Array()
	d.progress = 0.0


func _destroy(d: World.Division, why: String) -> void:
	if not d.alive:
		return
	d.alive = false
	if world.nations[d.owner].is_player:
		world.log_event("Наша дивизия %s: %s" % [why, world.p_name[d.prov]])


## Планирование: «противник» — с кем война или будущая война (фокусы, претензии).
func _phase_planning() -> void:
	var nc := world.nation_count
	var hostile := world.war.duplicate()
	for nat in world.nations:
		if not nat.alive:
			continue
		for t in nat.planned_wars:
			hostile[nat.id * nc + int(t)] = 1
		for t in nat.wargoals:
			hostile[nat.id * nc + int(t)] = 1
	world.k_plan(hostile, PLAN_GAIN, PLAN_ACTIVE, PLAN_REAR)


func _phase_recovery() -> void:
	var nc := world.nation_count
	var stock := PackedFloat32Array()
	stock.resize(nc * 7)
	var manpower := PackedFloat64Array()
	manpower.resize(nc)
	var rbonus := PackedFloat64Array()
	rbonus.resize(nc)
	for nat in world.nations:
		var st: PackedFloat32Array = nat.stock
		for k in 7:
			stock[nat.id * 7 + k] = st[k]
		manpower[nat.id] = nat.manpower
		rbonus[nat.id] = nat.b("reinforce")
	var r := world.k_recovery(stock, manpower, rbonus)
	stock = r[0]
	manpower = r[1]
	for nat in world.nations:
		var st := PackedFloat32Array()
		st.resize(7)
		for k in 7:
			st[k] = stock[nat.id * 7 + k]
		nat.stock = st
		nat.manpower = manpower[nat.id]
	for i in r[2]:
		_destroy(world.divisions[i], "погибла в окружении")


# --- Капитуляция -------------------------------------------------------------

# кэш проверки капитуляций: итоги по очкам пересчитываются, только когда
# сменились владельцы, контроль, очки провинций или стороны (сюзерены, фракции)
var _cap_owner := PackedInt32Array()
var _cap_ctrl := PackedInt32Array()
var _cap_vp := PackedInt32Array()
var _cap_side := PackedInt32Array()
var _cap_total := PackedInt32Array()
var _cap_held := PackedInt32Array()
var _cap_self := PackedInt32Array()   # провинций, что страна и владеет, и держит


func _check_capitulation() -> void:
	var nc := world.nations.size()
	var side := PackedInt32Array()
	side.resize(nc * 2)
	for n in nc:
		var r := Diplomacy.root(world, n)
		side[n * 2] = r
		side[n * 2 + 1] = world.nations[r].faction
	var owner := world.p_owner
	var ctrl := world.p_controller
	# порог страны — только по метрополии (решение пользователя): колонии
	# капитулируют отдельно (_cap_colonies)
	var vp := _metro_vp()
	if _cap_total.size() != nc or side != _cap_side or owner != _cap_owner or ctrl != _cap_ctrl or vp != _cap_vp:
		_cap_side = side
		_cap_owner = owner.duplicate()
		_cap_ctrl = ctrl.duplicate()
		_cap_vp = vp.duplicate()
		if Native.core != null:
			var tot: PackedInt32Array = Native.core.call("cap_totals", owner, ctrl, vp, side, nc)
			_cap_total = tot.slice(0, nc)
			_cap_held = tot.slice(nc, nc * 2)
			_cap_self = tot.slice(nc * 2, nc * 3)
		else:
			_cap_totals_gd(owner, ctrl, vp, side, nc)
	_cap_countries()
	_cap_colonies()


var _vp_metro := PackedInt32Array()
var _col_provs := PackedInt32Array()    # колониальные провинции
var _col_group := PackedInt32Array()    # провинция → номер территории (код страны Natural Earth)


## Очки победы метрополии: у колоний — 0 (флаг колонии неизменен).
func _metro_vp() -> PackedInt32Array:
	if _vp_metro.size() != world.prov_count:
		_vp_metro = world.p_vp.duplicate()
		_col_provs = PackedInt32Array()
		_col_group = PackedInt32Array()
		_col_group.resize(world.prov_count)
		_col_group.fill(-1)
		var ids := {}
		for p in world.prov_count:
			if world.p_colony[p] == 1:
				_vp_metro[p] = 0
				_col_provs.append(p)
				var a: String = world.p_adm0[p] if p < world.p_adm0.size() else ""
				if not ids.has(a):
					ids[a] = ids.size()
				_col_group[p] = ids[a]
	return _vp_metro


## Колонии капитулируют отдельно от метрополии: территория (по коду страны),
## потерявшая больше (1 − порог страны без черт) своих очков, отходит главному
## захватчику — только она, метрополия ничего не теряет.
func _cap_colonies() -> void:
	if _col_provs.is_empty():
		return
	var nc := world.nation_count
	var ctrl := world.p_controller
	var owner := world.p_owner
	var total := {}   # владелец * 4096 + территория → [всего, держит]
	for p in _col_provs:
		var o := owner[p]
		if o < 0 or world.nations[o].at_war.is_empty():
			continue
		var key := o * 4096 + _col_group[p]
		var v := world.p_vp[p]
		if not total.has(key):
			total[key] = [0, 0]
		total[key][0] += v
		var c := ctrl[p]
		if c == o or (c >= 0 and Diplomacy.same_side(world, c, o)):
			total[key][1] += v
	var keys := total.keys()
	keys.sort()
	for key in keys:
		var t: Array = total[key]
		var o: int = key / 4096
		var g: int = key % 4096
		var nat: World.Nation = world.nations[o]
		if int(t[0]) <= 0 or not nat.alive or world.col_done.has(key) or float(t[1]) / float(t[0]) >= nat.capitulate_at:
			continue
		# главный захватчик территории
		var occ := {}
		for p in _col_provs:
			if owner[p] == o and _col_group[p] == g:
				var c := ctrl[p]
				if c >= 0 and c != o and not Diplomacy.same_side(world, c, o) and world.is_at_war(o, c):
					occ[c] = int(occ.get(c, 0)) + world.p_vp[p] + 1
		var winner := -1
		var best := -1
		var ks := occ.keys()
		ks.sort()
		for c in ks:
			if int(occ[c]) > best:
				best = occ[c]
				winner = c
		if winner < 0:
			continue
		# территория занята до мирных переговоров (Peace), гарнизон сдаётся
		world.col_done[key] = true
		var big := -1
		for p in _col_provs:
			if owner[p] == o and _col_group[p] == g:
				if big < 0 or world.p_vp[p] > world.p_vp[big]:
					big = p
				if world.p_controller[p] == o:
					world.p_controller[p] = winner
		for d in world.divisions:
			if d.alive and d.owner == o and _col_group[d.prov] == g and world.p_owner[d.prov] == o:
				d.alive = false
		world.palette_dirty = true
		world.log_event("Колония сдаётся: %s (%s) занята страной %s до мирных переговоров" % [world.p_name[big], nat.name, world.nations[winner].name])
		# правительство в изгнании без последней земли — капитуляция
		if nat.exile:
			var left := false
			for p in world.prov_count:
				if world.p_owner[p] == o and world.p_controller[p] == o:
					left = true
					break
			if not left:
				Peace.capitulate(world, o, winner)
		_fix_capitals()


## Двойник MeowqCore::cap_totals.
func _cap_totals_gd(owner: PackedInt32Array, ctrl: PackedInt32Array, vp: PackedInt32Array, side: PackedInt32Array, nc: int) -> void:
	var total := PackedInt32Array()
	var held := PackedInt32Array()
	var selfc := PackedInt32Array()
	total.resize(nc)
	held.resize(nc)
	selfc.resize(nc)
	for p in world.prov_count:
		var o := owner[p]
		if o < 0:
			continue
		var c := ctrl[p]
		if c == o:
			selfc[o] += 1
		if vp[p] == 0:
			continue
		total[o] += vp[p]
		# провинции у союзника по стороне (сюзерен, фракция) — не потеряны
		if c == o or (c >= 0 and (side[c * 2] == side[o * 2] or (side[c * 2 + 1] >= 0 and side[c * 2 + 1] == side[o * 2 + 1]))):
			held[o] += vp[p]
	_cap_total = total
	_cap_held = held
	_cap_self = selfc


func _cap_countries() -> void:
	# капитуляция в этом же проходе меняет карту — тогда счётчик своих провинций устарел
	var moved := false
	for nat in world.nations:
		if nat.alive and nat.exile and world.p_controller[nat.capital] != nat.id:
			_move_capital(nat)   # изгнанники переезжают внутри колоний
		if nat.alive and _cap_total[nat.id] > 0:
			nat.vp_ratio = float(_cap_held[nat.id]) / float(_cap_total[nat.id])
		if not nat.alive or nat.capitulated or nat.exile or nat.at_war.is_empty() or _cap_total[nat.id] == 0:
			continue
		var ratio := float(_cap_held[nat.id]) / float(_cap_total[nat.id])
		# порог капитуляции: базовый + черты (расколотое правительство, бескрайние
		# просторы); черта capital_fall — капитуляция и при потере столицы противнику
		var c_ctl := world.p_controller[nat.capital]
		var cap_lost: bool = nat.b("capital_fall") > 0.0 and c_ctl != nat.id and c_ctl >= 0 and world.is_at_war(nat.id, c_ctl)
		if cap_lost or ratio < nat.capitulate_at + nat.b("surrender"):
			_capitulate(nat.id)
			moved = true
		elif world.p_controller[nat.capital] != nat.id and (moved or _cap_self[nat.id] > 0):
			# без своих неоккупированных провинций переносить столицу некуда
			_move_capital(nat)

	var alive := 0
	var player := world.player_nation()
	for nat in world.nations:
		if nat.alive:
			alive += 1
	if player >= 0:
		if not world.nations[player].alive or world.nations[player].overlord >= 0 or world.nations[player].capitulated:
			world.game_over = "defeat"
		else:
			var rivals := 0
			for nat in world.nations:
				if nat.alive and not nat.capitulated and not Diplomacy.same_side(world, player, nat.id):
					rivals += 1
			if rivals == 0:
				world.game_over = "victory"


func _capitulate(nid: int) -> void:
	var occ := _occupants(nid)
	# главный победитель — тот, кто держит больше всего наших провинций
	var winner := -1
	var best := -1
	for k in occ:
		if occ[k] > best:
			best = occ[k]
			winner = k
	if winner < 0:
		return
	var w_root := Diplomacy.root(world, winner)
	_spoils(nid, occ)
	# исторические правила (Виши, Московский мир, раздел Польши) — отдельный мир
	if History.capitulation_hook(world, nid, w_root, Parallel.rng(world.seed_value, world.day, 8888)):
		_fix_capitals()
		return
	# иначе — изгнание (есть колонии и союзники) или оккупация до конца войны
	if not Diplomacy.try_exile(world, nid, winner):
		Peace.capitulate(world, nid, winner)


## Кто занял наши провинции: страна → очки победы занятого (+1 за провинцию).
func _occupants(nid: int) -> Dictionary:
	var occ := {}
	for p in world.prov_count:
		var c := world.p_controller[p]
		if world.p_owner[p] == nid and c != nid and c >= 0 and not Diplomacy.same_side(world, c, nid):
			occ[c] = int(occ.get(c, 0)) + world.p_vp[p] + 1
	return occ


const SPOILS := 0.5   # доля складов проигравшего, что достаётся победителям (решение пользователя)


## Трофеи: половина складов проигравшего — победителям, по доле занятого ими.
func _spoils(nid: int, occ: Dictionary) -> void:
	var nl: World.Nation = world.nations[nid]
	var tot := 0
	for k in occ:
		tot += int(occ[k])
	if tot <= 0:
		return
	var ks := occ.keys()
	ks.sort()
	for k in ks:
		var nw: World.Nation = world.nations[k]
		var f := SPOILS * float(occ[k]) / float(tot)
		for e in Military.EQ_COUNT:
			nw.stock[e] += nl.stock[e] * f
	for e in Military.EQ_COUNT:
		nl.stock[e] *= 1.0 - SPOILS
	world.log_event("%s: половина складов достаётся победителям" % nl.name)


func resolve_event(option: int) -> void:
	if world.pending_events.is_empty():
		return
	var id: String = world.pending_events.pop_front()
	world.pending_since.erase(id)
	History.choose_option(world, id, option, Parallel.rng(world.seed_value, world.day, 9999))
	_fix_capitals()


## Переговоры ждут хода игрока: kind = "annex" / "puppet" / "free" / "pass" / "done";
## "auto" — за игрока до конца ходит ИИ (тесты, замеры).
func resolve_peace(kind: String, arg: int = -1) -> void:
	var w := Peace.current(world)
	if w < 0:
		world.pending_peace.clear()
		return
	if kind == "auto" or kind == "annex" and arg < 0:
		while not world.conference.is_empty() and world.nations[Peace.current(world)].is_player:
			var me := Peace.current(world)
			var pick := Peace.ai_pick(world, me)
			if pick.is_empty():
				Peace.act(world, me, "done")
			else:
				Peace.act(world, me, pick[0], pick[1])
	else:
		Peace.act(world, w, kind, arg)
	_fix_capitals()


func _phase_diplomacy() -> void:
	if not world.diplomacy:
		return
	var _pt := Time.get_ticks_usec()
	Diplomacy.daily(world)
	Prof.add("дип:Diplomacy.daily", _pt)
	_pt = Time.get_ticks_usec()
	Relations.daily(world)
	Prof.add("дип:Relations.daily", _pt)
	_pt = Time.get_ticks_usec()
	History.daily(world, Parallel.rng(world.seed_value, world.day, 7777))
	Prof.add("дип:история", _pt)
	_pt = Time.get_ticks_usec()
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + nat.id) % 7 == 0:
			Diplomacy.ai_turn(world, nat.id, Parallel.rng(world.seed_value, world.day, 1000 + nat.id))
	Prof.add("дип:ИИ", _pt)


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
func _move_capital(nat: World.Nation) -> bool:
	var best := -1
	var owner := world.p_owner
	var ctrl := world.p_controller
	var vp := world.p_vp
	var nid := nat.id
	for p in world.prov_count:
		if owner[p] == nid and ctrl[p] == nid:
			if best < 0 or vp[p] > vp[best]:
				best = p
	if best < 0:
		return false
	var old := nat.capital
	nat.capital = best
	world.log_event("%s: столица захвачена (%s), правительство переезжает в %s" % [nat.name, world.p_name[old], world.p_name[best]])
	return true

