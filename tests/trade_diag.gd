extends SceneTree
## Диагностика закупок ресурсов страны (по умолчанию Германия): по датам —
## добыча, нужда, куплено, обеспеченность, бюджет и доступные экспортёры.
##   godot --headless --path . --script res://tests/trade_diag.gd [-- --nation=GER]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var tag := "GER"
	var dates := ["1939-11-01", "1940-09-01", "1941-06-01"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--nation="):
			tag = a.split("=")[1]
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
		if a.begins_with("--dates="):
			dates = Array(a.split("=")[1].split(","))
	var n := w.nation_tags.find(tag)
	for ds in dates:
		var end := w.day_of(ds)
		while w.day < end:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("annex")
			sim.tick()
			w.events.clear()
		var nat: World.Nation = w.nations[n]
		print("== %s %s  гражд.заводы %d, на закупки %.1f (потолок %.1f), курс %d" % [ds, tag, nat.civ, nat.trade_civ, nat.civ * Economy.AI_CIV_SHARE, nat.trade_law])
		for r in Economy.RES_COUNT:
			print("  %-9s добыча %6.1f нужда %6.1f куплено %6.1f обесп. %3d%%" % [Economy.RES_NAMES[r], nat.res_prod[r], nat.res_need[r], nat.res_in[r], int(nat.res_fill[r] * 100)])
			if nat.res_fill[r] < 0.95:
				var lines: Array = []
				for s in w.nation_count:
					var sn: World.Nation = w.nations[s]
					if not sn.alive or s == n or sn.res_prod[r] < 0.5:
						continue
					var cap := Economy.export_cap(sn, r)
					var ex := Economy.exportable(w, sn, r)
					var why := Economy.can_trade(w, n, s)
					var sc: float = w.trade_score[s * w.nation_count + n] if w.trade_score.size() > s * w.nation_count + n else -1.0
					var who: Array = []
					for c in w.contracts:
						if int(c[1]) == s and int(c[2]) == r:
							who.append("%s:%.1f" % [w.nation_tags[int(c[0])], float(c[3])])
					lines.append("%s[%s](добыча %.0f нужда %.0f предел %.1f свободно %.1f рейт %.2f%s)" % [w.nation_tags[s], " ".join(who), sn.res_prod[r], sn.res_need[r], cap, ex, sc, (" " + why) if why != "" else ""])
				print("     продавцы: " + ", ".join(lines))
		var bl: Array = []
		for s in w.nation_count:
			if Economy.is_blocked(w, n, s):
				bl.append(w.nation_tags[s])
		print("  блокада (%d): %s" % [bl.size(), " ".join(bl)])
		var cs: Array = []
		for c in w.contracts:
			if int(c[0]) == n:
				cs.append("%s %s %.1f" % [w.nation_tags[int(c[1])], Economy.RES_SHORT[int(c[2])], float(c[3])])
		print("  поставки: " + ", ".join(cs))
	quit()
