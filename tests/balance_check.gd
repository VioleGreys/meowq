extends SceneTree
## Военный баланс в исторической игре без игрока: раз в месяц (по выбранным
## странам) — дивизии, оснащение, организация, доля своих очков победы под
## контролем; плюс капитуляции. Для подбора баланса, чтобы войны шли к
## историческим датам.
##   godot --headless --path . --script res://tests/balance_check.gd [-- --until=1942-01-01 --tags=GER,SOV]

var w: World


func _init() -> void:
	w = World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1942-01-01"
	var tags := ["GER", "SOV", "FRA", "ENG", "ITA", "POL", "FIN", "ROM", "SPR", "NSP", "CHI", "JAP", "MAN"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var summary := "--summary" in OS.get_cmdline_user_args()
	# сводка по историческим точкам: [дата, тег, что]
	var marks := {"1937-07-01": ["SPR", "NSP"], "1939-06-01": ["SPR", "NSP"], "1940-04-01": ["FIN", "FRA"],
		"1940-08-01": ["FRA"], "1940-01-01": ["CHI", "MAN", "JAP"], "1942-01-01": ["SOV", "CHI", "JAP", "MAN"],
		"1943-01-01": ["SOV", "GER"], "1941-10-01": ["SOV", "GER"]}
	var out: Array = []
	var end_day := w.day_of(until)
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		for e in w.events:
			if "капитулирует" in e or "объявляет войну" in e or "заключают" in e:
				print("  %s — %s" % [w.date_short(), e])
		w.events.clear()
		var watch := ""
		var watch_from := 0
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--watch="):
				watch = a.split("=")[1].split("@")[0]
				watch_from = w.day_of(a.split("@")[1])
		if watch != "" and w.day >= watch_from:
			var wn := w.nation_tags.find(watch)
			if wn >= 0:
				var vt := 0
				var vh := 0
				var lines: Array = []
				for p in w.prov_count:
					if w.p_owner[p] == wn and w.p_vp[p] > 0:
						vt += w.p_vp[p]
						if w.p_controller[p] == wn:
							vh += w.p_vp[p]
						else:
							lines.append("%s(%d)→%s" % [w.p_name[p], w.p_vp[p], w.nation_tags[w.p_controller[p]]])
				print("   %s %s ОП %d/%d жив=%s потеряно: %s" % [w.date_short(), watch, vh, vt, w.nations[wn].alive, ", ".join(lines)])
		for md in marks:
			if w.day == w.day_of(md):
				for tg in marks[md]:
					var mn := w.nation_tags.find(tg)
					var vt := 0
					var vh := 0
					for p in w.prov_count:
						if w.p_owner[p] == mn and w.p_vp[p] > 0:
							vt += w.p_vp[p]
							if w.p_controller[p] == mn or (w.p_controller[p] >= 0 and Diplomacy.same_side(w, w.p_controller[p], mn)):
								vh += w.p_vp[p]
					out.append("%s %s:%s" % [md.substr(0, 7), tg, ("%d%%" % roundi(100.0 * vh / maxf(vt, 1))) if w.nations[mn].alive else "нет"])
		if summary:
			continue
		if w.date_short().begins_with("01."):
			var parts: Array = []
			for tg in tags:
				var n := w.nation_tags.find(tg)
				if n < 0 or not w.nations[n].alive:
					continue
				var nat: World.Nation = w.nations[n]
				var divs := 0
				var eq := 0.0
				var org := 0.0
				var org_max := 0.0
				for d in w.divisions:
					if d.alive and d.owner == n:
						divs += 1
						eq += d.eq
						org += d.org
						org_max += d.max_org
				var vp_total := 0
				var vp_held := 0
				for p in w.prov_count:
					if w.p_owner[p] == n and w.p_vp[p] > 0:
						vp_total += w.p_vp[p]
						if w.p_controller[p] == n or (w.p_controller[p] >= 0 and Diplomacy.same_side(w, w.p_controller[p], n)):
							vp_held += w.p_vp[p]
				if nat.at_war.is_empty() and w.date_short().substr(3, 2) != "01":
					continue   # мирные — только в январе
				parts.append("%s %dд осн%d%% орг%d%% ОП%d%%%s" % [tg, divs, roundi(100.0 * eq / maxf(divs, 1)),
					roundi(100.0 * org / maxf(org_max, 1.0)), roundi(100.0 * vp_held / maxf(vp_total, 1)),
					"*" if not nat.at_war.is_empty() else ""])
			print("%s  %s" % [w.date_short(), "  ".join(parts)])
			if "--east" in OS.get_cmdline_user_args():
				# где стоят армии: восточнее 21° д. (восточный фронт) и западнее
				var ge := 0
				var gw := 0
				var se := 0
				var sf := 0
				var g := w.nation_tags.find("GER")
				var so := w.nation_tags.find("SOV")
				for d in w.divisions:
					if not d.alive:
						continue
					var ll: Vector2 = w.p_lonlat[d.prov]
					if d.owner == g:
						var at_border := false
						for k in range(w.adj_start[d.prov], w.adj_start[d.prov + 1]):
							if w.p_controller[w.adj_list[k]] == so:
								at_border = true
						if at_border:
							ge += 1
						else:
							gw += 1
					elif d.owner == so:
						if ll.x < 45.0 and ll.y > 43.0:
							se += 1
						else:
							sf += 1
				print("     Германия: у границы СССР %d, прочие %d | СССР: Европа %d, Азия/прочее %d" % [ge, gw, se, sf])
			if "--bonus" in OS.get_cmdline_user_args():
				for tg in tags:
					var bn := w.nation_tags.find(tg)
					if bn >= 0 and w.nations[bn].alive and not w.nations[bn].at_war.is_empty():
						var nb: World.Nation = w.nations[bn]
						print("     %s атака %+d%% оборона %+d%% орг %+d%% ман %d" % [tg, roundi(100 * nb.b("attack")), roundi(100 * nb.b("defense")), roundi(100 * nb.b("org")), roundi(nb.manpower)])
	if summary:
		print("СВОДКА seed=%d  %s" % [w.seed_value, "  ".join(out)])
	quit(0)
