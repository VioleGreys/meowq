class_name Climate
extends RefCounted
## Акклиматизация (решение пользователя, ноябрь 2026): в пустынях (особенно
## летом), зимой на севере и в горах войска движутся медленнее, сильнее
## истощаются (теряют людей) и слабее в бою. Акклиматизация дивизии (к жаре и к
## холоду, 0..1) снимает штраф: растёт, пока дивизия стоит в таком климате, и
## медленно спадает вне его до уровня страны. Страна, чьи коренные провинции
## (не колонии) лежат в таком климате, даёт дивизиям высокий уровень сразу, а
## выше 1 — бонус в бою в своём климате (коренные жители: Финляндия, север СССР,
## арабские страны, горные страны).
##
## Суровость провинций (p_hot, p_cold 0..1) — раз в месяц (World.refresh_def_mult);
## уровни стран (n_hot, n_cold 0..1,5) — раз в месяц; дивизии — каждый день ядром
## (C++ MeowqCore.climate, GDScript — kernel_gd; результаты совпадают до бита).
## Ядро выдаёт «действующие» скорость, атаку и оборону (d_spd_eff, d_atk_eff,
## d_def_eff) — их берут ядра движения и боя.

const HOT_DESERT := 0.5        # пустыня круглый год
const HOT_SUMMER := 1.0        # пустыня летом (июнь–август; в южном полушарии — декабрь–февраль)
const HOT_SHOULDER := 0.75     # пустыня в соседние месяцы
const COLD_MOUNT := 0.5        # горы круглый год
const COLD_MOUNT_WINTER := 0.8 # горы зимой
const COLD_ARCTIC := 0.3       # за полярным кругом и летом
const NATIVE_K := 2.5          # уровень страны = доля коренных провинций × 2,5, до 1,5
const NATIVE_MAX := 1.5
const GAIN := 0.012            # акклиматизации в день при полной суровости (~3 месяца до 1)
const DECAY := 0.003           # в день вне такого климата
const SPD_PEN := 0.4           # скорость при полной неакклиматизированности ×0,6
const COMBAT_PEN := 0.25       # атака и оборона ×0,75
const ATTRITION := 0.3         # потеря людей, % в день (не ниже ATTR_FLOOR)
const ATTR_FLOOR := 10.0
const NATIVE_BONUS := 0.15     # коренным в своём климате — атака и оборона до +15 %


## Суровость провинций на месяц m (0 — январь).
static func refresh_provinces(world: World, m: int) -> void:
	var pc := world.prov_count
	world.p_hot.resize(pc)
	world.p_cold.resize(pc)
	var n_summer := m >= 5 and m <= 7
	var n_shoulder := m == 4 or m == 8
	var s_summer := m == 11 or m <= 1
	var s_shoulder := m == 10 or m == 2
	var deep := m == 11 or m <= 2
	var mid := m == 11 or m <= 1
	for p in pc:
		var hot := 0.0
		var cold := 0.0
		if world.p_land[p] == 1:
			var lat := world.p_lonlat[p].y
			var terr := world.p_terrain[p]
			if terr == World.T_DESERT:
				hot = HOT_DESERT
				var summer := n_summer if lat >= 0.0 else s_summer
				var shoulder := n_shoulder if lat >= 0.0 else s_shoulder
				if summer:
					hot = HOT_SUMMER
				elif shoulder:
					hot = HOT_SHOULDER
			# зима — как в обороне провинции (refresh_def_mult), плюс юг полушария
			if deep and lat >= 60.0:
				cold = 1.0
			elif deep and lat >= 55.0:
				cold = 0.8
			elif mid and lat >= 48.0:
				cold = 0.5
			elif n_summer and lat <= -45.0:
				cold = 0.6
			if absf(lat) >= 66.0:
				cold = maxf(cold, COLD_ARCTIC)
			if terr == World.T_MOUNTAIN:
				var winter := (deep and lat >= 30.0) or (n_summer and lat <= -30.0)
				cold = maxf(cold, COLD_MOUNT_WINTER if winter else COLD_MOUNT)
		world.p_hot[p] = hot
		world.p_cold[p] = cold
	refresh_nations(world)


## Уровни стран: доля коренных провинций (не колоний) в жарком (пустыня) и
## холодном (широта ≥ 55° или ≤ −45°, горы) климате × NATIVE_K, до NATIVE_MAX.
static func refresh_nations(world: World) -> void:
	var nc := world.nation_count
	var hot := PackedFloat64Array()
	hot.resize(nc)
	var cold := PackedFloat64Array()
	cold.resize(nc)
	var cnt := PackedInt32Array()
	cnt.resize(nc)
	var has_col := world.p_colony.size() == world.prov_count
	for p in world.prov_count:
		var o := world.p_owner[p]
		if world.p_land[p] == 0 or o < 0 or (has_col and world.p_colony[p] == 1):
			continue
		cnt[o] += 1
		var lat := world.p_lonlat[p].y
		var terr := world.p_terrain[p]
		if terr == World.T_DESERT:
			hot[o] += 1.0
		if lat >= 55.0 or lat <= -45.0 or terr == World.T_MOUNTAIN:
			cold[o] += 1.0
	for n in nc:
		var c := maxf(1.0, float(cnt[n]))
		hot[n] = minf(NATIVE_MAX, hot[n] / c * NATIVE_K)
		cold[n] = minf(NATIVE_MAX, cold[n] / c * NATIVE_K)
	world.n_hot = hot
	world.n_cold = cold


## Дневной шаг (главный поток, перед движением и боями).
static func daily(world: World) -> void:
	var n := world.d_alive.size()
	if world.p_hot.size() != world.prov_count or world.n_hot.size() != world.nation_count:
		refresh_provinces(world, world.month_of(world.day))
	# новые дивизии (и старые сохранения) — с уровнем своей страны
	if world.d_acl_hot.size() != n or world.d_acl_cold.size() != n:
		var old := world.d_acl_hot.size()
		world.d_acl_hot.resize(n)
		world.d_acl_cold.resize(n)
		for i in range(mini(old, world.d_acl_cold.size()), n):
			var o := world.d_owner[i]
			world.d_acl_hot[i] = minf(1.0, world.n_hot[o])
			world.d_acl_cold[i] = minf(1.0, world.n_cold[o])
	var t := {"alive": world.d_alive, "transit": world.d_transit, "prov": world.d_prov, "owner": world.d_owner,
		"str": world.d_str, "acl_hot": world.d_acl_hot, "acl_cold": world.d_acl_cold, "spd": world.d_spd,
		"atk": world.d_atk, "def": world.d_def, "p_hot": world.p_hot, "p_cold": world.p_cold,
		"n_hot": world.n_hot, "n_cold": world.n_cold,
		"k": PackedFloat64Array([GAIN, DECAY, SPD_PEN, COMBAT_PEN, ATTRITION, ATTR_FLOOR, NATIVE_BONUS])}
	var r: Array = Native.core.call("climate", t) if Native.core != null else kernel_gd(t)
	world.d_acl_hot = r[0]
	world.d_acl_cold = r[1]
	world.d_str = r[2]
	world.d_spd_eff = r[3]
	world.d_atk_eff = r[4]
	world.d_def_eff = r[5]
	world.d_cmul = r[6]
	chaos(world)


## Раскол страны (решение пользователя, ноябрь 2026, как в жанре): в гражданской
## войне вся земля страны — неразбериха: атака, оборона и скорость войск сторон
## там × множитель (World.reg_chaos: район -> множитель; ставит эффект civil_war).
## Каждая сторона сама снимает её в одном районе в день раскола и дальше раз в
## every дней — по своему списку (шаблон в данных, от зерна не зависит;
## World.chaos_plan); список кончился — снята везде. Снятые районы стороны —
## World.chaos_lift (страна -> {район: true}).
static func chaos(world: World) -> void:
	if world.reg_chaos.is_empty():
		return
	# выбор районов по шаблону
	for pl in world.chaos_plan:
		var n: int = pl[0]
		var lst: Array = pl[1]
		if world.day < int(pl[2]) or not world.chaos_lift.has(n):
			continue
		var lifted: Dictionary = world.chaos_lift[n]
		while not lst.is_empty() and lifted.has(int(lst[0])):
			lst.pop_front()
		if lst.is_empty():
			for r in world.reg_chaos:
				lifted[r] = true
		else:
			var r: int = lst.pop_front()
			lifted[r] = true
			world.log_event("%s: порядок наведён в районе %s" % [world.nations[n].name, world.air_region_names[r] if r < world.air_region_names.size() else str(r)])
		pl[2] = int(pl[2]) + int(pl[3])
	# все стороны навели порядок везде — неразбериха кончилась
	var done := true
	for n in world.chaos_lift:
		if (world.chaos_lift[n] as Dictionary).size() < world.reg_chaos.size() and world.nations[int(n)].alive:
			done = false
	if done:
		world.reg_chaos = {}
		world.chaos_lift = {}
		world.chaos_plan = []
		return
	var alive := world.d_alive
	var prov := world.d_prov
	var owner := world.d_owner
	var reg := world.p_region
	var ae := world.d_atk_eff
	var de := world.d_def_eff
	var se := world.d_spd_eff
	for i in alive.size():
		if alive[i] == 0 or prov[i] < 0:
			continue
		var lf: Variant = world.chaos_lift.get(owner[i])
		if lf == null:
			continue
		var r := reg[prov[i]]
		if (lf as Dictionary).has(r):
			continue
		var c: Variant = world.reg_chaos.get(r)
		if c != null:
			var m: float = c
			ae[i] *= m
			de[i] *= m
			se[i] *= m
	world.d_atk_eff = ae
	world.d_def_eff = de
	world.d_spd_eff = se


## Поставить неразбериху раскола на районы провинций ps (штраф v: 0,95 —
## характеристики × 0,05) для сторон из pick: страна -> районы по порядку
## выбора (первый — сразу, дальше раз в every дней).
static func set_chaos(world: World, ps: PackedInt32Array, v: float, pick: Dictionary, every: int) -> void:
	for p in ps:
		var r := world.p_region[p]
		if r >= 0:
			world.reg_chaos[r] = 1.0 - v
	var ns: Array = pick.keys()
	ns.sort()
	for n in ns:
		world.chaos_lift[n] = {}
		world.chaos_plan.append([n, (pick[n] as Array).duplicate(), world.day, every])


## GDScript-двойник MeowqCore.climate → [acl_hot, acl_cold, str, spd_eff, atk_eff, def_eff, cmul].
static func kernel_gd(t: Dictionary) -> Array:
	var alive: PackedByteArray = t["alive"]
	var transit: PackedInt32Array = t["transit"]
	var prov: PackedInt32Array = t["prov"]
	var owner: PackedInt32Array = t["owner"]
	var st: PackedFloat64Array = (t["str"] as PackedFloat64Array).duplicate()
	var ah: PackedFloat64Array = (t["acl_hot"] as PackedFloat64Array).duplicate()
	var ac: PackedFloat64Array = (t["acl_cold"] as PackedFloat64Array).duplicate()
	var spd: PackedFloat64Array = t["spd"]
	var atk: PackedFloat64Array = t["atk"]
	var def: PackedFloat64Array = t["def"]
	var ph: PackedFloat32Array = t["p_hot"]
	var pcd: PackedFloat32Array = t["p_cold"]
	var nh: PackedFloat64Array = t["n_hot"]
	var ncd: PackedFloat64Array = t["n_cold"]
	var k: PackedFloat64Array = t["k"]
	var gain := k[0]
	var decay := k[1]
	var spd_pen := k[2]
	var cpen := k[3]
	var attr := k[4]
	var floor_s := k[5]
	var bonus := k[6]
	var n := alive.size()
	var se := PackedFloat64Array()
	se.resize(n)
	var ae := PackedFloat64Array()
	ae.resize(n)
	var de := PackedFloat64Array()
	de.resize(n)
	var cm := PackedFloat64Array()
	cm.resize(n)
	for i in n:
		se[i] = spd[i]
		ae[i] = atk[i]
		de[i] = def[i]
		cm[i] = 1.0
		if alive[i] == 0 or transit[i] > 0:
			continue
		var p := prov[i]
		var o := owner[i]
		var hh := float(ph[p])
		var hc := float(pcd[p])
		var bh := minf(1.0, nh[o])
		var bc := minf(1.0, ncd[o])
		# акклиматизация: растёт в таком климате, вне его спадает до уровня страны
		if hh > 0.0:
			ah[i] = minf(1.0, maxf(ah[i], bh) + gain * hh)
		else:
			ah[i] = maxf(bh, ah[i] - decay)
		if hc > 0.0:
			ac[i] = minf(1.0, maxf(ac[i], bc) + gain * hc)
		else:
			ac[i] = maxf(bc, ac[i] - decay)
		var u := minf(1.0, hh * (1.0 - ah[i]) + hc * (1.0 - ac[i]))
		var b := minf(1.0, hh * clampf((nh[o] - 1.0) / 0.5, 0.0, 1.0) + hc * clampf((ncd[o] - 1.0) / 0.5, 0.0, 1.0))
		if u <= 0.0 and b <= 0.0:
			continue
		var mult := (1.0 - cpen * u) * (1.0 + bonus * b)
		cm[i] = mult
		se[i] = spd[i] * (1.0 - spd_pen * u)
		ae[i] = atk[i] * mult
		de[i] = def[i] * mult
		if u > 0.0 and st[i] > floor_s:
			st[i] = maxf(floor_s, st[i] - attr * u)
	return [ah, ac, st, se, ae, de, cm]
