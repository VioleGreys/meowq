extends SceneTree
## Стенд фазы флота на одной и той же партии (сравнение «до/после» на шумной
## машине): -- --make — разгон до --until и сохранение «_fleet_bench»;
## без него — загрузка и --days дней с профилем (Prof) фазы флота, --rep раз.
##   godot --headless --path . --script res://tests/fleet_bench.gd -- --make --until=1941-07-01
##   godot --headless --path . --script res://tests/fleet_bench.gd -- --days=30 --rep=3

func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.split("=")[1]
	return def


func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	if OS.get_cmdline_user_args().has("--make"):
		var until := w.day_of(_arg("until", "1941-07-01"))
		while w.day < until:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("annex")
			sim.tick()
			w.events.clear()
		print("сохранение: ", SaveGame.write("_fleet_bench", w, sim, {"title": "стенд флота"}))
		w.dispose()
		quit()
		return
	var days := int(_arg("days", "30"))
	var rep := int(_arg("rep", "3"))
	var keys := ["флот:ИИ", "флот", "флот:бои", "  флот:торговля", "  кв:страны", "  кв:опасность", "  флот:пункты", "  пс:components", "  пс:разбор", "  пс:split_cut", "  пс:by_nat"]
	for r in rep:
		var w2 := World.new()
		MapLoader.load_world(w2)
		var s2 := Simulation.new(w2)
		SaveGame.load_into("_fleet_bench", w2, s2)
		Prof.on = true
		Prof.acc.clear()
		var ph := {}
		for i in days:
			if not w2.pending_peace.is_empty():
				s2.resolve_peace("annex")
			s2.tick()
			w2.events.clear()
			for k in s2.phase_usec:
				ph[k] = int(ph.get(k, 0)) + s2.phase_usec[k]
		for k in Prof.acc:
			ph["  " + k] = Prof.acc[k]
		var line := "проход %d:" % r
		for k in keys:
			if ph.has(k):
				line += " %s %.2f," % [k.strip_edges(), ph[k] / 1000.0 / days]
		print(line)
		w2.dispose()
	w.dispose()
	quit()
