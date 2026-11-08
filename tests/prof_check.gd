extends SceneTree
## Профиль участков кода в позднем прогоне (Prof.add): разгон до даты, затем
## N дней с замером.  godot --headless --path . --script res://tests/prof_check.gd [-- --days=30]

func _init() -> void:
	var days := 30
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--days="):
			days = int(a.split("=")[1])
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	while w.day < w.day_of("1940-09-01"):
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
	Prof.on = true
	Prof.acc.clear()
	var phases := {}
	var total := 0
	for i in days:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		total += sim.last_tick_usec
		for k in sim.phase_usec:
			phases[k] = int(phases.get(k, 0)) + sim.phase_usec[k]
	for k in Prof.acc:
		phases["  " + k] = Prof.acc[k]
	var keys := phases.keys()
	keys.sort_custom(func(a, b): return phases[a] > phases[b])
	print("Тик %.2f мс в среднем за %d дн." % [total / 1000.0 / days, days])
	for k in keys:
		print("%-24s %.2f мс" % [k, phases[k] / 1000.0 / days])
	w.dispose()
	quit()
