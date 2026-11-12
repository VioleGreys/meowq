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

	print("ОШИБОК: %d" % errors if errors > 0 else "Мир: OK")
	quit(1 if errors > 0 else 0)
