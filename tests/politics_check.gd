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

	print("Политика: %s" % ("OK" if errors == 0 else "ОШИБОК %d" % errors))
	quit(1 if errors > 0 else 0)
