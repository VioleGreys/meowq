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


func fleet_of(w: World, n: int, name: String) -> World.Fleet:
	for f in w.fleets:
		if f.alive and f.owner == n and f.name == name:
			return f
	return null


func _init() -> void:
	var r := fresh()
	var w: World = r[0]
	var sim: Simulation = r[1]
	var GER := w.nation_tags.find("GER")
	var ENG := w.nation_tags.find("ENG")
	var NOR := w.nation_tags.find("NOR")
	print("Стартовые силы:")
	var eng_main := fleet_of(w, ENG, "Основной флот")
	var ger_main := fleet_of(w, GER, "Основной флот")
	check(eng_main != null and ger_main != null, "у Британии и Германии есть флоты")
	check(Forces.fleet_power(eng_main) > Forces.fleet_power(ger_main) * 5.0, "британский флот многократно сильнее (%.0f против %.0f)" % [Forces.fleet_power(eng_main), Forces.fleet_power(ger_main)])
	var ger_wings := 0
	for wg in w.wings:
		if wg.owner == GER:
			ger_wings += 1
	check(ger_wings >= 4, "у Германии %d авиакрыльев" % ger_wings)

	print("Морской бой и блокада:")
	w.set_war(GER, ENG)
	w.nations[GER].is_player = true
	w.nations[ENG].is_player = true
	sim._refresh_sides()
	eng_main.zone = ger_main.zone
	eng_main.path = PackedInt32Array()
	var before := Forces.fleet_power(ger_main)
	for i in 5:
		sim.tick()
	check(not ger_main.alive or Forces.fleet_power(ger_main) < before * 0.6, "германский флот разбит в бою (%.0f → %.0f)" % [before, Forces.fleet_power(ger_main) if ger_main.alive else 0.0])
	var port := -1
	for q in w.p_adj[eng_main.zone]:
		if w.p_land[q] == 1 and w.p_owner[q] == GER and w.p_vp[q] >= 3:
			port = q
	check(port >= 0 and Forces.port_blockaded(w, GER, port), "германский порт %s заблокирован" % (w.p_name[port] if port >= 0 else "?"))

	print("Рейды подлодок:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.nations[GER].is_player = true
	w.nations[ENG].is_player = true
	w.set_war(GER, ENG)
	sim._refresh_sides()
	var subs := fleet_of(w, GER, "Подводные силы")
	subs.ships[Forces.SHIP_SS] = 150
	var tz: Dictionary = Forces.trade_zones(w, ENG)
	subs.zone = tz.keys()[0]
	subs.mission = "raid"
	for f in w.fleets:
		if f.owner == ENG:
			f.zone = f.home
			f.mission = "port"
	sim.tick()
	check(w.nations[ENG].trade_penalty > 0.05, "рейды снижают выпуск Британии на %d%%" % (w.nations[ENG].trade_penalty * 100.0))

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
		if w.p_owner[p] == NOR and w.p_coastal[p] == 1 and w.prov_divs[p].is_empty():
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
	var sup: float = w.air_sup[london_r * w.nation_count + ENG]
	print("  превосходство Британии над Лондоном: %d%%" % (sup * 100.0))

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
