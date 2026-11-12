class_name Supply
extends RefCounted
## Снабжение по принципу жанра (режим world.supply_regions, флаг
## -- --supply=regions; числа свои):
##  * источники — столица и открытые порты (мощность порта — по его величине),
##    плацдармы высадок;
##  * узлы снабжения — главный город каждого района (воздушного района), где
##    сторона держит провинции; узел работает, если связан с источником
##    железной дорогой по районам своей стороны;
##  * пропускная способность дороги — по самому слабому району пути (уровень
##    дороги района — средняя ёмкость его провинций), самый широкий путь; длинная
##    дорога теряет подачу (RAIL_LOSS за район, не ниже RAIL_MIN); захваченная
##    дорога другой колеи (широкая — СССР, Финляндия) даёт вдвое меньше;
##  * в районе действует один источник стороны — самый сильный из узла,
##    столицы и портов; он подаёт снабжение в провинции в радиусе HUB_RANGE
##    переходов, с каждым переходом меньше (FALLOFF); провинция берёт лучшую
##    подачу плюс своё местное снабжение (LOCAL × ёмкость провинции);
##  * дивизии в провинции делят её снабжение (моторизованные — ×1,5 нагрузки);
##    в окружении (нет связи с источником по своей территории) узлы не работают,
##    местного — POCKET_LOCAL.
##
## Поле подачи (field) — упреждением: накануне в фоне по снимку территории
## (Spec), вчерашние данные — естественное отставание подвоза: провинция,
## взятая за сутки, получает только местное снабжение. Раздача по дивизиям
## (divisions) — каждый день по сегодняшней территории. Оба расчёта — чистые
## функции от снимка: GDScript (подача — параллельно по районам) и C++
## (MeowqCore.supply_field / supply_divs), результаты совпадают до бита.

const HUB_RANGE := 6
const FALLOFF := 0.8          # доля, доходящая через каждый переход после первого
const LOCAL := 0.5            # местное снабжение провинции: × ёмкость (2–6)
const CAPITAL := 14.0         # подача столицы
const PORT_BASE := 4.0        # подача порта: 4 + 1,5 × очки победы (до 5)
const PORT_VP := 1.5
const LEVEL_K := 3.0          # подача узла = 3 × уровень дороги (самое узкое место пути)
# длина дороги мощность не режет (решение пользователя, ноябрь 2026): связь со
# столицей (портом) нужна лишь, чтобы узел работал; мощность — от узкого места
# дороги и уровня узла, нагрузка — от ближайшего к войскам узла
const RAIL_LOSS := 0.0
const RAIL_MIN := 0.3
const GAUGE_LOSS := 0.5       # чужая колея: провинция даёт дороге вдвое меньше
const POCKET_LOCAL := 0.3     # отрезанная от источников провинция: местного снабжения — 30 %
# Узлы (ноябрь 2026): у каждого узла — бюджет подачи (BUDGET_K × его подача);
# провинция берёт сначала у ближайшего узла, остаток — у следующих по
# удалённости (до K_CAND узлов): основную нагрузку несут ближние.
const K_CAND := 3
const BUDGET_K := 2.0
# помощь дальнего узла ближайшему к войскам (решение пользователя): чем ближе
# он к ближайшему узлу, тем больше берёт — −SPILL_STEP за каждый переход между
# узлами, не меньше SPILL_MIN (и SPILL_MIN, если узлы дальше радиуса друг от друга)
const SPILL_STEP := 0.15
const SPILL_MIN := 0.1
# улучшение узла (стройка): уровень 0..NODE_MAX — подача +NODE_UP за уровень,
# радиус +1 за каждые 2 уровня, дорога района +RAIL_UP за уровень (узкие места)
const NODE_MAX := 5
const NODE_UP := 0.25
const RAIL_UP := 0.5
# доставка от узла к войскам: 0 — конная, 1 — половина на грузовиках, 2 — грузовики
const TRUCK_CAP := [1.0, 1.2, 1.4]
const TRUCK_RANGE := [0, 1, 2]
const TRUCK_SHARE := [0.0, 0.5, 1.0]
const TRUCK_USE := 0.01       # грузовиков в день на единицу подачи узла (при полной доле)
const MAX_RANGE := HUB_RANGE + NODE_MAX / 2 + 2
## Широкая колея (как было: СССР, Финляндия); у остальных — стандартная.
const BROAD_GAUGE := ["SOV", "FIN"]


## Неизменные таблицы: соседство районов по суше (CSR).
static func _static(world: World) -> void:
	if world.reg_adj_start.size() == world.region_count + 1:
		return
	var nr := world.region_count
	var sets: Array = []
	sets.resize(nr)
	for r in nr:
		sets[r] = {}
	for p in world.prov_count:
		if world.p_land[p] == 0:
			continue
		var r := world.p_region[p]
		for k in range(world.adj_start[p], world.adj_start[p + 1]):
			var q := world.adj_list[k]
			if world.p_land[q] == 1 and world.p_region[q] != r:
				sets[r][world.p_region[q]] = true
	world.reg_adj_start = PackedInt32Array([0])
	world.reg_adj_list = PackedInt32Array()
	for r in nr:
		var ks: Array = sets[r].keys()
		ks.sort()
		for x in ks:
			world.reg_adj_list.append(int(x))
		world.reg_adj_start.append(world.reg_adj_list.size())


## Снимок для поля подачи (копии — можно считать в фоне, пока мир идёт дальше).
static func field_snapshot(world: World, side_of: PackedInt32Array, sources: Array, capitals: PackedInt32Array) -> Dictionary:
	_static(world)
	var src_flat := PackedInt32Array()
	var src_off := PackedInt32Array([0])
	for sl in sources:
		src_flat.append_array(sl)
		src_off.append(src_flat.size())
	var fall := PackedFloat64Array()
	for h in MAX_RANGE + 1:
		fall.append(pow(FALLOFF, maxi(0, h - 1)))
	# только копии: снимок читается в фоне, пока мир идёт дальше (правило
	# многопоточности — часть записей в массивы мира идёт на месте)
	# подача портов за морем — по доставке конвоями (Convoys; 1 — дома)
	var smult := world.p_conv.duplicate()
	if smult.size() != world.prov_count:
		smult.resize(world.prov_count)
		smult.fill(1.0)
	var gauge := PackedByteArray()
	gauge.resize(world.nation_count)
	# грузовики страны-хозяина узла: множитель подачи и прибавка радиуса
	var tcap := PackedFloat64Array()
	tcap.resize(world.nation_count)
	var trange := PackedInt32Array()
	trange.resize(world.nation_count)
	for nat in world.nations:
		gauge[nat.id] = 1 if BROAD_GAUGE.has(nat.tag) else 0
		var m := clampi(nat.truck_mode, 0, 2)
		tcap[nat.id] = 1.0 + (float(TRUCK_CAP[m]) - 1.0) * nat.truck_ok
		trange[nat.id] = int(TRUCK_RANGE[m]) if nat.truck_ok >= 0.5 else 0
	nodes_init(world)
	return {"owner": world.p_owner.duplicate(), "gauge": gauge, "adj_start": world.adj_start.duplicate(), "adj_list": world.adj_list.duplicate(), "land": world.p_land.duplicate(),
		"ctrl": world.p_controller.duplicate(), "preg": world.p_region.duplicate(), "vp": world.p_vp.duplicate(),
		"pop": world.p_population.duplicate() if world.p_population.size() == world.prov_count else PackedInt32Array(),
		"pcap": world.p_supply_cap.duplicate(), "smult": smult, "side_of": side_of.duplicate(), "ns": sources.size(), "nr": world.region_count,
		"reg_adj_start": world.reg_adj_start.duplicate(), "reg_adj_list": world.reg_adj_list.duplicate(),
		"src": src_flat, "src_off": src_off, "capitals": capitals.duplicate(), "fall": fall,
		"nlvl": world.p_node_lvl.duplicate(), "join": world.p_join.duplicate(), "tcap": tcap, "trange": trange,
		"k": PackedFloat64Array([CAPITAL, PORT_BASE, PORT_VP, LEVEL_K, LOCAL, float(HUB_RANGE), RAIL_LOSS, RAIL_MIN, GAUGE_LOSS, POCKET_LOCAL,
			NODE_UP, RAIL_UP, float(K_CAND), SPILL_STEP, SPILL_MIN])}


## Массивы узлов мира (уровень, присоединение) — по числу провинций.
static func nodes_init(world: World) -> void:
	if world.p_node_lvl.size() != world.prov_count:
		world.p_node_lvl.resize(world.prov_count)
	if world.p_join.size() != world.prov_count:
		world.p_join.resize(world.prov_count)
		world.p_join.fill(-1)


## Поле подачи по снимку → [сторона провинции, подача].
static func field(t: Dictionary) -> Array:
	if Native.core != null:
		return Native.core.call("supply_field", t)
	return field_gd(t)


## Дневной расчёт. sides — сторона каждой страны сегодня (−1 — нет сети);
## поле — готовое со вчера (world.sup_job) или посчитанное сейчас.
static func regions(world: World, side_of: PackedInt32Array, sources: Array, capitals: PackedInt32Array) -> void:
	var f: Array
	var job: Dictionary = world.sup_job
	if int(job.get("day", -1)) == world.day and job.has("field") and job["n"] == world.nation_count:
		Spec.finish(world)
		f = job["field"]
	else:
		f = field(field_snapshot(world, side_of, sources, capitals))
	world.sup_job = {}
	var fall := PackedFloat64Array()
	for h in MAX_RANGE + 1:
		fall.append(pow(FALLOFF, maxi(0, h - 1)))
	var t := {"ps": f[0], "conn": f[3], "pocket": POCKET_LOCAL, "side_of": side_of, "ctrl": world.p_controller, "pcap": world.p_supply_cap,
		"d_alive": world.d_alive, "d_prov": world.d_prov, "d_owner": world.d_owner,
		"mot": Native.gather_i32(world.tpl_motor, world.d_tpl), "local": LOCAL,
		"cand": f[5], "chop": f[6], "cfac": f[11], "nf": f[7], "nprov": f[8], "fall": fall, "budget": BUDGET_K, "kc": K_CAND, "nr": world.region_count}
	world.p_supcap = f[4]   # для расстановки войск ИИ (AIPlanner: не скапливать сверх снабжения)
	var r: Array = Native.core.call("supply_divs", t) if Native.core != null else divisions_gd(t)
	world.d_sup = r[0]
	# узлы для окна и расхода грузовиков: провинция узла, подача, бюджет, взято сегодня
	world.node_f = f[7]
	world.node_prov = f[8]
	world.node_used = r[1]
	world.node_hub = f[9]
	world.node_keys = f[10]
	_trucks(world)
	_map_dist(world, side_of, f[0], f[1])


## Расход грузовиков: узлы страны с доставкой на грузовиках тратят их по
## подаче за день; не хватает на складе — грузовики помогают лишь отчасти (truck_ok).
static func _trucks(world: World) -> void:
	var nc := world.nation_count
	var cons := PackedFloat64Array()
	cons.resize(nc)
	var used := world.node_used
	var np := world.node_prov
	var ctrl := world.p_controller
	for k in world.node_keys:
		if used[k] > 0.0:
			var c := ctrl[np[k]]
			if c >= 0:
				cons[c] += used[k]
	for nat in world.nations:
		var m := clampi(nat.truck_mode, 0, 2)
		if m == 0 or not nat.alive:
			nat.truck_ok = 1.0
			nat.truck_use = 0.0
			continue
		var want := cons[nat.id] * TRUCK_USE * float(TRUCK_SHARE[m])
		nat.truck_use = want
		var st: float = nat.stock[Military.EQ_TRUCK]
		if want <= st:
			nat.stock[Military.EQ_TRUCK] = st - want
			nat.truck_ok = 1.0
		else:
			nat.stock[Military.EQ_TRUCK] = 0.0
			nat.truck_ok = st / want


## Упреждение (Spec): поле подачи на завтра — в фоне по сегодняшней территории.
## Стороны и источники берутся из сегодняшней фазы снабжения (world.sup_args).
static func spec(world: World, jobs: Array) -> void:
	world.sup_job = {}
	if not world.supply_regions or world.sup_args.is_empty():
		return
	var a: Array = world.sup_args
	var t := field_snapshot(world, a[0], a[1], a[2])
	var job := {"day": world.day + 1, "n": world.nation_count}
	world.sup_job = job
	jobs.append(func(): job["field"] = field(t))


## GDScript-вариант поля подачи (C++ — MeowqCore.supply_field).
static func field_gd(t: Dictionary) -> Array:
	var adj_start: PackedInt32Array = t["adj_start"]
	var adj_list: PackedInt32Array = t["adj_list"]
	var land: PackedByteArray = t["land"]
	var ctrl: PackedInt32Array = t["ctrl"]
	var preg: PackedInt32Array = t["preg"]
	var vp: PackedInt32Array = t["vp"]
	var pop: PackedInt32Array = t["pop"]
	var pcap: PackedFloat32Array = t["pcap"]
	var smult: PackedFloat32Array = t["smult"]
	var side_of: PackedInt32Array = t["side_of"]
	var ns: int = t["ns"]
	var nr: int = t["nr"]
	var radj_s: PackedInt32Array = t["reg_adj_start"]
	var radj_l: PackedInt32Array = t["reg_adj_list"]
	var src: PackedInt32Array = t["src"]
	var src_off: PackedInt32Array = t["src_off"]
	var capitals: PackedInt32Array = t["capitals"]
	var fall: PackedFloat64Array = t["fall"]
	var kk: PackedFloat64Array = t["k"]
	var k_cap := kk[0]
	var k_port := kk[1]
	var k_pvp := kk[2]
	var k_level := kk[3]
	var hub_range := int(kk[5])
	var rail_loss := kk[6]
	var rail_min := kk[7]
	var gauge_loss := kk[8]
	var owner: PackedInt32Array = t["owner"]
	var gauge: PackedByteArray = t["gauge"]
	var nlvl: PackedByteArray = t["nlvl"]
	var join: PackedInt32Array = t["join"]
	var tcap: PackedFloat64Array = t["tcap"]
	var trange: PackedInt32Array = t["trange"]
	var node_up := kk[10]
	var rail_up := kk[11]
	var kc := int(kk[12])
	var pc := ctrl.size()
	var has_pop := pop.size() == pc
	# сторона провинции; узел района — главный город
	var ps := PackedInt32Array()
	ps.resize(pc)
	ps.fill(-1)
	var hub := PackedInt32Array()
	hub.resize(ns * nr)
	hub.fill(-1)
	var hscore := PackedFloat64Array()
	hscore.resize(ns * nr)
	var capsum := PackedFloat64Array()
	capsum.resize(ns * nr)
	var pcount := PackedInt32Array()
	pcount.resize(ns * nr)
	for p in pc:
		if land[p] == 0 or ctrl[p] < 0:
			continue
		var s := side_of[ctrl[p]]
		if s < 0:
			continue
		ps[p] = s
		var k := s * nr + preg[p]
		pcount[k] += 1
		var sc := float(vp[p]) * 1.0e6 + (float(pop[p]) if has_pop else 0.0)
		if hub[k] < 0 or sc > hscore[k]:
			hub[k] = p
			hscore[k] = sc
	# узел свой (владелец — своей стороны) или присоединён к сети; иначе не работает
	var hub_ok := PackedByteArray()
	hub_ok.resize(ns * nr)
	for k in ns * nr:
		var h := hub[k]
		if h < 0:
			continue
		var s := k / nr
		var o := owner[h]
		if (o >= 0 and side_of[o] == s) or (join[h] >= 0 and side_of[join[h]] == s):
			hub_ok[k] = 1
	# дорога района; чужая колея (владелец и хозяин разной ширины) — хуже, пока
	# узел района не присоединён (перешивка)
	for p in pc:
		var s := ps[p]
		if s < 0:
			continue
		var k := s * nr + preg[p]
		var o := owner[p]
		var lose := o >= 0 and gauge[o] != gauge[ctrl[p]] and not (hub[k] >= 0 and join[hub[k]] >= 0 and hub_ok[k] == 1)
		capsum[k] += float(pcap[p]) * (gauge_loss if lose else 1.0)
	# связь с источником по своей территории (котлы): узел вне связи не работает
	var conn := PackedByteArray()
	conn.resize(pc)
	var cq := PackedInt32Array()
	for s in ns:
		for j in range(src_off[s], src_off[s + 1]):
			var h := src[j]
			if ps[h] == s and conn[h] == 0:
				conn[h] = 1
				cq.append(h)
	var chead := 0
	while chead < cq.size():
		var p := cq[chead]
		chead += 1
		var s := ps[p]
		for e in range(adj_start[p], adj_start[p + 1]):
			var q := adj_list[e]
			if conn[q] == 0 and ps[q] == s:
				conn[q] = 1
				cq.append(q)
	var level := PackedFloat64Array()
	level.resize(ns * nr)
	for k in ns * nr:
		if pcount[k] > 0:
			level[k] = capsum[k] / float(pcount[k])
			if hub_ok[k] == 1:
				level[k] += rail_up * float(nlvl[hub[k]])
	# источники и узлы; дорога — самый широкий путь по районам стороны
	var best_src := PackedInt32Array()
	best_src.resize(ns * nr)
	best_src.fill(-1)
	var best_f := PackedFloat64Array()
	best_f.resize(ns * nr)
	var best := PackedFloat64Array()
	best.resize(nr)
	var rd := PackedInt32Array()   # районов пути от ближайшего источника
	rd.resize(nr)
	for s in ns:
		best.fill(-1.0)
		rd.fill(-1)
		var open := PackedInt32Array()
		for j in range(src_off[s], src_off[s + 1]):
			var r := preg[src[j]]
			if best[r] < 99.0:
				best[r] = 99.0
				rd[r] = 0
				open.append(r)
		# длина пути: волна по районам стороны
		var q2 := open.duplicate()
		var head2 := 0
		while head2 < q2.size():
			var r0 := q2[head2]
			head2 += 1
			for j in range(radj_s[r0], radj_s[r0 + 1]):
				var r2 := radj_l[j]
				if rd[r2] >= 0 or pcount[s * nr + r2] == 0:
					continue
				rd[r2] = rd[r0] + 1
				q2.append(r2)
		while not open.is_empty():
			var nxt := PackedInt32Array()
			for r in open:
				for j in range(radj_s[r], radj_s[r + 1]):
					var r2 := radj_l[j]
					var k2 := s * nr + r2
					if pcount[k2] == 0:
						continue
					var w := minf(best[r], level[k2])
					if w > best[r2] + 1e-9:
						best[r2] = w
						nxt.append(r2)
			open = nxt
		for r in nr:
			var k := s * nr + r
			var h := hub[k]
			if h >= 0 and hub_ok[k] == 1 and best[r] > 0.0 and conn[h] == 1:
				best_src[k] = h
				best_f[k] = k_level * minf(best[r], level[k]) * maxf(rail_min, 1.0 - rail_loss * float(rd[r])) \
						* (1.0 + node_up * float(nlvl[h])) * tcap[ctrl[h]]
		for j in range(src_off[s], src_off[s + 1]):
			var h := src[j]
			var f := k_cap if capitals.has(h) else (k_port + k_pvp * minf(5.0, float(vp[h]))) * float(smult[h])
			f *= (1.0 + node_up * float(nlvl[h])) * tcap[ctrl[h]]
			var k := s * nr + preg[h]
			if f > best_f[k]:
				best_f[k] = f
				best_src[k] = h
	# радиус узла: основной + 1 за каждые 2 уровня + грузовики хозяина
	var nrange := PackedInt32Array()
	nrange.resize(ns * nr)
	for k in ns * nr:
		var h := best_src[k]
		if h >= 0:
			nrange[k] = hub_range + int(nlvl[h]) / 2 + trange[ctrl[h]]
	# волна от узла каждого района — параллельно по районам
	var parts: Array = []
	parts.resize(nr)
	var args := [adj_start, adj_list, ps, best_src, nrange, ns, nr, pc, parts]
	Parallel.run(nr, _flood_region.bind(args), "снабжение:районы", 8)
	var got := PackedFloat64Array()
	got.resize(pc)
	var gsrc := PackedInt32Array()   # узел лучшей подачи провинции
	gsrc.resize(pc)
	gsrc.fill(-1)
	# до kc ближайших узлов провинции (по переходам, при равенстве — по номеру узла)
	var cand := PackedInt32Array()
	cand.resize(pc * kc)
	cand.fill(-1)
	var chop := PackedInt32Array()
	chop.resize(pc * kc)
	# узел провинции (для расстояний между узлами)
	var nk := ns * nr
	var pkey := PackedInt32Array()
	pkey.resize(pc)
	pkey.fill(-1)
	for k in nk:
		if best_src[k] >= 0:
			pkey[best_src[k]] = k
	var nn := {}   # (узел волны)*nk + (узел, до которого дошла) → переходов
	for r in nr:
		var out: PackedInt32Array = parts[r]
		for j in range(0, out.size(), 3):
			var p := out[j]
			var h := out[j + 1]
			var k := out[j + 2]
			if pkey[p] >= 0:
				nn[k * nk + pkey[p]] = h
			var v := best_f[k] * fall[h]
			if v > got[p]:
				got[p] = v
				gsrc[p] = best_src[k]
			# вставка в упорядоченный список кандидатов
			var b := p * kc
			var pos := kc
			for m in kc:
				var ck := cand[b + m]
				if ck < 0 or h < chop[b + m] or (h == chop[b + m] and k < ck):
					pos = m
					break
			if pos < kc:
				var m2 := kc - 1
				while m2 > pos:
					cand[b + m2] = cand[b + m2 - 1]
					chop[b + m2] = chop[b + m2 - 1]
					m2 -= 1
				cand[b + pos] = k
				chop[b + pos] = h
	# доля помощи узлов-кандидатов: ближайший — целиком, дальние — по расстоянию до него
	var spill_step := kk[13]
	var spill_min := kk[14]
	var cfac := PackedFloat64Array()
	cfac.resize(pc * kc)
	for p in pc:
		var b := p * kc
		var k0 := cand[b]
		if k0 < 0:
			continue
		cfac[b] = 1.0
		for m in range(1, kc):
			var km := cand[b + m]
			if km < 0:
				break
			var d: int = nn.get(km * nk + k0, -1)
			cfac[b + m] = spill_min if d < 0 else maxf(spill_min, 1.0 - spill_step * float(d))
	# ёмкость провинции для военного ИИ (сколько «дивизий» она прокормит):
	# подача + местное снабжение (в котле — урезанное)
	var k_loc := kk[4]
	var k_pock := kk[9]
	var supcap := PackedFloat32Array()
	supcap.resize(pc)
	for p in pc:
		if ps[p] >= 0:
			supcap[p] = got[p] + k_loc * float(pcap[p]) * (1.0 if conn[p] == 1 else k_pock)
	var keys := PackedInt32Array()   # узлы, где у стороны есть провинции района
	for k in ns * nr:
		if hub[k] >= 0:
			keys.append(k)
	return [ps, got, gsrc, conn, supcap, cand, chop, best_f, best_src, hub, keys, cfac]


## Волна от узла района r (тройки: провинция, переходов, номер узла s*nr+r) → parts[r].
static func _flood_region(r: int, args: Array) -> void:
	var adj_start: PackedInt32Array = args[0]
	var adj_list: PackedInt32Array = args[1]
	var ps: PackedInt32Array = args[2]
	var best_src: PackedInt32Array = args[3]
	var nrange: PackedInt32Array = args[4]
	var ns: int = args[5]
	var nr: int = args[6]
	var pc: int = args[7]
	var parts: Array = args[8]
	var out := PackedInt32Array()
	var mark := PackedInt32Array()
	for s in ns:
		var k := s * nr + r
		var start := best_src[k]
		if start < 0:
			continue
		var rng := nrange[k]
		if mark.is_empty():
			mark.resize(pc)
		var stamp := s + 1
		mark[start] = stamp
		var queue := PackedInt32Array([start])
		var hops := PackedInt32Array([0])
		var head := 0
		while head < queue.size():
			var p := queue[head]
			var h := hops[head]
			head += 1
			out.append(p)
			out.append(h)
			out.append(k)
			if h >= rng:
				continue
			for e in range(adj_start[p], adj_start[p + 1]):
				var q := adj_list[e]
				if mark[q] == stamp or ps[q] != s:
					continue
				mark[q] = stamp
				queue.append(q)
				hops.append(h + 1)
	parts[r] = out


## GDScript-вариант раздачи по дивизиям (C++ — MeowqCore.supply_divs) →
## [обеспеченность дивизий, подача каждого узла за день]. Спрос провинции сверх
## местного снабжения берётся у её узлов по удалённости: сначала у ближайшего,
## не хватило бюджета узла (его делят провинции поровну по доле запроса) —
## у следующего. Узел работает, если и сегодня за своей стороной; провинция
## получает подачу, только если вчера была за той же стороной (иначе — лишь
## местное: подвоз ещё не подтянулся).
static func divisions_gd(t: Dictionary) -> Array:
	var ps: PackedInt32Array = t["ps"]
	var conn: PackedByteArray = t["conn"]
	var k_pocket: float = t["pocket"]
	var side_of: PackedInt32Array = t["side_of"]
	var ctrl: PackedInt32Array = t["ctrl"]
	var pcap: PackedFloat32Array = t["pcap"]
	var d_alive: PackedByteArray = t["d_alive"]
	var d_prov: PackedInt32Array = t["d_prov"]
	var d_owner: PackedInt32Array = t["d_owner"]
	var mot: PackedInt32Array = t["mot"]
	var k_local: float = t["local"]
	var cand: PackedInt32Array = t["cand"]
	var chop: PackedInt32Array = t["chop"]
	var cfac: PackedFloat64Array = t["cfac"]
	var nf: PackedFloat64Array = t["nf"]
	var nprov: PackedInt32Array = t["nprov"]
	var fall: PackedFloat64Array = t["fall"]
	var budget_k: float = t["budget"]
	var kc: int = t["kc"]
	var nr: int = t["nr"]
	var n := d_alive.size()
	var pc := ctrl.size()
	var dem := PackedFloat64Array()
	dem.resize(pc)
	for i in n:
		if d_alive[i] == 1:
			var s := side_of[d_owner[i]]
			var c := ctrl[d_prov[i]]
			if s >= 0 and c >= 0 and side_of[c] == s:
				dem[d_prov[i]] += 1.5 if mot[i] >= 1 else 1.0
	# местное снабжение и нужда сверх него
	var have := PackedFloat64Array()
	have.resize(pc)
	var need := PackedFloat64Array()
	need.resize(pc)
	var plist := PackedInt32Array()
	for p in pc:
		if dem[p] <= 0.0:
			continue
		var s := side_of[ctrl[p]]
		have[p] = k_local * float(pcap[p]) * (1.0 if ps[p] == s and conn[p] == 1 else k_pocket)
		if ps[p] == s and dem[p] > have[p]:
			need[p] = dem[p] - have[p]
			plist.append(p)
	var nk := nf.size()
	var rem := PackedFloat64Array()   # остаток бюджета узла (заводится при первом запросе)
	rem.resize(nk)
	var rset := PackedByteArray()
	rset.resize(nk)
	var used := PackedFloat64Array()
	used.resize(nk)
	var req := PackedFloat64Array()
	req.resize(nk)
	var rq := PackedFloat64Array()
	rq.resize(plist.size())
	var rk := PackedInt32Array()
	rk.resize(plist.size())
	for j in kc:
		for m in plist.size():
			var p := plist[m]
			rk[m] = -1
			var k := cand[p * kc + j]
			if k < 0 or need[p] <= 0.0:
				continue
			var g := nprov[k]
			if ctrl[g] < 0 or side_of[ctrl[g]] != k / nr:
				continue   # узел взят противником
			var r := minf(need[p], nf[k] * fall[chop[p * kc + j]] * cfac[p * kc + j])
			if rset[k] == 0:
				rset[k] = 1
				rem[k] = nf[k] * budget_k
			rq[m] = r
			rk[m] = k
			req[k] += r
		for m in plist.size():
			var k := rk[m]
			if k < 0:
				continue
			var p := plist[m]
			var d := rq[m] if rem[k] >= req[k] else rq[m] * (rem[k] / req[k])
			have[p] += d
			need[p] -= d
			used[k] += d
		for m in plist.size():
			var k := rk[m]
			if k >= 0 and req[k] > 0.0:
				rem[k] = maxf(0.0, rem[k] - req[k])
				req[k] = 0.0
	var sup := PackedFloat64Array()
	sup.resize(n)
	for i in n:
		if d_alive[i] == 0:
			continue
		var p := d_prov[i]
		var s := side_of[d_owner[i]]
		var c := ctrl[p]
		if s < 0 or c < 0 or side_of[c] != s:
			continue   # не своя сторона — снабжения нет
		var d := dem[p]
		sup[i] = 1.0 if have[p] >= d else have[p] / maxf(1.0, d)
	return [sup, used]


## Для режима карты «Снабжение» — только сторона игрока (условные «переходы»
## по подаче); остальным не нужно.
static func _map_dist(world: World, side_of: PackedInt32Array, ps: PackedInt32Array, got: PackedFloat64Array) -> void:
	var nc := world.nation_count
	world.supply_dist.resize(nc)
	var me := world.player_nation()
	var ms := side_of[me] if me >= 0 else -1
	var dist := PackedInt32Array()
	if ms >= 0:
		dist.resize(world.prov_count)
		dist.fill(-1)
		var pcap := world.p_supply_cap
		for p in world.prov_count:
			if ps[p] == ms:
				var v := got[p] + LOCAL * pcap[p]
				dist[p] = 0 if v >= 8.0 else clampi(int(round(13.0 - v)), 0, 20)
	for a in nc:
		world.supply_dist[a] = dist if a == me or (ms >= 0 and side_of[a] == ms) else PackedInt32Array()


# --- Стройка узлов: улучшение и присоединение захваченных ---------------------

const SUP_SHARE := 0.5        # доля очков стройки на узлы, пока есть заказы
const UPGRADE_COST := 12.0    # очков за уровень × (новый уровень)
const JOIN_COST := 2.5        # присоединить захваченный узел (восстановить пути)
const GAUGE_JOIN := 4.0       # узел чужой колеи — перешивка дороже
const JOB_UP := 0
const JOB_JOIN := 1


## Сторона страны сегодня (номер ведущей страны) или −1.
static func side(world: World, nid: int) -> int:
	if world.sup_args.is_empty():
		return -1
	var so: PackedInt32Array = world.sup_args[0]
	return so[nid] if nid < so.size() else -1


## Узел провинции p для стороны s: номер k или −1 (p — главный город района у стороны).
static func node_of(world: World, s: int, p: int) -> int:
	if s < 0 or world.node_hub.is_empty():
		return -1
	var k := s * world.region_count + world.p_region[p]
	if k < world.node_hub.size() and world.node_hub[k] == p:
		return k
	if k < world.node_prov.size() and world.node_prov[k] == p:
		return k
	return -1


## Узел работает на свою сторону (свой или присоединён).
static func node_ok(world: World, s: int, p: int) -> bool:
	nodes_init(world)
	var so: PackedInt32Array = world.sup_args[0] if not world.sup_args.is_empty() else PackedInt32Array()
	var o := world.p_owner[p]
	if o >= 0 and o < so.size() and so[o] == s:
		return true
	var j := world.p_join[p]
	return j >= 0 and j < so.size() and so[j] == s


static func job_cost(world: World, job: Array) -> float:
	if int(job[1]) == JOB_JOIN:
		# узел чужой колеи (широкая — СССР, Финляндия) — перешивка: вчетверо дороже
		var p: int = job[0]
		var o := world.p_owner[p]
		var c := world.p_controller[p]
		if o >= 0 and c >= 0 and BROAD_GAUGE.has(world.nations[o].tag) != BROAD_GAUGE.has(world.nations[c].tag):
			return JOIN_COST * GAUGE_JOIN
		return JOIN_COST
	return UPGRADE_COST * float(world.p_node_lvl[int(job[0])] + 1)


## Заказ ещё имеет смысл (провинция за страной, узел ещё не улучшен до предела / не присоединён).
static func job_valid(world: World, nat: World.Nation, job: Array) -> bool:
	var p: int = job[0]
	if world.p_controller[p] != nat.id:
		return false
	var s := side(world, nat.id)
	if int(job[1]) == JOB_JOIN:
		return not node_ok(world, s, p)
	return world.p_node_lvl[p] < NODE_MAX and node_ok(world, s, p)


static func has_job(nat: World.Nation, p: int, kind: int) -> bool:
	for j in nat.sup_jobs:
		if int(j[0]) == p and int(j[1]) == kind:
			return true
	return false


## Заказ игрока или ИИ (только между world_lock/unlock). Присоединение — в начало очереди.
static func order(world: World, nat: World.Nation, p: int, kind: int) -> bool:
	nodes_init(world)
	var job := [p, kind, 0.0]
	if has_job(nat, p, kind) or not job_valid(world, nat, job):
		return false
	if kind == JOB_JOIN:
		var at := 0
		while at < nat.sup_jobs.size() and int(nat.sup_jobs[at][1]) == JOB_JOIN:
			at += 1
		nat.sup_jobs.insert(at, job)
	else:
		nat.sup_jobs.append(job)
	return true


## Очки стройки дня: до SUP_SHARE — на заказы узлов по очереди; остаток — фабрикам.
static func build(world: World, nat: World.Nation, pts: float) -> float:
	if nat.sup_jobs.is_empty():
		return pts
	nodes_init(world)
	var budget := pts * SUP_SHARE
	var spent := 0.0
	while not nat.sup_jobs.is_empty() and budget - spent > 1e-9:
		var job: Array = nat.sup_jobs[0]
		if not job_valid(world, nat, job):
			nat.sup_jobs.pop_front()
			continue
		var cost := job_cost(world, job)
		var put := minf(budget - spent, cost - float(job[2]))
		job[2] = float(job[2]) + put
		spent += put
		if float(job[2]) >= cost - 1e-9:
			var p: int = job[0]
			if int(job[1]) == JOB_JOIN:
				world.p_join[p] = nat.id
				if nat.is_player:
					world.log_event("Узел снабжения присоединён к сети: %s" % world.p_name[p])
			else:
				world.p_node_lvl[p] += 1
				if nat.is_player:
					world.log_event("Узел снабжения улучшен: %s, уровень %d" % [world.p_name[p], world.p_node_lvl[p]])
			nat.sup_jobs.pop_front()
	return pts - spent


## ИИ узлов (раз в день, главный поток): захваченные узлы — присоединять (и игроку
## с sup_auto); ИИ раз в месяц улучшает самый загруженный свой узел и выбирает
## доставку грузовиками по войне и запасу.
static func ai_daily(world: World) -> void:
	if world.node_hub.is_empty() or world.sup_args.is_empty():
		return
	nodes_init(world)
	var nr := world.region_count
	var hubs := world.node_hub
	var ctrl := world.p_controller
	var so: PackedInt32Array = world.sup_args[0]
	for k in world.node_keys:
		var h := hubs[k]
		if h < 0:
			continue
		var c := ctrl[h]
		if c < 0 or so[c] != k / nr:
			continue
		var nat: World.Nation = world.nations[c]
		if (nat.is_player and not nat.sup_auto) or node_ok(world, k / nr, h):
			continue
		order(world, nat, h, JOB_JOIN)
	for nat in world.nations:
		if not nat.alive or nat.is_player or (world.day + nat.id) % 30 != 7:
			continue
		var at_war := false
		for o in world.nation_count:
			if world.war[nat.id * world.nation_count + o] == 1:
				at_war = true
				break
		# грузовики: на войне, если запас позволяет
		var tr: float = nat.stock[Military.EQ_TRUCK]
		nat.truck_mode = (2 if tr > 400.0 else (1 if tr > 80.0 else 0)) if at_war else 0
		var busy := false
		for j in nat.sup_jobs:
			if int(j[1]) == JOB_UP:
				busy = true
				break
		if busy or not at_war:
			continue
		var best := -1
		var best_load := 0.9
		for k in world.node_keys:
			var p := world.node_prov[k]
			if p < 0 or ctrl[p] != nat.id or world.p_node_lvl[p] >= NODE_MAX:
				continue
			var cap := world.node_f[k] * BUDGET_K
			if cap <= 0.0:
				continue
			var load := world.node_used[k] / cap
			if load > best_load:
				best_load = load
				best = p
		if best >= 0:
			order(world, nat, best, JOB_UP)
