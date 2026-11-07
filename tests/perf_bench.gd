extends SceneTree
## Замер производительности позднего этапа (исторический прогон до даты, затем
## N дней в одном и в нескольких потоках, с разбивкой по фазам).
##   godot --headless --path . --script res://tests/perf_bench.gd [-- --until=1940-09-01 --days=40]

func _init() -> void:
	var until := "1940-09-01"
	var days := 40
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--days="):
			days = int(a.split("=")[1])
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var t0 := Time.get_ticks_msec()
	while w.day < w.day_of(until):
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
	print("Разгон до %s: %d мс; дивизий %d, флотов %d, крыльев %d, провинций %d" % [w.date_string(), Time.get_ticks_msec() - t0,
		w.divisions.size(), w.fleets.filter(func(f): return f.alive).size(), w.wings.filter(func(x): return x.alive).size(), w.prov_count])
	for mode in [false, true]:
		Parallel.enabled = mode
		var sums := {}
		var total := 0
		# один и тот же отрезок: копировать мир нельзя, поэтому сравниваем
		# соседние отрезки — нагрузка за 40 дней меняется мало
		for i in days:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("annex")
			sim.tick()
			w.events.clear()
			total += sim.last_tick_usec
			for k in sim.phase_usec:
				sums[k] = int(sums.get(k, 0)) + sim.phase_usec[k]
		var parts: Array = []
		var keys := sums.keys()
		keys.sort_custom(func(a, b): return sums[a] > sums[b])
		for k in keys:
			parts.append("%s %.1f" % [k, sums[k] / 1000.0 / days])
		print("%s: тик %.1f мс | %s" % ["многопоточно" if mode else "один поток ", total / 1000.0 / days, ", ".join(parts)])
	quit()
