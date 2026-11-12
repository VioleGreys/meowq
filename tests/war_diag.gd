extends SceneTree
## Диагностика хода войны: раз в месяц (с --from) по странам --tags — где стоят
## дивизии (по странам Natural Earth `p_adm0`), их снабжение, организация,
## снаряжение; заводы, призыв, производство снаряжения.
##   godot --headless --path . --script res://tests/war_diag.gd -- --until=1941-06-01 --from=1940-06-01 --tags=ITA,ENG [--seed=N]

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
		for e in w.events:
			if "капитулирует" in e or "объявляет войну" in e:
				if w.day >= from_day:
					print("  %s — %s" % [w.date_short(), e])
		w.events.clear()
		if w.day < from_day or not w.date_short().begins_with("01."):
			continue
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var nat: World.Nation = w.nations[n]
			var by := {}
			for d in w.divisions:
				if not d.alive or d.owner != n:
					continue
				var k: String = w.p_adm0[d.prov]
				if not by.has(k):
					by[k] = [0, 0.0, 0.0, 0.0]
				by[k][0] += 1
				by[k][1] += d.supply
				by[k][2] += d.org / maxf(d.max_org, 0.01)
				by[k][3] += d.eq
			var parts: Array = []
			for k in by:
				var c: int = by[k][0]
				parts.append("%s:%d сн%d%% орг%d%% осн%d%%" % [k, c, roundi(100 * by[k][1] / c), roundi(100 * by[k][2] / c), roundi(100 * by[k][3] / c)])
			print("%s %s гр%d вз%d ман%d | %s" % [w.date_short(), tg, nat.civ, nat.mil, roundi(nat.manpower), "  ".join(parts)])
	quit(0)
