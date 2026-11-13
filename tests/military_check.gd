extends SceneTree
## Военная система: производство, подготовка, бой по родам войск и местности,
## окружение без снабжения, армия игрока (оборона и наступление).
##   godot --headless --path . --script res://tests/military_check.gd

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


func _init() -> void:
	var r := fresh()
	var w: World = r[0]
	var sim: Simulation = r[1]
	var GER := w.nation_tags.find("GER")
	var POL := w.nation_tags.find("POL")
	var ger: World.Nation = w.nations[GER]

	print("Производство и подготовка:")
	ger.is_player = true   # чтобы ИИ не тратил склад на новые дивизии
	var before := ger.stock.duplicate()
	for i in 30:
		sim.tick()
	check(ger.stock[0] > before[0] and ger.stock[2] > before[2], "за 30 дней выросли запасы винтовок (%d→%d) и танков (%d→%d)" % [before[0], ger.stock[0], before[2], ger.stock[2]])
	check(Military.can_train(w, w.nations[POL], Military.T_ARM).contains("технолог"), "Польше без технологии танковые дивизии недоступны")
	ger.stock[Military.EQ_TANK] = 5000.0
	ger.stock[Military.EQ_TRUCK] = 5000.0
	ger.manpower = 500.0
	var n_train := ger.training.size()
	check(Military.start_training(w, ger, Military.T_ARM) and ger.training.size() == n_train + 1, "Германия формирует танковую дивизию")

	print("Бой: танки против пехоты на равнине и в горах:")
	var tank := w.spawn_division(GER, w.nations[GER].capital, Military.T_ARM)
	var inf := w.spawn_division(POL, w.nations[POL].capital, Military.T_INF)
	var mnt := w.spawn_division(POL, w.nations[POL].capital, Military.T_MNT)
	var tmul := w.tpl_terrain
	var plains: float = Military.side_power([tank], World.T_PLAINS, tmul, false)[0]
	var mountains: float = Military.side_power([tank], World.T_MOUNTAIN, tmul, false)[0]
	var inf_att: float = Military.side_power([inf], World.T_PLAINS, tmul, false)[0]
	check(plains > inf_att * 2.0, "танковая атакует втрое сильнее пехотной на равнине (%.1f против %.1f)" % [plains, inf_att])
	check(mountains < plains * 0.6, "в горах танки теряют силу (%.1f против %.1f)" % [mountains, plains])
	var m_def: float = Military.side_power([mnt], World.T_MOUNTAIN, tmul, true)[0]
	var i_def: float = Military.side_power([inf], World.T_MOUNTAIN, tmul, true)[0]
	check(m_def > i_def * 1.3, "горные части в горах держатся лучше пехоты (%.1f против %.1f)" % [m_def, i_def])
	inf.eq = 0.3
	var low: float = Military.side_power([inf], World.T_PLAINS, tmul, true)[0]
	inf.eq = 1.0
	check(low < Military.side_power([inf], World.T_PLAINS, tmul, true)[0] * 0.7, "нехватка снаряжения ослабляет дивизию")
	var full: float = Military.side_power([inf], World.T_PLAINS, tmul, true)[0]
	inf.supply = 0.4
	var p_bad: float = Military.side_power([inf], World.T_PLAINS, tmul, true)[0]
	inf.supply = 0.2
	var p_exh: float = Military.side_power([inf], World.T_PLAINS, tmul, true)[0]
	inf.supply = 1.0
	check(is_equal_approx(p_bad, full * 0.75) and is_equal_approx(p_exh, full * 0.5), "плохое снабжение — сила ×0,75, истощение — ×0,5 (%.1f, %.1f из %.1f)" % [p_bad, p_exh, full])

	print("Ширина фронта:")
	r = fresh()
	w = r[0]
	sim = r[1]
	var fp := -1
	var fq := -1
	for p in w.p_land.size():
		if w.p_land[p] == 1 and w.p_terrain[p] == World.T_PLAINS and w.p_owner[p] == POL:
			for q in w.p_adj[p]:
				if w.p_land[q] == 1 and w.p_owner[q] == POL:
					fp = p
					fq = q
					break
		if fp >= 0:
			break
	w.set_war(GER, POL)
	var defd := w.spawn_division(POL, fp, Military.T_INF)
	var atts := PackedInt32Array()
	for i in 12:
		atts.append(w.spawn_division(GER, fq, Military.T_INF).slot)
	var org0 := defd.org
	w.k_combat(PackedInt32Array([fp]), PackedInt32Array([0, atts.size()]), atts, PackedInt64Array([1]), 0.0)
	var hit := 0
	for i in atts:
		if w.d_org[i] < w.d_morg[i]:
			hit += 1
	var line := int(World.FRONT_WIDTH[World.T_PLAINS] / Military.template_width(w.templates[Military.T_INF]))
	check(hit == line, "на равнине в линии %d пехотных дивизий из 12, остальные в резерве (%d)" % [line, hit])
	check(defd.org < org0 and w.d_battle[atts[11]] == 1, "резерв тоже в бою, защитник получил урон")
	check(Military.template_width(w.templates[Military.T_ART]) == 26.0, "пехотная с артиллерией — ширина 26")
	var arts := PackedInt32Array()
	for i in 5:
		arts.append(w.spawn_division(GER, fq, Military.T_ART).slot)
	var part := PackedFloat64Array()
	var picked := w.front_pick(arts, 100.0, part)
	check(picked.size() == 4 and part[3] > 0.84 and part[3] < 0.85, "ширина 100: три дивизии по 26 целиком, четвёртая — с долей 22/26 (%s)" % [part])

	print("Броня и бронебойность (конструктор танков):")
	var ger2: World.Nation = w.nations[GER]
	check(not TankDesigns.valid(ger2, "light1", ["gun20", "gun20"]), "в проекте танка одна пушка")
	var st := TankDesigns.stats("light1", ["gun20", "mg", "armor"])
	check(is_equal_approx(float(st["armor"]), 16.0) and is_equal_approx(float(st["pierce"]), 15.0), "броня шасси + листы, бронебойность — лучшая из модулей (%s)" % TankDesigns.stats_text(st))
	var tk := w.spawn_division(GER, fp, Military.T_ARM)
	tk.org = tk.max_org
	check(tk.armor >= 10.0 and tk.pierce >= 15.0, "танковая дивизия: броня %.0f, бронебойность %.0f" % [tk.armor, tk.pierce])
	var pol_inf := w.spawn_division(POL, fq, Military.T_INF)
	pol_inf.org = pol_inf.max_org
	defd.alive = false
	w.rebuild_prov_divs()
	check(pol_inf.pierce < tk.armor, "пехота не пробивает танки (бронебойность %.0f < брони %.0f)" % [pol_inf.pierce, tk.armor])
	# Польша атакует танки: без пробития урон пехоты ×0,5
	var w_at := PackedInt32Array([pol_inf.slot])
	var t0 := tk.org
	var ps0 := pol_inf.strength
	var po0 := pol_inf.org
	var ts0 := tk.strength
	var pe0 := pol_inf.eq
	var te0 := tk.eq
	w.set_war(POL, GER)
	w.k_combat(PackedInt32Array([fp]), PackedInt32Array([0, 1]), w_at, PackedInt64Array([7]), 0.0)
	var loss_cut := t0 - tk.org
	tk.org = t0
	tk.strength = ts0
	pol_inf.strength = ps0
	pol_inf.org = po0
	pol_inf.eq = pe0
	tk.eq = te0
	var pr0 := pol_inf.pierce
	pol_inf.pierce = 100.0
	w.k_combat(PackedInt32Array([fp]), PackedInt32Array([0, 1]), w_at, PackedInt64Array([7]), 0.0)
	var loss_full := t0 - tk.org
	pol_inf.pierce = pr0
	check(loss_cut > 0.0 and is_equal_approx(loss_cut * 2.0, loss_full), "без пробития урон по танкам вдвое меньше (%.2f против %.2f)" % [loss_cut, loss_full])
	var at_t := w.templates.size()
	w.templates.append(Military.make_template("Пехотная с ПТО", "п+пто", [9, 0, 0, 0, 0, 0, 1], POL))
	Military.build_tables(w)
	var at_d := w.spawn_division(POL, fq, at_t)
	check(at_d.pierce > 15.0 and at_d.pierce > pol_inf.pierce, "батальон ПТО поднимает бронебойность пехоты (%.1f против %.1f)" % [at_d.pierce, pol_inf.pierce])

	print("Экономика: ПТО, выпуск, эффективность, нормы ресурсов:")
	var at_eq: Array = Military.BATTALIONS[Military.B_AT]["eq"]
	check(float(at_eq[Military.EQ_AT]) > 0.0 and float(at_eq[Military.EQ_ART]) == 0.0, "батальон ПТО — из противотанковых пушек, не из артиллерии")
	var inf_eq: Array = Military.BATTALIONS[Military.B_INF]["eq"]
	check(float(inf_eq[Military.EQ_INF]) == 100.0, "пехотный батальон — 100 единиц стрелкового на 1000 человек")
	var all_int := true
	for row in Economy.RES_NEED:
		for v in row:
			all_int = all_int and float(v) == floorf(float(v))
	check(all_int, "нормы ресурсов на завод — целые")
	var pn: World.Nation = w.nations[POL]
	pn.lines = []
	var mil0 := pn.mil
	pn.mil = 10
	Military._add_to_line(pn, Military.EQ_INF, 10)
	var st0 := pn.stock[Military.EQ_INF]
	pn.res_fill.fill(1.0)
	Military.produce(pn)
	var want_u := 10.0 * Military.factory_points(pn, Military.EFF_START) / float(Military.EQ_COST[Military.EQ_INF])
	check(absf(pn.stock[Military.EQ_INF] - st0 - want_u) < 0.05 * want_u, "10 заводов при %d%% дают %.0f стрелкового в день (ожидалось %.0f)" % [
		roundi(Military.EFF_START * 100.0), pn.stock[Military.EQ_INF] - st0, want_u])
	for i in 400:
		Military.produce(pn)
	var cap := Military.eff_cap(pn)
	check(absf(float(pn.lines[0][2]) - cap) < 0.01, "эффективность растёт к потолку %d%% (%d%%)" % [roundi(cap * 100.0), roundi(float(pn.lines[0][2]) * 100.0)])
	Military._shift_lines(pn, [0.5, 0, 0, 0, 0.5, 0, 0, 0])
	var at_line := -1.0
	for ln in pn.lines:
		if int(ln[0]) == Military.EQ_AT:
			at_line = float(ln[2])
	check(at_line > Military.EFF_START and at_line < cap, "переведённые заводы сохраняют часть эффективности (%d%%)" % roundi(at_line * 100.0))
	pn.mil = mil0

	print("Роты поддержки:")
	var base_t := Military.make_template("Пехотная", "п", [9, 0, 0, 0, 0, 0, 0], POL)
	var sup_t := Military.make_template("Пехотная с ротами", "п+р", [9, 0, 0, 0, 0, 0, 0], POL, ["eng", "art", "rec", "sig", "aa", "med"])
	check(Military.template_support(sup_t).size() == Military.SUPPORT_MAX, "в шаблоне не больше %d рот (%d)" % [Military.SUPPORT_MAX, Military.template_support(sup_t).size()])
	check(Military.template_width(sup_t) == Military.template_width(base_t), "роты не занимают ширину фронта (%.0f)" % Military.template_width(sup_t))
	check(float(sup_t["men"]) > float(base_t["men"]) and float(sup_t["eq"][Military.EQ_INF]) > float(base_t["eq"][Military.EQ_INF]), "роты берут людей и снаряжение")
	check((sup_t["req"] as Array).has("eng1"), "сапёрная рота требует технологию «Сапёрные роты»")
	var b_i := w.templates.size()
	w.templates.append(base_t)
	w.templates.append(sup_t)
	Military.build_tables(w)
	var pnat: World.Nation = w.nations[POL]
	var d_b := w.spawn_division(POL, pnat.capital, b_i)
	var d_s := w.spawn_division(POL, pnat.capital, b_i + 1)
	check(d_s.def > d_b.def * 1.05 and d_s.atk > d_b.atk and d_s.spd > d_b.spd, "сапёры, батарея и разведка: оборона %.1f→%.1f, атака %.1f→%.1f, скорость %.3f→%.3f" % [d_b.def, d_s.def, d_b.atk, d_s.atk, d_b.spd, d_s.spd])
	check(w.tpl_sc[(b_i + 1) * Military.SC_K] == 1.5 and w.tpl_sc[(b_i + 1) * Military.SC_K + 1] == 0.5, "в таблице шаблонов: окопы ×1,5, защита от штурмовиков 50 %")
	var was_player := pnat.is_player
	pnat.is_player = true   # ИИ не двигает дивизии — окапываются стоящие
	for i in 30:
		sim.tick()
	pnat.is_player = was_player
	check(d_s.entrench > 1.0 and d_b.entrench <= 1.0, "с сапёрами окопы глубже (%d%% против %d%%)" % [roundi(d_s.entrench * 100.0), roundi(d_b.entrench * 100.0)])
	var at_t2 := Military.make_template("П+птб", "п", [9, 0, 0, 0, 0, 0, 0], POL, ["at"])
	var ap0 := Military.armor_pierce(pnat, base_t["bat"], TankDesigns.FALLBACK)
	var ap1 := Military.armor_pierce(pnat, at_t2["bat"], TankDesigns.FALLBACK, float(at_t2["fx"]["pierce"]))
	check(ap1[1] > ap0[1] + 10.0, "противотанковая батарея поднимает бронебойность (%.1f → %.1f)" % [ap0[1], ap1[1]])
	# переучивание: дивизия без рот → шаблон с ротами; люди и снаряжение пересчитаны, организация — половина
	check(Military.retrain_block(w, d_b, b_i + 1).contains("технолог") or pnat.techs.has("rad2"), "без технологий рот переучить нельзя")
	for r_ in sup_t["req"]:
		pnat.techs[r_] = true
	var men0 := pnat.manpower
	var org_before := d_b.org
	check(Military.retrain(w, d_b, b_i + 1) and d_b.tpl == b_i + 1, "дивизия переучена в шаблон с ротами")
	check(d_b.strength < 100.0 and d_b.eq < 1.0 and d_b.org <= d_b.max_org * Military.RETRAIN_ORG + 1e-6 and org_before > d_b.org,
		"после переучивания недокомплект (сила %d%%, снаряжение %d%%), организация %d%% — дойдёт пополнением" % [roundi(d_b.strength), roundi(d_b.eq * 100.0), roundi(100.0 * d_b.org / d_b.max_org)])
	check(Military.retrain_block(w, d_b, b_i + 1) != "", "на тот же шаблон переучить нельзя")
	check(Military.retrain(w, d_b, b_i) and pnat.manpower > men0 - 0.01, "обратно — лишние люди и снаряжение возвращаются (призывники %.1f → %.1f)" % [men0, pnat.manpower])

	# ИИ берёт роту, только если выпускает её снаряжение (решение пользователя)
	var lines0: Array = pnat.lines.duplicate(true)
	pnat.lines = [[Military.EQ_INF, 5, 0.5]]
	var s1 := Military.ai_support(w, pnat)
	pnat.lines = [[Military.EQ_INF, 5, 0.5], [Military.EQ_ART, 2, 0.5], [Military.EQ_TRUCK, 2, 0.5]]
	var s2 := Military.ai_support(w, pnat)
	pnat.lines = lines0
	check(s1.has("eng") and not s1.has("art") and not s1.has("med") and s2.has("art") and s2.has("rec") and s2.size() > s1.size(),
		"ИИ берёт роты только под выпускаемое снаряжение (только винтовки: %s; + орудия и грузовики: %s)" % [s1, s2])
	print("Окружение:")
	r = fresh()
	w = r[0]
	sim = r[1]
	w.set_war(GER, POL)
	var pocket := -1
	for d in w.divisions_of(POL):
		if w.p_controller[d.prov] == POL and d.prov != w.nations[POL].capital:
			pocket = d.prov
			break
	for q in w.p_adj[pocket]:
		if w.p_land[q] == 1:
			w.p_controller[q] = GER
	# поле снабжения считается упреждением по вчерашней территории — котёл
	# чувствуется со второго дня; остаётся лишь урезанное местное снабжение
	for i in 2:
		for q in w.p_adj[pocket]:
			if w.p_land[q] == 1:
				w.p_controller[q] = GER
		sim.tick()
	var trapped: Array = []
	for d in w.divs_in(pocket):
		if d.owner == POL:
			trapped.append(d)
	check(not trapped.is_empty() and trapped[0].supply < 0.5, "дивизии в котле почти без снабжения (%s, %d%%)" % [w.p_name[pocket], roundi(100.0 * (trapped[0].supply if not trapped.is_empty() else 1.0))])
	for i in 10:
		for q in w.p_adj[pocket]:
			if w.p_land[q] == 1:
				w.p_controller[q] = GER
		sim.tick()
	check(trapped[0].strength < 100.0, "в котле дивизия теряет силы (%.0f%%)" % trapped[0].strength)

	print("Армия игрока: держать границу, затем наступать на Варшаву:")
	r = fresh()
	w = r[0]
	sim = r[1]
	ger = w.nations[GER]
	ger.is_player = true
	var ger_divs := w.divisions_of(GER)
	var g := sim.create_group(GER, ger_divs)
	g.enemy = POL
	g.mode = "hold"
	for i in 40:
		sim.tick()
	var on_border := 0
	for d in w.divisions_of(GER):
		for q in w.p_adj[d.prov]:
			if w.p_controller[q] == POL:
				on_border += 1
				break
	check(on_border >= ger_divs.size() * 0.6, "армия встала на польской границе: %d из %d" % [on_border, ger_divs.size()])
	ger.wargoals[POL] = true
	ger.pacts.erase(POL)
	w.nations[POL].pacts.erase(GER)
	Diplomacy.declare_war(w, GER, POL)
	g.mode = "attack"
	var warsaw: int = w.nations[POL].capital
	g.objective = warsaw
	var taken_max := 0
	for i in 200:
		sim.tick()
		var taken := 0
		for p in w.prov_count:
			if w.p_owner[p] == POL and w.p_controller[p] == GER:
				taken += 1
		taken_max = maxi(taken_max, taken)
		if not w.pending_peace.is_empty():
			break
	print("  за %d дней занято польских провинций: %d, Польша %s" % [w.day - 40, taken_max,
		"капитулировала" if not w.pending_peace.is_empty() else "держится"])
	check(taken_max >= 5, "наступление армии продвигается вглубь Польши")
	_check_leaders()
	if errors == 0:
		print("Военная система: OK")
	quit(1 if errors > 0 else 0)


## Командиры: армии ИИ до 24 дивизий под закреплёнными генералами, маршал — до 4
## армий; новая дивизия — в армию с местом; бонусы армии игрока.
func _check_leaders() -> void:
	print("Командиры:")
	var r := fresh()
	var w: World = r[0]
	var sim: Simulation = r[1]
	var SOV := w.nation_tags.find("SOV")
	var cnt := {}
	var subs := {}
	var none := 0
	for d in w.divisions_of(SOV):
		if d.lead < 0:
			none += 1
		else:
			cnt[d.lead] = int(cnt.get(d.lead, 0)) + 1
	var over := 0
	for g in cnt:
		if int(cnt[g]) > Leaders.ARMY_MAX:
			over += 1
		var b: int = w.commanders[g].boss
		if b >= 0:
			subs[b] = int(subs.get(b, 0)) + 1
	var over_m := 0
	for m in subs:
		if int(subs[m]) > Leaders.FRONT_MAX:
			over_m += 1
	print("  СССР: дивизий %d, армий %d, групп армий %d, без генерала %d" % [w.divisions_of(SOV).size(), cnt.size(), subs.size(), none])
	check(none == 0 and over == 0 and over_m == 0, "у ИИ все дивизии в армиях до %d, у маршала до %d армий" % [Leaders.ARMY_MAX, Leaders.FRONT_MAX])
	check(w.commanders[cnt.keys()[0]].name != "" and Leaders.of_nation(w, SOV, false).any(func(c): return c.name == "Георгий Жуков"), "исторические генералы из commanders.json")
	var before := {}
	for d in w.divisions_of(SOV):
		before[d.id] = d.lead
	var nd := w.spawn_division(SOV, w.nations[SOV].capital, Military.T_INF)
	for i in 35:
		sim.tick()
	var moved := 0
	for d in w.divisions_of(SOV):
		if before.has(d.id) and int(before[d.id]) != d.lead:
			moved += 1
	check(moved == 0, "за месяц ИИ не переназначил генералов старых дивизий (сменилось %d)" % moved)
	check(nd.lead >= 0, "новая дивизия ИИ сразу в армии (генерал %s)" % (w.commanders[nd.lead].name if nd.lead >= 0 else "нет"))
	# армия игрока: генерал и маршал дают бонус к атаке
	var GER := w.nation_tags.find("GER")
	w.nations[GER].is_player = true
	var divs: Array = w.divisions_of(GER).slice(0, 30)
	var g1 := sim.create_group(GER, divs.slice(0, Leaders.ARMY_MAX))
	var g2 := sim.create_group(GER, divs.slice(Leaders.ARMY_MAX))
	Leaders.auto_general(w, g1)
	Leaders.auto_general(w, g2)
	var f := Leaders.create_front(w, GER, [g1, g2])
	sim.tick()
	var d0: World.Division = divs[0]
	var c: World.Commander = w.commanders[g1.general]
	var m: World.Commander = w.commanders[f.marshal]
	var want := (1.0 + Leaders.ATK_K * c.atk) * (1.0 + Leaders.ATK_K * m.atk * Leaders.MARSHAL_K)
	print("  %s: генерал %s, маршал %s, атака ×%.3f" % [g1.name, c.name, m.name, w.ld_atk[d0.slot]])
	check(absf(w.ld_atk[d0.slot] - want) < 1e-9 and g1.general != g2.general, "бонус генерала и маршала у дивизии армии игрока")
	Leaders.disband_front(w, f)
	sim.disband_group(g1)
	sim.tick()
	check(w.ld_gen[d0.slot] < 0 and w.ld_atk[d0.slot] == 1.0, "вне армии — без бонуса")
