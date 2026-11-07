extends SceneTree
## Проверка дипломатии: правила (пакты, претензии, гаранты, фракции, мир) и
## прогон нескольких лет с журналом событий.
##   godot --headless --path . --script res://tests/diplomacy_check.gd [-- --years=3]

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
	var sim := Simulation.new(w)
	return [w, sim]


func _init() -> void:
	var r := fresh()
	var w: World = r[0]
	var GER := w.nation_tags.find("GER")
	var POL := w.nation_tags.find("POL")
	var FRA := w.nation_tags.find("FRA")
	var ENG := w.nation_tags.find("ENG")
	var CZE := w.nation_tags.find("CZE")
	var ROM := w.nation_tags.find("ROM")
	var AUS := w.nation_tags.find("AUS")
	var SOV := w.nation_tags.find("SOV")
	var EST := w.nation_tags.find("EST")
	print("Стартовая обстановка:")
	check(Diplomacy.faction_name(w, ENG) == "Союзники" and Diplomacy.faction_name(w, FRA) == "Союзники", "Британия и Франция — Союзники")
	check(Diplomacy.faction_name(w, ROM) == "Малая Антанта", "Румыния в Малой Антанте")
	check(w.nations[FRA].guarantees.has(POL), "Франция гарантирует Польшу")
	check(Diplomacy.can_justify(w, GER, POL) != "", "пакт мешает Германии обосновать претензии к Польше")
	check(Diplomacy.can_justify(w, SOV, EST) != "", "пакт мешает СССР обосновать претензии к Эстонии")
	check(Diplomacy.can_justify(w, FRA, GER) != "", "демократии при низкой напряжённости нельзя обосновывать претензии")
	check(Diplomacy.can_declare(w, GER, AUS) != "", "без претензий войну не объявить")
	check(Diplomacy.can_justify(w, GER, AUS) == "", "Германия может обосновать претензии к Австрии")

	print("Война Германии с Чехословакией втягивает Малую Антанту и гаранта:")
	w.nations[GER].wargoals[CZE] = true
	check(Diplomacy.declare_war(w, GER, CZE), "Германия объявляет войну Чехословакии")
	check(w.is_at_war(GER, ROM), "Румыния (Малая Антанта) воюет с Германией")
	check(w.is_at_war(GER, FRA), "Франция (гарант) воюет с Германией")
	check(w.is_at_war(GER, ENG), "Британия (фракция Франции) воюет с Германией")
	check(w.tension > 8.0, "напряжённость выросла (%.0f%%)" % w.tension)

	print("Мир: аннексия и марионетка:")
	r = fresh()
	w = r[0]
	w.nations[GER].wargoals[AUS] = true
	Diplomacy.declare_war(w, GER, AUS)
	for p in w.prov_count:
		if w.p_owner[p] == AUS:
			w.p_controller[p] = GER
	Diplomacy.make_peace(w, AUS, GER, "annex")
	var aus_left := 0
	for p in w.prov_count:
		if w.p_owner[p] == AUS:
			aus_left += 1
	check(not w.nations[AUS].alive and aus_left == 0, "Австрия аннексирована")
	var HUN := w.nation_tags.find("HUN")
	w.tension = 60.0
	w.nations[FRA].wargoals[HUN] = true
	Diplomacy.declare_war(w, FRA, HUN)
	Diplomacy.make_peace(w, HUN, FRA, "puppet")
	check(w.nations[HUN].alive and w.nations[HUN].overlord == FRA, "Венгрия — марионетка Франции")
	check(Diplomacy.same_side(w, HUN, ENG), "марионетка на стороне союзников сюзерена")

	print("Сценарий игрока: Германия против Австрии:")
	r = fresh()
	w = r[0]
	var psim: Simulation = r[1]
	w.nations[GER].is_player = true
	check(Diplomacy.start_justify(w, GER, AUS), "обоснование претензий началось")
	var guard := 0
	while not w.nations[GER].wargoals.has(AUS) and guard < 200:
		psim.tick()
		guard += 1
	check(w.nations[GER].wargoals.has(AUS), "претензии обоснованы за %d дн." % guard)
	check(Diplomacy.declare_war(w, GER, AUS), "война объявлена")
	for p in w.prov_count:
		if w.p_owner[p] == AUS:
			w.p_controller[p] = GER
	psim.tick()
	check(w.pending_peace.size() == 1 and w.pending_peace[0][0] == AUS, "игроку предложен мирный договор")
	var day_before := w.day
	psim.tick()
	check(w.day == day_before, "время стоит до решения игрока")
	psim.resolve_peace("puppet")
	check(w.nations[AUS].overlord == GER and w.pending_peace.is_empty(), "Австрия — марионетка Германии")

	var years := 3
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--years="):
			years = int(a.split("=")[1])
	print("Прогон %d лет без игрока:" % years)
	r = fresh()
	w = r[0]
	var sim: Simulation = r[1]
	var t := Time.get_ticks_msec()
	for i in 365 * years:
		sim.tick()
		for e in w.events:
			print("  %s — %s" % [w.date_string(), e])
		w.events.clear()
	print("  итог: %s, напряжённость %.0f%%, живых стран %d, %d мс" % [w.date_string(), w.tension, w.nations.filter(func(n): return n.alive).size(), Time.get_ticks_msec() - t])
	for f in w.factions:
		if f.alive:
			var names: Array = []
			for m in Diplomacy.faction_members(w, f.id):
				names.append(w.nations[m].name)
			print("  фракция «%s»: %s" % [f.name, ", ".join(names)])
	if errors == 0:
		print("Дипломатия: OK")
	quit(1 if errors > 0 else 0)
