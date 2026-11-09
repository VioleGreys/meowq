extends SceneTree
## Историческая игра без игрока: события и фокусы должны дать узнаваемый ход
## 1936–1941 гг. Печатает журнал и проверяет вехи (сроки — с запасом).
##   godot --headless --path . --script res://tests/history_check.gd [-- --until=1941-07-01 --quiet]

var errors := 0
var w: World


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func t(tag: String) -> int:
	return w.nation_tags.find(tag)


func alive(tag: String) -> bool:
	return w.nations[t(tag)].alive


func _init() -> void:
	w = World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1941-07-01"
	var quiet := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a == "--quiet":
			quiet = true
	var marks := {}
	var milestones := {
		"1936-04-01": func(): check(w.events_fired.has("rhineland"), "Рейнская область ремилитаризована (март 1936)"),
		"1936-08-01": func(): check(alive("NSP") and w.is_at_war(t("NSP"), t("SPR")), "в Испании гражданская война"),
		"1937-01-01": func(): check(Diplomacy.faction_name(w, t("GER")) == "Ось" and Diplomacy.same_side(w, t("GER"), t("ITA")), "Германия и Италия — Ось"),
		"1938-04-15": func(): check(not alive("AUS"), "аншлюс Австрии"),
		"1938-11-01": func(): check(w.events_fired.has("munich"), "Мюнхенское соглашение"),
		"1939-04-15": func(): check(not alive("CZE") and alive("SLO") and w.nations[t("SLO")].overlord == t("GER"), "Чехия занята, Словакия — марионетка Германии"),
		"1939-09-05": func(): check(w.is_at_war(t("GER"), t("POL")) and w.is_at_war(t("GER"), t("ENG")) and w.is_at_war(t("GER"), t("FRA")), "1 сентября: Германия против Польши, Британия и Франция вступили"),
		"1939-09-25": func(): check(w.is_at_war(t("SOV"), t("POL")) or not alive("POL"), "СССР вступил в Польшу") ; check(not w.is_at_war(t("SOV"), t("ENG")), "Союзники не объявили войну СССР"),
		"1940-08-01": func(): check(not alive("EST") and not alive("LAT"), "Прибалтика присоединена к СССР"),
	}
	var end_day := w.day_of(until)
	var t0 := Time.get_ticks_msec()
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		for e in w.events:
			if not quiet:
				print("  %s — %s" % [w.date_string(), e])
		w.events.clear()
		for m in milestones:
			if not marks.has(m) and w.day >= w.day_of(m):
				marks[m] = true
				milestones[m].call()
	print("Итог %s за %d мс: напряжённость %d%%" % [w.date_string(), Time.get_ticks_msec() - t0, w.tension])
	print("Последний тик %.1f мс: %s" % [sim.last_tick_usec / 1000.0, sim.phase_usec])
	var lines: Array = []
	for n in w.nations:
		if n.alive:
			var provs := 0
			for p in w.prov_count:
				if w.p_owner[p] == n.id:
					provs += 1
			lines.append([provs, "%s (%d пров., %d див.%s%s)" % [n.name, provs, n.division_count,
				", война: " + ", ".join(n.at_war.keys().map(func(x): return w.nations[x].name)) if not n.at_war.is_empty() else "",
				", марионетка: " + w.nations[n.overlord].name if n.overlord >= 0 else ""]])
	lines.sort_custom(func(a, b): return a[0] > b[0])
	for l in lines.slice(0, 12):
		print("  ", l[1])
	# баланс: к своей ли дате страны набрали условия событий (100 % — все условия)
	print("Шансы событий (исторический ответ):")
	for r in w.chance_log:
		print("  %s  %-14s %3d %%  %s%s" % [w.date_short(int(r[0])), r[1], int(r[2]), "да " if r[3] else "НЕТ",
			("  не хватало: " + String(r[4])) if String(r[4]) != "" else ""])
		if r.size() > 5:
			print("      ", "; ".join(r[5]))
	if errors == 0:
		print("История: OK")
	quit(1 if errors > 0 else 0)
