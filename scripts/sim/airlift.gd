class_name Airlift
extends RefCounted
## Транспортная авиация (решение пользователя, ноябрь 2026): гражданские и
## транспортные самолёты возят снабжение по воздуху туда, куда нет пути по
## суше, — в отрезанные участки (котлы, раскол страны) и за море.
##  * Парк страны — число самолётов (Nation.air_trans), как конвои. Начальный —
##    гражданская авиация (START_PER_CIV на гражданский завод); пополнение —
##    переделка двухмоторных машин из резерва бомбардировщиков (Ju 52 был и
##    бомбардировщиком, и транспортом): ИИ — по нужде, игрок — сам или по нужде.
##  * Нужда — недостача снабжения дивизий на участках не метрополии в пределах
##    RANGE_KM от пункта снабжения метрополии: PER_DIV самолётов закрывают
##    дивизию полностью. Груз — из запаса страны (Depots.SUP_EQ на дивизию в
##    день). Самолётов меньше нужды — каждый участок получает поровну долю.
##  * Чужое господство в воздухе над участком (World.air_sup < 0,5): доставка
##    падает до половины, самолёты гибнут (LOSS в день при полном господстве).
## Работает после раскладки снабжения по дивизиям (Simulation._phase_supply),
## в главном потоке; общая для ядер GDScript и C++.

const START_PER_CIV := 3.0     # гражданская авиация на старте: самолётов на гражданский завод
const PER_DIV := 25.0          # самолётов на полное снабжение одной дивизии
const RANGE_KM := 1200.0       # дальность от пункта снабжения метрополии
const LOSS := 0.03             # доля самолётов, что теряется в день при полном чужом господстве
const BUILD_MAX := 5.0         # переделка из резерва бомбардировщиков: самолётов в день
const RESERVE := 1.2           # ИИ держит парк с запасом к нужде
const EARTH_KM := 111.0        # км в градусе


## День: нужда, доставка, потери, пополнение парка.
static func daily(world: World) -> void:
	var nc := world.nation_count
	var pc := world.prov_count
	if world.p_comp.size() != pc or world.d_sup.size() != world.d_alive.size():
		return
	var comp := world.p_comp
	var alive := world.d_alive
	var dprov := world.d_prov
	var downer := world.d_owner
	var sup := world.d_sup
	# дивизии с недостачей на участках не метрополии: страна * pc + участок -> [слоты]
	var pockets := {}
	for i in alive.size():
		if alive[i] == 0 or dprov[i] < 0 or sup[i] >= 0.999:
			continue
		var o := downer[i]
		var c := comp[dprov[i]]
		if c < 0 or c == world.nations[o].dep_home:
			continue
		var key := o * pc + c
		if not pockets.has(key):
			pockets[key] = []
		pockets[key].append(i)
	var by_nat := {}   # страна -> [ключи участков]
	var keys: Array = pockets.keys()
	keys.sort()
	for key in keys:
		var o: int = key / pc
		if not by_nat.has(o):
			by_nat[o] = []
		by_nat[o].append(key)
	for nat: World.Nation in world.nations:
		if not nat.alive:
			continue
		if nat.air_trans < 0.0:
			nat.air_trans = START_PER_CIV * float(nat.civ)
		nat.air_trans_need = 0.0
		nat.air_trans_use = 0.0
		if by_nat.has(nat.id):
			_deliver(world, nat, by_nat[nat.id], pockets)
		_build(nat)


static func _deliver(world: World, nat: World.Nation, keys: Array, pockets: Dictionary) -> void:
	var nc := world.nation_count
	var bases := _home_depots(world, nat)
	if bases.is_empty():
		return
	# участки в пределах дальности: недостача (в дивизиях) и опасность в воздухе
	var plan: Array = []   # [слоты, недостача, опасность]
	var need := 0.0
	for key in keys:
		var slots: Array = pockets[key]
		var reach := false
		for i in slots:
			if _in_range(world, bases, world.d_prov[i]):
				reach = true
				break
		if not reach:
			continue
		var gap := 0.0
		var danger := 0.0
		for i in slots:
			gap += 1.0 - world.d_sup[i]
			var r := world.p_region[world.d_prov[i]]
			if world.air_sup.size() == world.region_count * nc and r >= 0:
				danger = maxf(danger, clampf((0.5 - world.air_sup[r * nc + nat.id]) * 2.0, 0.0, 1.0))
		plan.append([slots, gap, danger])
		need += gap * PER_DIV
	nat.air_trans_need = need
	if need <= 0.0 or nat.air_trans < 1.0:
		return
	var a := minf(1.0, nat.air_trans / need)
	nat.air_trans_use = need * a
	# груз — из запаса страны (по суше до аэродромов метрополии)
	var have := 0.0
	for k in Military.EQ_LAND:
		have += nat.stock[k] * float(Military.EQ_COST[k])
	var lost := 0.0
	for pl in plan:
		var slots: Array = pl[0]
		var gap: float = pl[1]
		var danger: float = pl[2]
		var eff := a * (1.0 - 0.5 * danger)
		var want := gap * eff * Depots.SUP_EQ
		var got := minf(want, have)
		if got <= 0.0:
			continue
		var f := got / want
		have -= got
		var stf := got / maxf(1e-9, have + got)
		for k in Military.EQ_LAND:
			nat.stock[k] -= nat.stock[k] * stf
		for i in slots:
			world.d_sup[i] = minf(1.0, world.d_sup[i] + (1.0 - world.d_sup[i]) * eff * f)
		lost += gap * PER_DIV * a * danger * LOSS
	if lost > 0.0:
		nat.air_trans = maxf(0.0, nat.air_trans - lost)
		nat.air_trans_lost += lost


## Пункты снабжения метрополии страны (аэродромы вылета).
static func _home_depots(world: World, nat: World.Nation) -> Array:
	var res: Array = []
	if nat.dep_home < 0:
		return res
	var comp := world.p_comp
	var ctrl := world.p_controller
	for p in world.prov_count:
		if ctrl[p] == nat.id and comp[p] == nat.dep_home and (world.p_vp[p] >= Depots.DEPOT_VP or p == nat.capital):
			res.append(world.p_lonlat[p])
	return res


static func _in_range(world: World, bases: Array, p: int) -> bool:
	var ll: Vector2 = world.p_lonlat[p]
	var kx := cos(deg_to_rad(ll.y))
	var lim := RANGE_KM / EARTH_KM
	for b: Vector2 in bases:
		var dx := (b.x - ll.x) * kx
		var dy := b.y - ll.y
		if dx * dx + dy * dy <= lim * lim:
			return true
	return false


## Пополнение парка: переделка резерва бомбардировщиков (ИИ — до нужды с
## запасом; игрок — по нужде, если включено, и сверх — по заказу).
static func _build(nat: World.Nation) -> void:
	var want := float(nat.air_order)
	if nat.air_auto or not nat.is_player:
		want += maxf(0.0, ceilf(nat.air_trans_need * RESERVE - nat.air_trans))
	if want <= 0.0:
		return
	var k := minf(BUILD_MAX, minf(want, floorf(nat.stock[Military.EQ_BOMB])))
	if k <= 0.0:
		return
	nat.stock[Military.EQ_BOMB] -= k
	nat.air_trans += k
	nat.air_order = maxi(0, nat.air_order - int(k))
