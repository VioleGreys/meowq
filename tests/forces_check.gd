extends SceneTree
## Флот и авиация: морской бой, блокада, рейды подлодок, высадка, воздушные бои,
## бомбардировки, исторический ИИ высаживается в Норвегии.
##   godot --headless --path . --script res://tests/forces_check.gd

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func fresh() -> Array:
	var w := World.new()
	MapLoader.load_world(w)
	return [w, Simulation.new(w)]


## Флот по названию; «Основной флот» — сильнейший надводный (у Британии
## флот поделён по базам: Флот метрополии, Средиземноморский, Восточный).
func fleet_of(w: World, n: int, name: String) -> World.Fleet:
	var best: World.Fleet = null
	for f in w.fleets:
		if f.alive and f.owner == n and f.name == name:
			return f
		if name == "Основной флот" and f.alive and f.owner == n and f.mission != "raid" \
				and (best == null or Forces.fleet_power(f) > Forces.fleet_power(best)):
			best = f
	return best


func _init() -> void:
	var r := fresh()
	var w: World = r[0]
	var sim: Simulation = r[1]
	var GER := w.nation_tags.find("GER")
	var ENG := w.nation_tags.find("ENG")
	var NOR := w.nation_tags.find("NOR")
	print("Стартовые силы:")
	var eng_main := fleet_of(w, ENG, "Флот метрополии")
	var ger_main := fleet_of(w, GER, "Основной флот")
	check(eng_main != null and ger_main != null, "у Британии и Германии есть флоты")
	var eng_home := 0.0
	for f in w.fleets:
		if f.alive and f.owner == ENG and f.home == eng_main.home and f.mission != "raid":
			eng_home += Forces.fleet_power(f)
	check(eng_home > Forces.fleet_power(ger_main) * 3.5, "Флот метрополии многократно сильнее (%.0f против %.0f)" % [eng_home, Forces.fleet_power(ger_main)])
	var biggest := 0
	var eng_cv := 0
	for f in w.fleets:
		if f.alive:
			biggest = maxi(biggest, Forces.fleet_size(f))
			if f.owner == ENG:
				eng_cv += f.ships[Forces.SHIP_CV]
	check(biggest <= Forces.FLEET_MAX, "в соединении не больше %d кораблей (самое большое — %d)" % [Forces.FLEET_MAX, biggest])
	check(eng_cv == 6, "у Британии 6 авианосцев (%d)" % eng_cv)
	var kinds := {}
	for d in w.ship_designs:
		kinds[int(d["kind"])] = true
	check(kinds.size() == 3, "проекты кораблей всех трёх категорий: подлодки, крейсеры, авианосцы")
	var ger_wings := 0
	for wg in w.wings:
		if wg.owner == GER:
			ger_wings += 1
	check(ger_wings >= 4, "у Германии %d авиакрыльев" % ger_wings)

	var bases := 0
	for p in w.prov_count:
		if w.p_naval_base[p] == 1 and w.p_owner[p] == ENG:
			bases += 1
	check(bases >= 5, "у Британии %d военно-морских баз" % bases)

	print("Морской бой и блокада:")
	w.set_war(GER, ENG)
	w.nations[GER].is_player = true
	w.nations[ENG].is_player = true
	sim._refresh_sides()
	# бой в открытом море, по соседству с германской базой
	var open_sea := -1
	for q in w.p_adj[ger_main.zone]:
		if w.p_land[q] == 0:
			open_sea = q
			break
	var ger_base_zone := ger_main.zone
	ger_main.zone = open_sea
	# в бой идут все соединения Флота метрополии (у одной базы)
	for f in w.fleets:
		if f.alive and f.owner == ENG and f.home == eng_main.home and f.mission != "raid":
			f.zone = open_sea
			f.path = PackedInt32Array()
	var before := Forces.fleet_power(ger_main)
	sim.tick()
	check(eng_main.readiness < 1.0, "в бою готовность британского флота падает (%.1f%%)" % (eng_main.readiness * 100.0))
	for i in 4:
		sim.tick()
	check(not ger_main.alive or (Forces.fleet_power(ger_main) < before and ger_main.mission == "port"),
		"германский флот потерял корабли и ушёл на базу (%.0f → %.0f)" % [before, Forces.fleet_power(ger_main) if ger_main.alive else 0.0])
	# блокада: британский флот у германской базы (флот в порту господства не даёт)
	eng_main.zone = ger_base_zone
	eng_main.path = PackedInt32Array()
	Forces._refresh_cache(w)
	var port := -1
	for q in w.p_adj[ger_base_zone]:
		if w.p_land[q] == 1 and w.p_owner[q] == GER and Forces.is_port(w, q):
			port = q
	check(port >= 0 and Forces.port_blockaded(w, GER, port), "германский порт %s заблокирован" % (w.p_name[port] if port >= 0 else "?"))
	# ремонт на своей базе
	eng_main.readiness = 0.5
	eng_main.zone = eng_main.home
	eng_main.mission = "port"
	for i in 5:
		sim.tick()
	check(eng_main.readiness > 0.6, "на базе готовность восстанавливается (%d%%)" % (eng_main.readiness * 100.0))
	var ger_port_fleet := Forces.create_fleet(w, GER, eng_main.home, "тест")
	Forces.add_ships(w, ger_port_fleet, w.nations[GER].ship_role[0], 5)
	ger_port_fleet.mission = "port"
	w.set_war(GER, ENG)
	sim.tick()
	check(ger_port_fleet.alive and ger_port_fleet.ships[Forces.SHIP_CR] == 5, "флот в порту в морском бою не участвует")

	print("Ширина морского боя:")
	var many: Array = []
	for i in 14:
		var tf := Forces.create_fleet(w, GER, open_sea, "ширина %d" % i)
		Forces.add_ships(w, tf, w.nations[GER].ship_role[0], 1 + i)
		many.append(tf)
	var line := Forces._battle_line(many)
	check(line.size() == Forces.NAVY_WIDTH and line[0] == many[13], "в бою у стороны %d соединений, сильнейшие первыми" % line.size())
	var sp := Forces.split_fleet(w, many[13])
	check(sp != null and Forces.fleet_size(many[13]) + Forces.fleet_size(sp) == 14, "соединение делится пополам (%d + %d)" % [Forces.fleet_size(many[13]), Forces.fleet_size(sp) if sp != null else 0])
	Forces.merge_here(w, many[12])
	check(Forces.fleet_size(many[12]) == Forces.FLEET_MAX, "слияние — не больше %d кораблей (%d)" % [Forces.FLEET_MAX, Forces.fleet_size(many[12])])

	print("Конвои и рейды подлодок:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.nations[GER].is_player = true
	w.nations[ENG].is_player = true
	var eng: World.Nation = w.nations[ENG]
	# мирное время: поставки и пути конвоев (обход — раз в 14 дней)
	while eng.conv_trade_need <= 0.0 and w.day < 400:
		sim.tick()
		w.events.clear()
	w.set_war(GER, ENG)
	sim._refresh_sides()
	sim.tick()
	var rz := -1
	var rz_units := 0.0
	for rt in eng.conv_routes:
		if int(rt[0]) == 0 and float(rt[3]) > rz_units:
			rz_units = float(rt[3])
			var b0: int = (rt[2] as PackedInt32Array)[0]
			rz = w.bas_zone_list[w.bas_zone_start[b0]]   # зона бассейна на пути
	check(rz >= 0 and eng.conv_trade_need > 0.0, "у Британии морской импорт идёт конвоями (нужно %.0f, есть %.0f)" % [eng.conv_trade_need, eng.convoys])
	check(eng.conv_sup_need > 0.0, "войскам Британии за морем нужны конвои (%.0f)" % eng.conv_sup_need)
	var subs := fleet_of(w, GER, "Подводные силы")
	Forces.add_ships(w, subs, w.nations[GER].ship_role[3], 150)
	subs.zone = rz if rz >= 0 else Forces.trade_zones(w, ENG).keys()[0]
	subs.path = PackedInt32Array()
	subs.mission = "raid"
	for f in w.fleets:
		if f.owner == ENG:
			f.zone = f.home
			f.path = PackedInt32Array()
			f.mission = "port"
	var conv0 := eng.convoys
	var mil_mult := 1.0 + eng.b("industry")
	sim.tick()
	var lost := 0.0
	for x in Economy.RES_COUNT:
		lost += eng.res_lost[x]
	var sb: int = w.z_basin[subs.zone]
	check(eng.conv_danger.has(sb) and lost > 0.0, "рейды в бассейне «%s» топят груз: не дошло %.2f ед. (перехват %d%%)" % [w.basin_name[sb], lost, roundi(float(eng.conv_danger.get(sb, 0.0)) * 100.0)])
	check(w.basin_name.size() < 150 and w.basin_name.has("Тихий океан (север)"), "бассейнов %d (из 214 зон), Тихий океан — север и юг" % w.basin_name.size())
	check(eng.convoys < conv0, "рейды топят конвои (%.1f → %.1f)" % [conv0, eng.convoys])
	check(is_equal_approx(mil_mult, 1.0 + eng.b("industry")), "выпуск заводов рейды не режут")
	eng.convoys = 0.0
	eng.conv_auto = false
	sim.tick()
	var cut := 0
	for rt in eng.conv_routes:
		if int(rt[0]) == 1 and w.p_conv[int(rt[1])] < 0.01:
			cut += 1
	check(cut > 0 and eng.conv_trade < 0.01, "без конвоев заморские порты не снабжают (%d), импорт морем не доходит" % cut)

	print("Морская высадка:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.nations[GER].is_player = true
	w.set_war(GER, NOR)
	sim._refresh_sides()
	for f in w.fleets:
		if f.owner == NOR:
			f.alive = false
	Forces._refresh_cache(w)
	var target := -1
	for p in w.prov_count:
		if w.p_owner[p] == NOR and w.p_coastal[p] == 1 and w.divs_count(p) == 0:
			target = p
			break
	var coast := -1
	for p in w.prov_count:
		if w.p_owner[p] == GER and w.p_coastal[p] == 1 and w.p_lonlat[p].y > 53.5 and w.p_lonlat[p].x < 11.0:
			coast = p
	var divs: Array = []
	for d in w.divisions_of(GER):
		if divs.size() < 3:
			d.prov = coast
			divs.append(d)
	w.rebuild_prov_divs()
	var why := Forces.plan_invasion(w, divs, target)
	check(why == "", "план высадки из %s в %s: %s" % [w.p_name[coast], w.p_name[target], why if why != "" else "подготовка %d дн." % w.invasions[0].total])
	var prep: int = w.invasions[0].total
	check(prep >= 30 and prep <= 60, "подготовка занимает 1–2 месяца (%d дн.)" % prep)
	for i in prep - 2:
		sim.tick()
	check(divs[0].transit_days == 0 and divs[0].prov == coast, "до конца подготовки войска ждут в порту")
	for i in 25:
		sim.tick()
	check(w.p_controller[target] == GER, "высадившиеся войска заняли %s" % w.p_name[target])
	check(w.beachheads.has(target), "плацдарм работает как временный порт")

	print("Переправа:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.nations[ENG].is_player = true
	var FRA := w.nation_tags.find("FRA")
	var dover := -1
	var calais := -1
	for p in w.prov_count:
		if w.p_owner[p] == ENG and Forces.is_port(w, p) and w.p_lonlat[p].x > 0.0 and w.p_lonlat[p].y < 52.0:
			dover = p
		if w.p_owner[p] == FRA and Forces.is_port(w, p) and w.p_lonlat[p].y > 47.0 and w.p_lonlat[p].x < 3.0:
			calais = p
	var tdivs: Array = []
	for d in w.divisions_of(ENG):
		if tdivs.size() < 2:
			d.prov = dover
			tdivs.append(d)
	w.rebuild_prov_divs()
	var tw := Forces.sea_transfer(w, tdivs, calais)
	check(tw == "", "переправа %s → %s (союзная Франция): %s" % [w.p_name[dover], w.p_name[calais], tw if tw != "" else "%d дн." % tdivs[0].transit_days])
	for i in tdivs[0].transit_total + 2:
		sim.tick()
	check(tdivs[0].prov == calais, "дивизии прибыли во французский порт")
	var inland := -1
	for p in w.prov_count:
		if w.p_owner[p] == ENG and w.p_coastal[p] == 0:
			inland = p
			break
	tdivs[0].prov = inland
	check(Forces.plan_invasion(w, [tdivs[0]], calais) != "", "без порта посадки высадка невозможна")

	print("Авиация:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.nations[GER].is_player = true
	w.nations[ENG].is_player = true
	w.set_war(GER, ENG)
	sim._refresh_sides()
	var london_r: int = w.p_region[w.nations[ENG].capital]
	for wg in w.wings:
		if wg.owner == GER:
			wg.region = london_r
			wg.mission = "sup" if wg.kind == 0 else "bomb"
		elif wg.owner == ENG:
			wg.region = london_r
			wg.mission = "sup" if wg.kind == 0 else "cas"
	var factories_before := 0
	for p in w.prov_count:
		if w.p_region[p] == london_r and w.p_owner[p] == ENG:
			factories_before += w.p_civ[p] + w.p_mil[p]
	var ger_planes := 0.0
	for wg in w.wings:
		if wg.owner == GER:
			ger_planes += wg.planes
	for i in 60:
		sim.tick()
	var ger_after := 0.0
	for wg in w.wings:
		if wg.owner == GER and wg.alive:
			ger_after += wg.planes
	var factories_after := 0
	for p in w.prov_count:
		if w.p_region[p] == london_r and w.p_owner[p] == ENG:
			factories_after += w.p_civ[p] + w.p_mil[p]
	check(ger_after < ger_planes, "воздушные бои над Лондоном: потери Германии %d самолётов" % (ger_planes - ger_after))
	check(factories_after < factories_before, "бомбардировки разрушили заводы: %d → %d" % [factories_before, factories_after])
	var dmg_n := 0
	var cap_lost := 0.0
	for p in w.bombed:
		dmg_n += 1
		cap_lost += w.p_supply_base[p] - w.p_supply_cap[p]
	check(dmg_n > 0 and cap_lost > 0.0, "бомбёжки повредили узлы и дороги: провинций %d, снабжение −%.1f" % [dmg_n, cap_lost])
	var probe: int = w.bombed.keys()[0] if dmg_n > 0 else -1
	var d0: float = w.p_bomb[probe] if probe >= 0 else 0.0
	Forces.repair_bombing(w)
	check(probe >= 0 and w.p_bomb[probe] < d0, "повреждения чинятся: %.2f → %.2f" % [d0, w.p_bomb[probe] if probe >= 0 else 0.0])
	var sup: float = w.air_sup[london_r * w.nation_count + ENG]
	print("  превосходство Британии над Лондоном: %d%%" % (sup * 100.0))
	# господство в воздухе: войска страны без своей авиации в районе, где у
	# противника истребители, слабеют (до −30 %)
	for wg in w.wings:
		if wg.owner == ENG:
			wg.alive = false
		elif wg.owner == GER and wg.alive:
			wg.mission = "sup"
	Forces.daily_air(w, RandomNumberGenerator.new())
	var m_eng: float = w.cas_mult[london_r * w.nation_count + ENG]
	check(m_eng < 1.0 and m_eng >= 1.0 - Forces.AIR_SUP_PENALTY - 0.001, "без своей авиации под чужим господством: сила войск ×%.2f" % m_eng)

	print("Исторический ИИ: Норвегия 1940:")
	r = fresh()
	w = r[0]
	sim = r[1]
	var launched := false
	while w.day < w.day_of("1940-06-15"):
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		for e in w.events:
			if e.contains("высадк") or e.contains("Норвег"):
				print("  ", w.date_string(), " — ", e)
			if e.contains("морская высадка"):
				launched = true
		w.events.clear()
	var nor_taken := 0
	for p in w.prov_count:
		if (w.p_owner[p] == NOR or not w.nations[NOR].alive) and w.p_controller[p] == GER and w.p_lonlat[p].y > 58.0 and w.p_lonlat[p].x < 31.0 and w.p_lonlat[p].x > 4.0:
			nor_taken += 1
	check(launched, "Германия подготовила и провела высадку в Норвегии")
	print("  занято норвежских провинций: %d, Норвегия %s" % [nor_taken, "существует" if w.nations[NOR].alive else "капитулировала"])
	if errors == 0:
		print("Флот и авиация: OK")
	quit(1 if errors > 0 else 0)
