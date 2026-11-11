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
const RAIL_LOSS := 0.05       # длина дороги: −5 % подачи узла за каждый район пути от источника
const RAIL_MIN := 0.3         # дальше не падает
const GAUGE_LOSS := 0.5       # чужая колея: провинция даёт дороге вдвое меньше
const POCKET_LOCAL := 0.3     # отрезанная от источников провинция: местного снабжения — 30 %
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
	for h in HUB_RANGE + 1:
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
	for nat in world.nations:
		gauge[nat.id] = 1 if BROAD_GAUGE.has(nat.tag) else 0
	return {"owner": world.p_owner.duplicate(), "gauge": gauge, "adj_start": world.adj_start.duplicate(), "adj_list": world.adj_list.duplicate(), "land": world.p_land.duplicate(),
		"ctrl": world.p_controller.duplicate(), "preg": world.p_region.duplicate(), "vp": world.p_vp.duplicate(),
		"pop": world.p_population.duplicate() if world.p_population.size() == world.prov_count else PackedInt32Array(),
		"pcap": world.p_supply_cap.duplicate(), "smult": smult, "side_of": side_of.duplicate(), "ns": sources.size(), "nr": world.region_count,
		"reg_adj_start": world.reg_adj_start.duplicate(), "reg_adj_list": world.reg_adj_list.duplicate(),
		"src": src_flat, "src_off": src_off, "capitals": capitals.duplicate(), "fall": fall,
		"k": PackedFloat64Array([CAPITAL, PORT_BASE, PORT_VP, LEVEL_K, LOCAL, float(HUB_RANGE), RAIL_LOSS, RAIL_MIN, GAUGE_LOSS, POCKET_LOCAL])}


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
	var t := {"ps": f[0], "got": f[1], "gsrc": f[2], "conn": f[3], "pocket": POCKET_LOCAL, "side_of": side_of, "ctrl": world.p_controller, "pcap": world.p_supply_cap,
		"d_alive": world.d_alive, "d_prov": world.d_prov, "d_owner": world.d_owner,
		"mot": Native.gather_i32(world.tpl_motor, world.d_tpl), "local": LOCAL}
	world.p_supcap = f[4]   # для расстановки войск ИИ (AIPlanner: не скапливать сверх снабжения)
	if Native.core != null:
		world.d_sup = Native.core.call("supply_divs", t)
	else:
		world.d_sup = divisions_gd(t)
	_map_dist(world, side_of, f[0], f[1])


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
	var pc := ctrl.size()
	var has_pop := pop.size() == pc
	# сторона провинции; узел района — главный город; уровень дороги
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
		# дорога чужой колеи (владелец и хозяин сейчас — разной ширины) — хуже
		var o := owner[p]
		capsum[k] += float(pcap[p]) * (gauge_loss if o >= 0 and gauge[o] != gauge[ctrl[p]] else 1.0)
		pcount[k] += 1
		var sc := float(vp[p]) * 1.0e6 + (float(pop[p]) if has_pop else 0.0)
		if hub[k] < 0 or sc > hscore[k]:
			hub[k] = p
			hscore[k] = sc
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
			if hub[k] >= 0 and best[r] > 0.0 and conn[hub[k]] == 1:
				best_src[k] = hub[k]
				best_f[k] = k_level * minf(best[r], level[k]) * maxf(rail_min, 1.0 - rail_loss * float(rd[r]))
		for j in range(src_off[s], src_off[s + 1]):
			var h := src[j]
			var f := k_cap if capitals.has(h) else (k_port + k_pvp * minf(5.0, float(vp[h]))) * float(smult[h])
			var k := s * nr + preg[h]
			if f > best_f[k]:
				best_f[k] = f
				best_src[k] = h
	# подача: волна от источника каждого района — параллельно по районам
	var parts: Array = []
	parts.resize(nr)
	var args := [adj_start, adj_list, ps, best_src, best_f, fall, ns, nr, hub_range, pc, parts]
	Parallel.run(nr, _flood_region.bind(args), "снабжение:районы", 8)
	var got := PackedFloat64Array()
	got.resize(pc)
	var gsrc := PackedInt32Array()   # источник лучшей подачи провинции
	gsrc.resize(pc)
	gsrc.fill(-1)
	for r in nr:
		var out: PackedFloat64Array = parts[r]
		for j in range(0, out.size(), 3):
			var p := int(out[j])
			if out[j + 1] > got[p]:
				got[p] = out[j + 1]
				gsrc[p] = int(out[j + 2])
	# ёмкость провинции для военного ИИ (сколько «дивизий» она прокормит):
	# подача + местное снабжение (в котле — урезанное)
	var k_loc := kk[4]
	var k_pock := kk[9]
	var supcap := PackedFloat32Array()
	supcap.resize(pc)
	for p in pc:
		if ps[p] >= 0:
			supcap[p] = got[p] + k_loc * float(pcap[p]) * (1.0 if conn[p] == 1 else k_pock)
	return [ps, got, gsrc, conn, supcap]


## Волна подачи от источников района r (тройки: провинция, подача, источник) → parts[r].
static func _flood_region(r: int, args: Array) -> void:
	var adj_start: PackedInt32Array = args[0]
	var adj_list: PackedInt32Array = args[1]
	var ps: PackedInt32Array = args[2]
	var best_src: PackedInt32Array = args[3]
	var best_f: PackedFloat64Array = args[4]
	var fall: PackedFloat64Array = args[5]
	var ns: int = args[6]
	var nr: int = args[7]
	var hub_range: int = args[8]
	var pc: int = args[9]
	var parts: Array = args[10]
	var out := PackedFloat64Array()
	var mark := PackedInt32Array()
	for s in ns:
		var start := best_src[s * nr + r]
		if start < 0:
			continue
		var f0 := best_f[s * nr + r]
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
			out.append(float(p))
			out.append(f0 * fall[h])
			out.append(float(start))
			if h >= hub_range:
				continue
			for e in range(adj_start[p], adj_start[p + 1]):
				var q := adj_list[e]
				if mark[q] == stamp or ps[q] != s:
					continue
				mark[q] = stamp
				queue.append(q)
				hops.append(h + 1)
	parts[r] = out


## GDScript-вариант раздачи по дивизиям (C++ — MeowqCore.supply_divs): подача
## поля засчитывается, только если провинция была за той же стороной (иначе —
## только местное снабжение: подвоз ещё не подтянулся).
static func divisions_gd(t: Dictionary) -> PackedFloat64Array:
	var ps: PackedInt32Array = t["ps"]
	var got: PackedFloat64Array = t["got"]
	var gsrc: PackedInt32Array = t["gsrc"]
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
	var n := d_alive.size()
	var dem := PackedFloat64Array()
	dem.resize(ctrl.size())
	for i in n:
		if d_alive[i] == 1:
			dem[d_prov[i]] += 1.5 if mot[i] >= 1 else 1.0
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
		# местное снабжение; в котле (провинция вчера без связи с источником) — меньше
		var have := k_local * float(pcap[p]) * (1.0 if ps[p] == s and conn[p] == 1 else k_pocket)
		# подача вчерашнего поля — если провинция и её источник (узел, порт,
		# столица) и сегодня за этой стороной: захваченный за сутки узел не кормит
		var g := gsrc[p]
		if ps[p] == s and g >= 0 and ctrl[g] >= 0 and side_of[ctrl[g]] == s:
			have += got[p]
		var d := dem[p]
		sup[i] = 1.0 if have >= d else have / maxf(1.0, d)
	return sup


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
