extends SceneTree
## Внутренняя политика и гарантии (Politics): шкалы, перевес для гарантий,
## событие «вступиться или нет» у игрока и у ИИ, исторические гарантии,
## деревья марионетки и изгнания, баффы сторон войны.
##   godot --headless --path . --script res://tests/politics_check.gd

var errors := 0
var w: World
var rng := RandomNumberGenerator.new()


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func t(tag: String) -> int:
	return w.nation_tags.find(tag)


func fresh(player: String = "") -> Simulation:
	w = World.new()
	MapLoader.load_world(w)
	w.historical = false
	w.events.clear()
	if player != "":
		w.nations[t(player)].is_player = true
	return Simulation.new(w)


func gcall_ids() -> Array:
	var r: Array = []
	for id in w.event_defs:
		if String(id).begins_with("gcall_"):
			r.append(id)
	return r


func attack(sim: Simulation, a: int, b: int) -> bool:
	w.nations[a].wargoals[b] = true
	w.nations[a].pacts.erase(b)
	w.nations[b].pacts.erase(a)
	var ok := Diplomacy.declare_war(w, a, b)
	sim.tick()   # событие вызова гаранта наступает в ходе дня
	return ok


func _init() -> void:
	# --- 1. Перевес для гарантий ---------------------------------------------
	print("Гарантии — только при перевесе:")
	fresh("ENG")
	var eng := t("ENG")
	var pol := t("POL")
	var lux := t("LUX")
	w.nations[eng].pol_power = 0.0
	check(Diplomacy.can_guarantee(w, eng, pol).begins_with("нужно"), "без ПВ гарантия не даётся: %s" % Diplomacy.can_guarantee(w, eng, pol))
	w.nations[eng].pol_power = 100.0
	check(Diplomacy.can_guarantee(w, eng, pol) == "", "Британия может гарантировать Польшу")
	w.nations[lux].pol_power = 100.0
	var why := Diplomacy.can_guarantee(w, lux, t("BEL"))
	check(why.begins_with("нужна"), "Люксембург не гарантирует Бельгию: %s" % why)
	Diplomacy.guarantee(w, eng, pol)
	check(w.nations[eng].guarantees.has(pol) and not w.nations[eng].guar_hist.has(pol), "гарантия дана (не историческая)")
	check(absf(w.nations[eng].pol_power - 75.0) < 0.01, "гарантия стоит %d ПВ" % int(Politics.COST_GUARANTEE))

	# --- 2. Игрок-гарант вступается ------------------------------------------
	print("Игрок-гарант: вступиться:")
	var sim := fresh("ENG")
	eng = t("ENG")
	pol = t("NOR")
	var ger := t("GER")
	w.nations[eng].pol_power = 100.0
	w.nations[eng].guarantees.clear()
	Diplomacy.guarantee(w, eng, pol)
	var ws_pol: float = w.nations[pol].war_support
	attack(sim, ger, pol)
	check(not w.is_at_war(eng, ger), "Британия не втянута в войну сама")
	var ids := gcall_ids()
	check(ids.size() == 1 and w.pending_events.has(ids[0] if ids.size() > 0 else ""), "игроку пришло событие с выбором")
	check(w.nations[ger].spirits.has("war_initiative") and w.nations[pol].spirits.has("war_homeland"), "черты сторон: «Инициатива нападающего» и «Защита родины»")
	check(w.nations[pol].war_support > ws_pol + 0.1, "поддержка войны у жертвы выросла (%d%% → %d%%)" % [roundi(ws_pol * 100), roundi(w.nations[pol].war_support * 100)])
	var st: float = w.nations[eng].stability
	var divs: int = w.nations[eng].division_count
	if ids.size() > 0:
		w.pending_events.erase(ids[0])
		History.choose_option(w, ids[0], 0, rng)
	check(w.is_at_war(eng, ger), "вступилась: Британия воюет с Германией")
	check(w.nations[eng].stability > st, "стабильность выросла")
	w.rebuild_prov_divs()
	var divs2 := 0
	for d in w.divisions:
		if d.alive and d.owner == eng:
			divs2 += 1
	check(divs2 > divs, "войска: %d → %d дивизий" % [divs, divs2])
	check(w.nations[eng].spirits.has("guar_kept"), "черта «Верность слову»")

	# --- 3. Игрок-гарант остаётся в стороне ----------------------------------
	print("Игрок-гарант: остаться в стороне:")
	sim = fresh("ENG")
	eng = t("ENG")
	pol = t("NOR")
	ger = t("GER")
	w.nations[eng].pol_power = 100.0
	w.nations[eng].guarantees.clear()
	Diplomacy.guarantee(w, eng, pol)
	attack(sim, ger, pol)
	ids = gcall_ids()
	st = w.nations[eng].stability
	var wsu: float = w.nations[eng].war_support
	var pp: float = w.nations[eng].pol_power
	if ids.size() > 0:
		w.pending_events.erase(ids[0])
		History.choose_option(w, ids[0], 1, rng)
	check(not w.is_at_war(eng, ger), "не вступила")
	check(w.nations[eng].stability < st - 0.05 and w.nations[eng].war_support < wsu - 0.05, "стабильность и поддержка войны упали")
	check(w.nations[eng].pol_power < pp - 40.0, "ПВ потеряна (%d → %d)" % [int(pp), int(w.nations[eng].pol_power)])
	check(not w.nations[eng].guarantees.has(pol), "гарантия снята")
	check(w.nations[eng].spirits.has("guar_broken"), "черта «Нарушенное слово»")

	# --- 4. ИИ-гарант, нападает игрок ----------------------------------------
	print("ИИ-гарант при нападении игрока:")
	sim = fresh("GER")
	ger = t("GER")
	var fra := t("FRA")
	var bel := t("BEL")
	w.nations[fra].guarantees.clear()
	w.nations[fra].guar_hist.clear()
	w.nations[fra].pol_power = 100.0
	Diplomacy.guarantee(w, fra, bel)
	var j := Politics.ai_judge(w, fra, bel, ger)
	print("    расчёт: ", j["why"])
	attack(sim, ger, bel)
	sim.tick()
	check(gcall_ids().size() == 1, "ИИ получил событие (не историческая гарантия)")
	check(w.is_at_war(fra, ger) == bool(j["join"]), "решение по расчёту: %s" % ("вступилась" if j["join"] else "отреклась"))
	# заведомый перевес нападающего — отрекается со штрафами
	sim = fresh("GER")
	ger = t("GER")
	fra = t("FRA")
	bel = t("BEL")
	w.nations[fra].guarantees.clear()
	w.nations[fra].guar_hist.clear()
	w.nations[fra].pol_power = 100.0
	Diplomacy.guarantee(w, fra, bel)
	w.nations[ger].civ += 400
	st = w.nations[fra].stability
	attack(sim, ger, bel)
	sim.tick()
	check(not w.is_at_war(fra, ger) and not w.nations[fra].guarantees.has(bel), "перевес Германии: Франция отреклась, гарантия снята")
	check(w.nations[fra].stability < st - 0.05 and w.nations[fra].spirits.has("guar_broken"), "и получила штрафы")
	# историческая гарантия срабатывает сама
	sim = fresh("GER")
	ger = t("GER")
	fra = t("FRA")
	bel = t("BEL")
	w.nations[fra].guarantees.clear()
	Diplomacy.guarantee(w, fra, bel, true)
	attack(sim, ger, bel)
	check(w.is_at_war(fra, ger) and gcall_ids().is_empty(), "историческая гарантия: ИИ вступает сразу, без события")

	# --- 5. Шкалы ------------------------------------------------------------
	print("Шкалы:")
	sim = fresh()
	ger = t("GER")
	var usa := t("USA")
	check(w.nations[ger].stability > 0.6 and w.nations[usa].war_support < 0.45, "старт по строю: Германия стаб. %d%%, США поддержка войны %d%%" % [roundi(w.nations[ger].stability * 100), roundi(w.nations[usa].war_support * 100)])
	for i in 30:
		sim.tick()
	check(w.nations[ger].pol_power > 25.0, "ПВ копится: %d за 30 дней" % int(w.nations[ger].pol_power))
	w.nations[usa].stability = 0.2
	Politics._refresh_mods(w, w.nations[usa])
	check(w.nations[usa].b("industry") < -0.1 and w.nations[usa].b("surrender") > 0.0, "низкая стабильность режет промышленность и приближает сдачу")
	w.nations[usa].is_player = true
	w.nations[usa].war_support = 0.3
	w.tension = 100.0
	check(Diplomacy.can_justify(w, usa, t("MEX")).begins_with("нужна поддержка войны"), "без поддержки войны игрок не обосновывает претензии")
	var take := Politics.take_decision(w, w.nations[usa], "propaganda")
	check(take == "" or take.begins_with("нужно"), "решение «Военная пропаганда»: %s" % (take if take != "" else "принято"))

	# --- 6. Дерево марионетки -------------------------------------------------
	print("Дерево марионетки:")
	sim = fresh()
	pol = t("POL")
	ger = t("GER")
	Puppets.make(w, pol, ger)
	check(History.tree_key(w, pol) == "_puppet", "у новой марионетки дерево марионетки")
	for i in 80:
		sim.tick()
	var nat: World.Nation = w.nations[pol]
	check(nat.focus_done.has("pup_new_gov") and (nat.focus_done.has("pup_loyal") or nat.focus_current == "pup_loyal"), "исторический ИИ идёт путём лояльности (%s)" % nat.focus_current)
	check(not nat.focus_done.has("pup_autonomy"), "путь самостоятельности закрыт развилкой")
	check(History.tree_key(w, t("SLO")) == "SLO", "рождённая марионеткой Словакия ведёт своё дерево")

	# --- 7. Изгнание ----------------------------------------------------------
	print("Правительство в изгнании:")
	sim = fresh()
	var hol := t("HOL")
	ger = t("GER")
	w.set_war(ger, hol)
	w.nations[hol].exile = true
	check(History.tree_key(w, hol) == "HOL+exile", "у изгнанника своё дерево с веткой изгнания")
	var fd := History.focus_def(w, hol, "exl_radio")
	check(not fd.is_empty() and History.focus_open(w, hol, fd), "фокус «Голос из-за моря» доступен")
	var hp: Array = []
	for p in w.prov_count:
		if w.p_owner[p] == hol and w.p_land[p] == 1 and w.p_colony[p] == 0:
			w.p_controller[p] = ger
			hp.append(p)
	Occupation.step(w)
	var r0: float = w.p_resist[hp[0]]
	History.apply(w, hol, [{"t": "resist", "v": 20}], rng)
	check(w.p_resist[hp[0]] > r0 + 19.0, "сопротивление на занятых землях +20 (%d%% → %d%%)" % [roundi(r0), roundi(w.p_resist[hp[0]])])
	History.apply(w, hol, [{"t": "bonus", "key": "resistance", "v": 1.0}], rng)
	var r1: float = w.p_resist[hp[0]]
	Occupation.step(w)
	check(w.p_resist[hp[0]] > r1 or w.occ_garrison.get(Occupation.tkey(ger, hol), 0.0) > 0.0, "бонус сопротивления изгнанника работает")
	w.nations[hol].exile = false
	w.nations[hol].capitulated = true
	check(History.tree_key(w, hol) == "HOL", "сдавшаяся без изгнания страна ветки изгнания не имеет")


	# --- 8. Несколько гарантов ------------------------------------------------
	print("Несколько гарантов:")
	fresh("GER")
	ger = t("GER")
	fra = t("FRA")
	bel = t("BEL")
	eng = t("ENG")
	w.nations[fra].guarantees.clear()
	w.nations[eng].guarantees.clear()
	w.nations[fra].guarantees[bel] = true
	var j1 := Politics.ai_judge(w, fra, bel, ger)
	w.nations[eng].guarantees[bel] = true
	var j2 := Politics.ai_judge(w, fra, bel, ger)
	print("    один гарант: ", j1["why"])
	print("    два гаранта: ", j2["why"])
	check(String(j2["why"]).length() > 0 and String(j2["why"]) != String(j1["why"]), "вторая гарантия Британии входит в расчёт Франции")
	check(Politics.other_guarantors(w, bel, ger, fra) == [eng], "другие гаранты: Британия")
	usa = t("USA")
	w.nations[usa].guarantees[eng] = true
	var chain := Politics.other_guarantors(w, bel, ger, fra)
	check(chain.has(eng) and chain.has(usa), "цепочка: США гарантируют Британию — тоже в расчёте")
	var j3 := Politics.ai_judge(w, fra, bel, ger)
	print("    с цепочкой: ", j3["why"])

	# --- 9. Два отказа — «Позор нации» -----------------------------------------
	print("Два отказа подряд:")
	sim = fresh("ENG")
	eng = t("ENG")
	ger = t("GER")
	w.nations[eng].guarantees.clear()
	for tag in ["NOR", "DEN"]:
		var v := t(tag)
		w.nations[eng].pol_power = 100.0
		Diplomacy.guarantee(w, eng, v)
		check(w.nations[eng].guarantees.has(v), "гарантия стране %s дана" % tag)
		attack(sim, ger, v)
		var gid := ""
		for id in w.pending_events:
			if String(id).begins_with("gcall_"):
				gid = id
		if gid != "":
			w.pending_events.erase(gid)
			History.choose_option(w, gid, 1, rng)
	check(w.nations[eng].spirits.has("national_shame"), "черта «Позор нации»")
	check(w.nations[eng].guarantees.is_empty(), "все гарантии сняты")
	w.nations[eng].pol_power = 100.0
	var ban := Diplomacy.can_guarantee(w, eng, t("BEL"))
	check(ban.begins_with("«Позор нации»"), "новые гарантии запрещены: %s" % ban)
	check(w.nations[eng].guar_ban_until - w.day >= 1090, "запрет на 3 года")

	# --- Законы, влияние шкал, советники (ноябрь 2026) --------------------------
	print("Законы об экономике и призыве:")
	var _sim2 := fresh("FRA")
	var fr2 := t("FRA")
	var nf: World.Nation = w.nations[fr2]
	check(nf.econ_law == 0 and nf.conscr_law == 2, "Франция 1936 г.: гражданская экономика, всеобщая воинская обязанность")
	check(w.nations[t("GER")].econ_law == 2 and w.nations[t("ENG")].conscr_law == 0, "Германия — частичная мобилизация, Британия — добровольцы")
	var cg0 := Politics.consumer_factories(nf)
	check(absf(Politics.consumer_share(nf) - (0.30 + float(nf.pol_bonus.get("cons_goods", 0.0)))) < 1e-6, "товары народного потребления: 30 %% и поправка стабильности (%.2f)" % Politics.consumer_share(nf))
	nf.war_support = 0.2
	check(Politics.law_block(w, nf, "econ", 2).begins_with("нужна поддержка войны 30"), "частичная мобилизация требует 30 % поддержки войны")
	check(Politics.law_block(w, nf, "econ", 4) == "только во время войны", "тотальная мобилизация — только на войне")
	nf.war_support = 0.55
	nf.pol_power = 100.0
	check(Politics.set_law(w, nf, "econ", 3) == "", "военная экономика при 55 % поддержки войны")
	check(nf.pol_power == 50.0, "закон стоит 50 ПВ")
	check(Politics.consumer_factories(nf) < cg0, "товаров народного потребления меньше: %.1f → %.1f" % [cg0, Politics.consumer_factories(nf)])
	var mp0 := nf.b("manpower")
	nf.pol_power = 100.0
	check(Politics.set_law(w, nf, "conscr", 3) == "", "призыв всех годных")
	check(absf(nf.b("manpower") - mp0 - 0.3) < 1e-6 and nf.b("conscription") >= 0.3, "приток людей +30 %, потолок армии выше")

	print("Влияние шкал:")
	var lo := Politics.scale_mods(0.0, 0.0)
	var hi := Politics.scale_mods(1.0, 1.0)
	check(is_equal_approx(hi["attack"], 0.2) and is_equal_approx(hi["defense"], 0.2) and is_equal_approx(hi["occ_suppress"], 0.2), "поддержка войны 100 %: атака, оборона, подавление +20 %")
	check(is_equal_approx(lo["attack"], -0.1), "поддержка войны 0 %: атака −10 %")
	check(hi["mil_build"] > 0.0 and hi["plan_speed"] > 0.0 and hi["xp_land"] > 0.0 and hi["xp_lead"] > 0.0, "поддержка войны: военные заводы, планирование, опыт")
	check(lo["cons_goods"] > 0.0 and hi["cons_goods"] < 0.0, "стабильность меняет товары народного потребления")
	check(lo["construction"] < 0.0 and lo["industry"] < 0.0 and lo["manpower"] < 0.0 and lo["occ_comply"] < 0.0 and lo["war_support"] < 0.0,
		"низкая стабильность: стройка, выпуск, призыв, принятие, поддержка войны ниже")
	var mid := Politics.scale_mods(0.5, 0.5)
	var zero := true
	for k in mid:
		zero = zero and (float(mid[k]) == 0.0 or k == "surrender")
	check(zero, "на 50 % обе шкалы без влияния")
	nf.war_support = 1.0
	nf.stability = 0.5
	Politics.daily(w)
	check(Politics.cp_rate(nf) > Politics.CP_DAY, "КР копится быстрее при высокой поддержке войны: %.2f" % Politics.cp_rate(nf))

	print("Советники:")
	nf.pol_power = 500.0
	nf.command_power = 200.0
	var xp_before := nf.b("xp_land")
	check(Politics.hire(w, nf, "army_chief") == "", "нанят начальник штаба армии")
	check(is_equal_approx(nf.b("xp_land") - xp_before, 0.2), "прибавка опыта армии +20 %")
	check(nf.command_power == 150.0, "военный советник — 50 КР")
	nf.xp[0] = 0.0
	Doctrine.gain(nf, 0, 1.0)
	check(is_equal_approx(nf.xp[0], 1.0 + nf.b("xp_land")), "опыт за бой умножен: %.2f" % nf.xp[0])
	nf.xp[0] = 0.0
	Doctrine.gain(nf, 0, 0.0)
	check(nf.xp[0] == 0.0, "без боёв советник опыта не даёт")
	for id in ["industrialist", "organizer", "lawkeeper"]:
		Politics.hire(w, nf, id)
	check(Politics.advisors_of(nf, false).size() == 3, "три политических советника")
	check(Politics.hire_block(w, nf, "propagandist").begins_with("все 3"), "четвёртого места нет")
	var st0 := nf.b("stability")
	Politics.dismiss(w, nf, "lawkeeper")
	check(is_equal_approx(st0 - nf.b("stability"), 0.05), "отпущенный советник снимает бонус")
	check(Politics.hire(w, nf, "propagandist") == "", "место освободилось")

	print("ИИ: законы на войне:")
	_sim2 = fresh()
	var pl := t("POL")
	var np: World.Nation = w.nations[pl]
	w.historical = true
	np.war_support = 0.6
	w.set_war(t("GER"), pl)
	Politics.ai_laws(w, np)
	check(np.econ_law == 3 and np.conscr_law == 3, "Польша на войне: военная экономика и призыв всех годных (%d, %d)" % [np.econ_law, np.conscr_law])

	print("Политика: %s" % ("OK" if errors == 0 else "ОШИБОК %d" % errors))
	quit(1 if errors > 0 else 0)
