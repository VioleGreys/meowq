extends SceneTree
## Конец войны и мирные переговоры (Peace): капитуляция в оккупацию, конец
## конфликта, переговоры по кругам у ИИ и у игрока, правительство в изгнании.
##   godot --headless --path . --script res://tests/peace_check.gd

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


func war(a: int, b: int) -> void:
	w.nations[a].at_war[b] = true
	w.nations[b].at_war[a] = true
	w.war[a * w.nation_count + b] = 1
	w.war[b * w.nation_count + a] = 1


func fresh() -> Simulation:
	w = World.new()
	MapLoader.load_world(w)
	for e in w.events:
		pass
	w.events.clear()
	return Simulation.new(w)


func provs_of(n: int) -> Array:
	var r: Array = []
	for p in w.prov_count:
		if w.p_owner[p] == n and w.p_land[p] == 1:
			r.append(p)
	return r


func _init() -> void:
	# --- 1. Раздел между двумя победителями (ИИ) ------------------------------
	print("Польша против Германии и СССР:")
	fresh()
	var ger := t("GER")
	var sov := t("SOV")
	var pol := t("POL")
	war(ger, pol)
	war(sov, pol)
	var pp := provs_of(pol)
	pp.sort_custom(func(a, b): return w.p_lonlat[a].x < w.p_lonlat[b].x)
	for i in pp.size():
		w.p_controller[pp[i]] = ger if i < pp.size() / 2 else sov
	w.nations[ger].war_score = 100.0
	w.nations[sov].war_score = 60.0
	Peace.capitulate(w, pol, ger)
	check(w.nations[pol].capitulated and w.nations[pol].alive, "Польша сдалась и ждёт переговоров")
	Peace.check_end(w)
	check(w.conference.is_empty(), "переговоры прошли сразу (одни ИИ)")
	var g := 0
	var s := 0
	var other := 0
	for p in pp:
		if w.p_owner[p] == ger:
			g += 1
		elif w.p_owner[p] == sov:
			s += 1
		else:
			other += 1
		if w.p_controller[p] != w.p_owner[p]:
			other += 1000
	print("  Германия %d, СССР %d, осталось/прочее %d из %d" % [g, s, other, pp.size()])
	check(g > 0 and s > 0, "земли делят оба победителя")
	check(other < 1000, "после мира контроль у владельцев")
	check(not w.is_at_war(ger, pol) and not w.is_at_war(sov, pol), "войны окончены")
	check(not w.nations[pol].capitulated, "флаг капитуляции снят")
	check(w.nations[ger].war_score == 0.0, "вклад обнулён")

	# --- 2. Ход игрока: освобождение со сменой строя ------------------------
	print("Игрок (Великобритания) против Италии:")
	var sim := fresh()
	var eng := t("ENG")
	var ita := t("ITA")
	w.nations[eng].is_player = true
	war(eng, ita)
	for p in provs_of(ita):
		if w.p_colony[p] == 0:
			w.p_controller[p] = eng
	Peace.capitulate(w, ita, eng)
	Peace.check_end(w)
	check(not w.pending_peace.is_empty() and Peace.current(w) == eng, "переговоры ждут хода игрока")
	var budget: float = w.conference["budget"][eng]
	check(Peace.can_do(w, eng, "free", ita), "освобождение по карману (очков %d, цена %d)" % [budget, Peace.price(w, eng, "free", ita)])
	sim.resolve_peace("free", ita)
	check(w.conference.is_empty() and w.pending_peace.is_empty(), "переговоры закончены")
	check(w.nations[ita].alive and w.nations[ita].ideology == "democracy" and w.nations[ita].overlord < 0, "Италия свободна, строй — демократия")
	check(not w.is_at_war(eng, ita), "мир")

	# --- 3. Правительство в изгнании -----------------------------------------
	print("Нидерланды: изгнание; Дания — без него:")
	sim = fresh()
	ger = t("GER")
	var hol := t("HOL")
	eng = t("ENG")
	var den := t("DEN")
	war(ger, hol)
	war(ger, eng)
	war(ger, den)
	for p in provs_of(hol):
		if w.p_colony[p] == 0:
			w.p_controller[p] = ger
	check(Diplomacy.try_exile(w, hol, ger), "Нидерланды уходят в изгнание")
	check(w.p_colony[w.nations[hol].capital] == 1, "столица — в колонии (%s)" % w.p_name[w.nations[hol].capital])
	var metro_kept := true
	for p in provs_of(hol):
		if w.p_colony[p] == 0 and w.p_owner[p] != hol:
			metro_kept = false
	check(metro_kept, "метрополия остаётся за страной до мира")
	for p in provs_of(den):
		if w.p_colony[p] == 0:
			w.p_controller[p] = ger
	check(not Diplomacy.try_exile(w, den, ger), "Дания в Гренландию не уходит")

	# --- 4. Оккупация: сопротивление, гарнизон, законы, интеграция -----------
	print("Оккупация Польши Германией:")
	sim = fresh()
	ger = t("GER")
	pol = t("POL")
	war(ger, pol)
	var pp2 := provs_of(pol)
	for p in pp2:
		w.p_controller[p] = ger
	sim._refresh_sides()
	Peace.capitulate(w, pol, ger)
	var k := Occupation.tkey(ger, pol)
	w.nations[ger].is_player = true   # без ИИ-гарнизона
	Occupation.step(w)
	var s0 := Occupation.stats(w, k)
	var nc_pol := 0
	for p in pp2:
		if not Claims.is_core(w, ger, p):
			nc_pol += 1
	check(int(s0[0]) == nc_pol, "территория — провинции Польши, кроме национальной земли Германии (%d)" % s0[0])
	pp2 = pp2.filter(func(p): return not Claims.is_core(w, ger, p))
	for i in 36:
		w.day += Occupation.STEP
		Occupation.step(w)
	var s1 := Occupation.stats(w, k)
	print("  без гарнизона за 180 дней: сопротивление %.0f%%, принятие %.0f%%, отдача %.0f%%" % [s1[1], s1[2], s1[3] * 100.0])
	check(s1[1] > 15.0, "без гарнизона сопротивление растёт")
	w.nations[ger].manpower = 5000.0
	w.nations[ger].stock[Military.EQ_INF] = 50000.0
	Occupation.set_garrison(w, k, ceilf(float(w.occ_need[k])))
	check(float(w.occ_garrison[k]) >= float(w.occ_need[k]), "гарнизон набран (%d)" % int(w.occ_garrison[k]))
	for i in 36:
		w.day += Occupation.STEP
		Occupation.step(w)
	var s2 := Occupation.stats(w, k)
	print("  с гарнизоном ещё 180 дней: сопротивление %.0f%%, принятие %.0f%%" % [s2[1], s2[2]])
	check(s2[1] < s1[1], "гарнизон гасит сопротивление")
	# жёсткие законы — сразу больше, мягкие — меньше
	var p0: int = pp2[0]
	w.occ_law[k] = 3
	Occupation.step(w)
	var y_hard := w.p_yield[p0]
	w.occ_law[k] = 0
	Occupation.step(w)
	var y_soft := w.p_yield[p0]
	check(y_hard > y_soft, "жёсткие законы дают больше сразу (%.0f%% против %.0f%%)" % [y_hard * 100.0, y_soft * 100.0])
	# мир, аннексия, интеграция — до 100 %
	w.nations[ger].is_player = false
	Peace.start(w, [ger], [pol])
	w.nations[ger].is_player = true
	var annexed := 0
	var remembered := 0
	for p in pp2:
		if w.p_owner[p] == ger:
			annexed += 1
			if w.p_from[p] == pol:
				remembered += 1
	check(annexed == remembered, "присоединённое помнит прежнего владельца (%d из %d)" % [remembered, annexed])
	var pa := -1
	for p in pp2:
		if w.p_owner[p] == ger:
			pa = p
			break
	if pa >= 0:
		w.occ_law[k] = 0
		w.occ_integrate[k] = true
		Occupation.set_garrison(w, k, ceilf(float(w.occ_need.get(k, 50.0))) + 20.0)
		for i in 300:
			w.day += Occupation.STEP
			Occupation.step(w)
		print("  мягкие законы + интеграция, 1500 дней: принятие %.0f%%, отдача %.0f%%" % [w.p_comply[pa], w.p_yield[pa] * 100.0])
		check(w.p_yield[pa] > 0.95, "полная отдача достижима")
		var inc := w.compute_all_income()
		var civ0: int = inc[ger][0]
		Occupation.adjust_income(w, inc)
		check(int(inc[ger][0]) <= civ0, "интеграция и отдача учтены в доходе (%d → %d)" % [civ0, inc[ger][0]])

	# --- 5. Марионетки: отчисления и свобода -----------------------------------
	print("Марионетки:")
	fresh()
	ger = t("GER")
	pol = t("POL")
	var np: World.Nation = w.nations[pol]
	np.overlord = ger
	np.puppet_since = w.day
	np.freedom = Puppets.START_FREEDOM
	check(absf(Puppets.share(w, pol) - 0.5) < 0.001, "первый год — 50 %")
	w.day += 400
	check(absf(Puppets.share(w, pol) - 0.3) < 0.001, "потом — 30 %")
	np.freedom = 0.0
	check(absf(Puppets.share(w, pol) - 0.9) < 0.001, "без свободы — 90 %")
	np.freedom = 100.0
	check(Puppets.share(w, pol) == 0.0, "полная свобода — ничего")
	np.freedom = 50.0
	var inc2 := w.compute_all_income()
	var pc0: int = inc2[pol][0]
	var gc0: int = inc2[ger][0]
	Puppets.adjust_income(w, inc2)
	check(int(inc2[pol][0]) < pc0 and int(inc2[ger][0]) - gc0 == pc0 - int(inc2[pol][0]), "фабрики марионетки уходят сюзерену (%d → %d)" % [pc0, inc2[pol][0]])
	Peace.add_score(w, pol, 40.0)
	check(np.freedom > 50.0, "вклад в войну поднимает свободу (%.0f)" % np.freedom)
	var f1 := np.freedom
	w.nations[ger].stock[Military.EQ_INF] = 10000.0
	Relations.give_aid(w, ger, pol)
	check(np.freedom < f1, "помощь сюзерена снижает свободу")
	f1 = np.freedom
	w.nations[ger].build_puppet = pol
	check(Puppets.build_in(w, w.nations[ger], pol) and np.freedom < f1, "стройка сюзерена снижает свободу")

	# --- 6. Национальные территории ---------------------------------------
	print("Национальные территории:")
	fresh()
	ger = t("GER")
	pol = t("POL")
	sov = t("SOV")
	for tag in ["GER", "HUN", "BUL", "LIT", "CHI"]:
		var n := t(tag)
		var extra := 0
		for ck in w.cores:
			if int(ck) % 4096 == n and w.p_owner[int(ck) / 4096] != n:
				extra += 1
		print("  %s: чужих провинций в претензиях %d" % [tag, extra])
		check(extra > 0, "у %s есть претензии с 1936 г." % tag)
	var before := 0
	for p in provs_of(pol):
		if Claims.is_core(w, sov, p):
			before += 1
	History.apply(w, sov, [{"t": "claim", "area": "east_poland"}], Parallel.rng(1, 1, 1))
	var after := 0
	for p in provs_of(pol):
		if Claims.is_core(w, sov, p):
			after += 1
	check(before == 0 and after > 0, "фокус даёт претензии (СССР на восток Польши: %d пров.)" % after)
	# переговоры: национальная земля за полцены и сразу интегрирована
	war(ger, pol)
	for p in provs_of(pol):
		w.p_controller[p] = ger
	Peace.capitulate(w, pol, ger)
	w.nations[ger].is_player = true
	Peace.start(w, [ger], [pol])
	var cf: Dictionary = w.conference
	var core_u := -1
	var best_sh := 0.0
	for u in (cf["u_owner"] as PackedInt32Array).size():
		var sh := Claims.share(w, ger, cf["u_provs"][u])
		if sh > best_sh:
			best_sh = sh
			core_u = u
	check(core_u >= 0, "есть участок с национальной землёй Германии (доля %.2f)" % best_sh)
	# всё занято Германией: ×0,75; национальная доля — ещё × (1 − 0,5 × доля)
	var r1 := Peace.unit_price(w, core_u, ger) / float(cf["u_cost"][core_u])
	check(absf(r1 - 0.75 * (1.0 - 0.5 * best_sh)) < 0.01, "скидка 50%% на национальную землю (цена %.2f от стоимости)" % r1)
	var cp: PackedInt32Array = cf["u_provs"][core_u]
	Peace.act(w, ger, "annex", core_u)
	if not w.conference.is_empty():
		Peace.act(w, ger, "done")
	var integ := 0
	var bad := 0
	var cp0 := -1
	for p in cp:
		if not Claims.is_core(w, ger, p):
			continue
		if w.p_owner[p] == ger and w.p_from[p] == -1 and Occupation.key_of(w, p) < 0:
			integ += 1
			cp0 = p
		else:
			bad += 1
	check(integ > 0 and bad == 0, "после мира национальная земля сразу часть страны (%d пров.)" % integ)
	Occupation.step(w)
	check(cp0 >= 0 and w.p_yield[cp0] == 1.0, "отдача национальной земли — 100 %%")

	print("ОШИБОК: %d" % errors if errors > 0 else "Мир: OK")
	quit(1 if errors > 0 else 0)
