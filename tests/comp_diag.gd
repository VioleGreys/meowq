extends SceneTree
## Участки суши страны (связная земля стороны) раз в N дней: провинций, дивизий,
## их снабжение и снаряжение, пункты снабжения участка и их подача; доля земли.
##   godot --headless --path . --script res://tests/comp_diag.gd -- --from=1936-07-17 --until=1937-01-01 --tags=NSP,SPR [--step=7 --seed=N --brief]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1937-01-01"
	var from := "1936-07-17"
	var tags := ["NSP", "SPR"]
	var step := 7
	var brief := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--from="):
			from = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
		if a.begins_with("--step="):
			step = int(a.split("=")[1])
		if a == "--brief":
			brief = true
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var end_day := w.day_of(until)
	var from_day := w.day_of(from)
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		if w.day < from_day or (w.day - from_day) % step != 0:
			continue
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var nat: World.Nation = w.nations[n]
			var stv := 0.0
			for k in Military.EQ_LAND:
				stv += nat.stock[k] * Military.EQ_COST[k]
			var by := {}   # участок -> [провинций, дивизий, снабжение, снаряжение, пункты]
			for p in w.prov_count:
				if w.p_controller[p] == n and w.p_comp[p] >= 0:
					var c := w.p_comp[p]
					if not by.has(c):
						by[c] = [0, 0, 0.0, 0.0, [], p]
					by[c][0] += 1
					if Depots.is_depot(w, p):
						by[c][4].append("%s %.0f%%%s" % [w.p_name[p], 100.0 * w.p_dsup[p], (" склад %.0f" % Depots._value(w.dep_stock[p])) if w.dep_stock.has(p) else ""])
			for d in w.divisions:
				if d.alive and d.owner == n and by.has(w.p_comp[d.prov]):
					var v: Array = by[w.p_comp[d.prov]]
					v[1] += 1
					v[2] += d.supply
					v[3] += d.eq
			var np := 0
			for p in w.prov_count:
				if w.p_controller[p] == n:
					np += 1
			var nd := 0
			for d in w.divisions:
				if d.alive and d.owner == n:
					nd += 1
			print("%s %s: провинций %d, дивизий %d, запас %.0f, воен %d, черты %s" % [w.date_short(), tg, np, nd, stv, nat.mil, ",".join(nat.spirits.keys())])
			if brief:
				continue
			for c in by:
				var v: Array = by[c]
				if v[0] < 2 and v[1] == 0:
					continue
				print("   %s%s (%s): пров %d, див %d, сн %d%%, осн %d%% | пункты: %s" % ["дом " if c == nat.dep_home else "", w.p_name[v[5]], w.p_adm0[v[5]], v[0], v[1], roundi(100.0 * v[2] / maxf(1, v[1])), roundi(100.0 * v[3] / maxf(1, v[1])), ", ".join(v[4]) if not v[4].is_empty() else "нет"])
	quit(0)
