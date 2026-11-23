extends SceneTree
## Охрана границ ИИ по отношениям (AIPlanner.guard_table): на даты --dates для
## стран --tags — по каждому соседу уровень охраны (0 — не держим, 1 — минимум,
## 2 — фронт), отношения (худшее из двух мнений), наших приграничных провинций
## и дивизий в них; сколько дивизий в тылу.
##   godot --headless --path . --script res://tests/guard_diag.gd -- [--dates=1936-06-01,1939-08-01 --tags=GER,FRA,SWE --seed=N]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var dates := ["1936-06-01", "1939-08-01"]
	var tags := ["GER", "FRA", "POL", "SWE", "SOV"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dates="):
			dates = Array(a.split("=")[1].split(","))
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var nc := w.nation_count
	for ds in dates:
		var end_day := w.day_of(ds)
		while w.day < end_day:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("annex")
			sim.tick()
			w.events.clear()
		var gt := AIPlanner.guard_table(w)
		print("== %s" % w.date_short())
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var cnt := {}   # провинция -> наших дивизий
			var total := 0
			for d in w.divisions:
				if d.alive and d.owner == n and d.prov >= 0:
					cnt[d.prov] = int(cnt.get(d.prov, 0)) + 1
					total += 1
			var by := {}    # сосед -> [провинций, дивизий]
			var on_border := {}
			for p in w.p_controller.size():
				if w.p_controller[p] != n or w.p_land[p] == 0:
					continue
				var seen := {}
				for k in range(w.adj_start[p], w.adj_start[p + 1]):
					var q := w.adj_list[k]
					var c := w.p_controller[q]
					if w.p_land[q] == 0 or c < 0 or c == n or seen.has(c):
						continue
					seen[c] = true
					on_border[p] = true
					if not by.has(c):
						by[c] = [0, 0]
					by[c][0] += 1
					by[c][1] += int(cnt.get(p, 0))
			var border_divs := 0
			for p in on_border:
				border_divs += int(cnt.get(p, 0))
			var war := "война" if not w.nations[n].at_war.is_empty() else "мир"
			print("%s (%s): дивизий %d, у границ %d, в тылу %d" % [tg, war, total, border_divs, total - border_divs])
			for c in by:
				var r := minf(Relations.rep(w, n, c), Relations.rep(w, c, n))
				var st := "война" if w.is_at_war(n, c) else ("союз" if w.ally[n * nc + c] == 1 else "ур.%d" % gt[n * nc + c])
				print("   %-4s %-6s отн.%3d  провинций %3d  дивизий %3d" % [w.nation_tags[c], st, roundi(r), by[c][0], by[c][1]])
	quit()
