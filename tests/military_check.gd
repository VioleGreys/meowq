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
	var before := ger.stock.duplicate()
	for i in 30:
		sim.tick()
	check(ger.stock[0] > before[0] and ger.stock[2] > before[2], "за 30 дней выросли запасы винтовок (%d→%d) и танков (%d→%d)" % [before[0], ger.stock[0], before[2], ger.stock[2]])
	check(Military.can_train(w.nations[POL], Military.T_ARM).contains("технолог"), "Польше без технологии танковые дивизии недоступны")
	ger.stock[Military.EQ_TANK] = 500.0
	ger.stock[Military.EQ_TRUCK] = 500.0
	ger.manpower = 500.0
	var n_train := ger.training.size()
	check(Military.start_training(ger, Military.T_ARM) and ger.training.size() == n_train + 1, "Германия формирует танковую дивизию")

	print("Бой: танки против пехоты на равнине и в горах:")
	var tank := World.Division.new()
	tank.owner = GER
	tank.tpl = Military.T_ARM
	Military.refresh_division(w, tank)
	var inf := World.Division.new()
	inf.owner = POL
	inf.tpl = Military.T_INF
	Military.refresh_division(w, inf)
	var mnt := World.Division.new()
	mnt.owner = POL
	mnt.tpl = Military.T_MNT
	Military.refresh_division(w, mnt)
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
	sim.tick()
	var trapped: Array = []
	for d in w.prov_divs[pocket]:
		if d.owner == POL:
			trapped.append(d)
	check(not trapped.is_empty() and trapped[0].supply == 0.0, "дивизии в котле без снабжения (%s)" % w.p_name[pocket])
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
	if errors == 0:
		print("Военная система: OK")
	quit(1 if errors > 0 else 0)
