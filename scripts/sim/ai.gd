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
	# черта army_cap — доля обычной армии (США: «ставка на 90 дивизий» — промышленность
	# на флот, авиацию и ленд-лиз; иначе к 1944 г. 310 дивизий и Берлин в июле)
	return int(maxi(t, mini(nat.prep_divs, int(cap * 1.5))) * maxf(0.1, 1.0 + nat.b("army_cap")))


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
	# без плана — штурм осаждённого города в его срок (эффект siege)
	if obj < 0:
		for sp in nat.siege:
			if siege_assault(world, nat, sp):
				obj = sp
				break
	if obj >= 0:
		opts["objective"] = obj
	var lim := war_limit_fronts(world, nat)
	if not lim.is_empty():
		opts["fronts"] = lim   # готовый список (по возрастанию — как ключи словаря)
	return military_args(world, nid, mine, opts)


## Рубеж операций (эффект war_limit: [код страны Natural Earth, рамки [запад,
## юг, восток, север]]): фронт ИИ — все наши и союзные провинции, кроме взятых на этих
## землях вне рамок (Ставка ограничивала японские операции в Китае районами:
## 1937 г. — Северный Китай и низовья Янцзы, 1938-й — до Уханя и Кантон).
## Цель атаки — у допустимого участка, так что за рамку фронт заходит не
## дальше чем на провинцию. Пусто — ограничения нет.
static func war_limit_fronts(world: World, nat: World.Nation) -> PackedInt32Array:
	if nat.war_limit.is_empty():
		return PackedInt32Array()
	var ctrl := world.p_controller
	var land := world.p_land
	var nc := world.nation_count
	var al := world.ally
	var fresh := al.size() == nc * nc   # = Diplomacy.same_side (Simulation._refresh_sides)
	var excl := _wl_excl(world, nat.war_limit)
	if fresh and Native.core != null and Native.core.has_method("side_provs"):
		var r: PackedInt32Array = Native.core.call("side_provs", ctrl, land, al, excl, nat.id, nc)
		if wl_check.size() == 2:
			wl_check[0] += 1
			if r != _side_provs_gd(world, nat, excl):
				wl_check[1] += 1
		return r
	return _side_provs_gd(world, nat, excl)


static var wl_check: Array = []   # [проверок, расхождений] — сверка ядра (tests/kernel_check.gd)


## Двойник MeowqCore.side_provs: наши и союзные провинции суши по возрастанию,
## кроме excl.
static func _side_provs_gd(world: World, nat: World.Nation, excl: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ctrl := world.p_controller
	var land := world.p_land
	var nc := world.nation_count
	var al := world.ally
	var fresh := al.size() == nc * nc
	var base := nat.id * nc
	for p in world.prov_count:
		# и союзная земля: японские войска в Таиланде идут на Малайю и Бирму
		if land[p] == 0 or excl[p] == 1:
			continue
		var c := ctrl[p]
		if c < 0 or (c != nat.id and not (al[base + c] == 1 if fresh else Diplomacy.same_side(world, c, nat.id))):
			continue
		out.append(p)
	return out


static var _wl_key := ""
static var _wl_mask := PackedByteArray()
static var _wl_of := 0


## Провинции страны-кода рубежа вне его рамок (код и координаты провинций за
## партию не меняются — маска по самому рубежу).
static func _wl_excl(world: World, wl: Array) -> PackedByteArray:
	var key := var_to_str(wl)
	if key == _wl_key and _wl_of == world.get_instance_id() and _wl_mask.size() == world.prov_count:
		return _wl_mask
	var code: String = wl[0]
	var boxes: Array = wl[1]
	var m := PackedByteArray()
	m.resize(world.prov_count)
	for p in _adm0_index(world).get(code, PackedInt32Array()):
		var ll: Vector2 = world.p_lonlat[p]
		var inside := false
		for b in boxes:
			if ll.x >= float(b[0]) and ll.y >= float(b[1]) and ll.x <= float(b[2]) and ll.y <= float(b[3]):
				inside = true
				break
		if not inside:
			m[p] = 1
	_wl_key = key
	_wl_mask = m
	_wl_of = world.get_instance_id()
	return m


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


## Осада (эффект siege): город ещё у врага, с которым воюем.
static func siege_on(world: World, nat: World.Nation, sp: int) -> bool:
	var c := world.p_controller[sp]
	return c >= 0 and c != nat.id and world.is_at_war(nat.id, c)


## Срок штурма осаждённого города: последние assault дней каждого периода.
static func siege_assault(world: World, nat: World.Nation, sp: int) -> bool:
	if not siege_on(world, nat, sp):
		return false
	var sg: Array = nat.siege[sp]
	var period: int = sg[1]
	return (world.day - int(sg[4])) % period >= period - int(sg[2])


## Второстепенные направления удара стран ИИ (CSR по странам): ax_start (nc + 1),
## ax_list — пары «провинция-цель, вес в %»: текущие вехи второстепенных
## направлений плана и осаждённые города в срок штурма. Только при идущем плане.
## st_start (nc + 1) / st_list — осаждённые города в срок штурма (с планом и без):
## их штурмуют тем, что собрано у города, без полного перевеса (STORM_NEED).
static func axes_tables(world: World) -> Array:
	var start := PackedInt32Array()
	var lst := PackedInt32Array()
	var st_start := PackedInt32Array()
	var st_list := PackedInt32Array()
	start.resize(world.nation_count + 1)
	st_start.resize(world.nation_count + 1)
	var n := 0
	for nid in world.nation_count:
		start[nid] = n
		st_start[nid] = st_list.size()
		var nat: World.Nation = world.nations[nid]
		if nat.is_player or not nat.alive:
			continue
		for sp in nat.siege:
			if siege_assault(world, nat, sp):
				st_list.append(sp)
		if offensive_objective(world, nat) < 0:
			continue
		if nat.offensive.size() > 4:
			for ax in nat.offensive[4]:
				var route: PackedInt32Array = ax[0]
				var p: int = route[int(ax[1])]
				if siege_on(world, nat, p) and not nat.siege.has(p):
					lst.append(p)
					lst.append(int(ax[2]))
					n += 1
		for sp in nat.siege:
			if siege_assault(world, nat, sp):
				lst.append(sp)
				lst.append(int(nat.siege[sp][3]))
				n += 1
	start[world.nation_count] = n
	st_start[world.nation_count] = st_list.size()
	return [start, lst, st_start, st_list]


## Осаждённые города (эффект siege у врага): prov_count, 1 — гарнизон (hold) не
## уходит на отдых и смену ниже заданного (иначе город пустеет под штурмом).
static func besieged_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	for nat in world.nations:
		if nat.siege.is_empty() or not nat.alive:
			continue
		for sp in nat.siege:
			if siege_on(world, nat, sp):
				if t.is_empty():
					t.resize(world.prov_count)
				t[int(sp)] = 1
	return t


## Аргументы plan_job из opts (главный поток): всё, что план читает у страны.
static func military_args(world: World, nid: int, divs: PackedInt32Array, opts: Dictionary) -> Array:
	var nat: World.Nation = world.nations[nid]
	var objective: int = opts.get("objective", -1)
	var fr: Variant = opts.get("fronts", {})
	var allowed: PackedInt32Array = fr if fr is PackedInt32Array else PackedInt32Array((fr as Dictionary).keys())
	return [nid, divs, ["auto", "hold", "attack"].find(opts.get("mode", "auto")), int(opts.get("enemy", -1)), objective,
		allowed, float(opts.get("ratio", 1.15 if objective >= 0 else 1.3)), nat.capital,
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
	# выделенный игроком участок (кисть, Hud): наши провинции — как есть, цели
	# атаки — со знаком минус (−(q+1)); пусто — весь фронт
	var allowed := {}
	var tgt := {}
	for p in allowed_list:
		if p >= 0:
			allowed[p] = true
		else:
			tgt[-p - 1] = true
	var has_tgt := not tgt.is_empty()

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
	var guard: PackedByteArray = tb.get("guard", PackedByteArray())
	var guard_w: PackedFloat32Array = tb.get("guard_w", PackedFloat32Array())
	var prov_count := land.size()
	var atklim: PackedByteArray = tb.get("atklim", PackedByteArray())
	var atk_base := nid * prov_count if atklim.size() == nc * prov_count else -1
	var holdt: PackedByteArray = tb.get("hold", PackedByteArray())
	var hold_base := nid * prov_count if holdt.size() == nc * prov_count else -1
	var besieged: PackedByteArray = tb.get("besieged", PackedByteArray())
	var has_cap := supcap.size() == prov_count
	# туман войны (World.fog_table): врагов вне видимости не считаем; своя и
	# союзная земля видна всегда
	var fog: PackedByteArray = tb.get("fog", PackedByteArray())
	var fog_base := nid * prov_count if fog.size() == nc * prov_count else -1
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
	# охрана границ по отношениям (guard_table) — только общий план страны ИИ
	var use_guard := guard.size() == nc * nc and guard_w.size() == nc * nc and mode == "auto" and enemy < 0 and allowed.is_empty() and not has_tgt
	var war_front := {}   # участки у противника (в войну)
	var guard_lvl := {}   # война: наша провинция у враждебного не-противника -> 1 (минимум)
	var sparse_cand := {} # война: наша провинция у нейтрала — охрана через провинцию
	var gw := {}          # мир: наша провинция -> худшие отношения соседей (вес, guard_w)
	# до войны с выбранной страной (развёртывание): и союзная земля у её границы —
	# обычный участок (вермахт в Румынии, Болгарии и Венгрии весной 1941 г.)
	var stage_ally := not at_war and enemy >= 0
	for p in prov_count:
		var own_p := ctrl[p] == nid
		if not own_p and not ((at_war or stage_ally) and ctrl[p] >= 0 and ally.size() > 0 and ally[nid * nc + ctrl[p]] == 1):
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
					war_front[p] = true
				elif use_guard and own_p and not hostile and guard[nid * nc + c] == 2:
					# в войну: граница с враждебным не-противником — минимум
					fronts[p] = true
					guard_lvl[p] = 1
				elif use_guard and own_p and not hostile and guard[nid * nc + c] != 0:
					sparse_cand[p] = true   # нейтрал или слабый сосед
			elif (own_p or (stage_ally and c == enemy)) and matches and (enemy >= 0 or mode == "auto" or has_tgt) and (ally.size() == 0 or ally[nid * nc + c] == 0):
				var g := 2
				if use_guard:
					g = guard[nid * nc + c]
					if g == 0:
						continue   # хорошие отношения — границу не держим
					if g == 3:
						sparse_cand[p] = true   # слабый сосед — в мир тоже лишь минимум
						continue
				fronts[p] = true
				if use_guard:
					gw[p] = maxf(float(gw.get(p, 0.0)), guard_w[nid * nc + c])
				fpairs.append(p)
				fpairs.append(q)
	# участки «ровно минимум»: в войну у враждебного не-противника — каждая
	# провинция; у нейтрала и слабого соседа (в мир — только у слабого) — реже:
	# провинция, рядом с которой нет участка фронта
	# (по возрастанию номера — одинаково в GDScript и C++)
	var guard_min := {}
	for p in guard_lvl:
		if not war_front.has(p):
			guard_min[p] = true
	for p in sparse_cand:
		if fronts.has(p):
			continue
		var covered := false
		for k in range(a_start[p], a_start[p + 1]):
			if fronts.has(a_list[k]):
				covered = true
				break
		if not covered:
			fronts[p] = true
			guard_min[p] = true
	if not allowed.is_empty() or has_tgt:
		for f in fronts.keys():
			if not allowed.has(f):
				fronts.erase(f)
		for t in targets.keys():
			var near := false
			if has_tgt:
				near = tgt.has(t)
			else:
				for k in range(a_start[t], a_start[t + 1]):
					if allowed.has(a_list[k]):
						near = true
						break
			if not near:
				targets.erase(t)
		var fp := PackedInt32Array()
		for i in range(0, fpairs.size(), 2):
			if allowed.has(fpairs[i]) and (not has_tgt or tgt.has(fpairs[i + 1])):
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
		# гарнизон (эффект hold) — участок и вдали от фронта: войска стягиваются
		# заранее (Ленинград с июля 1941 г., а не когда немцы уже у города)
		if hold_base >= 0:
			for p in prov_count:
				if ctrl[p] == nid and holdt[hold_base + p] > 0:
					fronts[p] = true

	var idle := PackedInt32Array()
	var in_group := {}
	for i in divs:
		in_group[i] = true
		if dv_flags[i] & 1 == 1:
			idle.append(i)
	if idle.is_empty():
		return result

	# направления удара: главное (цель наступления, вес 100) и второстепенные из
	# плана страны (таблица ax_start / ax_list: пары «провинция, вес в %») — только
	# для общего плана страны (mode auto), не для котлов и деблокирования
	var ax_prov := PackedInt32Array()
	var ax_w := PackedInt32Array()
	if objective >= 0:
		ax_prov.append(objective)
		ax_w.append(100)
		var ax_start: PackedInt32Array = tb.get("ax_start", PackedInt32Array())
		if mode_i == 0 and ax_start.size() == nc + 1:
			var ax_list: PackedInt32Array = tb["ax_list"]
			for k in range(ax_start[nid], ax_start[nid + 1]):
				ax_prov.append(ax_list[2 * k])
				ax_w.append(ax_list[2 * k + 1])
	var n_ax := ax_prov.size()
	var bl: PackedByteArray = tb.get("blitz", PackedByteArray())
	var blitz := mode_i == 0 and bl.size() == nc and bl[nid] == 1
	# штурм осаждённого города (st_start / st_list) — только общий план страны
	var storm := {}
	var st_start: PackedInt32Array = tb.get("st_start", PackedInt32Array())
	if mode_i == 0 and st_start.size() == nc + 1:
		var st_list: PackedInt32Array = tb["st_list"]
		for k in range(st_start[nid], st_start[nid + 1]):
			storm[st_list[k]] = true
	# расстояние до цели каждого направления (по суше, без учёта владельца)
	var obj_dist := PackedInt32Array()
	if n_ax > 0:
		obj_dist.resize(n_ax * prov_count)
		obj_dist.fill(1 << 20)
		for a in n_ax:
			var base := a * prov_count
			obj_dist[base + ax_prov[a]] = 0
			var queue := PackedInt32Array([ax_prov[a]])
			var head := 0
			while head < queue.size():
				var p := queue[head]
				head += 1
				for k in range(a_start[p], a_start[p + 1]):
					var q := a_list[k]
					if land[q] == 1 and obj_dist[base + q] > obj_dist[base + p] + 1:
						obj_dist[base + q] = obj_dist[base + p] + 1
						queue.append(q)

	var used := {}
	var orders: Array = []
	# направление удара: лучшие цели атаки, к ним стягиваем силы; значение —
	# номер направления (0 — главное или без плана)
	var main_axis := {}
	var t_axis := {}   # цель -> ближайшее направление
	if attack_allowed:
		# Атакуем слабые вражеские провинции превосходящими силами; при цели —
		# в первую очередь те, что ближе к ней.
		var target_list: Array = []
		var empty_t := {}   # цели без видимого врага
		for t in targets:
			var enemy_str := 0.0
			var pocketed := 0
			var t_end := pd_start[t + 1]
			if fog_base >= 0 and fog[fog_base + t] == 0 and ctrl[t] != nid and (ctrl[t] < 0 or ally.size() == 0 or ally[nid * nc + ctrl[t]] == 0):
				t_end = pd_start[t]   # не видно — врагов там не знаем
			for k in range(pd_start[t], t_end):
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
			if n_ax > 0:
				var best := 0
				for a in range(1, n_ax):
					if obj_dist[a * prov_count + t] < obj_dist[best * prov_count + t]:
						best = a
				t_axis[t] = best
				score += obj_dist[best * prov_count + t] * 25.0
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
			# нужная сила: множитель обороны сверх FORT_LIN (крепости) — корнем
			# (квадратичный закон: каждая новая атакующая дивизия добавляет и урон, и
			# запас организации; линейно — крепость не брали никогда: Рим, Ленинград)
			var need_mult := def_mult
			if def_mult > FORT_LIN:
				need_mult = FORT_LIN * sqrt(def_mult / FORT_LIN)
			target_list.append([score, t, enemy_str * need_mult * risk / climf, dirs])
			if enemy_str <= 0.0:
				empty_t[t] = true
		# порядок однозначный (при равенстве — номер провинции): так же сортирует C++
		target_list.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
		if n_ax == 0:
			for j in mini(3, target_list.size()):
				main_axis[int(target_list[j][1])] = 0
		else:
			# на каждое направление — свои лучшие цели: главному AXIS_TARGETS, второстепенному
			# по весу (при 6: 40 % — 2, 60 % — 4)
			var quota := PackedInt32Array()
			quota.resize(n_ax)
			for a in n_ax:
				quota[a] = maxi(1, int(round((BLITZ_TARGETS if blitz else AXIS_TARGETS) * float(ax_w[a]) / 100.0)))
			for entry in target_list:
				var a: int = t_axis[int(entry[1])]
				if quota[a] > 0:
					quota[a] -= 1
					main_axis[int(entry[1])] = a
		var left := {}   # сколько наших дивизий останется в провинции
		for entry in target_list:
			var t: int = entry[1]
			var need: float = entry[2] * ratio
			# направление главного удара к цели наступления — сил с запасом (AXIS_COMMIT)
			var commit: float = need
			if n_ax > 0 and main_axis.has(t):
				commit = need * (1.0 + ((BLITZ_COMMIT if blitz else AXIS_COMMIT) - 1.0) * float(ax_w[int(main_axis[t])]) / 100.0)
			# осторожная страна не лезет в пустую провинцию-выступ (котёл)
			if float(entry[2]) <= 0.0 and ratio >= 4.0 and int(entry[3]) < 2:
				continue
			var breach := n_ax > 0 and float(entry[2]) <= 0.0 and main_axis.has(t)
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
					# у гарнизона (hold) — только наши, что остаются: атакующие из провинции
					# числятся в ней, пока идёт бой (иначе вылазка набирается день за днём)
					if hold_base >= 0 and holdt[hold_base + pv] > 1:
						var stay := 0
						for m in range(pd_start[pv], pd_start[pv + 1]):
							if dv_owner[pd_list[m]] == nid and dv_flags[pd_list[m]] & 8 == 0:
								stay += 1
						left[pv] = stay
				# последняя дивизия участок не бросает — кроме прорыва: пустая провинция на
				# направлении удара к цели наступления (участок заполнится в следующий раз);
				# гарнизон (эффект hold) идёт в атаку только излишком сверх заданного
				var keep := 1
				if hold_base >= 0:
					keep = maxi(1, int(holdt[hold_base + pv]))
				if int(left[pv]) <= keep and not (breach and keep == 1 and int(left[pv]) == 1):
					continue
				chosen.append(i)
				left[pv] = int(left[pv]) - 1
				power += dv_power[i]
				if power > commit and (entry[2] <= 0.0 or chosen.size() >= 2):
					break
			# штурм осаждённого города — тем, что собрано, с долей нужного перевеса
			if power > (need * STORM_NEED if storm.has(t) else need) and not chosen.is_empty():
				# блицкриг — развитие прорыва: за целью следующая пустая цель ближе к цели
				# наступления (не ждать нового плана после захвата)
				var nxt := -1 if n_ax == 0 or not blitz else _exploit(t, t_axis, obj_dist, prov_count, a_start, a_list, targets, empty_t)
				for i in chosen:
					used[i] = true
					orders.append([i, PackedInt32Array([t]) if nxt < 0 else PackedInt32Array([t, nxt])])
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
			# гарнизон (hold) осаждённого города не уходит ниже заданного
			var hn := 0
			if hold_base >= 0 and besieged.size() == prov_count and besieged[pv] == 1:
				hn = int(holdt[hold_base + pv])
			if o < REGROUP_ORG:
				go = hn == 0 or int(ours_left[pv]) > hn
			elif o < ROTATE_ORG:
				go = int(ours_left[pv]) > maxi(1, hn)
			elif hold_base < 0 or holdt[hold_base + pv] == 0:   # гарнизон не отходит
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
	var axis_front := {}   # к цели наступления: участки удара -> вес направления (доля ёмкости снабжения)
	for f in fronts:
		var threat := 0.0
		for k in range(a_start[f], a_start[f + 1]):
			var q := a_list[k]
			if fog_base >= 0 and fog[fog_base + q] == 0 and ctrl[q] != nid and (ctrl[q] < 0 or ally.size() == 0 or ally[nid * nc + ctrl[q]] == 0):
				continue   # туман войны
			for m in range(pd_start[q], pd_start[q + 1]):
				var eo := dv_owner[pd_list[m]]
				if eo != nid and (ally.size() == 0 or ally[nid * nc + eo] == 0):
					if use_guard and not at_war and guard[nid * nc + eo] == 0:
						continue   # в мир угроза — только от тех, чью границу держим
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
			# у направления удара по плану — и на союзной земле до ёмкости снабжения
			# за вычетом союзников (Апрельская война: удар на Белград из Венгрии)
			if not main_axis.is_empty() and n_ax > 0 and has_cap:
				var aw2 := 0
				for k in range(a_start[f], a_start[f + 1]):
					if main_axis.has(a_list[k]):
						aw2 = maxi(aw2, ax_w[int(main_axis[a_list[k]])])
				if aw2 > 0:
					axis_front[f] = aw2
					ally_need[f] = maxf(float(ally_need[f]), float(_axis_cap(supcap[f], aw2) - allyc))
			continue
		if guard_min.has(f):
			weight[f] = 0.0   # минимум — вне раздела армии
			continue
		weight[f] = 1.0 + threat + vp[f] * 0.15   # крупные города держим плотнее
		# мир: вся армия на границах, больше — где отношения хуже
		if use_guard and not at_war:
			weight[f] = float(weight[f]) * (1.0 + GUARD_WMUL * float(gw.get(f, 0.0)))
		# участки у направления главного удара — плотнее (в пределах снабжения)
		if not main_axis.is_empty():
			var aw := 0
			for k in range(a_start[f], a_start[f + 1]):
				if main_axis.has(a_list[k]):
					aw = maxi(aw, ax_w[int(main_axis[a_list[k]])] if n_ax > 0 else 1)
			if aw > 0:
				weight[f] = float(weight[f]) + 3.0
				if n_ax > 0:
					axis_front[f] = aw
		wsum += weight[f]
	var desired := {}
	# план наступления: участкам главного удара — до ёмкости снабжения, прочим —
	# остаток армии (их лишние дивизии уходят к удару)
	var pool := divs.size()
	if has_cap and not axis_front.is_empty():
		for f in axis_front:
			pool -= maxi(0, int(ceil(float(ally_need[f])))) if ally_front.has(f) else _axis_cap(supcap[f], axis_front[f])
		pool = maxi(0, pool)
	for f in fronts:
		if ally_front.has(f):
			desired[f] = maxi(0, int(ceil(float(ally_need[f]))))
			if has_cap:
				desired[f] = mini(int(desired[f]), maxi(1, int(floor(supcap[f]))))
			continue
		if guard_min.has(f):
			desired[f] = 1
			if hold_base >= 0 and holdt[hold_base + f] > 0:
				desired[f] = maxi(1, int(holdt[hold_base + f]))
			continue
		desired[f] = maxi(1, int(round(pool * weight[f] / wsum))) if wsum > 0.0 else 1
		# не больше, чем провинция прокормит (снабжение по узлам районов)
		if has_cap:
			desired[f] = mini(int(desired[f]), maxi(1, int(floor(supcap[f]))))
			# план наступления: участки главного удара заполняем до ёмкости снабжения
			if axis_front.has(f):
				desired[f] = _axis_cap(supcap[f], axis_front[f])
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
	# мир: наши провинции у чужой земли — отвод лишних к столице, тыл перегруза без них
	var withdraw := use_guard and not at_war and capital >= 0 and ctrl[capital] == nid
	var border := {}
	if withdraw:
		for p in prov_count:
			if ctrl[p] != nid or land[p] == 0:
				continue
			for k in range(a_start[p], a_start[p + 1]):
				var q := a_list[k]
				if land[q] == 1 and ctrl[q] >= 0 and ctrl[q] != nid:
					border[p] = true
					break
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
		# мир: с границы, которую не держим (хорошие отношения), — к столице, если
		# участкам фронта никого не нужно или до них по суше не дойти (остров)
		var back := withdraw and pv != capital and not fronts.has(pv) and border.has(pv)
		var path := PackedInt32Array()
		if not goal.is_empty():
			path = _nearest(tb, nid, pv, goal)
		if path.is_empty() and back:
			path = _nearest(tb, nid, pv, {capital: true})
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
			if int(rcount[q]) < maxi(1, int(floor(supcap[q]))) and not border.has(q):
				goal[q] = true
		for i in idle:
			if used.has(i):
				continue
			var pv := dv_prov[i]
			var cap_pv := maxi(1, int(floor(supcap[pv])))
			if fronts.has(pv) and hold_base >= 0:
				cap_pv = maxi(cap_pv, int(holdt[hold_base + pv]))   # гарнизон — сверх снабжения
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
				if int(rcount[pv]) < cap_pv and not border.has(pv):
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
const CAP_GARRISON := 6  # крупный город у фронта: гарнизон не меньше (решение пользователя)
const CAP_VP := 50       # «крупный» — очки победы столичные (Москва, Берлин, Рим, Нанкин)
const CAP_NEAR := 2      # «у фронта» — враг в стольких переходах по суше
const FORT_LIN := 2.5    # оценка силы на цель: множитель обороны до 2,5 — как есть, сверх — корнем (крепости)
const STORM_NEED := 0.1  # штурм осаждённого города в его срок: атака при силе > 1/10 нужной (решение пользователя: «время от времени пытаются взять»)
const GUARD_EVERY := 3   # охрана границ: отношения и претензии пересматриваем раз в 3 дня (решение пользователя)
const GUARD_GOOD := 65.0 # отношения от 65 — границу не держим (демократии между собой — 65)
const GUARD_WMUL := 2.0 # мир: вес участка × (1 + 2 × вес границы) — нейтральный ×1..3, плохой ×3..6, претензии +2
const GUARD_WEAK := 0.15  # сосед с союзниками слабее 15 % нашей армии — лишь минимум и в мир (уровень 3)
const GUARD_BAD := 40.0  # ниже 40 — держим фронт (демократия и фашизм — 35, фашизм и коммунизм — 25)
const AXIS_COMMIT := 2.0 # к цели наступления (план, группа с целью): на лучшие цели — вдвое больше нужного
const AXIS_TARGETS := 3.0 # лучших целей главного направления (второстепенному — по весу)
# блицкриг (черта с ключом blitz, «Барбаросса»): на лучшие цели — вчетверо, их вдвое
# больше, и развитие прорыва (за целью — следующая пустая); без него «Барбаросса»
# ползла: Минск в августе, Смоленск в сентябре 1941 г.
const BLITZ_COMMIT := 4.0
const BLITZ_TARGETS := 6.0


## Участок у направления удара: доля ёмкости снабжения по весу направления
## (главное — вся ёмкость), не меньше одной дивизии.
static func _axis_cap(cap: float, w: int) -> int:
	if w >= 100:
		return maxi(1, int(floor(cap)))
	return maxi(1, int(floor(cap * float(w) / 100.0)))


## Провинция, которую не удержать: наши в ней уже в бою, а сила атакующих (враги
## в бою в соседних провинциях) больше обороны (с местностью) в ESCAPE_RATIO раз.
## Развитие прорыва: за целью t — следующая пустая цель ближе к цели наступления
## (направление t). Нет — -1. При равенстве — меньший номер провинции.
static func _exploit(t: int, t_axis: Dictionary, obj_dist: PackedInt32Array, prov_count: int,
		a_start: PackedInt32Array, a_list: PackedInt32Array, targets: Dictionary, empty_t: Dictionary) -> int:
	var base: int = int(t_axis[t]) * prov_count
	var best := -1
	for k in range(a_start[t], a_start[t + 1]):
		var q := a_list[k]
		if not targets.has(q) or not empty_t.has(q) or obj_dist[base + q] >= obj_dist[base + t]:
			continue
		if best < 0 or obj_dist[base + q] < obj_dist[base + best] or (obj_dist[base + q] == obj_dist[base + best] and q < best):
			best = q
	return best


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
	var axt := axes_tables(world)
	var gt := guard_table(world)   # до world.guard_w: пересчёт обновляет обе таблицы
	return {"ax_start": axt[0], "ax_list": axt[1], "st_start": axt[2], "st_list": axt[3], "besieged": besieged_table(world), "ctrl": world.p_controller, "land": world.p_land, "adj_start": world.adj_start, "adj_list": world.adj_list,
		"war": world.war, "ally": world.ally, "pass": world.pass_table(), "nc": world.nation_count, "def": world.p_def_mult, "vp": world.vp_ai(),
		"coastal": world.p_coastal, "owner": world.p_owner, "dv_id": world.dv_id, "dv_owner": world.dv_owner,
		"dv_prov": world.dv_prov, "dv_flags": world.dv_flags, "dv_org": world.dv_org, "dv_power": world.dv_power,
		"dv_defw": world.dv_defw, "pd_start": world.pd_start, "pd_list": world.pd_list, "supcap": world.p_supcap,
		"guard": gt, "guard_w": world.guard_w, "nohit": no_attack_table(world), "atklim": attack_limit_table(world), "hold": hold_table(world), "dv_sup": world.d_sup, "p_hot": world.p_hot, "p_cold": world.p_cold,
		"n_hot": world.n_hot, "n_cold": world.n_cold, "blitz": blitz_table(world), "fog": world.fog_table() if world.fog_ai else PackedByteArray()}


## Блицкриг по странам (черта с ключом blitz): nc, 1 — да.
static func blitz_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	t.resize(world.nation_count)
	for nat in world.nations:
		if nat.id < world.nation_count and nat.alive and nat.b("blitz") > 0.0:
			t[nat.id] = 1
	return t


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
		# осада: город вне срока штурма — не цель (кольцо держат, но не лезут);
		# в срок штурма — цель и поверх рамки операций (зимой 1941–42 гг. и при
		# «Блау» рамка Германии — только юг России)
		var closed: Array = []
		var opened: Array = []
		for sp in nat.siege:
			if siege_on(world, nat, sp):
				if siege_assault(world, nat, sp):
					opened.append(sp)
				else:
					closed.append(sp)
		if not nat.defend_lands.is_empty():
			lims.append([nat.defend_lands, [[0.0, 0.0, 0.0, 0.0]], []])
		if (not lims.is_empty() or not closed.is_empty()) and t.is_empty():
			t.resize(world.nation_count * pc)
		for lim in lims:
			_attack_limit_fill(world, t, nat.id, lim)
		for sp in closed:
			t[nat.id * pc + int(sp)] = 1
		if not t.is_empty():
			for sp in opened:
				t[nat.id * pc + int(sp)] = 0
	return t


static var _lim_memo := {}   # hash(рамки) -> [рамки, провинции вне них]
static var _lim_of := 0


static func _attack_limit_fill(world: World, t: PackedByteArray, nid: int, lim: Array) -> void:
	# провинции вне рамок зависят только от рамок (p_adm0, p_lonlat неизменны)
	if _lim_of != world.get_instance_id():
		_lim_memo = {}
		_lim_of = world.get_instance_id()
	var h := hash(lim)
	var e: Variant = _lim_memo.get(h)
	if e == null or e[0] != lim:
		e = [lim.duplicate(true), _attack_limit_provs(world, lim)]
		_lim_memo[h] = e
	var base: int = nid * world.prov_count
	for p in e[1]:
		t[base + p] = 1


static func _attack_limit_provs(world: World, lim: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var codes: Array = lim[0]
	var boxes: Array = lim[1]
	var excl: Array = lim[2] if lim.size() > 2 else []
	var by_code := _adm0_index(world)
	var lonlat := world.p_lonlat
	var seen := {}
	for code in codes:
		if seen.has(code) or not by_code.has(code):
			continue
		seen[code] = true
		for p: int in by_code[code]:
			var ll: Vector2 = lonlat[p]
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
				out.append(p)
	return out


static var _adm0_idx := {}
static var _adm0_of := 0


## Провинции по коду страны Natural Earth (p_adm0 не меняется за партию).
static func _adm0_index(world: World) -> Dictionary:
	if _adm0_of != world.get_instance_id() or _adm0_idx.is_empty():
		var idx := {}
		for p in world.prov_count:
			var code := world.p_adm0[p]
			if not idx.has(code):
				idx[code] = PackedInt32Array()
			var lst: PackedInt32Array = idx[code]
			lst.append(p)
			idx[code] = lst
		_adm0_idx = idx
		_adm0_of = world.get_instance_id()
	return _adm0_idx


## Гарнизоны (Nation.hold): nc×prov_count — не меньше дивизий на участке фронта;
## пусто — гарнизонов нет.
static var _big := PackedInt32Array()
static var _big_of := 0
static var _big_pc := 0


static func hold_table(world: World) -> PackedByteArray:
	var t := PackedByteArray()
	var pc := world.prov_count
	# крупный город (очки победы столичные, CAP_VP) у фронта — враг в CAP_NEAR
	# переходах по суше — гарнизон не меньше CAP_GARRISON (решение пользователя:
	# важные города, как Москва, держать на крайний случай; столица могла переехать).
	# Только своя национальная земля (Claims): не захваченные и не переданные —
	# Германия держала бы Париж, Прагу и Рим после перемирия Италии.
	# Один проход по городам (у города один хозяин), по возрастанию номера.
	var caps_of := {}
	var vp := world.p_vp
	var land := world.p_land
	var ctrl := world.p_controller
	# без войны врага рядом нет (_enemy_near смотрит war) — города мирных стран
	# не обходим
	var nc := world.nation_count
	var war := world.war
	var at_war := PackedByteArray()
	at_war.resize(nc)
	for n in nc:
		var w := war.find(1, n * nc)
		if w >= 0 and w < (n + 1) * nc:
			at_war[n] = 1
	if _big_of != world.get_instance_id() or _big_pc != pc:
		# крупные города суши (очки победы задаются картой и не меняются)
		_big = PackedInt32Array()
		for c in pc:
			if vp[c] >= CAP_VP and land[c] != 0:
				_big.append(c)
		_big_of = world.get_instance_id()
		_big_pc = pc
	for c in _big:
		var n := ctrl[c]
		if n < 0 or at_war[n] == 0:
			continue
		var on: World.Nation = world.nations[n]
		if on.is_player or not on.alive or not Claims.is_core(world, n, c) or not _enemy_near(world, n, c, CAP_NEAR):
			continue
		if not caps_of.has(n):
			caps_of[n] = []
		caps_of[n].append(c)
	for nat in world.nations:
		if nat.is_player or not nat.alive:
			continue
		var caps: Array = caps_of.get(nat.id, [])
		if nat.hold.is_empty() and nat.siege.is_empty() and caps.is_empty():
			continue
		if t.is_empty():
			t.resize(world.nation_count * pc)
		for c in caps:
			t[nat.id * pc + int(c)] = CAP_GARRISON
		for hp in nat.hold:
			t[nat.id * pc + int(hp)] = maxi(t[nat.id * pc + int(hp)], clampi(int(nat.hold[hp]), 0, 255))
		# осада: на каждом нашем участке у города — не меньше n дивизий (кольцо)
		for sp in nat.siege:
			if not siege_on(world, nat, sp):
				continue
			var sn := clampi(int(nat.siege[sp][0]), 0, 255)
			for k in range(world.adj_start[sp], world.adj_start[sp + 1]):
				var q := world.adj_list[k]
				if world.p_land[q] == 1 and world.p_controller[q] == nat.id:
					t[nat.id * pc + q] = maxi(t[nat.id * pc + q], sn)
	return t


## Враг (страна, с которой воюем) — в depth переходах по суше от провинции p.
static func _enemy_near(world: World, nid: int, p: int, depth: int) -> bool:
	var nc := world.nation_count
	var seen := {p: 0}
	var q: Array = [p]
	var head := 0
	var ctrl := world.p_controller
	var war := world.war
	var a_start := world.adj_start
	var a_list := world.adj_list
	var land := world.p_land
	while head < q.size():
		var x: int = q[head]
		head += 1
		var c := ctrl[x]
		if c >= 0 and c != nid and war[nid * nc + c] == 1:
			return true
		if int(seen[x]) >= depth:
			continue
		for k in range(a_start[x], a_start[x + 1]):
			var y := a_list[k]
			if land[y] == 1 and not seen.has(y):
				seen[y] = int(seen[x]) + 1
				q.append(y)
	return false


## Охрана границ ИИ (решение пользователя, ноябрь 2026): как страна A держит
## границу с B — 0 не держит (союзник, хорошие отношения), 1 — минимум (по дивизии
## на провинцию; нейтральные отношения), 2 — фронт (плохие отношения или претензии
## одной из сторон, в том числе к союзнику A), 3 — слабый сосед: B с союзниками
## слабее GUARD_WEAK армии A, и A к нему претензий нет — лишь минимум и в мир.
## Отношения — худшее из двух мнений.
## В войну с не-противником: 2 — по дивизии на провинцию, 1 и 3 — через провинцию. nc×nc; пересчёт раз в
## GUARD_EVERY дней (таблица хранится в мире и попадает в сохранение).
static func guard_table(world: World) -> PackedByteArray:
	var nc := world.nation_count
	if world.guard_t.size() == nc * nc and world.guard_w.size() == nc * nc and world.day - world.guard_day < GUARD_EVERY:
		return world.guard_t
	var t := PackedByteArray()
	t.resize(nc * nc)
	var tw := PackedFloat32Array()   # вес границы в мир: (65 − отношения) / 25, претензии +1
	tw.resize(nc * nc)
	var ally := world.ally
	# претензии страны: к кому обоснованы или обосновываются
	var claims: Array = []
	claims.resize(nc)
	for b in nc:
		var nb: World.Nation = world.nations[b]
		var cl := PackedInt32Array()
		if nb.alive:
			for k in nb.wargoals.keys():
				cl.append(int(k))
			if nb.justify_target >= 0:
				cl.append(nb.justify_target)
		claims[b] = cl
	# армия страны (для «слабого соседа»)
	var own := PackedInt32Array()
	own.resize(nc)
	for a in nc:
		if world.nations[a].alive:
			own[a] = world.nations[a].division_count
	# соседство стран по суше (по контролю провинций)
	var nb_t := PackedByteArray()
	nb_t.resize(nc * nc)
	var ctrl := world.p_controller
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	for p in ctrl.size():
		var cp := ctrl[p]
		if cp < 0 or land[p] == 0:
			continue
		for k in range(a_start[p], a_start[p + 1]):
			var cq := ctrl[a_list[k]]
			if cq >= 0 and cq != cp and land[a_list[k]] == 1:
				nb_t[cp * nc + cq] = 1
	for a in nc:
		if not world.nations[a].alive:
			continue
		for b in nc:
			if a == b or not world.nations[b].alive or ally[a * nc + b] == 1:
				continue
			var r := minf(Relations.rep(world, a, b), Relations.rep(world, b, a))
			var g := 1
			if r >= GUARD_GOOD:
				g = 0
			elif r < GUARD_BAD:
				g = 2
			# претензии B к нам или к нашему союзнику, наши — к B
			var claim := false
			for x in claims[b]:
				if x == a or ally[a * nc + x] == 1:
					claim = true
					break
			var mine := false   # наши претензии к B — граница под удар, не охрана
			for x in claims[a]:
				if x == b:
					mine = true
					break
			if claim or mine:
				g = 2
			# слабый сосед (с союзниками, что тоже граничат с нами, меньше GUARD_WEAK
			# нашей армии) не угроза:
			# граница — лишь минимум и в мир (не держим 30 дивизий у Афганистана)
			if g > 0 and not mine and nb_t[a * nc + b] == 1 and float(_bloc_at(b, a, own, ally, nb_t, nc)) < GUARD_WEAK * float(own[a]):
				g = 3
			claim = claim or mine
			t[a * nc + b] = g
			if g == 1 or g == 2:
				tw[a * nc + b] = maxf(0.0, (GUARD_GOOD - r) / (GUARD_GOOD - GUARD_BAD)) + (1.0 if claim else 0.0)
	world.guard_t = t
	world.guard_w = tw
	world.guard_day = world.day
	return t


## Армия B вместе с союзниками B, которые тоже граничат с A (охрана границ).
static func _bloc_at(b: int, a: int, own: PackedInt32Array, ally: PackedByteArray, nb_t: PackedByteArray, nc: int) -> int:
	var sb := own[b]
	for x in nc:
		if x != b and x != a and ally[b * nc + x] == 1 and ally[a * nc + x] == 0 and nb_t[x * nc + a] == 1:
			sb += own[x]
	return sb


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
