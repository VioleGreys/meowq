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
##    страны, за морем — склад участка; он пуст — во вторую очередь морем (из
##    метрополии, если к пункту участка есть путь конвоев); иначе не пополняется.

const DEPOT_VP := 15            # крупный город (очки победы) — пункт снабжения
const CAP_W := 3.0              # вес столицы в раскладке запаса страны по пунктам
const DEFAULT_SHARE := 0.5      # доля запаса страны на складе (игрок, по умолчанию)
const SHARE_SUM_MAX := 0.8      # склады за морем вместе — не больше (метрополии остаётся)
const AI_SHARE_K := 1.5         # ИИ: доля = доля дивизий страны на участке × K…
const AI_SHARE_MAX := 0.5       # …не больше
const CARGO := 15.0             # снаряжения (в очках заводов) за рейс конвоя
const TRIP_BASE := 4.0          # рейс: дней…
const TRIP_PER := 3.0           # …и ещё за каждый бассейн пути
const HORIZON := 20.0           # недостачу склада закрывают за столько дней
const RETURN_AT := 1.5          # запас склада сверх доли × столько — излишек…
const RETURN_RATE := 0.05       # …вывозится домой по столько в день
const SUP_EQ := 2.5             # снаряжения (очки заводов) в день на дивизию без подвоза


## Пункт снабжения: столица хозяина, крупный город или порт с улучшенным узлом.
static func is_depot(world: World, p: int) -> bool:
	if world.p_land[p] == 0:
		return false
	var c := world.p_controller[p]
	if c >= 0 and world.nations[c].capital == p:
		return true
	if world.p_vp[p] >= DEPOT_VP:
		return true
	if _colcap(world)[p] == 1:
		return true
	return world.p_node_lvl.size() == world.prov_count and world.p_node_lvl[p] >= 1 and Forces.is_port(world, p)


## Маска пунктов снабжения на всех провинциях — то же, что is_depot(p) для
## каждой p (на день: владельцы не меняются). Постоянная часть (крупные
## города, столицы колоний) — списком один раз, остальное — по портам,
## плацдармам и столицам: без прохода по всем провинциям.
static func mask(world: World) -> PackedByteArray:
	return mask_list(world)[0]


static var _base_list := PackedInt32Array()
static var _base_cc := PackedByteArray()
static var _base_of := 0


static var _big := PackedInt32Array()
static var _big_of := 0


## Крупные города (очки победы ≥ DEPOT_VP) по возрастанию номера — очки
## победы постоянны, список один на карту.
static func big_cities(world: World) -> PackedInt32Array:
	if _big_of != world.get_instance_id() or _big.is_empty():
		var res := PackedInt32Array()
		var vp := world.p_vp
		for p in world.prov_count:
			if vp[p] >= DEPOT_VP:
				res.append(p)
		_big = res
		_big_of = world.get_instance_id()
	return _big


## [маска, пункты по возрастанию номера].
static func mask_list(world: World) -> Array:
	var pc := world.prov_count
	var res := PackedByteArray()
	res.resize(pc)
	var land := world.p_land
	var ctrl := world.p_controller
	var cc := _colcap(world)
	if world.p_port.size() != pc:
		Forces.refresh_ports(world)
	if _base_of != world.get_instance_id() or _base_cc != cc:
		var vp := world.p_vp
		var bl := PackedInt32Array()
		for p in pc:
			if land[p] == 1 and (vp[p] >= DEPOT_VP or cc[p] == 1):
				bl.append(p)
		_base_list = bl
		_base_cc = cc.duplicate()
		_base_of = world.get_instance_id()
	var lst: PackedInt32Array = _base_list.duplicate()
	for p in lst:
		res[p] = 1
	var extra := false
	var lvl := world.p_node_lvl
	if lvl.size() == pc:
		for p in world.port_list:
			if res[p] == 0 and land[p] == 1 and lvl[p] >= 1:
				res[p] = 1
				lst.append(p)
				extra = true
		var bh := world.beachheads
		for p in bh:
			if res[p] == 0 and land[p] == 1 and lvl[p] >= 1 and int(bh[p]) >= world.day:
				res[p] = 1
				lst.append(p)
				extra = true
	for nat in world.nations:
		var cp: int = nat.capital
		if cp >= 0 and cp < pc and land[cp] == 1 and ctrl[cp] == nat.id and res[cp] == 0:
			res[cp] = 1
			lst.append(cp)
			extra = true
	if extra:
		lst.sort()
	return [res, lst]


## Столицы колоний: крупнейший город (очки победы; при равенстве — меньший
## номер) каждой колониальной территории владельца на начало игры (код страны
## Natural Earth; сначала порт, потом побережье) — тоже пункт снабжения (Тетуан, Эль-Аюн, Асмэра, Дакар):
## иначе гарнизоны колоний без большого города сидели без снабжения
## (Африканская армия франкистов в Марокко 1936 г. — 11 %).
static func _colcap(world: World) -> PackedByteArray:
	if world.p_colcap.size() == world.prov_count:
		return world.p_colcap
	var res := PackedByteArray()
	res.resize(world.prov_count)
	var best := {}
	for p in world.prov_count:
		if world.p_land[p] == 0 or world.p_colony.size() != world.prov_count or world.p_colony[p] != 1:
			continue
		var key := "%d:%s" % [world.p_owner[p], world.p_adm0[p]]
		if not best.has(key) or _colscore(world, p) > _colscore(world, int(best[key])):
			best[key] = p
	for key in best:
		res[int(best[key])] = 1
	world.p_colcap = res
	return res


## Столица колонии — сначала порт (туда ходят конвои), потом очки победы.
static func _colscore(world: World, p: int) -> int:
	return world.p_vp[p] + (1000 if Forces.is_port(world, p) else (500 if world.p_coastal[p] == 1 else 0))


## Пункты, куда ходят конвои снабжения: порты и столицы колоний на побережье.
static var _sea_extra := PackedInt32Array()
static var _sea_cc := PackedByteArray()
static var _sea_of := 0


static func sea_points(world: World) -> PackedInt32Array:
	var res := world.port_list.duplicate()
	var cc := _colcap(world)
	# столицы колоний на побережье без порта — постоянны (столицы колоний и
	# порты не меняются): список один раз на карту
	if _sea_of != world.get_instance_id() or _sea_cc != cc:
		var ex := PackedInt32Array()
		for p in world.prov_count:
			if cc[p] == 1 and world.p_coastal[p] == 1 and world.p_port[p] == 0:
				ex.append(p)
		_sea_extra = ex
		_sea_cc = cc.duplicate()
		_sea_of = world.get_instance_id()
	res.append_array(_sea_extra)
	return res


## Участки суши сторон: обход от каждой провинции по соседям той же стороны
## (своя или союзная), через безлюдную пустыню — не дальше.
# прошлый обход участков: входы (копии) и ответ — суша и соседство у карты постоянны
static var _cmp_of := 0
static var _cmp_ctrl := PackedInt32Array()
static var _cmp_ally := PackedByteArray()
static var _cmp_waste := PackedByteArray()
static var _cmp_res := PackedInt32Array()


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
	var fresh := true
	if _cmp_of == world.get_instance_id() and _cmp_ctrl == ctrl and _cmp_ally == ally and _cmp_waste == waste \
			and _cmp_res.size() == pc:
		# контролёры, союзы и пустыни те же, что при прошлом обходе, — участки те же
		comp = _cmp_res
		fresh = false
	elif Native.core != null and Native.core.has_method("land_components"):
		# C++ — MeowqCore.land_components, тот же обход и номера
		comp = Native.core.call("land_components", ctrl, land, ally, a_start, a_list, waste, nc)
	else:
		comp = _components_gd(pc, nc, ctrl, land, ally, has_ally, a_start, a_list, waste, has_waste)
	if fresh:
		_cmp_of = world.get_instance_id()
		_cmp_ctrl = ctrl.duplicate()
		_cmp_ally = ally.duplicate()
		_cmp_waste = waste.duplicate()
		_cmp_res = comp
	world.p_comp = comp
	for nat in world.nations:
		var cp: int = nat.capital
		nat.dep_home = comp[cp] if nat.alive and cp >= 0 and cp < pc and ctrl[cp] == nat.id else -1


static func _components_gd(pc: int, nc: int, ctrl: PackedInt32Array, land: PackedByteArray, ally: PackedByteArray,
		has_ally: bool, a_start: PackedInt32Array, a_list: PackedInt32Array, waste: PackedByteArray, has_waste: bool) -> PackedInt32Array:
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
	return comp


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
	var _q := Time.get_ticks_usec()
	Supply._static(world)
	Prof.add("пс:static", _q); _q = Time.get_ticks_usec()
	components(world)
	Prof.add("пс:components", _q); _q = Time.get_ticks_usec()
	var ml := mask_list(world)
	var dmask: PackedByteArray = ml[0]
	var dlist: PackedInt32Array = ml[1]
	var ctrl := world.p_controller
	if world.p_dsup.size() != pc:
		world.p_dsup.resize(pc)
	world.p_dsup.fill(1.0)
	# склады: хозяин сменился — запас пропал; участок стал метрополией — в общий запас
	var keys: Array = world.dep_stock.keys()
	keys.sort()
	for p in keys:
		var o: int = world.dep_owner.get(p, -1)
		if o < 0 or ctrl[p] != o or not world.nations[o].alive or dmask[p] == 0:
			world.dep_stock.erase(p)
			world.dep_owner.erase(p)
			continue
		if not overseas(world, o, p):
			var st: PackedFloat64Array = world.dep_stock[p]
			for k in Military.EQ_LAND:
				world.nations[o].stock[k] += st[k]
			world.dep_stock.erase(p)
			world.dep_owner.erase(p)
	Prof.add("пс:склады", _q); _q = Time.get_ticks_usec()
	var sc := _scan(world, dlist)
	_apply_cut(world, sc)
	Prof.add("пс:разбор", _q); _q = Time.get_ticks_usec()
	ai_ports(world, sc)
	Prof.add("пс:ai_ports", _q); _q = Time.get_ticks_usec()
	var g_ns: PackedInt32Array = sc[3]
	var g_start: PackedInt32Array = sc[5]
	var g_pts: PackedInt32Array = sc[6]
	var g_best: PackedInt32Array = sc[7]
	var g_dv: PackedInt32Array = sc[8]
	var g_f: PackedFloat64Array = sc[9]
	var total: PackedInt32Array = sc[12]
	var stk := PackedByteArray()   # есть склад (World.dep_stock)
	stk.resize(pc)
	for p in world.dep_stock:
		stk[p] = 1
	var dsup := world.p_dsup
	world.dep_want = {}
	for nat: World.Nation in world.nations:
		var n := nat.id
		nat.conv_eq_need = 0.0
		nat.conv_eq_use = 0.0
		var g0 := g_ns[n]
		var g1 := g_ns[n + 1]
		if not nat.alive or g0 == g1:
			continue
		# доли: игрок — свои (по умолчанию 0,5), ИИ — по дивизиям участка; главный
		# склад участка (g_best) — порт с лучшим путём конвоев (иначе первый пункт)
		var shs := PackedFloat64Array()
		shs.resize(g1 - g0)
		var share_sum := 0.0
		for g in range(g0, g1):
			var best := g_best[g]
			var sh: float
			var dv := g_dv[g]
			if nat.is_player:
				# своя доля игрока; по умолчанию — 50 % там, где стоят его войска
				if not world.dep_share.has(best):
					world.dep_share[best] = DEFAULT_SHARE if dv > 0 else 0.0
				sh = float(world.dep_share[best])
			else:
				sh = 0.0 if dv == 0 else minf(AI_SHARE_MAX, AI_SHARE_K * float(dv) / maxf(1.0, float(total[n])))
			world.dep_want[best] = sh
			shs[g - g0] = sh
			share_sum += sh
		var norm := 1.0 if share_sum <= SHARE_SUM_MAX else SHARE_SUM_MAX / share_sum
		# запас страны всего (метрополия + склады)
		var tot := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
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
		for g in range(g0, g1):
			var mp := g_best[g]
			var sh: float = shs[g - g0] * norm
			world.dep_want[mp] = sh
			var st: PackedFloat64Array = world.dep_stock.get(mp, PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0]))
			# ежедневное снабжение: недостача подвоза — со складов участка
			# (подвоз g_f — только у портов с путём конвоев; Convoys: обход раз в 14 дней)
			var dv := g_dv[g]
			var f := g_f[g]
			var m := f
			var pa := g_start[g]
			var pb := g_start[g + 1]
			if dv > 0 and f < 1.0:
				var want := SUP_EQ * float(dv) * (1.0 - f)
				var have := 0.0
				for j in range(pa, pb):
					var p := g_pts[j]
					if stk[p] == 1:
						have += _value(world.dep_stock[p])
				var got := minf(want, have)
				if got > 0.0:
					for j in range(pa, pb):
						var p := g_pts[j]
						if stk[p] == 1 and got > 0.0:
							got -= _take(world.dep_stock[p], got)
					m = f + (1.0 - f) * minf(want, have) / want
			elif dv == 0 and f < 1.0:
				# войск нет — пункт подаёт, пока есть запас
				for j in range(pa, pb):
					var p := g_pts[j]
					if stk[p] == 1 and _value(world.dep_stock[p]) > 0.0:
						m = 1.0
			for j in range(pa, pb):
				dsup[g_pts[j]] = m
			# подвоз снаряжения на главный склад участка
			var safe: float = float(nat.conv_safe.get(mp, 0.0))
			if safe <= 0.0:
				continue
			# излишки (доля упала) — понемногу домой теми же конвоями
			if st.size() == Military.EQ_LAND:
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
			var gap := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
			var gv := 0.0
			for k in Military.EQ_LAND:
				gap[k] = maxf(0.0, sh * tot[k] - (st[k] if st.size() == Military.EQ_LAND else 0.0))
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
				world.dep_stock[mp] = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
				world.dep_owner[mp] = n
				stk[mp] = 1
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
	world.p_dsup = dsup


## ИИ (раз в 30 дней): участок за морем со своими войсками, но без пункта
## снабжения, — улучшить узел в лучшем своём порту там (порт с узлом ≥ 1 —
## пункт снабжения): иначе гарнизоны островов и колоний без крупного города
## остаются без снабжения. sc — разбор пунктов (_scan).
static func ai_ports(world: World, sc: Array) -> void:
	var pc := world.prov_count
	var ctrl := world.p_controller
	var comp := world.p_comp
	# страны, чей сегодня день (раз в 30 дней), — маской: без них прохода нет
	var turn := PackedByteArray()
	turn.resize(world.nation_count)
	var any := false
	for nat in world.nations:
		if not nat.is_player and (world.day + nat.id) % 30 == 19:
			turn[nat.id] = 1
			any = true
	if not any:
		return
	var divs := {}   # страна * pc + участок с дивизиями за морем
	for key in sc[10]:
		divs[key] = true
	var grp := {}    # страна * pc + участок с пунктами
	var g_ns: PackedInt32Array = sc[3]
	var g_comp: PackedInt32Array = sc[4]
	for c in world.nation_count:
		if turn[c] == 1:
			for g in range(g_ns[c], g_ns[c + 1]):
				grp[c * pc + g_comp[g]] = true
	var best := {}   # страна * pc + участок -> порт с наибольшими очками
	for p in world.port_list:
		var c := ctrl[p]
		if c < 0 or turn[c] == 0 or comp[p] < 0:
			continue
		var key := c * pc + comp[p]
		if not divs.has(key) or grp.has(key):
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


# связь пунктов со столицей вчера — зеркало World.dep_linked (словарь, он в
# сохранении) по провинциям; зеркало — того словаря, что в _lp_dict
static var _lp := PackedInt32Array()
static var _lp_dict: Dictionary = {}


## Разбор пунктов за день (ядро: C++ — MeowqCore.depots_scan, двойник —
## _scan_gd): связь со столицей и отрезанные пункты (запас страны лежит по её
## пунктам снабжения, столица — с весом CAP_W по очкам победы; пункт, вчера
## связанный со столицей, а сегодня отрезанный (котёл, раскол страны),
## оставляет себе свою долю запаса метрополии — отрезанный город держится на
## своих складах, юг националистов 1936 г.), дивизии за морем по участкам,
## пункты за морем по странам и участкам (по возрастанию номеров), у групп —
## главный порт (лучший путь конвоев), дивизии и подвоз конвоями.
## → [связь (pc), отрезанные, веса стран, начала групп стран (nc + 1), участок
## группы, начала пунктов групп, пункты, главный, дивизий, подвоз, ключи
## «страна * pc + участок» с дивизиями, их число, дивизий страны всего].
static func _scan(world: World, dlist: PackedInt32Array) -> Array:
	var t := _scan_t(world, dlist)
	var r: Array
	if Native.core != null and Native.core.has_method("depots_scan"):
		r = Native.core.call("depots_scan", t)
	else:
		r = _scan_gd(t)
	r.append(t["total"])
	# связь сменилась — новый словарь (по возрастанию номеров, как всегда)
	var ln: PackedInt32Array = r[0]
	if ln != _lp:
		var now := {}
		for p in dlist:
			if ln[p] >= 0:
				now[p] = ln[p]
		world.dep_linked = now
		_lp_dict = now
		_lp = ln
	return r


## Входы разбора пунктов (у ядра «total» не читается — дивизий страны всего).
static func _scan_t(world: World, dlist: PackedInt32Array) -> Dictionary:
	var pc := world.prov_count
	var nc := world.nation_count
	var ctrl := world.p_controller
	var home := PackedInt32Array()
	home.resize(nc)
	var capn := PackedInt32Array()
	capn.resize(nc)
	for nat in world.nations:
		home[nat.id] = nat.dep_home
		capn[nat.id] = nat.capital
	if not is_same(_lp_dict, world.dep_linked) or _lp.size() != pc:
		var lp := PackedInt32Array()
		lp.resize(pc)
		lp.fill(-1)
		for p in world.dep_linked:
			lp[int(p)] = int(world.dep_linked[p])
		_lp = lp
		_lp_dict = world.dep_linked
	# доля, что доходит до порта (Convoys.daily) — у страны, что держит порт
	var cs := PackedFloat64Array()
	cs.resize(pc)
	cs.fill(-1.0)
	for nat in world.nations:
		var csd: Dictionary = nat.conv_safe
		if csd.is_empty():
			continue
		var n: int = nat.id
		for p in csd:
			if ctrl[p] == n:
				cs[p] = float(csd[p])
	# дивизии вне метрополии — выборкой (World.overseas_slots), не проходом всех
	var osl := world.overseas_slots(home)
	var t := {"nc": nc, "pc": pc, "ctrl": ctrl, "comp": world.p_comp, "dlist": dlist, "home": home,
		"capn": capn, "vp": world.p_vp, "cap_w": CAP_W, "lp": _lp, "slots": osl[0],
		"dprov": world.d_prov, "downer": world.d_owner, "cs": cs, "pconv": world.p_conv, "total": osl[1]}
	return t


## Двойник MeowqCore.depots_scan (см. _scan).
static func _scan_gd(t: Dictionary) -> Array:
	var nc: int = t["nc"]
	var pc: int = t["pc"]
	var ctrl: PackedInt32Array = t["ctrl"]
	var comp: PackedInt32Array = t["comp"]
	var dlist: PackedInt32Array = t["dlist"]
	var home: PackedInt32Array = t["home"]
	var capn: PackedInt32Array = t["capn"]
	var vp: PackedInt32Array = t["vp"]
	var cap_w: float = t["cap_w"]
	var lp: PackedInt32Array = t["lp"]
	var slots: PackedInt32Array = t["slots"]
	var dprov: PackedInt32Array = t["dprov"]
	var downer: PackedInt32Array = t["downer"]
	var cs: PackedFloat64Array = t["cs"]
	var pconv: PackedFloat32Array = t["pconv"]
	var has_comp := comp.size() == pc
	var has_conv := pconv.size() == pc
	var ln := PackedInt32Array()
	ln.resize(pc)
	ln.fill(-1)
	var cut := PackedInt32Array()
	var weight := PackedFloat64Array()
	weight.resize(nc)
	for p in dlist:
		var c := ctrl[p]
		if c < 0:
			continue
		var w := float(maxi(1, vp[p])) * (cap_w if capn[c] == p else 1.0)
		if has_comp and (home[c] < 0 or comp[p] != home[c]):   # = overseas(world, c, p)
			if lp[p] == c:
				cut.append(p)
				weight[c] += w
		else:
			ln[p] = c
			weight[c] += w
	var divs := {}   # страна * pc + участок -> дивизий (в порядке появления)
	for i in slots:
		var cpv := comp[dprov[i]]
		if cpv >= 0:
			var key := downer[i] * pc + cpv
			divs[key] = int(divs.get(key, 0)) + 1
	var grp := {}    # страна * pc + участок -> пункты (по возрастанию номера)
	for p in dlist:
		var c := ctrl[p]
		if c < 0 or comp[p] < 0 or comp[p] == home[c]:
			continue
		var key := c * pc + comp[p]
		if not grp.has(key):
			grp[key] = PackedInt32Array()
		var lst: PackedInt32Array = grp[key]
		lst.append(p)
		grp[key] = lst
	var gk: Array = grp.keys()
	gk.sort()
	var g_ns := PackedInt32Array()
	g_ns.resize(nc + 1)
	var g_comp := PackedInt32Array()
	var g_start := PackedInt32Array([0])
	var g_pts := PackedInt32Array()
	var g_best := PackedInt32Array()
	var g_dv := PackedInt32Array()
	var g_f := PackedFloat64Array()
	var cn := 0
	for key in gk:
		var c: int = key / pc
		while cn <= c:
			g_ns[cn] = g_comp.size()
			cn += 1
		g_comp.append(key % pc)
		var lst: PackedInt32Array = grp[key]
		var best := lst[0]
		var bs := -1.0
		var f := 0.0
		for p in lst:
			var sf := cs[p]
			if sf > bs:
				bs = sf
				best = p
			if sf != -1.0 and has_conv:
				f = maxf(f, pconv[p])
		g_pts.append_array(lst)
		g_start.append(g_pts.size())
		g_best.append(best)
		g_dv.append(int(divs.get(key, 0)))
		g_f.append(f)
	while cn <= nc:
		g_ns[cn] = g_comp.size()
		cn += 1
	var dv_key := PackedInt32Array(divs.keys())
	var dv_cnt := PackedInt32Array(divs.values())
	return [ln, cut, weight, g_ns, g_comp, g_start, g_pts, g_best, g_dv, g_f, dv_key, dv_cnt]


## Отрезанные пункты (_scan) забирают свою долю запаса метрополии — по очкам
## победы, в порядке номеров.
static func _apply_cut(world: World, sc: Array) -> void:
	var cut: PackedInt32Array = sc[1]
	if cut.is_empty():
		return
	var weight: PackedFloat64Array = sc[2]
	var ctrl := world.p_controller
	for p in cut:
		var c := ctrl[p]
		var nat: World.Nation = world.nations[c]
		var f := float(maxi(1, world.p_vp[p])) / maxf(1.0, weight[c])
		if not world.dep_stock.has(p):
			world.dep_stock[p] = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0])
			world.dep_owner[p] = c
		var st: PackedFloat64Array = world.dep_stock[p]
		for k in Military.EQ_LAND:
			var mv: float = nat.stock[k] * f
			nat.stock[k] -= mv
			st[k] += mv
		world.dep_stock[p] = st


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
		if _value(world.dep_stock[p]) <= 0.0:
			continue
		if not best.has(key) or _value(world.dep_stock[p]) > _value(world.dep_stock[order[int(best[key])]]):
			best[key] = j
	# склад участка пуст — во вторую очередь морем: из запаса метрополии, если
	# к пункту участка есть путь конвоев
	var sea := {}   # страна * pc + участок
	for nat in world.nations:
		for p in nat.conv_safe:
			if float(nat.conv_safe[p]) > 0.0 and world.p_controller[int(p)] == nat.id:
				sea[nat.id * pc + world.p_comp[int(p)]] = true
	var comp := world.p_comp
	var downer := world.d_owner
	var dprov := world.d_prov
	var home := PackedInt32Array()
	home.resize(nc)
	for nat in world.nations:
		home[nat.id] = nat.dep_home
	# по умолчанию — запас хозяина; вне метрополии — склад участка или море
	pool = downer.duplicate()
	pool.resize(n)
	for i in world.overseas_slots(home)[0]:
		var o := downer[i]
		var key := o * pc + comp[dprov[i]]
		pool[i] = nc + int(best[key]) if best.has(key) else (o if sea.has(key) else -1)
	return [pool, order]
