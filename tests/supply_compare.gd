extends SceneTree
## Сравнение моделей снабжения: средняя обеспеченность дивизий по странам,
## доля голодающих (< 50 %, < 20 %) и время фазы снабжения.
##   godot --headless --path . --script res://tests/supply_compare.gd [-- --supply=regions --until=1942-01-01]
func _init():
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1942-01-02"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var dates := ["1937-06-01", "1937-12-01", "1938-04-01", "1939-10-01", "1940-03-01", "1940-06-01", "1941-08-01", "1941-12-01"]
	var tags := ["GER", "SOV", "FRA", "ENG", "ITA", "JAP", "MAN", "CHI", "POL"]
	var t_sum := 0
	var t_n := 0
	var end := w.day_of(until)
	while w.day < end:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		t_sum += int(sim.phase_usec.get("снабжение", 0))
		t_n += 1
		for dd in dates:
			if w.day == w.day_of(dd):
				var parts: Array = []
				for tg in tags:
					var n := w.nation_tags.find(tg)
					if n < 0 or not w.nations[n].alive:
						continue
					var cnt := 0
					var s := 0.0
					var lo := 0
					var vlo := 0
					for i in w.d_id.size():
						if w.d_alive[i] == 1 and w.d_owner[i] == n:
							cnt += 1
							s += w.d_sup[i]
							if w.d_sup[i] < 0.5:
								lo += 1
							if w.d_sup[i] < 0.2:
								vlo += 1
					if cnt > 0:
						parts.append("%s %d%% (<50%%: %d, <20%%: %d из %d)" % [tg, roundi(100.0 * s / cnt), lo, vlo, cnt])
				print(w.date_short(), "  ", "  ".join(parts))
	print("снабжение: %.2f мс в среднем за день" % [t_sum / 1000.0 / maxi(1, t_n)])
	quit()
