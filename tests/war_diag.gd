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
			if "--stack" in OS.get_cmdline_user_args():
				# перегруз: дивизий в провинциях сверх ёмкости снабжения
				var cnt := {}
				for d in w.divisions:
					if d.alive and d.owner == n:
						cnt[d.prov] = int(cnt.get(d.prov, 0)) + 1
				var over := 0
				var cap := 0.0
				var worst := ""
				var wv := 0
				for pp in cnt:
					var c2: int = cnt[pp]
					cap += w.p_supcap[pp]
					if c2 > maxi(1, int(w.p_supcap[pp])):
						over += c2 - maxi(1, int(w.p_supcap[pp]))
					if c2 > wv:
						wv = c2
						worst = "%s %d/%.0f" % [w.p_name[pp], c2, w.p_supcap[pp]]
				print("   %s перегруз: провинций с войсками %d, ёмкость %.0f, дивизий сверх ёмкости %d, худшая %s" % [tg, cnt.size(), cap, over, worst])
			print("%s %s гр%d вз%d ман%d конв%d/%d(%d%%) | %s" % [w.date_short(), tg, nat.civ, nat.mil, roundi(nat.manpower),
				roundi(nat.convoys), roundi(nat.conv_sup_need + nat.conv_trade_need), roundi(100 * nat.conv_sup), "  ".join(parts)])
	quit(0)
