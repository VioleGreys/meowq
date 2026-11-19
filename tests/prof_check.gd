extends SceneTree
## Профиль участков кода в позднем прогоне (Prof.add): разгон до даты, затем
## N дней с замером.  godot --headless --path . --script res://tests/prof_check.gd [-- --days=30 --until=1940-09-01]
## --load=имя — вместо разгона загрузить сохранение (одинаковые условия для «до/после»)
## --peaks=N — по дням: метки дороже N мс (что дорого в дни пиков)

func _init() -> void:
	var days := 30
	var until := "1940-09-01"
	var load := ""
	var peaks := -1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--days="):
			days = int(a.split("=")[1])
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--load="):
			load = a.split("=")[1]
		if a.begins_with("--peaks="):
			peaks = float(a.split("=")[1])
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	if load != "":
		SaveGame.load_into(load, w, sim)
	while load == "" and w.day < w.day_of(until):
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
	Prof.on = true
	Prof.acc.clear()
	var phases := {}
	var peak := {}   # худший день по метке
	var total := 0
	for i in days:
		var before := Prof.acc.duplicate()
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		total += sim.last_tick_usec
		for k in sim.phase_usec:
			phases[k] = int(phases.get(k, 0)) + sim.phase_usec[k]
			peak[k] = maxi(int(peak.get(k, 0)), sim.phase_usec[k])
		if peaks >= 0.0:
			var ln := "%s тик %.1f:" % [w.date_short(), sim.last_tick_usec / 1000.0]
			for k in Prof.acc:
				var d: float = (Prof.acc[k] - int(before.get(k, 0))) / 1000.0
				if d >= peaks:
					ln += " %s=%.1f" % [k, d]
			print(ln)
		for k in Prof.acc:
			peak["  " + k] = maxi(int(peak.get("  " + k, 0)), Prof.acc[k] - int(before.get(k, 0)))
	for k in Prof.acc:
		phases["  " + k] = Prof.acc[k]
	var keys := phases.keys()
	keys.sort_custom(func(a, b): return phases[a] > phases[b])
	print("Тик %.2f мс в среднем за %d дн." % [total / 1000.0 / days, days])
	for k in keys:
		print("%-24s %.2f мс, худший день %.1f" % [k, phases[k] / 1000.0 / days, peak.get(k, 0) / 1000.0])
	w.dispose()
	quit()
