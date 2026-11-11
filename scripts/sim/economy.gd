class_name Economy
extends RefCounted
## Внешняя экономика: природные ресурсы провинций, их расход заводами (по
## тому, ЧТО завод выпускает), экономический курс (доля добычи на экспорт) и
## торговля поставками на месяц.
## Всё — в главном потоке, в фазе экономики (Simulation), порядок обхода
## постоянный — результат детерминирован.

const RES_COUNT := 6
const R_OIL := 0
const R_STEEL := 1
const R_ALU := 2
const R_RUBBER := 3
const R_TUNGSTEN := 4
const R_CHROME := 5
const RES_NAMES := ["Нефть", "Сталь", "Алюминий", "Каучук", "Вольфрам", "Хром"]
const RES_SHORT := ["Нефть", "Сталь", "Алюм.", "Кауч.", "Вольф.", "Хром"]

## Расход ресурсов одним заводом линии в день по типу снаряжения (Military.EQ_*):
## [нефть, сталь, алюминий, каучук, вольфрам, хром]. Стрелковое оружие — только
## сталь; артиллерия — сталь и вольфрам; танки — сталь, хром, нефть; грузовики —
## сталь, каучук, нефть; корабли — сталь и хром; самолёты — алюминий, каучук, нефть.
const RES_NEED := [
	[0.0, 0.35, 0.0, 0.0, 0.0, 0.0],
	[0.0, 0.6, 0.0, 0.0, 0.25, 0.0],
	[0.35, 0.7, 0.0, 0.0, 0.0, 0.35],
	[0.3, 0.3, 0.0, 0.3, 0.0, 0.0],
	[0.0, 0.7, 0.0, 0.0, 0.0, 0.25],
	[0.3, 0.0, 0.8, 0.25, 0.0, 0.0],
	[0.4, 0.0, 1.0, 0.3, 0.0, 0.0],
]
## Без ресурсов линия всё равно что-то выпускает (запасы, заменители, лом).
const SHORT_FLOOR := 0.3

## Экономический курс (как торговые законы жанра, значения свои): доля
## добычи, которую страна предлагает на экспорт, и бонусы открытости.
const LAWS := [
	{"name": "Закрытая экономика", "export": 0.0, "bonus": {}},
	{"name": "Ограниченный экспорт", "export": 0.25, "bonus": {"research": 0.02}},
	{"name": "Ориентация на экспорт", "export": 0.5, "bonus": {"construction": 0.04, "research": 0.04}},
	{"name": "Свободная торговля", "export": 0.75, "bonus": {"construction": 0.08, "research": 0.08, "industry": 0.03}},
]
## Курс 1936 г. (остальные — ориентация на экспорт).
const START_LAW := {"GER": 1, "SOV": 1, "JAP": 1, "ITA": 1, "MAN": 1, "SPR": 1, "NSP": 1, "POR": 1,
	"USA": 3, "ENG": 3, "HOL": 3, "BEL": 3, "SWI": 3, "DEN": 3, "CAN": 3, "AST": 3, "NZL": 3, "SAF": 3, "RAJ": 3}
const LAW_COOLDOWN := 60     # дней между сменами курса
## Марионетки с закрытой торговлей — только со своим сюзереном (как было:
## экономика Маньчжоу-го под Японией, Словакия по договору о «защите» 1939 г.,
## Виши по условиям перемирия). Другим можно закрыть эффектом closed_trade
## или решением сюзерена-игрока.
const CLOSED_PUPPETS := {"MAN": true, "SLO": true, "VIC": true}

const CONTRACT_DAYS := 30    # поставка покупается на месяц
const SWEEP_DAYS := 14       # обход поставок (сроки, отказы) — раз в 2 недели
const UNITS_PER_CIV := 8.0   # единиц ресурса на один гражданский завод оплаты
const SELLER_SHARE := 0.5    # продавцу — половина оплаты (заводы на его стройку)
const AI_CIV_SHARE := 0.4    # ИИ тратит на закупки не больше этой доли гражданских заводов


## Загрузить ресурсы провинций (data/world1936/resources.json).
static func load_resources(world: World, path: String) -> void:
	world.res_prov = PackedInt32Array()
	world.res_val = PackedFloat32Array()
	if FileAccess.file_exists(path):
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var keys: Array = data["provinces"].keys()
		keys.sort_custom(func(a, b): return int(a) < int(b))
		for k in keys:
			var p := int(k)
			if p >= world.prov_count:
				continue
			world.res_prov.append(p)
			var row: Array = data["provinces"][k]
			for r in RES_COUNT:
				world.res_val.append(float(row[r]))
	for nat in world.nations:
		nat.trade_law = int(START_LAW.get(nat.tag, 2))
		nat.trade_closed = CLOSED_PUPPETS.has(nat.tag)
	refresh(world)


## Добыча стран по контролируемым провинциям и потребность их линий.
static func refresh(world: World) -> void:
	for nat in world.nations:
		nat.res_need.fill(0.0)
	var ctrl := world.p_controller
	_refresh_prod(world)
	for nat in world.nations:
		if not nat.alive:
			continue
		for line in nat.lines:
			var f := float(line[1])
			if f <= 0.0:
				continue
			var need: Array = RES_NEED[int(line[0])]
			for r in RES_COUNT:
				nat.res_need[r] += f * float(need[r])


## Добыча стран по контролируемым провинциям + синтетика.
static func _refresh_prod(world: World) -> void:
	for nat in world.nations:
		nat.res_prod.fill(0.0)
	var ctrl := world.p_controller
	world.res_ctrl.resize(world.res_prov.size())
	for i in world.res_prov.size():
		var c := ctrl[world.res_prov[i]]
		world.res_ctrl[i] = c
		if c < 0:
			continue
		var nat: World.Nation = world.nations[c]
		var mult := 1.0 + nat.b("resources")
		for r in RES_COUNT:
			nat.res_prod[r] += world.res_val[i * RES_COUNT + r] * mult
	# синтетика (заводы синтетического горючего и каучука — эффект synthetic)
	for nat in world.nations:
		if nat.alive:
			for r in RES_COUNT:
				nat.res_prod[r] += nat.res_synth[r]


## Сколько ресурса r у страны в распоряжении: добыча − продано + куплено.
static func available(nat: World.Nation, r: int) -> float:
	# морской импорт, не дошедший (нехватка конвоев, перехват на пути — Convoys)
	return nat.res_prod[r] - nat.res_out[r] + nat.res_in[r] - nat.res_lost[r]


## Сколько ресурса r страна ещё может продать (её курс минус уже проданное).
## Продают только излишек сверх своей нужды (как было в войну: стратегическое
## сырьё, нужное самим, не вывозили — кроме договоров, см. oblige).
## Союзнику по фракции и сюзерену ИИ-продавец отдаёт весь излишек, без
## ограничения курса (как ресурсы шли внутри Оси и союзников в войну);
## buyer = −1 — по курсу.
static func exportable(world: World, seller: World.Nation, r: int, buyer := -1) -> float:
	var ally := buyer >= 0 and is_ally(world, seller.id, buyer)
	return maxf(0.0, export_cap(seller, r, ally) - seller.res_out[r])


## Продаёт ли ИИ-страна s покупателю b излишек сверх курса: одна фракция или
## b — её сюзерен. Игрок-продавец всегда торгует по своему курсу.
static func is_ally(world: World, s: int, b: int) -> bool:
	var sn: World.Nation = world.nations[s]
	if sn.is_player or b < 0 or b == s:
		return false
	return sn.overlord == b or (sn.faction >= 0 and sn.faction == world.nations[b].faction)


## Сколько всего ресурса r страна готова продавать в день: доля курса, но не
## больше излишка.
static func export_cap(seller: World.Nation, r: int, ally := false) -> float:
	# закрытая марионетка отдаёт сюзерену весь излишек, независимо от курса;
	# союзнику ИИ отдаёт весь излишек (ally)
	var share: float = 1.0 if (ally or (seller.trade_closed and seller.overlord >= 0)) else float(LAWS[seller.trade_law]["export"])
	var cap: float = seller.res_prod[r] * share
	return minf(cap, maxf(0.0, seller.res_prod[r] - seller.res_need[r] * 1.1))


## Можно ли торговать: не враги, не в войне, репутация не ниже −30.
static func can_trade(world: World, buyer: int, seller: int) -> String:
	if buyer == seller:
		return "своя страна"
	if not world.nations[seller].alive:
		return "страны нет"
	if world.is_at_war(buyer, seller):
		return "война"
	if world.embargoes.has(seller * 100000 + buyer):
		return "эмбарго"
	if is_blocked(world, buyer, seller):
		return "блокада"
	var sn: World.Nation = world.nations[seller]
	if sn.trade_closed and sn.overlord >= 0 and sn.overlord != buyer:
		return "марионетка торгует только с сюзереном"
	if world.rep.size() == world.nation_count * world.nation_count \
			and world.rep[seller * world.nation_count + buyer] < -30.0:
		return "продавец не хочет торговать"
	return ""


## Отрезан ли путь от продавца к покупателю морской блокадой.
static func is_blocked(world: World, buyer: int, seller: int) -> bool:
	var nc := world.nation_count
	return world.trade_block.size() == nc * nc and world.trade_block[buyer * nc + seller] == 1


## Морская блокада (раз в SWEEP_DAYS, главный поток — читает флоты): у
## воюющей страны продавец доступен, если до него есть путь по суше через
## страны, не воюющие с ней (World.trade_adj), или по морю — от её портов до
## портов продавца через открытые для неё морские зоны. Зона открыта: если в
## ней есть боевые флоты противника — по местному господству (≥ BLOCK_SHARE,
## как у блокады портов); если нет — у своих и союзных берегов открыта, а в
## открытом море — по перевесу флотов в округе (≥ BLOCK_OPEN; флоты в пределах BLOCK_RANGE
## зон, вес BLOCK_FALL за зону, и в порту — «флот в наличии»): так сильный
## флот держит дальнюю блокаду, как Британия в обе войны.
## Мирные страны не блокируются.
const BLOCK_SHARE := 0.3   # местное господство в зоне с боевыми флотами (как у блокады портов)
const BLOCK_OPEN := 0.4    # перевес в округе, чтобы прорвать дальнюю блокаду
const BLOCK_RANGE := 5
const BLOCK_FALL := 0.7

## Возвращает открытые зоны воюющих стран (страна -> {зона: true}) — по ним
## идут пути конвоев (Convoys.refresh_routes); страны без записи — всё открыто.
static func refresh_blockade(world: World) -> Dictionary:
	var nc := world.nation_count
	world.trade_block = PackedByteArray()
	world.trade_block.resize(nc * nc)
	var open_by := {}
	if world.fleets.is_empty() or world.trade_adj.size() != nc * nc:
		return open_by
	var zf := world.zone_fleets
	if zf.is_empty():
		return open_by
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var ctrl := world.p_controller
	var _pb := Time.get_ticks_usec()
	# морские зоны у портов каждой страны
	var zones: Array = []
	zones.resize(nc)
	for x in nc:
		zones[x] = PackedInt32Array()
	var zl: Array = []
	zl.resize(nc)
	for x in nc:
		zl[x] = []
	for p in world.prov_count:
		var c := ctrl[p]
		if c < 0 or land[p] == 0 or not Forces.is_port(world, p):
			continue
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				zl[c].append(q)
	for x in nc:
		zones[x] = PackedInt32Array(zl[x])
	var war := world.war
	# соседи по суше (на одном материке) — для транзита через их порты
	var transit: Array = []
	transit.resize(nc)
	for x in nc:
		transit[x] = PackedInt32Array()
	var tl: Array = []
	tl.resize(nc)
	for x in nc:
		tl[x] = {}
	for key in world.trade_mass:
		var x: int = int(key) % nc
		for k2 in world.trade_mass[key]:
			tl[x][int(k2) % nc] = true
	for x in nc:
		var ks: Array = tl[x].keys()
		ks.sort()
		transit[x] = PackedInt32Array(ks)
	Prof.add("бл:порты", _pb)
	_pb = Time.get_ticks_usec()
	# у каждого флота — округа: зоны в пределах BLOCK_RANGE и вес силы в них
	var reach: Array = []
	for f in world.fleets:
		if not f.alive or f.owner < 0:
			continue
		var pw := Forces.combat_power(f)
		if pw <= 0.0:
			continue
		var zs := PackedInt32Array([f.zone])
		var ws := PackedFloat32Array([pw])
		var dist := {f.zone: 0}
		var hh := 0
		while hh < zs.size():
			var z := zs[hh]
			var dz: int = dist[z]
			hh += 1
			if dz >= BLOCK_RANGE:
				continue
			for k in range(a_start[z], a_start[z + 1]):
				var q := a_list[k]
				if land[q] == 0 and not dist.has(q):
					dist[q] = dz + 1
					zs.append(q)
					ws.append(pw * pow(BLOCK_FALL, dz + 1))
		reach.append([f.owner, zs, ws])
	Prof.add("бл:округа", _pb)
	_pb = Time.get_ticks_usec()
	for b in nc:
		var bn: World.Nation = world.nations[b]
		if not bn.alive or bn.at_war.is_empty():
			continue
		# флоты в округе: своя сторона (союзники) против врагов
		var own_r := PackedFloat32Array()
		var en_r := PackedFloat32Array()
		var any_enemy := false
		# пишем прямо в en_r / own_r: присваивание упакованного массива другой
		# переменной и запись в неё копирует его целиком (копирование при записи)
		for fr in reach:
			var o: int = fr[0]
			var zs: PackedInt32Array = fr[1]
			var ws: PackedFloat32Array = fr[2]
			if war[b * nc + o] == 1:
				if en_r.is_empty():
					en_r.resize(world.prov_count)
				any_enemy = true
				for i in zs.size():
					en_r[zs[i]] += ws[i]
			elif world.ally[b * nc + o] == 1 or o == b:
				if own_r.is_empty():
					own_r.resize(world.prov_count)
				for i in zs.size():
					own_r[zs[i]] += ws[i]
		if not any_enemy:
			continue
		if own_r.is_empty():
			own_r.resize(world.prov_count)
		# у своих и союзных берегов
		var near := {}
		for x in nc:
			if world.ally[b * nc + x] == 1 or x == b:
				for z in zones[x]:
					near[z] = true
		# по суше: страны на нашем материке (материк столицы), связанные с нами
		# через невоюющих с нами (узел — страна на материке, без морских звеньев)
		var by_land := PackedByteArray()
		by_land.resize(nc)
		by_land[b] = 1
		var h := 0
		if bn.capital >= 0 and world.p_mass.size() == world.prov_count and world.p_mass[bn.capital] >= 0:
			var start := world.p_mass[bn.capital] * nc + b
			var seen_n := {start: true}
			var qn := PackedInt32Array([start])
			while h < qn.size():
				var key := qn[h]
				h += 1
				var nb: PackedInt32Array = world.trade_mass.get(key, PackedInt32Array())
				for k2 in nb:
					var y := k2 % nc
					if seen_n.has(k2) or war[b * nc + y] == 1 or not world.nations[y].alive:
						continue
					seen_n[k2] = true
					by_land[y] = 1
					qn.append(k2)
		h = 0
		# по морю: зоны, достижимые от наших портов без господства противника
		var seen := {}
		var open := {}
		var qz := PackedInt32Array()
		for z in zones[b]:
			if not seen.has(z):
				seen[z] = true
				if _zone_open(world, b, z, zf, near, own_r, en_r):
					open[z] = true
					qz.append(z)
		while h < qz.size():
			var z := qz[h]
			h += 1
			for k in range(a_start[z], a_start[z + 1]):
				var q := a_list[k]
				if land[q] != 0 or seen.has(q):
					continue
				seen[q] = true
				if _zone_open(world, b, q, zf, near, own_r, en_r):
					open[q] = true
					qz.append(q)
		open_by[b] = open
		for s in nc:
			if s == b or by_land[s] == 1 or war[b * nc + s] == 1 or not world.nations[s].alive:
				continue
			var ok := false
			for z in zones[s]:
				if open.has(z):
					ok = true
					break
			if not ok:
				# транзит через порты невоюющего с нами соседа по суше
				for y in transit[s]:
					if war[b * nc + y] == 1 or not world.nations[y].alive:
						continue
					for z in zones[y]:
						if open.has(z):
							ok = true
							break
					if ok:
						break
			if not ok:
				world.trade_block[b * nc + s] = 1
	Prof.add("бл:страны", _pb)
	return open_by


static func _zone_open(world: World, b: int, z: int, zf: Dictionary, near: Dictionary,
		own_r: PackedFloat32Array, en_r: PackedFloat32Array) -> bool:
	var fl: Array = zf.get(z, [])
	var nc := world.nation_count
	for f in fl:
		if f.alive and f.mission != "port" and world.war[b * nc + f.owner] == 1:
			return Forces.supremacy(world, b, z) >= BLOCK_SHARE
	if near.has(z) or en_r[z] <= 0.0:
		return true
	return own_r[z] / (own_r[z] + en_r[z]) >= BLOCK_OPEN


## Купить units ресурса r у продавца на месяц (сверх уже купленного; только
## из свободной экспортной доли). Возвращает false, если нельзя.
static func buy(world: World, buyer: int, seller: int, r: int, units: float, log := false) -> bool:
	units = snappedf(units, 0.1)
	if units < 0.1 or can_trade(world, buyer, seller) != "":
		return false
	var sn: World.Nation = world.nations[seller]
	if exportable(world, sn, r, buyer) + 0.001 < units:
		return false
	var bn: World.Nation = world.nations[buyer]
	var c := _find(world, buyer, seller, r)
	if not c.is_empty():
		c[3] = float(c[3]) + units
		if float(c[6]) >= 0.0:
			c[6] = float(c[6]) + units   # отказ/урезка на следующий месяц отменяется на эту часть
	else:
		# [покупатель, продавец, ресурс, ед. в день, оплачено до, договор до (0 — нет), со следующего месяца (−1 — как есть)]
		world.contracts.append([buyer, seller, r, units, world.day + CONTRACT_DAYS, 0, -1.0])
	_add(bn, sn, r, units)
	if log:
		world.log_event("Поставка: %s → %s, %s +%.1f в день" % [sn.name, bn.name, RES_NAMES[r].to_lower(), units])
	return true


## Отказаться от поставки (покупатель): она идёт и оплачивается до конца
## оплаченного месяца, потом снимается.
static func cancel(world: World, idx: int) -> void:
	if idx >= 0 and idx < world.contracts.size() and int(world.contracts[idx][5]) <= world.day:
		world.contracts[idx][6] = 0.0


## Учесть прибавку поставки у покупателя и продавца (без полного пересчёта).
static func _add(bn: World.Nation, sn: World.Nation, r: int, u: float) -> void:
	bn.res_in[r] += u
	sn.res_out[r] += u
	bn.trade_civ += u / UNITS_PER_CIV
	sn.trade_civ_in += u / UNITS_PER_CIV * SELLER_SHARE


## Пересчитать купленное/проданное и оплату у всех стран.
static func _recount(world: World) -> void:
	for nat in world.nations:
		nat.res_in.fill(0.0)
		nat.res_out.fill(0.0)
		nat.trade_civ = 0.0
		nat.trade_civ_in = 0.0
	for c in world.contracts:
		var u := float(c[3])
		var bn: World.Nation = world.nations[c[0]]
		var sn: World.Nation = world.nations[c[1]]
		bn.res_in[c[2]] += u
		sn.res_out[c[2]] += u
		bn.trade_civ += u / UNITS_PER_CIV
		sn.trade_civ_in += u / UNITS_PER_CIV * SELLER_SHARE


## Насколько линия обеспечена ресурсами (0..1) и множитель выпуска.
static func line_mult(nat: World.Nation, eq: int) -> float:
	var need: Array = RES_NEED[eq]
	var fill := 1.0
	for r in RES_COUNT:
		if float(need[r]) > 0.0:
			fill = minf(fill, nat.res_fill[r])
	return SHORT_FLOOR + (1.0 - SHORT_FLOOR) * fill


# --- Кому продавать: рейтинг покупателей у продавца (раз в месяц) ---------------

## Таблицы для рейтинга — снимок раз в месяц (World.trade_tab): только
## Packed-массивы, чтобы строки рейтинга считались в потоках.
static func trade_tables(world: World) -> Dictionary:
	var nc := world.nation_count
	var alive := PackedByteArray()
	alive.resize(nc)
	var cap := PackedVector2Array()
	cap.resize(nc)
	var ideo := PackedByteArray()
	ideo.resize(nc)
	var fac := PackedInt32Array()
	fac.resize(nc)
	var over := PackedInt32Array()
	over.resize(nc)
	var expw := PackedFloat32Array()
	expw.resize(nc)
	var fleetf := PackedFloat32Array()
	fleetf.resize(nc)
	var fleet := PackedFloat32Array()
	fleet.resize(nc)
	for f in world.fleets:
		if f.alive and f.owner >= 0 and f.owner < nc:
			fleet[f.owner] += Forces.fleet_power(f)
	var pact := PackedByteArray()
	pact.resize(nc * nc)
	var bonus := PackedFloat32Array()
	bonus.resize(nc * nc)
	for x in nc:
		var nx: World.Nation = world.nations[x]
		alive[x] = 1 if nx.alive and nx.capital >= 0 else 0
		if nx.capital >= 0:
			cap[x] = world.p_center[nx.capital]
		ideo[x] = Relations.IDEO.find(nx.ideology) + 1
		fac[x] = nx.faction
		over[x] = nx.overlord
		expw[x] = Relations.export_weight(nx)
		fleetf[x] = 1.0 + fleet[x] / (fleet[x] + 100.0)
		for y in nx.pacts:
			pact[x * nc + int(y)] = 1
			pact[int(y) * nc + x] = 1
		for y in nx.guarantees:
			pact[x * nc + int(y)] = 1
			pact[int(y) * nc + x] = 1
	for k in world.trade_bonus:
		var a := int(k) / 100000
		var b := int(k) % 100000
		if a < nc and b < nc:
			bonus[a * nc + b] = float(world.trade_bonus[k])
	return {"n": nc, "alive": alive, "cap": cap, "ideo": ideo, "fac": fac, "over": over,
		"expw": expw, "fleetf": fleetf, "pact": pact, "bonus": bonus,
		"adj": world.trade_adj, "coast": world.trade_coast}


## Строка рейтинга продавца s (читает только снимок t — можно в потоке):
##  экономическое влияние покупателя на продавца (его доля в торговле продавца,
##  как Relations.trade_influence) × близость столиц × расположение (сосед ×1,3;
##  через море без выхода к морю ×0,5) × враждебность (репутация продавца к
##  покупателю, строй-враг ×0,5; война и репутация ниже −30 — 0) × союз (одна
##  фракция ×2, пакт или гарантия ×1,3) × марионетка (сюзерен ×3, своя ×1,5).
static func rank_row(t: Dictionary, s: int) -> PackedFloat32Array:
	var nc: int = t["n"]
	var alive: PackedByteArray = t["alive"]
	var cap: PackedVector2Array = t["cap"]
	var ideo: PackedByteArray = t["ideo"]
	var fac: PackedInt32Array = t["fac"]
	var over: PackedInt32Array = t["over"]
	var expw: PackedFloat32Array = t["expw"]
	var fleetf: PackedFloat32Array = t["fleetf"]
	var pact: PackedByteArray = t["pact"]
	var bonus: PackedFloat32Array = t["bonus"]
	var adj: PackedByteArray = t["adj"]
	var coast: PackedByteArray = t["coast"]
	var war: PackedByteArray = t["war"]
	var rep: PackedFloat32Array = t["rep"]
	var rn: int = t["rep_n"]
	var emb: PackedByteArray = t["emb"]
	var closed: PackedByteArray = t["closed"]
	var block: PackedByteArray = t["block"]
	var has_block := block.size() == nc * nc
	var row := PackedFloat32Array()
	row.resize(nc)
	if alive[s] == 0:
		return row
	var ps := cap[s]
	# влияние: вес каждого экспортёра для продавца, потом доля
	var w := PackedFloat32Array()
	w.resize(nc)
	var total := 0.0
	for x in nc:
		if x == s or alive[x] == 0 or war[x * nc + s] == 1:
			continue
		var d := ps.distance_to(cap[x]) / 150.0
		var rp := rep[s * rn + x] if s < rn and x < rn else 50.0
		var v := expw[x] * fleetf[x] * (0.5 + rp / 100.0) / (1.0 + d * d)
		w[x] = v
		total += v
	for b in nc:
		if b == s or alive[b] == 0 or war[b * nc + s] == 1:
			continue
		if (closed[s] == 1 and over[s] != b) or emb[s * nc + b] == 1:
			continue   # марионетка торгует только с сюзереном; эмбарго
		if has_block and block[b * nc + s] == 1:
			continue   # путь отрезан морской блокадой
		var rp := rep[s * rn + b] if s < rn and b < rn else 50.0
		if rp < -30.0:
			continue
		var infl := clampf((100.0 * w[b] / total if total > 0.0 else 0.0) + bonus[b * nc + s], 0.0, 100.0)
		var v := 1.0 + infl / 10.0
		v /= 1.0 + cap[b].distance_to(ps) / 300.0
		if adj[s * nc + b] == 1:
			v *= 1.3
		elif coast[b] == 0 or coast[s] == 0:
			v *= 0.5
		v *= clampf(0.5 + rp / 100.0, 0.1, 1.5)
		if (ideo[s] == 3 and ideo[b] == 4) or (ideo[s] == 4 and ideo[b] == 3):
			v *= 0.5
		if fac[s] >= 0 and fac[s] == fac[b]:
			v *= 2.0
		elif pact[s * nc + b] == 1:
			v *= 1.3
		if over[s] == b:
			v *= 3.0
		elif over[b] == s:
			v *= 1.5
		row[b] = v
	return row


## Соседство стран (N×N) и выход к морю — одним проходом по провинциям;
## пересчитывается раз в CONTRACT_DAYS дней (World.trade_adj/trade_coast).
static func refresh_geo(world: World) -> void:
	var nc := world.nation_count
	if world.p_mass.size() != world.prov_count:
		_build_mass(world)
	var mass := world.p_mass
	var edges := {}
	world.trade_adj = PackedByteArray()
	world.trade_adj.resize(nc * nc)
	world.trade_coast = PackedByteArray()
	world.trade_coast.resize(nc)
	var ctrl := world.p_controller
	for p in world.prov_count:
		var c := ctrl[p]
		if c < 0 or world.p_land[p] == 0:
			continue
		if world.p_coastal[p] == 1:
			world.trade_coast[c] = 1
		for k in range(world.adj_start[p], world.adj_start[p + 1]):
			var q := world.adj_list[k]
			var d := ctrl[q]
			if d >= 0 and d != c and world.p_land[q] == 1:
				world.trade_adj[c * nc + d] = 1
				var ka := mass[p] * nc + c
				var kb := mass[p] * nc + d
				if not edges.has(ka):
					edges[ka] = {}
				edges[ka][kb] = true
	world.trade_mass = {}
	for k in edges:
		world.trade_mass[k] = PackedInt32Array(edges[k].keys())
	world.trade_geo_day = world.day


## Материки — связные куски суши (с проливами, как в графе соседства).
static func _build_mass(world: World) -> void:
	var n := world.prov_count
	world.p_mass = PackedInt32Array()
	world.p_mass.resize(n)
	world.p_mass.fill(-1)
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var m := 0
	for p0 in n:
		if land[p0] == 0 or world.p_mass[p0] >= 0:
			continue
		world.p_mass[p0] = m
		var q := PackedInt32Array([p0])
		var h := 0
		while h < q.size():
			var p := q[h]
			h += 1
			for k in range(a_start[p], a_start[p + 1]):
				var r := a_list[k]
				if land[r] == 1 and world.p_mass[r] < 0:
					world.p_mass[r] = m
					q.append(r)
		m += 1


## Раз в месяц продавец раздаёт экспортную долю по рейтингу: заявка покупателя —
## его нехватка плюс то, что он уже берёт у этого продавца. Прибавка — сразу,
## урезка — со следующего оплаченного месяца.
## План раздачи экспорта продавца s (i — его номер в снимке): по строке
## рейтинга row; читает только снимок t — считается в потоке вместе с
## рейтингом. Заявка покупателя — его нехватка (у ИИ и у игрока с
## автозакупками) плюс то, что он уже берёт у этого продавца. Возвращает
## [покупатель, ресурс, сколько дать].
static func plan_sales(t: Dictionary, i: int, s: int, row: PackedFloat32Array) -> Array:
	var nc: int = t["n"]
	var need: PackedFloat32Array = t["need"]
	var avail: PackedFloat32Array = t["avail"]
	var prod: PackedFloat32Array = t["prod"]
	var out: PackedFloat32Array = t["out"]
	var share: PackedFloat32Array = t["share"]
	var auto: PackedByteArray = t["auto"]
	var oblig: PackedFloat32Array = t["oblig"]
	var fac: PackedInt32Array = t["fac"]
	var over: PackedInt32Array = t["over"]
	var player: PackedByteArray = t["player"]
	var cur_all: Array = t["cur"]
	var c3_all: Array = t["c3"]
	var cur: PackedFloat32Array = cur_all[i]
	var c3: PackedFloat32Array = c3_all[i]
	var plan: Array = []
	# союзникам (фракция, сюзерен) ИИ-продавец отдаёт весь излишек сверх курса
	var allies := player[s] == 0 and (fac[s] >= 0 or over[s] >= 0)
	if share[s] <= 0.0 and not allies:
		return plan
	for r in RES_COUNT:
		var surplus: float = maxf(0.0, prod[s * RES_COUNT + r] - need[s * RES_COUNT + r] * 1.1)
		var cap: float = minf(prod[s * RES_COUNT + r] * share[s], surplus)
		cap = maxf(0.0, cap - oblig[s * RES_COUNT + r])   # договорные поставки — вне доли
		var cap_ally: float = maxf(0.0, surplus - oblig[s * RES_COUNT + r]) if allies else cap
		if cap_ally < 0.1 and out[s * RES_COUNT + r] <= 0.0:
			continue
		var order: Array = []
		for b in nc:
			var sc: float = row[b]
			if sc <= 0.0:
				continue
			var k := b * RES_COUNT + r
			var want: float = cur[k]
			if auto[b] == 1:
				want += maxf(0.0, need[k] * 1.05 - avail[k])
			if want >= 0.1:
				order.append([sc, b, want])
		order.sort_custom(func(x, y): return x[0] > y[0] or (x[0] == y[0] and x[1] < y[1]))
		for o in order:
			var b: int = o[1]
			var ally := allies and (over[s] == b or (fac[s] >= 0 and fac[s] == fac[b]))
			var give := snappedf(minf(float(o[2]), cap_ally if ally else cap), 0.1)
			# урезанная поставка дослуживает месяц и занимает свою часть доли
			var used := maxf(give, c3[b * RES_COUNT + r])
			cap = maxf(0.0, cap - used)
			cap_ally = maxf(0.0, cap_ally - used)
			plan.append([b, r, give])
	return plan


## Применить план раздачи продавца s (главный поток, по порядку). index —
## все поставки: продавец*100000 + покупатель*8 + ресурс → поставка.
static func apply_sales(world: World, s: int, plan: Array, index: Dictionary) -> void:
	var sn: World.Nation = world.nations[s]
	for p in plan:
		var b: int = p[0]
		var r: int = p[1]
		var give: float = p[2]
		var c: Array = index.get(s * 100000 + b * 8 + r, [])
		if not c.is_empty() and int(c[5]) > world.day:
			continue   # договорная поставка — не трогаем
		if c.is_empty():
			if give >= 0.1 and can_trade(world, b, s) == "" and _budget(world, b) >= give / UNITS_PER_CIV:
				var nc_: Array = [b, s, r, give, world.day + CONTRACT_DAYS, 0, -1.0]
				world.contracts.append(nc_)
				index[s * 100000 + b * 8 + r] = nc_
				_add(world.nations[b], sn, r, give)
		elif give < float(c[3]):
			c[6] = give      # урезка — со следующего месяца
		else:
			c[3] = give
			c[6] = -1.0


static func _find(world: World, b: int, s: int, r: int) -> Array:
	for c in world.contracts:
		if c[0] == b and c[1] == s and c[2] == r:
			return c
	return []


static func _budget(world: World, n: int) -> float:
	var nat: World.Nation = world.nations[n]
	if nat.is_player and not nat.trade_auto:
		return 0.0
	return float(nat.civ) * AI_CIV_SHARE - nat.trade_civ


## День внешней экономики: добыча и потребность, сроки поставок, рейтинг
## продавцов (у каждого раз в месяц, в свой день), докупки, обеспеченность.
## Вызывается до выпуска снаряжения.
static func daily(world: World) -> void:
	if world.res_prov.is_empty():
		return   # мир без ресурсов (процедурный) — заводы обеспечены всегда
	var nc := world.nation_count
	var first := world.trade_score.size() != nc * nc
	var dirty := false
	var open_by = null   # день обхода: открытые зоны для путей конвоев
	# раз в SWEEP_DAYS дней: добыча и потребность, обход поставок (истёкшие
	# продлеваются на месяц, отказ/урезка вступает в силу, поставки исчезнувших
	# и рассорившихся стран снимаются; война рвёт поставки сразу — on_war)
	if first or world.day % SWEEP_DAYS == 0:
		var _pt := Time.get_ticks_usec()
		refresh(world)
		Prof.add("вэ:refresh", _pt)
		_pt = Time.get_ticks_usec()
		open_by = refresh_blockade(world)
		Prof.add("вэ:блокада", _pt)
		dirty = true
		var keep: Array = []
		var cut := {}
		for c in world.contracts:
			if is_blocked(world, int(c[0]), int(c[1])):
				# морская блокада рвёт и договорные поставки
				cut[int(c[0])] = int(cut.get(int(c[0]), 0)) + 1
				continue
			if world.day >= int(c[4]):
				if can_trade(world, c[0], c[1]) != "":
					continue
				if float(c[6]) >= 0.0:
					c[3] = float(c[6])
					c[6] = -1.0
				if float(c[3]) < 0.05:
					continue
				while int(c[4]) <= world.day:
					c[4] = int(c[4]) + CONTRACT_DAYS
			keep.append(c)
		world.contracts = keep
		for b in cut:
			world.log_event("Морская блокада: %s теряет заморские поставки (%d)" % [world.nations[b].name, cut[b]])
		_recount(world)
	if world.trade_adj.size() != nc * nc or world.day - world.trade_geo_day >= CONTRACT_DAYS:
		var _pg := Time.get_ticks_usec()
		refresh_geo(world)
		world.trade_tab = trade_tables(world)
		Prof.add("вэ:гео", _pg)
	# раз в SWEEP_DAYS дней, пакетом: рейтинг покупателей и раздача экспорта
	# (продавцы), докупка недостающего и отказ от лишнего (покупатели)
	var due := _due(world, world.day, first)
	if not due.is_empty():
		dirty = true
		if first:
			world.trade_score.resize(nc * nc)
		# рейтинг и план раздачи: готовые со вчера (в фоне, по вчерашнему снимку —
		# start_rank) или, если их нет, сейчас — параллельно по продавцам
		var _pr := Time.get_ticks_usec()
		var rows: Array = []
		var plans: Array = []
		var job: Dictionary = world.trade_job
		if not first and not job.is_empty() and int(job["day"]) == world.day and job["due"] == due:
			Spec.finish(world)
			rows = job["rows"]
			plans = job["plans"]
		else:
			var t := _snapshot(world, due)
			rows.resize(due.size())
			plans.resize(due.size())
			Parallel.run(due.size(), func(i: int):
				var row := rank_row(t, due[i])
				rows[i] = row
				plans[i] = plan_sales(t, i, due[i], row), "торговля:рейтинг", 2)
		world.trade_job = {}
		Prof.add("вэ:рейтинг", _pr)
		_pr = Time.get_ticks_usec()
		var index := {}
		for c in world.contracts:
			index[int(c[1]) * 100000 + int(c[0]) * 8 + int(c[2])] = c
		for i in due.size():
			var row: PackedFloat32Array = rows[i]
			var s: int = due[i]
			for b in nc:
				world.trade_score[s * nc + b] = row[b]
			if world.nations[s].alive:
				apply_sales(world, s, plans[i], index)
		_recount(world)
		Prof.add("вэ:продажи", _pr)
		_pr = Time.get_ticks_usec()
		# покупатели этого дня: докупают из свободных остатков, отказываются от лишнего
		var free: Array = []   # продавцы со свободным остатком — собираются, когда понадобятся
		# договоры по покупателю (номера по возрастанию) — для отказа от лишнего
		var by_buyer := {}
		for k in world.contracts.size():
			var bk: int = world.contracts[k][0]
			if not by_buyer.has(bk):
				by_buyer[bk] = []
			by_buyer[bk].append(k)
		for x in due:
			var nat: World.Nation = world.nations[x]
			if not nat.alive or (nat.is_player and not nat.trade_auto):
				continue
			var n0 := world.contracts.size()
			_ai_buy(world, nat, free)
			var mine: Array = by_buyer.get(x, [])
			for k in range(n0, world.contracts.size()):
				mine.append(k)   # новые договоры — только этого покупателя
			_ai_cut(world, nat, mine)
		Prof.add("вэ:закупки", _pr)
	if open_by != null:
		# пути конвоев — по договорам после закупок этого дня
		var _pc := Time.get_ticks_usec()
		Convoys.refresh_routes(world, open_by)
		Prof.add("вэ:конвои", _pc)
	if dirty:
		var _pf := Time.get_ticks_usec()
		_update_fill(world)
		Prof.add("вэ:fill", _pf)


## Поставка по договору (эффект supply): seller отдаёт buyer units ресурса r в
## день days дней — даже если нужно самому; оплата как у обычной поставки.
static func oblige(world: World, seller: int, buyer: int, r: int, units: float, days: int) -> void:
	if can_trade(world, buyer, seller) != "" or world.res_prov.is_empty():
		return
	var c := _find(world, buyer, seller, r)
	if c.is_empty():
		c = [buyer, seller, r, 0.0, world.day + CONTRACT_DAYS, 0, -1.0]
		world.contracts.append(c)
	c[3] = float(c[3]) + units
	c[5] = maxi(int(c[5]), world.day + days)
	c[6] = -1.0
	_recount(world)
	_update_fill(world)
	world.log_event("Договор о поставках: %s → %s, %s %.0f в день" % [world.nations[seller].name, world.nations[buyer].name, RES_NAMES[r].to_lower(), units])


## Эмбарго (эффект embargo): seller больше не продаёт buyer, поставки рвутся.
static func embargo(world: World, seller: int, buyer: int) -> void:
	world.embargoes[seller * 100000 + buyer] = true
	var before := world.contracts.size()
	world.contracts = world.contracts.filter(func(c): return not (c[0] == buyer and c[1] == seller))
	if world.contracts.size() != before:
		_recount(world)
		_update_fill(world)
	world.log_event("Эмбарго: %s против страны %s" % [world.nations[seller].name, world.nations[buyer].name])


## Война между a и b: их взаимные поставки снимаются сразу.
static func on_war(world: World, a: int, b: int) -> void:
	var before := world.contracts.size()
	world.contracts = world.contracts.filter(func(c): return not ((c[0] == a and c[1] == b) or (c[0] == b and c[1] == a)))
	if world.contracts.size() != before:
		_recount(world)
		_update_fill(world)


## Кто торгует в этот день: все живые страны раз в SWEEP_DAYS дней (и в первый день).
static func _due(world: World, day: int, first: bool) -> PackedInt32Array:
	var due := PackedInt32Array()
	if first or day % SWEEP_DAYS == 0:
		for x in world.nation_count:
			if world.nations[x].alive:
				due.append(x)
	return due


## Снимок для строк рейтинга: месячные таблицы + война и репутация на сейчас (копии).
static func _snapshot(world: World, due: PackedInt32Array) -> Dictionary:
	var t: Dictionary = world.trade_tab.duplicate()
	t["war"] = world.war.duplicate()
	t["rep"] = world.rep.duplicate()
	t["rep_n"] = world.rep_n
	# для плана раздачи: нужда, наличие, добыча, продажи; курс, игрок, автозакупки
	var nc := world.nation_count
	var need := PackedFloat32Array()
	need.resize(nc * RES_COUNT)
	var avail := PackedFloat32Array()
	avail.resize(nc * RES_COUNT)
	var prod := PackedFloat32Array()
	prod.resize(nc * RES_COUNT)
	var out := PackedFloat32Array()
	out.resize(nc * RES_COUNT)
	var share := PackedFloat32Array()
	share.resize(nc)
	var player := PackedByteArray()
	player.resize(nc)
	var auto := PackedByteArray()
	auto.resize(nc)
	var closed := PackedByteArray()
	closed.resize(nc)
	for x in nc:
		var nx: World.Nation = world.nations[x]
		share[x] = (1.0 if (nx.trade_closed and nx.overlord >= 0) else float(LAWS[nx.trade_law]["export"])) if nx.alive else 0.0
		closed[x] = 1 if nx.trade_closed and nx.overlord >= 0 else 0
		player[x] = 1 if nx.is_player else 0
		auto[x] = 1 if nx.alive and (not nx.is_player or nx.trade_auto) else 0
		for r in RES_COUNT:
			need[x * RES_COUNT + r] = nx.res_need[r]
			avail[x * RES_COUNT + r] = available(nx, r)
			prod[x * RES_COUNT + r] = nx.res_prod[r]
			out[x * RES_COUNT + r] = nx.res_out[r]
	# поставки продавцов этого дня: сколько берут (с учётом урезки) и сколько идёт сейчас
	var idx := {}
	var cur_all: Array = []
	var c3_all: Array = []
	for i in due.size():
		idx[due[i]] = i
		var a := PackedFloat32Array()
		a.resize(nc * RES_COUNT)
		cur_all.append(a)
		var b := PackedFloat32Array()
		b.resize(nc * RES_COUNT)
		c3_all.append(b)
	var oblig := PackedFloat32Array()
	oblig.resize(nc * RES_COUNT)
	for c in world.contracts:
		if int(c[5]) > world.day:
			oblig[int(c[1]) * RES_COUNT + int(c[2])] += float(c[3])
			continue   # договорные — вне раздачи
		if idx.has(c[1]):
			var i: int = idx[c[1]]
			var k := int(c[0]) * RES_COUNT + int(c[2])
			var ca: PackedFloat32Array = cur_all[i]
			ca[k] = float(c[3]) if float(c[6]) < 0.0 else float(c[6])
			cur_all[i] = ca
			var cb: PackedFloat32Array = c3_all[i]
			cb[k] = float(c[3])
			c3_all[i] = cb
	t["need"] = need
	t["avail"] = avail
	t["prod"] = prod
	t["out"] = out
	t["share"] = share
	t["player"] = player
	t["auto"] = auto
	t["closed"] = closed
	t["oblig"] = oblig
	var emb := PackedByteArray()
	emb.resize(nc * nc)
	for k in world.embargoes:
		var a := int(k) / 100000
		var b := int(k) % 100000
		if a < nc and b < nc:
			emb[a * nc + b] = 1
	t["emb"] = emb
	t["block"] = world.trade_block.duplicate()
	t["cur"] = cur_all
	t["c3"] = c3_all
	return t


## Упреждение (Spec), на устаревших на день данных: в фазе ИИ — в фоне
## строки рейтинга продавцов завтрашнего дня (снимок — на этот момент дня, так
## что результат не зависит от потоков). Завтра Economy.daily берёт готовое;
## война, объявленная за это время, всё равно проверяется при раздаче (can_trade).
static func spec(world: World, jobs: Array) -> void:
	world.trade_job = {}
	var nc := world.nation_count
	if world.res_prov.is_empty() or world.trade_tab.is_empty() or world.trade_score.size() != nc * nc:
		return
	var due := _due(world, world.day + 1, false)
	if due.is_empty():
		return
	refresh(world)   # нужда и добыча — на сегодня, чтобы план не опирался на двухнедельные
	var t := _snapshot(world, due)
	var rows: Array = []
	rows.resize(due.size())
	var plans: Array = []
	plans.resize(due.size())
	for i in due.size():
		var ii := i
		jobs.append(func():
			var row := rank_row(t, due[ii])
			rows[ii] = row
			plans[ii] = plan_sales(t, ii, due[ii], row))
	world.trade_job = {"day": world.day + 1, "due": due, "rows": rows, "plans": plans}


static func _update_fill(world: World) -> void:
	for nat in world.nations:
		# на войне ИИ ограничивает экспорт (как в жанре)
		if not nat.is_player and nat.alive and not nat.at_war.is_empty() and nat.trade_law > 1:
			set_law(world, nat, 1)
		for r in RES_COUNT:
			var need: float = nat.res_need[r]
			nat.res_fill[r] = 1.0 if need <= 0.0 else clampf(available(nat, r) / need, 0.0, 1.0)


static func _ai_buy(world: World, nat: World.Nation, free: Array) -> void:
	var any := false
	for r in RES_COUNT:
		if nat.res_need[r] * 1.05 - available(nat, r) >= 0.3:
			any = true
			break
	if not any:
		return
	var nc := world.nation_count
	if free.is_empty():
		for r in RES_COUNT:
			var lst := PackedInt32Array()
			for x in nc:
				var xn: World.Nation = world.nations[x]
				# с запасом: союзникам продают и сверх курса (проверка ниже)
				if xn.alive and maxf(0.0, export_cap(xn, r, not xn.is_player) - xn.res_out[r]) >= 0.3:
					lst.append(x)
			free.append(lst)
	var budget := _budget(world, nat.id)
	for r in RES_COUNT:
		var lack: float = nat.res_need[r] * 1.05 - available(nat, r)
		if lack < 0.3 or budget <= 0.05:
			continue
		lack = minf(lack, budget * UNITS_PER_CIV)
		# сначала у тех продавцов, у кого мы выше в рейтинге; кто уже не может
		# продать (экспорт за время закупок только убывает) — дальше не смотрим
		var lst: PackedInt32Array = free[r]
		var dead := PackedByteArray()
		dead.resize(lst.size())
		while lack >= 0.3:
			var best := -1
			var best_score := 0.0
			for j in lst.size():
				if dead[j] == 1:
					continue
				var s := lst[j]
				var sc: float = world.trade_score[s * nc + nat.id]
				if sc <= best_score:
					if sc <= 0.0:
						dead[j] = 1
					continue
				if exportable(world, world.nations[s], r, nat.id) < 0.3:
					dead[j] = 1
					continue
				best_score = sc
				best = s
			if best < 0:
				break
			var take := minf(lack, exportable(world, world.nations[best], r, nat.id))
			if not buy(world, nat.id, best, r, take):
				break
			lack -= take
			budget -= take / UNITS_PER_CIV


## Раз в месяц: отказаться от лишних поставок (они идут до конца месяца).
## mine — номера договоров этого покупателя по возрастанию (обход — с конца).
static func _ai_cut(world: World, nat: World.Nation, mine: Array) -> void:
	for r in RES_COUNT:
		var extra: float = available(nat, r) - nat.res_need[r] * 1.15
		if extra <= 0.5:
			continue
		for j in range(mine.size() - 1, -1, -1):
			var c: Array = world.contracts[int(mine[j])]
			if c[0] == nat.id and c[2] == r and float(c[6]) < 0.0 and float(c[3]) <= extra and int(c[5]) <= world.day:
				c[6] = 0.0
				extra -= float(c[3])


## Сменить курс (игрок; ИИ — при вступлении в войну). Возвращает пусто или причину.
static func set_law(world: World, nat: World.Nation, law: int) -> String:
	if law == nat.trade_law:
		return ""
	if nat.law_day >= 0 and world.day - nat.law_day < LAW_COOLDOWN:
		return "курс можно менять раз в %d дней" % LAW_COOLDOWN
	nat.trade_law = law
	nat.law_day = world.day
	world.recalc_spirits(nat)
	# проданное сверх новой доли — поставки урезаются со следующего месяца
	var share: float = LAWS[law]["export"]
	for r in RES_COUNT:
		var over: float = nat.res_out[r] - nat.res_prod[r] * share
		for i in range(world.contracts.size() - 1, -1, -1):
			if over <= 0.0:
				break
			var c: Array = world.contracts[i]
			if c[1] == nat.id and c[2] == r and int(c[5]) <= world.day:
				var now := float(c[3]) if float(c[6]) < 0.0 else float(c[6])
				var cut := minf(over, now)
				c[6] = now - cut
				over -= cut
	return ""
