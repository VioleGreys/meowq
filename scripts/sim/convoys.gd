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
	for p in Depots.sea_points(world):   # порты и столицы колоний на побережье
		var c := ctrl[p]
		if c < 0:
			continue
		var home: bool
		if world.p_comp.size() == world.prov_count:
			home = not Depots.overseas(world, c, p)
		else:
			if hl[c] == null:
				hl[c] = home_land(world, c)
			home = hl[c][p] == 1
		if not home and Depots.is_depot(world, p):
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
	Prof.add("кв:подготовка", _t0)
	_t0 = Time.get_ticks_usec()
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
		var by_land := _by_land(world, b)
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
		for bi in bks:
			for j in range(world.bas_zone_start[bi], world.bas_zone_start[bi + 1]):
				bn.conv_zone_set[world.bas_zone_list[j]] = true
	Prof.add("кв:пути", _t0)


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
	while h < q.size():
		var key := q[h]
		h += 1
		var nb: PackedInt32Array = world.trade_mass.get(key, PackedInt32Array())
		for k2 in nb:
			var y := k2 % nc
			if seen.has(k2) or world.war[b * nc + y] == 1 or not world.nations[y].alive:
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
	while h < q.size():
		var z := q[h]
		h += 1
		var nbs: Array = []
		for k in range(a_start[z], a_start[z + 1]):
			nbs.append(a_list[k])
		if extra.has(z):
			nbs.append_array(extra[z])
		for y in nbs:
			if par[y] >= 0:
				continue
			if open != null and not open.has(y):
				continue
			if not cut.is_empty() and cut.has(z * nb + y):
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


## Силы бассейна на сегодня (один раз за день на бассейн), по хозяевам флотов
## (в порядке появления): рейды (с бонусом), охранение (с бонусом) и боевая
## сила вне порта, есть ли надводный боевой флот вне порта не в рейдах.
static func _basin_data(world: World, bi: int, memo: Dictionary) -> Array:
	var bd = memo.get(bi)
	if bd != null:
		return bd
	var idx := {}
	var ow := PackedInt32Array()
	var rd := PackedFloat64Array()
	var es := PackedFloat64Array()
	var cp := PackedFloat64Array()
	var surf := PackedByteArray()
	var zf := world.zone_fleets
	for j in range(world.bas_zone_start[bi], world.bas_zone_start[bi + 1]):
		var z := world.bas_zone_list[j]
		if not zf.has(z):
			continue
		for f in zf[z]:
			if not f.alive:
				continue
			var o: int = f.owner
			var i: int = idx.get(o, -1)
			if i < 0:
				i = ow.size()
				idx[o] = i
				ow.append(o)
				rd.append(0.0)
				es.append(0.0)
				cp.append(0.0)
				surf.append(0)
			if f.mission == "port":
				continue
			var nat: World.Nation = world.nations[o]
			var c := Forces.combat_power(f)
			cp[i] += c
			es[i] += (f.asw * Forces.NAVY_ESCORT + (f.ships[Forces.SHIP_CR] + f.ships[Forces.SHIP_CV]) * 2.0) * (1.0 + nat.b("escort"))
			if f.mission == "raid":
				rd[i] += f.raid * (1.0 + nat.b("sub_raid"))
			elif c > 0.0:
				surf[i] = 1
	bd = [ow, rd, es, cp, surf]
	memo[bi] = bd
	return bd


## Перехват в бассейне для страны n сегодня (x, 0..1) и охранение (y — для
## потерь рейдеров): рейды, охранение и господство — по всем его зонам.
static func danger(world: World, n: int, bi: int, memo: Dictionary) -> Vector2:
	var bd := _basin_data(world, bi, memo)
	var ow: PackedInt32Array = bd[0]
	if ow.is_empty():
		return Vector2.ZERO
	var rd: PackedFloat64Array = bd[1]
	var es: PackedFloat64Array = bd[2]
	var cp: PackedFloat64Array = bd[3]
	var surf: PackedByteArray = bd[4]
	var nc := world.nation_count
	var war := world.war
	var ally := world.ally
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
	var ic := clampf((raid - escort * ESCORT_K) * INTERCEPT, 0.0, INTERCEPT_MAX)
	if surface:
		var sup := 0.5 if mine + enemy <= 0.0 else mine / (mine + enemy)
		if sup < BLOCK_SHARE:
			ic = maxf(ic, BLOCKADE_LOSS)
	return Vector2(ic, escort)


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
	var memo := {}         # флоты зон на сегодня
	var esc := {}          # (зона, страна) опасной зоны -> охранение
	var changed := false
	for nat: World.Nation in world.nations:
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
		var n := nat.id
		var have := maxf(0.0, nat.convoys)
		var sup_need := nat.conv_sup_need
		var sup_fill := 1.0 if sup_need <= 0.0 else minf(1.0, have / sup_need)
		var left := maxf(0.0, have - sup_need - nat.conv_eq_use)   # снабжение, снаряжение складам (Depots), остаток — торговля
		var trade_fill := 1.0 if nat.conv_trade_need <= 0.0 else minf(1.0, left / nat.conv_trade_need)
		nat.conv_sup = sup_fill
		var war := not nat.at_war.is_empty()
		if war:
			var _td := Time.get_ticks_usec()
			for bi in nat.conv_basins:
				var dz := danger(world, n, bi, memo)
				if dz.x > 0.0:
					nat.conv_danger[bi] = dz.x
					esc[bi * nc + n] = dz.y
			Prof.add("кв:опасность", _td)
		var calm := nat.conv_danger.is_empty()
		if calm and trade_fill >= 1.0:
			# всё доходит: потерь нет, порты — по обеспеченности снабжения
			if had_lost:
				nat.res_lost.fill(0.0)
				changed = true
			nat.trade_penalty = 0.0
			nat.conv_trade = 1.0
			for rt in nat.conv_routes:
				if int(rt[0]) == 1:
					var pp := int(rt[1])
					var cut := (rt[2] as PackedInt32Array).is_empty()
					world.p_conv[pp] = 0.0 if cut else sup_fill
					nat.conv_safe[pp] = 0.0 if cut else 1.0
			continue
		if by_b.is_empty():
			by_b = _units_by_buyer(world)
		var old_lost := nat.res_lost.duplicate()
		nat.res_lost.fill(0.0)
		# заморские порты: вес по величине — доля конвоев снабжения на путь
		var wsum := 0.0
		for rt in nat.conv_routes:
			if int(rt[0]) == 1:
				wsum += 1.0 + float(world.vp_ai()[int(rt[1])])
		var sunk := 0.0
		var sea_total := 0.0
		var lost_total := 0.0
		var contracts: Dictionary = by_b[n] if by_b[n] != null else {}
		for rt in nat.conv_routes:
			var route: PackedInt32Array = rt[2]
			var safe := 1.0
			if not calm:
				for z in route:
					safe *= 1.0 - float(nat.conv_danger.get(z, 0.0))
			if int(rt[0]) == 0:
				var units: PackedFloat32Array = contracts.get(int(rt[1]), PackedFloat32Array())
				var got := trade_fill * safe
				for r in units.size():
					nat.res_lost[r] += units[r] * (1.0 - got)
					sea_total += units[r]
					lost_total += units[r] * (1.0 - got)
				sunk += float(rt[3]) * trade_fill * (1.0 - safe) * SINK
			else:
				var p: int = rt[1]
				if route.is_empty():
					world.p_conv[p] = 0.0
					nat.conv_safe[p] = 0.0
					continue
				world.p_conv[p] = sup_fill * safe
				nat.conv_safe[p] = safe
				var share := (1.0 + float(world.vp_ai()[p])) / maxf(1.0, wsum)
				sunk += sup_need * share * sup_fill * (1.0 - safe) * SINK
		nat.conv_trade = 1.0 if sea_total <= 0.0 else 1.0 - lost_total / sea_total
		nat.trade_penalty = 1.0 - nat.conv_trade
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
		if old_lost != nat.res_lost:
			changed = true
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


## Поставки по покупателю: продавец -> единиц по ресурсам. Кэш в мире,
## пересборка — когда меняются договоры (подпись: число и взвешенная сумма).
static func _units_by_buyer(world: World) -> Array:
	var sig := float(world.contracts.size())
	var k := 0
	for c in world.contracts:
		k += 1
		sig += float(c[3]) * float(k) + float(int(c[0]) * 7919 + int(c[1]) * 31 + int(c[2])) * 1.0e-3 * float(k)
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
	for i in alive.size():
		if alive[i] == 0:
			continue
		var o := owner[i]
		var p := prov[i]
		if o < 0 or p < 0 or land[p] == 0 or world.nations[o].capital < 0:
			continue
		var far: bool
		if world.p_comp.size() == world.prov_count:
			far = Depots.overseas(world, o, p)
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
