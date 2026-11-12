extends SceneTree
## Склады и пункты снабжения по странам раз в месяц: участки за морем, дивизии
## там и их снабжение, склады (запас, доля), конвои (снабжение / снаряжение / торговля).
##   godot --headless --path . --script res://tests/depot_diag.gd -- --until=1941-06-01 --from=1940-01-01 --tags=ITA,ENG [--seed=N]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1941-01-01"
	var from := "1936-01-01"
	var tags := ["ITA"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--from="):
			from = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var end_day := w.day_of(until)
	var from_day := w.day_of(from)
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		if w.day < from_day or not w.date_short().begins_with("01."):
			continue
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var nat: World.Nation = w.nations[n]
			var stv := 0.0
			for k in Military.EQ_LAND:
				stv += nat.stock[k] * Military.EQ_COST[k]
			print("%s %s запас %.0f конв %.0f (снаб %.0f, снар %.0f/%.0f, торг %.0f)" % [w.date_short(), tg, stv, nat.convoys, nat.conv_sup_need, nat.conv_eq_use, nat.conv_eq_need, nat.conv_trade_need])
			# участки за морем: дивизии и их снабжение
			var by := {}
			for d in w.divisions:
				if d.alive and d.owner == n and Depots.overseas(w, n, d.prov):
					var c := w.p_comp[d.prov]
					if not by.has(c):
						by[c] = [0, 0.0, 0.0, w.p_adm0[d.prov]]
					by[c][0] += 1
					by[c][1] += d.supply
					by[c][2] += d.eq
			for c in by:
				var v: Array = by[c]
				var deps := []
				for p in w.dep_stock:
					if int(w.dep_owner[p]) == n and w.p_comp[p] == c:
						deps.append("%s %.0f (доля %.0f%%, подача %.0f%%)" % [w.p_name[p], Depots._value(w.dep_stock[p]), 100.0 * float(w.dep_want.get(p, 0.0)), 100.0 * w.p_dsup[p]])
				print("   участок %s: дивизий %d сн %d%% осн %d%% | склады: %s" % [v[3], v[0], roundi(100 * v[1] / v[0]), roundi(100 * v[2] / v[0]), ", ".join(deps) if not deps.is_empty() else "нет"])
	quit(0)
