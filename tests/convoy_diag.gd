extends SceneTree
## Диагностика конвоев: у держав — импорт (по суше/по морю), войска за морем, верфи.
##   godot --headless --path . --script res://tests/convoy_diag.gd [-- --dates=1939-11-01,1941-06-01]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var dates := ["1937-01-01", "1939-11-01", "1941-06-01"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dates="):
			dates = Array(a.split("=")[1].split(","))
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var tags := ["ENG", "GER", "FRA", "ITA", "SOV", "USA", "JAP"]
	var nc := w.nation_count
	for ds in dates:
		var end := w.day_of(ds)
		var st0 := {}
		while w.day < end:
			if not w.pending_peace.is_empty():
				sim.resolve_peace("annex")
			sim.tick()
			w.events.clear()
		print("== ", ds)
		for tag in tags:
			var n := w.nation_tags.find(tag)
			var nat: World.Nation = w.nations[n]
			var land := 0.0
			var sea := 0.0
			var cm: int = w.p_mass[nat.capital] if nat.capital >= 0 else -1
			for c in w.contracts:
				if int(c[0]) != n:
					continue
				var s: World.Nation = w.nations[int(c[1])]
				var sm: int = w.p_mass[s.capital] if s.capital >= 0 else -2
				if sm == cm:
					land += float(c[3])
				else:
					sea += float(c[3])
			var od := 0
			var hd := 0
			for d in w.divisions:
				if d.alive and d.owner == n:
					if w.p_mass[d.prov] == cm:
						hd += 1
					else:
						od += 1
			var conv := " · конвои %.0f (торговля %.0f, снабж. %.0f; доходит %.0f%%, снабж. %.0f%%, потоплено %.0f, опасных бассейнов %d)" % [nat.convoys, nat.conv_trade_need, nat.conv_sup_need, nat.conv_trade * 100.0, nat.conv_sup * 100.0, nat.conv_sunk, nat.conv_danger.size()]
			print("  %s импорт суша %.1f море %.1f · дивизий дома %d за морем %d · верфи %.0f%s" % [tag, land, sea, hd, od, nat.stock[Military.EQ_SHIP], conv])
	quit()
