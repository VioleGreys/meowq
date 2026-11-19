class_name Convoys
extends RefCounted
## Конвои (как в жанре, числа свои): торговые суда страны. Нужны на
##  * морской импорт — по каждой поставке от продавца за морем: единиц в день ×
##    (PER_UNIT + PER_BASIN × длина пути в бассейнах);
##  * снабжение войск за морем — PER_DIV на дивизию не на материке столицы;
##    подача заморских портов (Supply, world.p_conv) — по обеспеченности и
##    доле, что доходит по пути от портов метрополии.
## Сначала конвои идут на снабжение, остаток — на торговлю. Нехватка конвоев —
## часть импорта не приходит (Nation.res_lost → Economy.available).
## Перехват (только на пути — штраф по торговле через это море, а не по всему
## выпуску): в бассейне с рейдерами противника — (рейды − 0,7 × охранение) ×
## INTERCEPT, не больше INTERCEPT_MAX; в зоне под господством боевых флотов
## противника (местное господство < BLOCK_SHARE — блокада) — BLOCKADE_LOSS:
## конвои там уничтожают. Доля, что доходит по пути, — произведение (1 − перехват)
## по его зонам; гибнет в день SINK × конвоев на пути × (1 − доля).
## Пути — раз в SWEEP_DAYS вместе с блокадой (Economy.daily → refresh_routes):
## от портов метрополии через открытые для страны БАССЕЙНЫ — морские зоны
## одного моря или океана (по названию, связные), например весь Тихий океан —
## один бассейн (решение пользователя: не делить путь на десятки зон).
## Перехват и охранение — по всему бассейну.

const COST := 25.0           # очков судостроения за конвой (эсминец — 110)
const PER_UNIT := 0.3        # конвоев на единицу импорта в день (ресурсы в единицах с ноября 2026 г., ×3 к прежним)…
const PER_BASIN := 0.09     # …и ещё столько за каждый бассейн пути (×0,3 к прежнему, как PER_UNIT)
const PER_DIV := 2.0         # конвоев на дивизию за морем
const INTERCEPT := 0.004
const INTERCEPT_MAX := 0.3
const ESCORT_K := 0.7
const BLOCK_SHARE := 0.3
const BLOCKADE_LOSS := 0.6
const SINK := 0.02
const RES_N := 6             # ресурсов в поставках (World.Nation.res_lost)
const BUILD_MAX := 3         # конвоев в день, не больше
const RESERVE := 1.2         # ИИ держит запас сверх нужды
const RESERVE_MIN := 5.0
const DEFAULT_PER_PORT := 3.0   # нет в forces.json — по 3 на порт метрополии…
const DEFAULT_MAX := 40.0       # …но не больше 40
const CHARTER := 0.2            # страна без верфей фрахтует конвои: в день, до нужды (не больше DEFAULT_MAX)


## Стартовые конвои: forces.json "convoys" или по числу портов метрополии.
static func setup(world: World, data: Dictionary) -> void:
	var ports := PackedInt32Array()
	ports.resize(world.nation_count)
	for p in world.prov_count:
		var o := world.p_owner[p]
		if o < 0 or world.p_land[p] == 0 or world.p_colony[p] == 1 or not Forces.is_port(world, p):
			continue
		ports[o] += 1
	for nat in world.nations:
		var fd: Dictionary = data.get(nat.tag, {})
		if fd.has("convoys"):
			nat.convoys = float(fd["convoys"])
		else:
			nat.convoys = minf(DEFAULT_MAX, DEFAULT_PER_PORT * float(ports[nat.id]))


## Проливы (forces.json "straits"): пара морских зон, держатели — провинции
## на берегу, страж — страна, что охраняет пролив, пока её не выбили (Британия:
## Суэц по договору с Египтом, Гибралтар). Связь link — между бассейнами, не
## соседними на карте (канал, Босфор). Пути конвоев страны через пролив закрыты,
## если с ней воюет кто-то из держателей (Convoys.strait_closed).
static func setup_straits(world: World, data: Array) -> void:
	world.straits = []
	var by_name := {}
	for p in world.prov_count:
		if not by_name.has(world.p_name[p]):
			by_name[world.p_name[p]] = p
	for st in data:
		var za: int = by_name.get(String(st.get("a", "")), -1)
		var zb: int = by_name.get(String(st.get("b", "")), -1)
		var hold := PackedInt32Array()
		for nm in st.get("hold", []):
			var hp: int = by_name.get(String(nm), -1)
			if hp >= 0 and world.p_land[hp] == 1:
				hold.append(hp)
		if za < 0 or zb < 0 or world.p_land[za] != 0 or world.p_land[zb] != 0 or hold.is_empty():
			push_warning("пролив %s: нет зон или берега" % st.get("name", "?"))
			continue
		var g := world.nation_tags.find(String(st.get("guard", "")))
		world.straits.append([za, zb, 1 if st.get("link", false) else 0, hold, g, String(st.get("name", ""))])


## Держатели пролива: хозяева провинций берега и страж, если он жив и не воюет
## ни с одним из них (иначе берег у врага стража — пролив его).
static func strait_holders(world: World, st: Array) -> PackedInt32Array:
	var nc := world.nation_count
	var res := PackedInt32Array()
	var g: int = st[4]
	var guard_ok: bool = g >= 0 and world.nations[g].alive
	for hp in st[3]:
		var c := world.p_controller[hp]
		if c < 0:
			continue
		if not res.has(c):
			res.append(c)
		if guard_ok and c != g and world.war[g * nc + c] == 1:
			guard_ok = false
	if guard_ok and not res.has(g):
		res.append(g)
	return res


## Пролив закрыт для страны n: с ней воюет кто-то из держателей (Италия до
## июня 1940 г. ходила Суэцем, хотя Германия уже воевала с Британией; порты
## невоюющих союзников — Виши — не снабжают сторону: Simulation._phase_supply).
static func strait_closed(world: World, st: Array, n: int) -> bool:
	var nc := world.nation_count
	for h in strait_holders(world, st):
		if world.war[h * nc + n] == 1:
			return true
	return false


## Связи бассейнов через проливы для страны n: [доп. соседи {бассейн: [бассейны]},
## закрытые пары {a * nb + b: true}].
static func _strait_links(world: World, n: int) -> Array:
	var nb := world.basin_name.size()
	var extra := {}
	var cut := {}
	var zb := world.z_basin
	for st in world.straits:
		var a: int = zb[int(st[0])]
		var b: int = zb[int(st[1])]
		if a < 0 or b < 0 or a == b:
			continue
		if strait_closed(world, st, n):
			cut[a * nb + b] = true
			cut[b * nb + a] = true
		elif int(st[2]) == 1:
			if not extra.has(a):
				extra[a] = []
			if not extra.has(b):
				extra[b] = []
			extra[a].append(b)
			extra[b].append(a)
	return [extra, cut]


## Материк столицы страны (−1 — нет).
static func home_mass(world: World, n: int) -> int:
	var c: int = world.nations[n].capital
	if c < 0 or world.p_mass.size() != world.prov_count:
		return -1
	return world.p_mass[c]


## Земля метрополии страны n: провинции, связанные со столицей по суше через
## свои и союзные (одна сторона) провинции (1). Порты и войска вне её — за
## морем: им нужны конвои. Раньше брался весь материк столицы, и Эритрея с
## Ливией для Италии (Африка связана с Евразией через Синай) снабжались без
## конвоев — Суэц и Гибралтар ничего не значили.
static func home_land(world: World, n: int) -> PackedByteArray:
	var pc := world.prov_count
	var nc := world.nation_count
	var res := PackedByteArray()
	res.resize(pc)
	var c: int = world.nations[n].capital
	if c < 0 or c >= pc:
		return res
	var ctrl := world.p_controller
	var land := world.p_land
	var ally := world.ally
	var has_ally := ally.size() == nc * nc
	var a_start := world.adj_start
	var a_list := world.adj_list
	res[c] = 1
	var q := PackedInt32Array([c])
	var h := 0
	while h < q.size():
		var p := q[h]
		h += 1
		for k in range(a_start[p], a_start[p + 1]):
			var y := a_list[k]
			if res[y] == 1 or land[y] == 0:
				continue
			var o := ctrl[y]
			if o != n and (o < 0 or not has_ally or ally[n * nc + o] != 1):
				continue
			res[y] = 1
			q.append(y)
	return res


## Бассейны (раз на карту): зоны с одним названием моря без уточнения в
## скобках и номера («Тихий океан (10° ю. ш., …)», «Средиземное море (запад) 2»),
## связные между собой; несвязные куски — разные бассейны.
static func build_basins(world: World) -> void:
	var pc := world.prov_count
	if world.z_basin.size() == pc:
		return
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var base := PackedStringArray()
	base.resize(pc)
	var rx := RegEx.new()
	rx.compile("\\s*(\\(.*\\))?\\s*\\d*$")
	for p in pc:
		if land[p] == 0:
			base[p] = rx.sub(world.p_name[p], "").strip_edges()
	world.z_basin = PackedInt32Array()
	world.z_basin.resize(pc)
	world.z_basin.fill(-1)
	world.basin_name = PackedStringArray()
	var zones: Array = []
	var count := {}
	for p in pc:
		if land[p] != 0 or world.z_basin[p] >= 0:
			continue
		var bi := world.basin_name.size()
		var nm := base[p]
		count[nm] = int(count.get(nm, 0)) + 1
		world.basin_name.append(nm if int(count[nm]) == 1 else "%s (%d)" % [nm, int(count[nm])])
		var zl := PackedInt32Array([p])
		world.z_basin[p] = bi
		var h := 0
		while h < zl.size():
			var z := zl[h]
			h += 1
			for k in range(a_start[z], a_start[z + 1]):
				var y := a_list[k]
				if land[y] == 0 and world.z_basin[y] < 0 and base[y] == nm:
					world.z_basin[y] = bi
					zl.append(y)
		zl.sort()
		zones.append(zl)
	var nb := zones.size()
	# несвязные куски одного моря: «(север)/(юг)» по средней широте, иначе номер
	var by_name := {}
	for bi in nb:
		var nm0: String = base[zones[bi][0]]
		if not by_name.has(nm0):
			by_name[nm0] = []
		by_name[nm0].append(bi)
	for nm0 in by_name:
		var lst: Array = by_name[nm0]
		if lst.size() < 2:
			continue
		var lats: Array = []
		for bi in lst:
			var la := 0.0
			for z in zones[bi]:
				la += world.p_lonlat[z].y
			lats.append(la / float(zones[bi].size()))
		var two_sides: bool = lst.size() == 2 and (float(lats[0]) > 0.0) != (float(lats[1]) > 0.0)
		for i in lst.size():
			world.basin_name[lst[i]] = "%s (%s)" % [nm0, ("север" if float(lats[i]) > 0.0 else "юг")] if two_sides else ("%s (%d)" % [nm0, i + 1])
	world.bas_zone_start = PackedInt32Array([0])
	world.bas_zone_list = PackedInt32Array()
	world.bas_adj_start = PackedInt32Array([0])
	world.bas_adj_list = PackedInt32Array()
	for bi in nb:
		world.bas_zone_list.append_array(zones[bi])
		world.bas_zone_start.append(world.bas_zone_list.size())
		var nbs := {}
		for z in zones[bi]:
			for k in range(a_start[z], a_start[z + 1]):
				var y := a_list[k]
				if land[y] == 0 and world.z_basin[y] != bi:
					nbs[world.z_basin[y]] = true
		var ks: Array = nbs.keys()
		ks.sort()
		for x in ks:
			world.bas_adj_list.append(int(x))
		world.bas_adj_start.append(world.bas_adj_list.size())


static var _bs: Array = []
static var _bs_of := 0
static var _bs_n := -1

## Зоны каждого бассейна словарём {зона: true} (по порядку bas_zone_list);
## бассейны постоянны — один раз на мир.
static func _basin_sets(world: World) -> Array:
	if _bs_of == world.get_instance_id() and _bs_n == world.bas_zone_list.size():
		return _bs
	var res: Array = []
	for bi in world.bas_zone_start.size() - 1:
		var d := {}
		for j in range(world.bas_zone_start[bi], world.bas_zone_start[bi + 1]):
			d[world.bas_zone_list[j]] = true
		res.append(d)
	_bs = res
	_bs_of = world.get_instance_id()
	_bs_n = world.bas_zone_list.size()
	return res


## Пути конвоев всех стран (раз в SWEEP_DAYS, после обхода поставок).
## open_by: страна -> открытые для неё зоны (Economy.refresh_blockade; нет — всё открыто).
static func refresh_routes(world: World, open_by: Dictionary) -> void:
	var nc := world.nation_count
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var ctrl := world.p_controller
	if world.p_mass.size() != world.prov_count:
		return
	var _t0 := Time.get_ticks_usec()
	build_basins(world)
	if Native.core != null and Native.core.has_method("conv_routes") and world.p_comp.size() == world.prov_count:
		# C++ — MeowqCore.conv_routes: бассейны у портов, транзит, обходы и пути
		var sel: Array = []
		sel.resize(nc)
		for x in nc:
			sel[x] = {}
		for c in world.contracts:
			sel[int(c[0])][int(c[1])] = float(sel[int(c[0])].get(int(c[1]), 0.0)) + float(c[3])
		Prof.add("кв:подготовка", _t0)
		_t0 = Time.get_ticks_usec()
		_routes_native(world, open_by, sel)
		Prof.add("кв:пути", _t0)
		return
	Economy.open_dicts(open_by)   # открытые зоны из ядра блокады — словарями
	var zb := world.z_basin
	# бассейны у портов: все и у портов метрополии
	var zl: Array = []
	var zh: Array = []
	zl.resize(nc)
	zh.resize(nc)
	for x in nc:
		zl[x] = {}
		zh[x] = {}
	var hl: Array = []   # земля метрополии (home_land) — по мере надобности
	hl.resize(nc)
	var over: Array = []   # заморские порты стран (порядок провинций)
	over.resize(nc)
	for x in nc:
		over[x] = []
	var dmask := Depots.mask(world)   # = Depots.is_depot по всем провинциям
	var comp := world.p_comp
	var has_comp := comp.size() == world.prov_count
	var dhome := PackedInt32Array()
	dhome.resize(nc)
	for nat in world.nations:
		dhome[nat.id] = nat.dep_home
	for p in Depots.sea_points(world):   # порты и столицы колоний на побережье
		var c := ctrl[p]
		if c < 0:
			continue
		var home: bool
		if has_comp:
			home = not (dhome[c] < 0 or comp[p] != dhome[c])   # = not Depots.overseas
		else:
			if hl[c] == null:
				hl[c] = home_land(world, c)
			home = hl[c][p] == 1
		if not home and dmask[p] == 1:
			over[c].append(p)   # конвои снабжения — только в пункты снабжения (Depots)
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				zl[c][zb[q]] = true
				if home:
					zh[c][zb[q]] = true
	# поставки по покупателю: продавцы (по порядку договоров)
	var sellers: Array = []
	sellers.resize(nc)
	for x in nc:
		sellers[x] = {}
	for c in world.contracts:
		sellers[int(c[0])][int(c[1])] = float(sellers[int(c[0])].get(int(c[1]), 0.0)) + float(c[3])
	# соседи по суше — транзит через их порты
	var transit: Array = []
	transit.resize(nc)
	for x in nc:
		transit[x] = {}
	for key in world.trade_mass:
		var x: int = int(key) % nc
		for k2 in world.trade_mass[key]:
			transit[x][int(k2) % nc] = true
	# связные части графа «материк × страна» по живым странам — для стран без
	# войн путь по суше = их часть (граф симметричен: соседство провинций)
	Prof.add("кв:подготовка", _t0)
	_t0 = Time.get_ticks_usec()
	var cc := _mass_components(world)
	for b in nc:
		var bn: World.Nation = world.nations[b]
		bn.conv_routes = []
		bn.conv_safe = {}
		bn.conv_zone_set = {}
		bn.conv_basins = {}
		bn.conv_trade_need = 0.0
		if not bn.alive:
			continue
		var sl: Dictionary = sellers[b]
		if sl.is_empty() and over[b].is_empty():
			continue
		var by_land := _by_land_cc(world, b, cc) if _no_war(world, b) else _by_land(world, b)
		var src: Array = zh[b].keys() if not zh[b].is_empty() else zl[b].keys()
		if src.is_empty():
			continue
		var open = null
		if open_by.has(b):
			# бассейн открыт, если открыта хоть одна его зона
			open = {}
			for z in open_by[b]:
				open[zb[z]] = true
		var links := _strait_links(world, b)
		var par := _bfs(world, src, open, links)
		var par_all: Array = []
		var ks: Array = sl.keys()
		ks.sort()
		for s in ks:
			if by_land[s] == 1:
				continue
			var tz: Array = zl[s].keys()
			if tz.is_empty():
				for y in transit[s]:
					tz.append_array(zl[y].keys())
			var route := _route(par, tz)
			if route.is_empty() and open != null:
				if par_all.is_empty():
					par_all = _bfs(world, src, null, links)
				route = _route(par_all, tz)
			if route.is_empty():
				continue
			var need: float = float(sl[s]) * (PER_UNIT + PER_BASIN * float(route.size()))
			bn.conv_routes.append([0, s, route, need])
			bn.conv_trade_need += need
		for p in over[b]:
			var tz: Array = []
			for k in range(a_start[p], a_start[p + 1]):
				if land[a_list[k]] == 0 and not tz.has(zb[a_list[k]]):
					tz.append(zb[a_list[k]])
			var route := _route(par, tz)
			if route.is_empty() and open == null:
				if links[1].is_empty() or _route(_bfs(world, src, null, [links[0], {}]), tz).is_empty():
					continue   # до порта не дойти (нет общей воды) — порт сам по себе
				# иначе путь закрыт проливом — порт отрезан
			bn.conv_routes.append([1, p, route, 0.0])   # пустой путь — порт отрезан блокадой
		# зоны бассейнов путей — для рейдеров противника и своих охотников
		for rt in bn.conv_routes:
			for bi in rt[2]:
				bn.conv_basins[bi] = true
		var bks: Array = bn.conv_basins.keys()
		bks.sort()
		var bset := _basin_sets(world)
		for bi in bks:
			bn.conv_zone_set.merge(bset[bi])   # = зоны бассейна по порядку, без повторов
	Prof.add("кв:пути", _t0)


## Пути конвоев в ядре C++ (MeowqCore.conv_routes): снимок в плоские массивы,
## итог — conv_routes, conv_trade_need, conv_basins, conv_zone_set стран.
static func _routes_native(world: World, open_by: Dictionary, sellers: Array) -> void:
	var nc := world.nation_count
	var nb := world.basin_name.size()
	var zb := world.z_basin
	var n_do := PackedByteArray()
	n_do.resize(nc)
	var start_key := PackedInt32Array()
	start_key.resize(nc)
	var sel_s := PackedInt32Array([0])
	var sel_l := PackedInt32Array()
	var op_has := PackedByteArray()
	op_has.resize(nc)
	var op_s := PackedInt32Array([0])
	var op_l := PackedInt32Array()
	var dhome := PackedInt32Array()
	dhome.resize(nc)
	# проливы: только связывающие разные бассейны; закрыты ли — по странам
	# (держатели пролива — один раз на пролив)
	var st_a := PackedInt32Array()
	var st_b := PackedInt32Array()
	var st_t := PackedInt32Array()
	var st_hold: Array = []
	for st in world.straits:
		var a: int = zb[int(st[0])]
		var b2: int = zb[int(st[1])]
		if a < 0 or b2 < 0 or a == b2:
			continue
		st_a.append(a)
		st_b.append(b2)
		st_t.append(int(st[2]))
		st_hold.append(strait_holders(world, st))
	var nst := st_hold.size()
	var st_closed := PackedByteArray()
	st_closed.resize(nc * nst)
	var war := world.war
	# открытые зоны — плоско из ядра блокады, если словари не заполнены
	var ob_flat: Array = Economy._ob_flat if is_same(Economy._ob_for, open_by) else []
	var ob_i := PackedInt32Array()
	if not ob_flat.is_empty():
		ob_i.resize(nc)
		var ob_n: PackedInt32Array = ob_flat[0]
		for i in ob_n.size():
			ob_i[ob_n[i]] = i
	for b in nc:
		var bn: World.Nation = world.nations[b]
		bn.conv_routes = []
		bn.conv_safe = {}
		bn.conv_zone_set = {}
		bn.conv_basins = {}
		bn.conv_trade_need = 0.0
		dhome[b] = bn.dep_home
		if bn.alive:
			n_do[b] = 1
			var hmb := home_mass(world, b)
			start_key[b] = hmb * nc + b if hmb >= 0 else -1
			for i in nst:
				for h in st_hold[i]:   # = strait_closed(world, st, b)
					if war[h * nc + b] == 1:
						st_closed[b * nst + i] = 1
						break
			if not ob_flat.is_empty():
				if (ob_flat[3] as PackedByteArray)[b] == 1:
					op_has[b] = 1
					var i := ob_i[b]
					op_l.append_array((ob_flat[2] as PackedInt32Array).slice((ob_flat[1] as PackedInt32Array)[i], (ob_flat[1] as PackedInt32Array)[i + 1]))
			elif open_by.has(b):
				op_has[b] = 1
				op_l.append_array(PackedInt32Array(open_by[b].keys()))
			var ks: Array = sellers[b].keys()
			ks.sort()
			sel_l.append_array(PackedInt32Array(ks))
		else:
			start_key[b] = -1
		op_s.append(op_l.size())
		sel_s.append(sel_l.size())
	var mf := Economy.mass_flat(world)
	var tm_keys: PackedInt32Array = mf[0]
	var tm_start: PackedInt32Array = mf[1]
	var tm_list: PackedInt32Array = mf[2]
	var t := {"nc": nc, "nb": nb, "bas_start": world.bas_adj_start, "bas_list": world.bas_adj_list,
		"adj_start": world.adj_start, "adj_list": world.adj_list, "zb": zb, "land": world.p_land, "war": war,
		"n_alive": n_do, "n_do": n_do, "op_has": op_has, "st_a": st_a, "st_b": st_b, "st_t": st_t,
		"st_closed": st_closed, "sel_s": sel_s, "sel_l": sel_l, "op_s": op_s, "op_l": op_l,
		"start_key": start_key, "tm_keys": tm_keys, "tm_start": tm_start, "tm_list": tm_list,
		"points": Depots.sea_points(world), "ctrl": world.p_controller, "comp": world.p_comp, "dhome": dhome,
		"dmask": Depots.mask(world)}
	var _tk := Time.get_ticks_usec()
	var r: Array = Native.core.call("conv_routes", t)
	Prof.add("кв:ядро", _tk)
	var r_nat: PackedInt32Array = r[0]
	var r_kind: PackedInt32Array = r[1]
	var r_tgt: PackedInt32Array = r[2]
	var r_start: PackedInt32Array = r[3]
	var r_list: PackedInt32Array = r[4]
	for i in r_nat.size():
		var b := r_nat[i]
		var bn: World.Nation = world.nations[b]
		var route := r_list.slice(r_start[i], r_start[i + 1])
		if r_kind[i] == 0:
			var s2 := r_tgt[i]
			var need: float = float(sellers[b][s2]) * (PER_UNIT + PER_BASIN * float(route.size()))
			bn.conv_routes.append([0, s2, route, need])
			bn.conv_trade_need += need
		else:
			bn.conv_routes.append([1, r_tgt[i], route, 0.0])
	# зоны бассейнов путей — для рейдеров противника и своих охотников
	for bn: World.Nation in world.nations:
		if bn.conv_routes.is_empty():
			continue
		for rt in bn.conv_routes:
			for bi in rt[2]:
				bn.conv_basins[bi] = true
		var bks: Array = bn.conv_basins.keys()
		bks.sort()
		var bset := _basin_sets(world)
		for bi in bks:
			bn.conv_zone_set.merge(bset[bi])   # = зоны бассейна по порядку, без повторов


## Узел графа World.trade_mass → номер связной части (по живым странам) и
## страны каждой части: [{узел: часть}, [PackedByteArray по странам]].
static func _mass_components(world: World) -> Array:
	var nc := world.nation_count
	var alive := PackedByteArray()
	alive.resize(nc)
	for nat in world.nations:
		alive[nat.id] = 1 if nat.alive else 0
	var tm := world.trade_mass
	var comp := {}
	var members: Array = []
	var keys: Array = tm.keys()
	keys.sort()
	for k0 in keys:
		var s0: int = k0
		if comp.has(s0) or alive[s0 % nc] == 0:
			continue
		var ci := members.size()
		var mem := PackedByteArray()
		mem.resize(nc)
		comp[s0] = ci
		mem[s0 % nc] = 1
		var q := PackedInt32Array([s0])
		var h := 0
		while h < q.size():
			var key := q[h]
			h += 1
			var nb: PackedInt32Array = tm.get(key, PackedInt32Array())
			for k2 in nb:
				if comp.has(k2) or alive[k2 % nc] == 0:
					continue
				comp[k2] = ci
				mem[k2 % nc] = 1
				q.append(k2)
		members.append(mem)
	return [comp, members]


## Страна ни с кем не воюет (строка матрицы войн пуста).
static func _no_war(world: World, b: int) -> bool:
	var nc := world.nation_count
	var war := world.war
	for y in nc:
		if war[b * nc + y] == 1:
			return false
	return true


## _by_land для страны без войн: страны её связной части графа.
static func _by_land_cc(world: World, b: int, cc: Array) -> PackedByteArray:
	var nc := world.nation_count
	var hmb := home_mass(world, b)
	if hmb >= 0:
		var ci = cc[0].get(hmb * nc + b)
		if ci != null:
			var res: PackedByteArray = cc[1][int(ci)].duplicate()
			res[b] = 1
			return res
	var res0 := PackedByteArray()
	res0.resize(nc)
	res0[b] = 1
	return res0


## Страны, до которых путь по суше (материк столицы, через невоюющих с b).
static func _by_land(world: World, b: int) -> PackedByteArray:
	var nc := world.nation_count
	var res := PackedByteArray()
	res.resize(nc)
	res[b] = 1
	var hmb := home_mass(world, b)
	if hmb < 0:
		return res
	var start := hmb * nc + b
	var seen := {start: true}
	var q := PackedInt32Array([start])
	var h := 0
	var war := world.war
	var tm := world.trade_mass
	var base := b * nc
	var alive := PackedByteArray()
	alive.resize(nc)
	for nat in world.nations:
		alive[nat.id] = 1 if nat.alive else 0
	while h < q.size():
		var key := q[h]
		h += 1
		var nb: PackedInt32Array = tm.get(key, PackedInt32Array())
		for k2 in nb:
			var y := k2 % nc
			if seen.has(k2) or war[base + y] == 1 or alive[y] == 0:
				continue
			seen[k2] = true
			res[y] = 1
			q.append(k2)
	return res


## Обход бассейнов от src через открытые (open == null — все): предок
## (−1 — не достигнут, сам себе — исток) и длина пути в бассейнах (от 1).
static func _bfs(world: World, src: Array, open, links: Array = []) -> Array:
	var nb := world.basin_name.size()
	var par := PackedInt32Array()
	par.resize(nb)
	par.fill(-1)
	var dist := PackedInt32Array()
	dist.resize(nb)
	var a_start := world.bas_adj_start
	var a_list := world.bas_adj_list
	var q := PackedInt32Array()
	var ss := src.duplicate()
	ss.sort()
	for z in ss:
		if open == null or open.has(z):
			par[z] = z
			dist[z] = 1
			q.append(z)
	var h := 0
	var extra: Dictionary = links[0] if not links.is_empty() else {}
	var cut: Dictionary = links[1] if not links.is_empty() else {}
	var has_open := open != null
	var has_cut := not cut.is_empty()
	var has_extra := not extra.is_empty()
	while h < q.size():
		var z := q[h]
		h += 1
		# соседи по карте бассейнов, потом связи проливов (тот же порядок)
		for k in range(a_start[z], a_start[z + 1]):
			var y := a_list[k]
			if par[y] >= 0 or (has_open and not open.has(y)) or (has_cut and cut.has(z * nb + y)):
				continue
			par[y] = z
			dist[y] = dist[z] + 1
			q.append(y)
		if has_extra and extra.has(z):
			for y in extra[z]:
				if par[y] >= 0 or (has_open and not open.has(y)) or (has_cut and cut.has(z * nb + y)):
					continue
				par[y] = z
				dist[y] = dist[z] + 1
				q.append(y)
	return [par, dist]


## Путь до ближайшего из целевых бассейнов (по длине, при равенстве — меньший номер).
static func _route(bfs: Array, targets: Array) -> PackedInt32Array:
	var par: PackedInt32Array = bfs[0]
	var dist: PackedInt32Array = bfs[1]
	var best := -1
	var best_len := 1 << 30
	for z in targets:
		if par[z] < 0:
			continue
		var l := dist[z]
		if l < best_len or (l == best_len and int(z) < best):
			best_len = l
			best = z
	var res := PackedInt32Array()
	if best < 0:
		return res
	res.resize(best_len)
	var x := best
	for i in range(best_len - 1, -1, -1):
		res[i] = x
		x = par[x]
	return res


## Перехват и охранение для пар (страна qn[i], бассейн qb[i]) сегодня:
## [перехват 0..1, охранение] (PackedFloat32Array — как прежний Vector2).
## Бассейны делят зоны без пересечений, а потери рейдеров в проходе стран
## меняют флоты только уже посчитанных бассейнов — поэтому всё сразу, до
## прохода, даёт то же, что расчёт по мере надобности (до бита).
## Силы флотов — по зонам (порядок World.zone_fleets), бассейны и опасность —
## ядро (C++ — MeowqCore.convoy_danger, двойник — _danger_gd).
static func _danger_all(world: World, qn: PackedInt32Array, qb: PackedInt32Array) -> Array:
	var t := _danger_t(world, qn, qb)
	if Native.core != null and Native.core.has_method("convoy_danger"):
		return Native.core.call("convoy_danger", t)
	return _danger_gd(t)


static func _danger_t(world: World, qn: PackedInt32Array, qb: PackedInt32Array) -> Dictionary:
	var pc := world.prov_count
	var zs := PackedInt32Array()
	zs.resize(pc)
	zs.fill(-1)
	var zn := PackedInt32Array()
	zn.resize(pc)
	var fo := PackedInt32Array()
	var fm := PackedByteArray()   # 0 — в порту, 1 — прочее, 2 — рейд
	var fc := PackedFloat64Array()
	var fe := PackedFloat64Array()
	var fr := PackedFloat64Array()
	var nb := world.bas_zone_start.size() - 1
	var want := PackedByteArray()   # бассейны из запросов — флоты только их зон
	want.resize(nb)
	for bi in qb:
		want[bi] = 1
	var zb := world.z_basin
	var nc := world.nation_count
	var b_done := PackedByteArray()   # бонусы охранения и рейдов страны — один раз
	b_done.resize(nc)
	var b_esc := PackedFloat64Array()
	b_esc.resize(nc)
	var b_raid := PackedFloat64Array()
	b_raid.resize(nc)
	var zf := world.zone_fleets
	for z in zf:
		var bz := zb[z]
		if bz < 0 or want[bz] == 0:
			continue
		var z0 := fo.size()
		zs[z] = z0
		for f in zf[z]:
			if not f.alive:
				continue
			var o: int = f.owner
			fo.append(o)
			if f.mission == "port":
				fm.append(0)
				fc.append(0.0)
				fe.append(0.0)
				fr.append(0.0)
				continue
			if b_done[o] == 0:
				var nat: World.Nation = world.nations[o]
				b_done[o] = 1
				b_esc[o] = 1.0 + nat.b("escort")
				b_raid[o] = 1.0 + nat.b("sub_raid")
			fc.append(Forces.combat_power(f))
			fe.append((f.asw * Forces.NAVY_ESCORT + (f.ships[Forces.SHIP_CR] + f.ships[Forces.SHIP_CV]) * 2.0) * b_esc[o])
			if f.mission == "raid":
				fm.append(2)
				fr.append(f.raid * b_raid[o])
			else:
				fm.append(1)
				fr.append(0.0)
		zn[z] = fo.size() - z0
	var t := {"nc": nc, "nb": nb, "war": world.war, "ally": world.ally,
		"bas_start": world.bas_zone_start, "bas_list": world.bas_zone_list, "zs": zs, "zn": zn,
		"f_owner": fo, "f_mode": fm, "f_cp": fc, "f_es": fe, "f_rd": fr, "qn": qn, "qb": qb,
		"k": PackedFloat64Array([ESCORT_K, INTERCEPT, INTERCEPT_MAX, BLOCK_SHARE, BLOCKADE_LOSS])}
	return t


## Двойник MeowqCore.convoy_danger: силы бассейна по хозяевам флотов (в порядке
## появления; флоты в порту — только хозяин) — рейды, охранение, боевая сила,
## есть ли надводный боевой флот не в рейдах; затем для страны — перехват
## (рейды против охранения, блокада при слабом господстве) и охранение.
static func _danger_gd(t: Dictionary) -> Array:
	var nc: int = t["nc"]
	var nb: int = t["nb"]
	var war: PackedByteArray = t["war"]
	var ally: PackedByteArray = t["ally"]
	var bs: PackedInt32Array = t["bas_start"]
	var bl: PackedInt32Array = t["bas_list"]
	var zs: PackedInt32Array = t["zs"]
	var zn: PackedInt32Array = t["zn"]
	var fo: PackedInt32Array = t["f_owner"]
	var fm: PackedByteArray = t["f_mode"]
	var fc: PackedFloat64Array = t["f_cp"]
	var fe: PackedFloat64Array = t["f_es"]
	var fr: PackedFloat64Array = t["f_rd"]
	var qn: PackedInt32Array = t["qn"]
	var qb: PackedInt32Array = t["qb"]
	var k: PackedFloat64Array = t["k"]
	var memo: Array = []
	memo.resize(nb)
	var out_ic := PackedFloat32Array()
	out_ic.resize(qn.size())
	var out_es := PackedFloat32Array()
	out_es.resize(qn.size())
	for q in qn.size():
		var n := qn[q]
		var bi := qb[q]
		if memo[bi] == null:
			var idx := {}
			var ow := PackedInt32Array()
			var rd := PackedFloat64Array()
			var es := PackedFloat64Array()
			var cp := PackedFloat64Array()
			var surf := PackedByteArray()
			for j in range(bs[bi], bs[bi + 1]):
				var z := bl[j]
				var z0 := zs[z]
				if z0 < 0:
					continue
				for x in range(z0, z0 + zn[z]):
					var o := fo[x]
					var i: int = idx.get(o, -1)
					if i < 0:
						i = ow.size()
						idx[o] = i
						ow.append(o)
						rd.append(0.0)
						es.append(0.0)
						cp.append(0.0)
						surf.append(0)
					var m := fm[x]
					if m == 0:
						continue
					cp[i] += fc[x]
					es[i] += fe[x]
					if m == 2:
						rd[i] += fr[x]
					elif fc[x] > 0.0:
						surf[i] = 1
			memo[bi] = [ow, rd, es, cp, surf]
		var bd: Array = memo[bi]
		var ow: PackedInt32Array = bd[0]
		if ow.is_empty():
			continue
		var rd: PackedFloat64Array = bd[1]
		var es: PackedFloat64Array = bd[2]
		var cp: PackedFloat64Array = bd[3]
		var surf: PackedByteArray = bd[4]
		var raid := 0.0
		var escort := 0.0
		var surface := false
		var mine := 0.0    # господство — как Forces.supremacy (флоты вне порта)
		var enemy := 0.0
		for i in ow.size():
			var o := ow[i]
			if war[n * nc + o] == 1:
				raid += rd[i]
				enemy += cp[i]
				if surf[i] == 1:
					surface = true
			elif o == n or ally[n * nc + o] == 1:
				escort += es[i]
				mine += cp[i]
		var ic := clampf((raid - escort * k[0]) * k[1], 0.0, k[2])
		if surface:
			var sup := 0.5 if mine + enemy <= 0.0 else mine / (mine + enemy)
			if sup < k[3]:
				ic = maxf(ic, k[4])
		out_ic[q] = ic
		out_es[q] = escort
	return [out_ic, out_es]


## День (фаза флота, вместо прежнего штрафа выпуска): нужда, перехват на
## путях, потери конвоев и рейдеров, доля импорта, подача портов. Быстрый путь:
## без опасных зон и с полной обеспеченностью — без обхода путей и поставок.
static func daily(world: World, rng: RandomNumberGenerator) -> void:
	var nc := world.nation_count
	var pc := world.prov_count
	if world.p_conv.size() != pc:
		world.p_conv.resize(pc)
		world.p_conv.fill(1.0)
	var _t0 := Time.get_ticks_usec()
	if world.day % 7 == 0 or world.day <= 1:
		_count_overseas(world)
	Prof.add("кв:за морем", _t0)
	_t0 = Time.get_ticks_usec()
	var month_start := world.day > 0 and world.month_of(world.day) != world.month_of(world.day - 1)
	var by_b: Array = []   # поставки покупателя по продавцам — только когда нужно
	var esc := {}          # (зона, страна) опасной зоны -> охранение
	var changed := false
	# опасность на путях воюющих стран — все пары (страна, бассейн) сразу
	var _td := Time.get_ticks_usec()
	var qn := PackedInt32Array()
	var qb := PackedInt32Array()
	for nat: World.Nation in world.nations:
		if nat.alive and not nat.conv_routes.is_empty() and not nat.at_war.is_empty():
			for bi in nat.conv_basins:
				qn.append(nat.id)
				qb.append(int(bi))
	var d_ic := PackedFloat32Array()
	var d_es := PackedFloat32Array()
	if not qn.is_empty():
		var dr := _danger_all(world, qn, qb)
		d_ic = dr[0]
		d_es = dr[1]
	var q := 0
	Prof.add("кв:опасность", _td)
	# подготовка по странам: опасные бассейны, обеспеченность; путь — ядро
	# (0 — без путей, 1 — всё доходит, 2 — потери: торговля и порты по путям)
	var mode := PackedByteArray()
	mode.resize(nc)
	var s_fill := PackedFloat64Array()
	s_fill.resize(nc)
	var t_fill := PackedFloat64Array()
	t_fill.resize(nc)
	var s_need := PackedFloat64Array()
	s_need.resize(nc)
	var q_ns := PackedInt32Array()
	q_ns.resize(nc + 1)
	var need_units := false
	for nat: World.Nation in world.nations:
		var n := nat.id
		q_ns[n] = q
		if month_start:
			nat.conv_sunk_last = nat.conv_sunk_month
			nat.conv_sunk_month = 0.0
		var had_lost := nat.trade_penalty > 0.0 or not nat.conv_danger.is_empty()
		nat.conv_danger = {}
		if not nat.alive or nat.conv_routes.is_empty():
			if had_lost:
				nat.res_lost.fill(0.0)
				changed = true
			nat.trade_penalty = 0.0
			nat.conv_trade = 1.0
			nat.conv_sup = 1.0
			continue
		var have := maxf(0.0, nat.convoys)
		var sup_need := nat.conv_sup_need
		var sup_fill := 1.0 if sup_need <= 0.0 else minf(1.0, have / sup_need)
		var left := maxf(0.0, have - sup_need - nat.conv_eq_use)   # снабжение, снаряжение складам (Depots), остаток — торговля
		var trade_fill := 1.0 if nat.conv_trade_need <= 0.0 else minf(1.0, left / nat.conv_trade_need)
		nat.conv_sup = sup_fill
		if not nat.at_war.is_empty():
			for bi in nat.conv_basins:
				var dx := d_ic[q]
				if dx > 0.0:
					nat.conv_danger[bi] = dx
					esc[bi * nc + n] = d_es[q]
				q += 1
		s_fill[n] = sup_fill
		t_fill[n] = trade_fill
		s_need[n] = sup_need
		if nat.conv_danger.is_empty() and trade_fill >= 1.0:
			# всё доходит: потерь нет, порты — по обеспеченности снабжения
			if had_lost:
				nat.res_lost.fill(0.0)
				changed = true
			nat.trade_penalty = 0.0
			nat.conv_trade = 1.0
			mode[n] = 1
		else:
			mode[n] = 2
			need_units = true
	q_ns[nc] = q
	var rf := _routes_flat(world)
	var r_ns: PackedInt32Array = rf[0]
	var r_kind: PackedByteArray = rf[1]
	var r_key: PackedInt32Array = rf[2]
	var units := PackedFloat32Array()   # по путям торговли: 6 ресурсов (поставки продавца)
	var u_has := PackedByteArray()
	if need_units:
		by_b = _units_by_buyer(world)
		var uf := _units_flat(world, by_b, rf)
		units = uf[0]
		u_has = uf[1]
	var t := {"nc": nc, "mode": mode, "s_fill": s_fill, "t_fill": t_fill, "s_need": s_need,
		"q_ns": q_ns, "qb": qb, "d_ic": d_ic, "nb": world.bas_zone_start.size() - 1,
		"r_ns": r_ns, "r_kind": r_kind, "r_key": r_key, "r_need": rf[3], "r_zs": rf[4], "r_z": rf[5],
		"units": units, "u_has": u_has, "vp": world.vp_ai(), "p_conv": world.p_conv, "sink": SINK}
	var res: Array
	if Native.core != null and Native.core.has_method("convoy_day"):
		res = Native.core.call("convoy_day", t)
		if not kernel_check.is_empty():
			# сверка ядра с двойником (tests/kernel_check.gd): [проверок, расхождений]
			kernel_check[0] += 1
			if var_to_bytes(res) != var_to_bytes(_day_gd(t)):
				kernel_check[1] += 1
	else:
		res = _day_gd(t)
	world.p_conv = res[0]
	var r_safe: PackedFloat64Array = res[1]
	var o_lost: PackedFloat32Array = res[2]
	var o_trade: PackedFloat64Array = res[3]
	var o_sunk: PackedFloat64Array = res[4]
	for nat: World.Nation in world.nations:
		var n := nat.id
		var m := mode[n]
		if m == 0:
			continue
		for i in range(r_ns[n], r_ns[n + 1]):
			if r_kind[i] == 1:
				nat.conv_safe[r_key[i]] = r_safe[i]
		if m == 1:
			continue
		var rl := nat.res_lost
		for r in RES_N:
			var v := o_lost[n * RES_N + r]
			if rl[r] != v:
				rl[r] = v
				changed = true
		nat.conv_trade = o_trade[n]
		nat.trade_penalty = 1.0 - nat.conv_trade
		var sunk := o_sunk[n]
		if sunk > 0.0:
			nat.convoys = maxf(0.0, nat.convoys - sunk)
			nat.conv_sunk += sunk
			nat.conv_sunk_month += sunk
		# охранение выбивает рейдеров на путях своих конвоев
		for bi in nat.conv_danger:
			var e: float = esc[bi * nc + n]
			if e <= 0.0:
				continue
			var raiders: Array = []
			for j in range(world.bas_zone_start[bi], world.bas_zone_start[bi + 1]):
				for f in world.zone_fleets.get(world.bas_zone_list[j], []):
					if f.alive and f.mission == "raid" and world.war[n * nc + f.owner] == 1:
						raiders.append(f)
			if not raiders.is_empty():
				Forces._take_losses(world, raiders, e * 0.01 * rng.randf_range(0.5, 1.5), rng, 1)
	Prof.add("кв:страны", _t0)
	_t0 = Time.get_ticks_usec()
	# порты, что больше не заморские (захвачены, путь пропал), — без ограничения
	# (раз в неделю: пути меняются только в день обхода)
	if world.day % 7 == 0:
		var keep := {}
		for nat: World.Nation in world.nations:
			for rt in nat.conv_routes:
				if int(rt[0]) == 1:
					keep[int(rt[1]) * nc + nat.id] = true
		for p in world.port_list:
			if world.p_conv[p] < 1.0:
				var c := world.p_controller[p]
				if c < 0 or not keep.has(p * nc + c):
					world.p_conv[p] = 1.0
	Prof.add("кв:порты", _t0)
	_t0 = Time.get_ticks_usec()
	if changed and not world.res_prov.is_empty():
		Economy._update_fill(world)
	Prof.add("кв:fill", _t0)


# сверка convoy_day с двойником (tests/kernel_check.gd задаёт [0, 0])
static var kernel_check: Array = []
# пути конвоев стран плоскими массивами: кэш, пока у всех стран те же массивы путей
static var _rf: Array = []
static var _rf_refs: Array = []
# поставки по путям торговли: кэш к тем же путям и тому же World.conv_units
static var _uf: Array = []
static var _uf_rf: Array = []
static var _uf_by: Array = []


## Пути стран (nat.conv_routes; меняются только при обходе — новым массивом):
## [начала путей стран (nc + 1), вид, ключ (продавец / порт), нужно конвоев,
## начала бассейнов путей, бассейны].
static func _routes_flat(world: World) -> Array:
	var ok := _rf_refs.size() == world.nations.size()
	if ok:
		for nat: World.Nation in world.nations:
			if not is_same(_rf_refs[nat.id], nat.conv_routes):
				ok = false
				break
	if ok:
		return _rf
	var nc := world.nation_count
	var r_ns := PackedInt32Array()
	r_ns.resize(nc + 1)
	var r_kind := PackedByteArray()
	var r_key := PackedInt32Array()
	var r_need := PackedFloat64Array()
	var r_zs := PackedInt32Array([0])
	var r_z := PackedInt32Array()
	var refs: Array = []
	refs.resize(world.nations.size())
	for nat: World.Nation in world.nations:
		r_ns[nat.id] = r_key.size()
		refs[nat.id] = nat.conv_routes
		for rt in nat.conv_routes:
			r_kind.append(int(rt[0]))
			r_key.append(int(rt[1]))
			r_need.append(float(rt[3]))
			r_z.append_array(rt[2])
			r_zs.append(r_z.size())
	r_ns[nc] = r_key.size()
	_rf = [r_ns, r_kind, r_key, r_need, r_zs, r_z]
	_rf_refs = refs
	return _rf


## Поставки покупателя по путям торговли (по RES_N на путь; нет договора — 0).
static func _units_flat(world: World, by_b: Array, rf: Array) -> Array:
	if is_same(_uf_rf, rf) and is_same(_uf_by, by_b):
		return _uf

	var r_ns: PackedInt32Array = rf[0]
	var r_kind: PackedByteArray = rf[1]
	var r_key: PackedInt32Array = rf[2]
	var nr := r_key.size()
	var units := PackedFloat32Array()
	units.resize(nr * RES_N)
	var u_has := PackedByteArray()
	u_has.resize(nr)
	for n in world.nation_count:
		if by_b[n] == null:
			continue
		var contracts: Dictionary = by_b[n]
		for i in range(r_ns[n], r_ns[n + 1]):
			if r_kind[i] != 0 or not contracts.has(r_key[i]):
				continue
			var u: PackedFloat32Array = contracts[r_key[i]]
			u_has[i] = 1
			for r in mini(RES_N, u.size()):
				units[i * RES_N + r] = u[r]
	_uf = [units, u_has]
	_uf_rf = rf
	_uf_by = by_b
	return _uf


## Двойник MeowqCore.convoy_day: пути стран за день. Всё доходит (вид 1) — порты
## по обеспеченности снабжения; с потерями (вид 2) — доля, что доходит по пути
## (перехват по опасным бассейнам), недошедший импорт, потопленные конвои
## (торговля и снабжение заморских портов по их величине).
## → [подача портов, доля пути (порты), недошедшее (nc × RES_N), доля импорта, потоплено].
static func _day_gd(t: Dictionary) -> Array:
	var nc: int = t["nc"]
	var nb: int = t["nb"]
	var mode: PackedByteArray = t["mode"]
	var s_fill: PackedFloat64Array = t["s_fill"]
	var t_fill: PackedFloat64Array = t["t_fill"]
	var s_need: PackedFloat64Array = t["s_need"]
	var q_ns: PackedInt32Array = t["q_ns"]
	var qb: PackedInt32Array = t["qb"]
	var d_ic: PackedFloat32Array = t["d_ic"]
	var r_ns: PackedInt32Array = t["r_ns"]
	var r_kind: PackedByteArray = t["r_kind"]
	var r_key: PackedInt32Array = t["r_key"]
	var r_need: PackedFloat64Array = t["r_need"]
	var r_zs: PackedInt32Array = t["r_zs"]
	var r_z: PackedInt32Array = t["r_z"]
	var units: PackedFloat32Array = t["units"]
	var u_has: PackedByteArray = t["u_has"]
	var vp: PackedInt32Array = t["vp"]
	var pconv: PackedFloat32Array = (t["p_conv"] as PackedFloat32Array).duplicate()
	var sink: float = t["sink"]
	var r_safe := PackedFloat64Array()
	r_safe.resize(r_key.size())
	var o_lost := PackedFloat32Array()
	o_lost.resize(nc * RES_N)
	var o_trade := PackedFloat64Array()
	o_trade.resize(nc)
	var o_sunk := PackedFloat64Array()
	o_sunk.resize(nc)
	var dz := PackedFloat64Array()   # перехват по бассейнам у текущей страны
	dz.resize(nb)
	for n in nc:
		var m := mode[n]
		if m == 0:
			continue
		var sup_fill := s_fill[n]
		if m == 1:
			for i in range(r_ns[n], r_ns[n + 1]):
				if r_kind[i] == 1:
					var cut := r_zs[i + 1] == r_zs[i]
					pconv[r_key[i]] = 0.0 if cut else sup_fill
					r_safe[i] = 0.0 if cut else 1.0
			continue
		var calm := true
		for q in range(q_ns[n], q_ns[n + 1]):
			var dx := d_ic[q]
			if dx > 0.0:
				dz[qb[q]] = dx
				calm = false
		var trade_fill := t_fill[n]
		var sup_need := s_need[n]
		var wsum := 0.0
		for i in range(r_ns[n], r_ns[n + 1]):
			if r_kind[i] == 1:
				wsum += 1.0 + float(vp[r_key[i]])
		var sunk := 0.0
		var sea_total := 0.0
		var lost_total := 0.0
		var lb := n * RES_N
		for i in range(r_ns[n], r_ns[n + 1]):
			var safe := 1.0
			if not calm:
				for j in range(r_zs[i], r_zs[i + 1]):
					safe *= 1.0 - dz[r_z[j]]
			if r_kind[i] == 0:
				var got := trade_fill * safe
				if u_has[i] == 1:
					for r in RES_N:
						var u := units[i * RES_N + r]
						o_lost[lb + r] += u * (1.0 - got)
						sea_total += u
						lost_total += u * (1.0 - got)
				sunk += r_need[i] * trade_fill * (1.0 - safe) * sink
			else:
				var p := r_key[i]
				if r_zs[i + 1] == r_zs[i]:
					pconv[p] = 0.0
					r_safe[i] = 0.0
					continue
				pconv[p] = sup_fill * safe
				r_safe[i] = safe
				var share := (1.0 + float(vp[p])) / maxf(1.0, wsum)
				sunk += sup_need * share * sup_fill * (1.0 - safe) * sink
		o_trade[n] = 1.0 if sea_total <= 0.0 else 1.0 - lost_total / sea_total
		o_sunk[n] = sunk
		for q in range(q_ns[n], q_ns[n + 1]):
			dz[qb[q]] = 0.0
	return [pconv, r_safe, o_lost, o_trade, o_sunk]


## Поставки по покупателю: продавец -> единиц по ресурсам. Кэш в мире,
## пересборка — когда меняются договоры (подпись: число и взвешенная сумма).
static func _units_by_buyer(world: World) -> Array:
	var sig: float
	if Native.core != null and Native.core.has_method("contracts_sig"):
		sig = Native.core.call("contracts_sig", world.contracts)   # C++ — MeowqCore.contracts_sig
	else:
		sig = contracts_sig_gd(world.contracts)
	if world.conv_units_sig == sig and world.conv_units.size() == world.nation_count:
		return world.conv_units
	var by_b: Array = []
	by_b.resize(world.nation_count)
	for c in world.contracts:
		var b: int = c[0]
		if by_b[b] == null:
			by_b[b] = {}
		var d: Dictionary = by_b[b]
		var s: int = c[1]
		if not d.has(s):
			d[s] = PackedFloat32Array([0, 0, 0, 0, 0, 0])
		var arr: PackedFloat32Array = d[s]
		arr[int(c[2])] += float(c[3])
		d[s] = arr
	world.conv_units = by_b
	world.conv_units_sig = sig
	return by_b


## Подпись договоров (двойник MeowqCore.contracts_sig): число и взвешенная сумма.
static func contracts_sig_gd(contracts: Array) -> float:
	var sig := float(contracts.size())
	var k := 0
	for c in contracts:
		k += 1
		sig += float(c[3]) * float(k) + float(int(c[0]) * 7919 + int(c[1]) * 31 + int(c[2])) * 1.0e-3 * float(k)
	return sig


## Дивизии за морем (вне земли метрополии) → нужда в конвоях снабжения.
static func _count_overseas(world: World) -> void:
	var nc := world.nation_count
	var cnt := PackedInt32Array()
	cnt.resize(nc)
	var hl: Array = []   # земля метрополии (home_land) — по мере надобности
	hl.resize(nc)
	var alive := world.d_alive
	var prov := world.d_prov
	var owner := world.d_owner
	var land := world.p_land
	var capn := PackedInt32Array()
	capn.resize(nc)
	var home := PackedInt32Array()
	home.resize(nc)
	for nat in world.nations:
		capn[nat.id] = nat.capital
		home[nat.id] = nat.dep_home
	var comp := world.p_comp
	var has_comp := comp.size() == world.prov_count
	for i in alive.size():
		if alive[i] == 0:
			continue
		var o := owner[i]
		var p := prov[i]
		if o < 0 or p < 0 or land[p] == 0 or capn[o] < 0:
			continue
		var far: bool
		if has_comp:
			far = home[o] < 0 or comp[p] != home[o]   # = Depots.overseas
		else:
			if hl[o] == null:
				hl[o] = home_land(world, o)
			far = hl[o][p] == 0
		if far:
			cnt[o] += 1
	for nat in world.nations:
		nat.conv_sup_need = PER_DIV * float(cnt[nat.id])


## Постройка из очков судостроения (раньше кораблей — Forces.daily_navy): по
## нужде (с запасом) и заказ игрока.
static func build(world: World) -> void:
	for nat: World.Nation in world.nations:
		if not nat.alive:
			continue
		var want := float(nat.conv_order)
		if nat.conv_auto:
			var target := (nat.conv_trade_need + nat.conv_sup_need + nat.conv_eq_need) * RESERVE
			if target > 0.0:
				target += RESERVE_MIN
			want += maxf(0.0, ceilf(target - nat.convoys))
		if want <= 0.0:
			continue
		var cost := COST / (1.0 + maxf(0.0, nat.b("shipyard")))
		var k := mini(BUILD_MAX, mini(int(want), int(nat.stock[Military.EQ_SHIP] / cost)))
		if k <= 0:
			# без своих верфей — фрахт: понемногу, до нужды (не больше DEFAULT_MAX)
			if nat.daily_output[Military.EQ_SHIP] <= 0.0:
				var cap := minf(DEFAULT_MAX, nat.conv_trade_need + nat.conv_sup_need)
				if nat.convoys < cap:
					nat.convoys = minf(cap, nat.convoys + CHARTER)
			continue
		nat.stock[Military.EQ_SHIP] -= cost * k
		nat.convoys += k
		nat.conv_order = maxi(0, nat.conv_order - k)


## Зоны путей конвоев страны (для рейдеров противника), иначе — у её портов.
static func target_zones(world: World, n: int) -> Dictionary:
	var nat: World.Nation = world.nations[n]
	if not nat.conv_zone_set.is_empty():
		return nat.conv_zone_set
	return Forces.trade_zones(world, n)
