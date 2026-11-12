class_name Depots
extends RefCounted
## Пункты снабжения и склады (решения пользователя, ноябрь 2026).
##  * Порт и пункт снабжения — разные вещи. Порт — база и ремонт кораблей.
##    Пункт снабжения — столица (первый, основной), крупный город (очки победы
##    ≥ DEPOT_VP) или порт с улучшенным узлом (Supply: уровень ≥ 1): только он
##    — источник снабжения войск (Simulation._phase_supply).
##  * Участок — связная по суше земля стороны (своя и союзная; через безлюдную
##    пустыню связь не идёт: World.p_waste). Участок столицы — метрополия, её
##    запас — склады страны (Nation.stock).
##  * Пункт на чужом участке (за морем) — склад: конвои довозят туда
##    снаряжение до доли запаса страны (по умолчанию DEFAULT_SHARE, игрок
##    меняет; ИИ — по доле своих дивизий там) — по грузоподъёмности
##    (CARGO за рейс) и дальности (рейс TRIP_BASE + TRIP_PER за бассейн
##    пути), с перехватом в пути (доля, что доходит, — Convoys.daily).
##  * Ежедневное снабжение участка за морем — конвоями (Convoys: PER_DIV на
##    дивизию); недостача берётся со складов участка (SUP_EQ снаряжения в день
##    на дивизию). Нет ни пути, ни запаса — пункты участка не подают (котёл).
##  * Пополнение дивизий — из запаса, доступного по суше: в метрополии — склады
##    страны, за морем — склады участка; нет склада на участке — не пополняется.

const DEPOT_VP := 15            # крупный город (очки победы) — пункт снабжения
const DEFAULT_SHARE := 0.5      # доля запаса страны на складе (игрок, по умолчанию)
const SHARE_SUM_MAX := 0.8      # склады за морем вместе — не больше (метрополии остаётся)
const AI_SHARE_K := 1.5         # ИИ: доля = доля дивизий страны на участке × K…
const AI_SHARE_MAX := 0.5       # …не больше
const CARGO := 6.0              # снаряжения (в очках заводов) за рейс конвоя
const TRIP_BASE := 4.0          # рейс: дней…
const TRIP_PER := 3.0           # …и ещё за каждый бассейн пути
const HORIZON := 20.0           # недостачу склада закрывают за столько дней
const RETURN_AT := 1.5          # запас склада сверх доли × столько — излишек…
const RETURN_RATE := 0.05       # …вывозится домой по столько в день
const SUP_EQ := 1.0             # снаряжения (очки заводов) в день на дивизию без подвоза


## Пункт снабжения: столица хозяина, крупный город или порт с улучшенным узлом.
static func is_depot(world: World, p: int) -> bool:
	if world.p_land[p] == 0:
		return false
	var c := world.p_controller[p]
	if c >= 0 and world.nations[c].capital == p:
		return true
	if world.p_vp[p] >= DEPOT_VP:
		return true
	return world.p_node_lvl.size() == world.prov_count and world.p_node_lvl[p] >= 1 and Forces.is_port(world, p)


## Участки суши сторон: обход от каждой провинции по соседям той же стороны
## (своя или союзная), через безлюдную пустыню — не дальше.
static func components(world: World) -> void:
	var pc := world.prov_count
	var nc := world.nation_count
	var ctrl := world.p_controller
	var land := world.p_land
	var ally := world.ally
	var has_ally := ally.size() == nc * nc
	var a_start := world.adj_start
	var a_list := world.adj_list
	var waste := world.p_waste
	var has_waste := waste.size() == pc
	var comp := PackedInt32Array()
	comp.resize(pc)
	comp.fill(-1)
	var next := 0
	var q := PackedInt32Array()
	for p0 in pc:
		if land[p0] == 0 or comp[p0] >= 0 or ctrl[p0] < 0:
			continue
		var c0 := ctrl[p0]
		comp[p0] = next
		q.resize(0)
		q.append(p0)
		var h := 0
		while h < q.size():
			var p := q[h]
			h += 1
			if has_waste and waste[p] == 1:
				continue   # безлюдная пустыня связь не передаёт (и с неё обход не начинается)
			for k in range(a_start[p], a_start[p + 1]):
				var y := a_list[k]
				if comp[y] >= 0 or land[y] == 0:
					continue
				var o := ctrl[y]
				if o < 0 or (o != c0 and (not has_ally or ally[c0 * nc + o] != 1)):
					continue
				comp[y] = next
				q.append(y)
		next += 1
	world.p_comp = comp
	for nat in world.nations:
		var cp: int = nat.capital
		nat.dep_home = comp[cp] if nat.alive and cp >= 0 and cp < pc and ctrl[cp] == nat.id else -1


## За морем ли провинция для страны n (не на участке её столицы).
static func overseas(world: World, n: int, p: int) -> bool:
	if world.p_comp.size() != world.prov_count:
		return false
	var h: int = world.nations[n].dep_home
	return h < 0 or world.p_comp[p] != h


## День (после конвоев): участки, склады (сменившие хозяина — пропали,
## вернувшиеся в метрополию — в общий запас), подача пунктов, подвоз снаряжения.
static func daily(world: World) -> void:
	var pc := world.prov_count
	var nc := world.nation_count
	Supply._static(world)
	components(world)
	var ctrl := world.p_controller
	var comp := world.p_comp
	if world.p_dsup.size() != pc:
		world.p_dsup.resize(pc)
	world.p_dsup.fill(1.0)
	# склады: хозяин сменился — запас пропал; участок стал метрополией — в общий запас
	var keys: Array = world.dep_stock.keys()
	keys.sort()
	for p in keys:
		var o: int = world.dep_owner.get(p, -1)
		if o < 0 or ctrl[p] != o or not world.nations[o].alive or not is_depot(world, p):
			world.dep_stock.erase(p)
			world.dep_owner.erase(p)
			continue
		if not overseas(world, o, p):
			var st: PackedFloat64Array = world.dep_stock[p]
			for k in Military.EQ_LAND:
				world.nations[o].stock[k] += st[k]
			world.dep_stock.erase(p)
			world.dep_owner.erase(p)
	# пункты за морем по странам и участкам; дивизии там
	var divs := {}   # страна * pc + участок -> дивизий
	var alive := world.d_alive
	var dprov := world.d_prov
	var downer := world.d_owner
	var total := PackedInt32Array()
	total.resize(nc)
	for i in alive.size():
		if alive[i] == 0 or dprov[i] < 0:
			continue
		var o := downer[i]
		total[o] += 1
		var cpv := comp[dprov[i]]
		if cpv >= 0 and cpv != world.nations[o].dep_home:
			var key := o * pc + cpv
			divs[key] = int(divs.get(key, 0)) + 1
	var by_nat: Array = []   # страна -> участок -> пункты (по возрастанию номера)
	by_nat.resize(nc)
	for p in pc:
		var c := ctrl[p]
		if c < 0 or comp[p] < 0 or comp[p] == world.nations[c].dep_home or not is_depot(world, p):
			continue
		if by_nat[c] == null:
			by_nat[c] = {}
		if not by_nat[c].has(comp[p]):
			by_nat[c][comp[p]] = []
		by_nat[c][comp[p]].append(p)
	ai_ports(world, divs, by_nat)
	world.dep_want = {}
	for nat: World.Nation in world.nations:
		var n := nat.id
		nat.conv_eq_need = 0.0
		nat.conv_eq_use = 0.0
		if not nat.alive or by_nat[n] == null:
			continue
		var groups: Dictionary = by_nat[n]
		var gk: Array = groups.keys()
		gk.sort()
		# доли: игрок — свои (по умолчанию 0,5), ИИ — по дивизиям участка; главный
		# склад участка — порт с лучшим путём конвоев (иначе первый пункт)
		var mains := {}
		var share_sum := 0.0
		for cpv in gk:
			var lst: Array = groups[cpv]
			var best: int = lst[0]
			var bs := -1.0
			for p in lst:
				var sf: float = float(nat.conv_safe.get(p, -1.0))
				if sf > bs:
					bs = sf
					best = p
			mains[cpv] = best
			var sh: float
			var dv := int(divs.get(n * pc + int(cpv), 0))
			if nat.is_player:
				# своя доля игрока; по умолчанию — 50 % там, где стоят его войска
				if not world.dep_share.has(best):
					world.dep_share[best] = DEFAULT_SHARE if dv > 0 else 0.0
				sh = float(world.dep_share[best])
			else:
				sh = 0.0 if dv == 0 else minf(AI_SHARE_MAX, AI_SHARE_K * float(dv) / maxf(1.0, float(total[n])))
			world.dep_want[best] = sh
			share_sum += sh
		var norm := 1.0 if share_sum <= SHARE_SUM_MAX else SHARE_SUM_MAX / share_sum
		# запас страны всего (метрополия + склады)
		var tot := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
		for k in Military.EQ_LAND:
			tot[k] = nat.stock[k]
		for p in world.dep_stock:
			if int(world.dep_owner.get(p, -1)) == n:
				var st: PackedFloat64Array = world.dep_stock[p]
				for k in Military.EQ_LAND:
					tot[k] += st[k]
		var free := maxf(0.0, nat.convoys - nat.conv_sup_need)
		var plan: Array = []   # [пункт, недостача по типам, конвоев нужно, рейс]
		var need_sum := 0.0
		for cpv in gk:
			var mp: int = mains[cpv]
			var sh: float = float(world.dep_want[mp]) * norm
			world.dep_want[mp] = sh
			var st: PackedFloat64Array = world.dep_stock.get(mp, PackedFloat64Array([0.0, 0.0, 0.0, 0.0]))
			# ежедневное снабжение: недостача подвоза — со складов участка
			var dv := int(divs.get(n * pc + int(cpv), 0))
			var f := 0.0
			for p in groups[cpv]:
				# подвоз — только у портов с путём конвоев (Convoys: обход раз в 14 дней)
				if nat.conv_safe.has(p) and world.p_conv.size() == pc:
					f = maxf(f, world.p_conv[p])
			var m := f
			if dv > 0 and f < 1.0:
				var want := SUP_EQ * float(dv) * (1.0 - f)
				var have := 0.0
				for p in groups[cpv]:
					if world.dep_stock.has(p):
						have += _value(world.dep_stock[p])
				var got := minf(want, have)
				if got > 0.0:
					for p in groups[cpv]:
						if world.dep_stock.has(p) and got > 0.0:
							got -= _take(world.dep_stock[p], got)
					m = f + (1.0 - f) * minf(want, have) / want
			elif dv == 0 and f < 1.0:
				# войск нет — пункт подаёт, пока есть запас
				for p in groups[cpv]:
					if world.dep_stock.has(p) and _value(world.dep_stock[p]) > 0.0:
						m = 1.0
			for p in groups[cpv]:
				world.p_dsup[p] = m
			# подвоз снаряжения на главный склад участка
			var safe: float = float(nat.conv_safe.get(mp, 0.0))
			if safe <= 0.0:
				continue
			# излишки (доля упала) — понемногу домой теми же конвоями
			if st.size() == 4:
				for k in Military.EQ_LAND:
					var over := st[k] - RETURN_AT * sh * tot[k]
					if over > 0.0:
						var mv := over * RETURN_RATE
						st[k] -= mv
						nat.stock[k] += mv * safe
				if world.dep_stock.has(mp):
					world.dep_stock[mp] = st
			if sh <= 0.0:
				continue
			var gap := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
			var gv := 0.0
			for k in Military.EQ_LAND:
				gap[k] = maxf(0.0, sh * tot[k] - (st[k] if st.size() == 4 else 0.0))
				gv += gap[k] * float(Military.EQ_COST[k])
			if gv <= 0.0:
				continue
			var trip := TRIP_BASE + TRIP_PER * float(_route_len(nat, mp))
			var conv := gv / HORIZON * trip / CARGO
			plan.append([mp, gap, conv, trip, safe, gv])
			need_sum += conv
		nat.conv_eq_need = need_sum
		if plan.is_empty() or free <= 0.0:
			continue
		var a := minf(1.0, free / need_sum)
		nat.conv_eq_use = need_sum * a
		var sunk := 0.0
		for pl in plan:
			var mp: int = pl[0]
			var gap: PackedFloat64Array = pl[1]
			var cv: float = float(pl[2]) * a
			var safe: float = pl[4]
			var flow := cv * CARGO / float(pl[3])   # очков заводов в день
			var frac := minf(1.0, flow / float(pl[5]))
			if not world.dep_stock.has(mp):
				world.dep_stock[mp] = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
				world.dep_owner[mp] = n
			var st: PackedFloat64Array = world.dep_stock[mp]
			for k in Military.EQ_LAND:
				var mv := minf(nat.stock[k], gap[k] * frac)
				nat.stock[k] -= mv
				st[k] += mv * safe   # не дошедшее потоплено
			world.dep_stock[mp] = st
			sunk += cv * (1.0 - safe) * Convoys.SINK
		if sunk > 0.0:
			nat.convoys = maxf(0.0, nat.convoys - sunk)
			nat.conv_sunk += sunk
			nat.conv_sunk_month += sunk


## ИИ (раз в 30 дней): участок за морем со своими войсками, но без пункта
## снабжения, — улучшить узел в лучшем своём порту там (порт с узлом ≥ 1 —
## пункт снабжения): иначе гарнизоны островов и колоний без крупного города
## остаются без снабжения.
static func ai_ports(world: World, divs: Dictionary, by_nat: Array) -> void:
	var pc := world.prov_count
	var ctrl := world.p_controller
	var comp := world.p_comp
	var best := {}   # страна * pc + участок -> порт с наибольшими очками
	for p in world.port_list:
		var c := ctrl[p]
		if c < 0 or comp[p] < 0 or world.nations[c].is_player or (world.day + c) % 30 != 19:
			continue
		var key := c * pc + comp[p]
		if not divs.has(key) or (by_nat[c] != null and by_nat[c].has(comp[p])):
			continue
		if not best.has(key) or world.p_vp[p] > world.p_vp[int(best[key])]:
			best[key] = p
	var ks: Array = best.keys()
	ks.sort()
	for key in ks:
		var c: int = key / pc
		var p: int = best[key]
		if not Supply.has_job(world.nations[c], p, Supply.JOB_UP):
			Supply.order(world, world.nations[c], p, Supply.JOB_UP)


## Длина пути конвоев до порта (в бассейнах; нет — 1).
static func _route_len(nat: World.Nation, p: int) -> int:
	for rt in nat.conv_routes:
		if int(rt[0]) == 1 and int(rt[1]) == p:
			return maxi(1, (rt[2] as PackedInt32Array).size())
	return 1


## Запас склада в очках заводов.
static func _value(st: PackedFloat64Array) -> float:
	var v := 0.0
	for k in Military.EQ_LAND:
		v += st[k] * float(Military.EQ_COST[k])
	return v


## Взять со склада v очков заводов (поровну по доле каждого типа); сколько взято.
static func _take(st: PackedFloat64Array, v: float) -> float:
	var have := _value(st)
	if have <= 0.0:
		return 0.0
	var f := minf(1.0, v / have)
	for k in Military.EQ_LAND:
		st[k] -= st[k] * f
	return have * f


## Пулы пополнения для ядра восстановления: дивизия -> пул (страна — запас
## метрополии; nc + j — склад j из списка), −1 — нет запаса по суше.
## Возвращает [пул по дивизиям, склады (провинции) по порядку].
static func pools(world: World) -> Array:
	var nc := world.nation_count
	var pc := world.prov_count
	var n := world.d_alive.size()
	var pool := PackedInt32Array()
	pool.resize(n)
	var order := PackedInt32Array()
	if world.p_comp.size() != pc:
		for i in n:
			pool[i] = world.d_owner[i]
		return [pool, order]
	# склад участка с наибольшим запасом
	var best := {}   # страна * pc + участок -> индекс склада
	var keys: Array = world.dep_stock.keys()
	keys.sort()
	for p in keys:
		var o: int = world.dep_owner[p]
		var key: int = o * pc + world.p_comp[p]
		var j := order.size()
		order.append(p)
		if not best.has(key) or _value(world.dep_stock[p]) > _value(world.dep_stock[order[int(best[key])]]):
			best[key] = j
	var comp := world.p_comp
	for i in n:
		var o := world.d_owner[i]
		var p := world.d_prov[i]
		if world.d_alive[i] == 0 or o < 0 or p < 0:
			pool[i] = o
			continue
		var cpv := comp[p]
		if cpv >= 0 and cpv == world.nations[o].dep_home:
			pool[i] = o
		else:
			pool[i] = nc + int(best[o * pc + cpv]) if best.has(o * pc + cpv) else -1
	return [pool, order]
