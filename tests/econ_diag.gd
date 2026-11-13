extends SceneTree
## Экономика крупных стран по датам: дивизии, военные заводы, выпуск в очках
## по типам, склад (в очках), заполненность снаряжением, ресурсы (добыча,
## нужда, обеспеченность). Для сравнения до и после правок экономики.
##   godot --headless --path . --script res://tests/econ_diag.gd -- [--dates=1937-01-01,1939-09-01,1941-06-22 --tags=GER,SOV,FRA,ENG,ITA,JAP,USA,CHI --seed=N --res]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var dates := ["1937-01-01", "1938-09-01", "1939-09-01", "1940-06-01", "1941-06-22", "1942-06-01"]
	var tags := ["GER", "SOV", "FRA", "ENG", "ITA", "JAP", "USA", "CHI"]
	var show_res := "--res" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dates="):
			dates = a.split("=")[1].split(",")
		if a.begins_with("--tags="):
			tags = a.split("=")[1].split(",")
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var costs: Array = Military.EQ_COST
	for ds in dates:
		var end := w.day_of(ds)
		while w.day < end:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("auto")
			sim.tick()
			w.events.clear()
		print("== %s" % w.date_short())
		# мировая нужда в ресурсах: по нынешним нормам и по прежним (до ноября 2026 г.)
		var old_need := [[0, .35, 0, 0, 0, 0], [0, .6, 0, 0, .25, 0], [.35, .7, 0, 0, 0, .35], [.3, .3, 0, .3, 0, 0],
			[0, .6, 0, 0, .25, 0], [0, .7, 0, 0, 0, .25], [.3, 0, .8, .25, 0, 0], [.4, 0, 1, .3, 0, 0]]
		var wn := PackedFloat64Array([0, 0, 0, 0, 0, 0])
		var wo := PackedFloat64Array([0, 0, 0, 0, 0, 0])
		var wp := PackedFloat64Array([0, 0, 0, 0, 0, 0])
		for nat in w.nations:
			if not nat.alive:
				continue
			for r in Economy.RES_COUNT:
				wn[r] += nat.res_need[r]
				wp[r] += nat.res_prod[r]
			for line in nat.lines:
				for r in Economy.RES_COUNT:
					wo[r] += int(line[1]) * float(old_need[int(line[0])][r])
		var ws: Array = []
		for r in Economy.RES_COUNT:
			ws.append("%s %.0f/%.0f (×%.2f) добыча %.0f" % [Economy.RES_SHORT[r], wn[r], wo[r], wn[r] / maxf(wo[r], 0.01), wp[r]])
		print("мир, нужда нов./прежн.: %s" % " · ".join(ws))
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var nat: World.Nation = w.nations[n]
			var dv := 0
			var eqs := 0.0
			for d in w.divisions:
				if d.alive and d.owner == n:
					dv += 1
					eqs += d.eq
			var out := 0.0
			var st := 0.0
			var parts: Array = []
			for k in Military.EQ_COUNT:
				var o: float = nat.daily_output[k] * float(costs[k])
				out += o
				st += nat.stock[k] * float(costs[k])
				if o > 0.0:
					parts.append("%s %.0f" % [Military.EQ_SHORT[k], o])
			var eff := 0.0
			var lf := 0
			for line in nat.lines:
				eff += float(line[2]) * int(line[1])
				lf += int(line[1])
			print("%s див %d (снар. %d%%) воен %d (на линиях %d, эфф %d%%) выпуск %.0f/д [%s] склад %.0f" % [tg, dv,
				roundi(100.0 * eqs / maxf(1, dv)), nat.mil, lf, roundi(100.0 * eff / maxf(1, lf)), out, ", ".join(parts), st])
			if show_res:
				var rs: Array = []
				for r in Economy.RES_COUNT:
					rs.append("%s %.0f/%.0f (%d%%)" % [Economy.RES_SHORT[r], nat.res_prod[r] + nat.res_in[r] - nat.res_out[r], nat.res_need[r], roundi(100.0 * nat.res_fill[r])])
				print("   ресурсы: %s" % " ".join(rs))
	quit(0)
