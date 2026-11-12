extends SceneTree
## Кампания на Западе 1939–40 гг.: когда ключевые города Франции, Бельгии,
## Нидерландов меняют хозяина, когда капитулирует Франция, где стоят немецкие
## дивизии у границ (раз в неделю с --from). После капитуляции — кто держит
## колонии Франции («Свободная Франция» или Виши).
##   godot --headless --path . --script res://tests/france_diag.gd -- [--until=1940-09-01 --from=1940-05-01 --seed=N --brief]

const STEP := 3
const CITIES := ["Страсбург", "Мец", "Нанси", "Люксембург", "Арлон", "Мёз", "Шарлеруа", "Арденны", "Эна", "Льеж", "Брюссель", "Гаага", "Амстердам",
	"Лилль", "Кале", "Реймс", "Руан", "Париж", "Лион", "Бордо"]

func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until := "1940-09-01"
	var from := "1940-05-01"
	var brief := "--brief" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--from="):
			from = a.split("=")[1]
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var end_day := w.day_of(until)
	var from_day := w.day_of(from)
	var cps: Array = []
	var names := Array(w.p_name)
	for c in CITIES:
		cps.append(names.find(c))
	var ctrl: Array = []
	for p in cps:
		ctrl.append(w.p_controller[p] if p >= 0 else -1)
	var ger := w.nation_tags.find("GER")
	var fra := w.nation_tags.find("FRA")
	var cap_day := -1
	var west_day := -1
	var fdone := {}
	var ffrom := w.day_of("1939-06-01")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--focus_from="):
			ffrom = w.day_of(a.split("=")[1])
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("auto")
		sim.tick()
		for e in w.events:
			if "капитулирует" in e or "Нидерланды" in e or "Бельгия" in e or "Компьен" in e or "Свободн" in e or "план" in e or ("объявляет войну" in e and ("Бельг" in e or "Нидерланд" in e)):
				print("  %s — %s" % [w.date_short(), e])
		w.events.clear()
		for n2 in [ger, fra, w.nation_tags.find("FFR")]:
			if w.day >= ffrom:
				for f in w.nations[n2].focus_done:
					if not fdone.has(f):
						fdone[f] = true
						print("  %s  фокус %s %s" % [w.date_short(), w.nation_tags[n2], f])
			else:
				for f in w.nations[n2].focus_done:
					fdone[f] = true
		if west_day < 0 and w.nation_tags.find("BEL") >= 0 and w.is_at_war(ger, w.nation_tags.find("BEL")):
			west_day = w.day
		if cap_day < 0 and (w.nations[fra].capitulated or not w.nations[fra].alive):
			cap_day = w.day
		for i in cps.size():
			var p: int = cps[i]
			if p < 0:
				continue
			var c := w.p_controller[p]
			if c != ctrl[i]:
				ctrl[i] = c
				print("  %s  %s → %s" % [w.date_short(), CITIES[i], w.nation_tags[c] if c >= 0 else "-"])
		if brief or w.day < from_day or w.day % STEP != 0 or cap_day >= 0:
			continue
		# немецкие дивизии по странам (Natural Earth adm0) и их снабжение
		var by := {}
		for d in w.divisions:
			if d.alive and d.owner == ger:
				var k: String = w.p_adm0[d.prov]
				if not by.has(k):
					by[k] = [0, 0.0]
				by[k][0] += 1
				by[k][1] += d.supply
		var parts: Array = []
		for k in by:
			if by[k][0] >= 3:
				parts.append("%s:%d(%d%%)" % [k, by[k][0], roundi(100.0 * by[k][1] / by[k][0])])
		var fr := 0
		for d in w.divisions:
			if d.alive and d.owner == fra:
				fr += 1
		print("%s GER %s | FRA див. %d" % [w.date_short(), " ".join(parts), fr])
		var gn: World.Nation = w.nations[ger]
		if not gn.offensive.is_empty():
			var obj: int = gn.offensive[1][gn.offensive[2]]
			var near := 0
			var at := 0
			for d in w.divisions:
				if d.alive and d.owner == ger:
					if d.prov == obj:
						at += 1
					for k in range(w.adj_start[obj], w.adj_start[obj + 1]):
						if w.adj_list[k] == d.prov:
							near += 1
			var en := {}
			for d in w.divisions:
				if d.alive and d.prov == obj:
					en[w.nation_tags[d.owner]] = int(en.get(w.nation_tags[d.owner], 0)) + 1
			var going := 0
			var org_sum := 0.0
			var org_n := 0
			for d in w.divisions:
				if d.alive and d.owner == ger:
					if not d.path.is_empty() and d.path[d.path.size() - 1] == obj:
						going += 1
					for k in range(w.adj_start[obj], w.adj_start[obj + 1]):
						if w.adj_list[k] == d.prov:
							org_sum += d.org / maxf(d.max_org, 0.01)
							org_n += 1
			var nb: Array = []
			for k in range(w.adj_start[obj], w.adj_start[obj + 1]):
				var q: int = w.adj_list[k]
				var cnt := {}
				for d in w.divisions:
					if d.alive and d.prov == q:
						cnt[w.nation_tags[d.owner]] = int(cnt.get(w.nation_tags[d.owner], 0)) + 1
				nb.append("%s[%s сн%.0f]%s" % [w.p_name[q], w.nation_tags[w.p_controller[q]], w.p_supcap[q], cnt])
			print("   соседи вехи: %s" % " ".join(nb))
			print("   в вехе: %s; идут на неё %d; орг. у вехи %d%%" % [en, going, roundi(100.0 * org_sum / maxf(1, org_n))])
			print("   план «%s»: веха %s (%s), у вехи %d, в ней %d, развёртывание против %s" % [gn.offensive[3], w.p_name[obj],
				w.nation_tags[w.p_controller[obj]], near, at, gn.planned_wars.keys().map(func(x): return w.nation_tags[x])])
	print("Война с Бельгией: %s; капитуляция Франции: %s (от удара %d дн.)" % [
		w.date_short(west_day) if west_day >= 0 else "нет", w.date_short(cap_day) if cap_day >= 0 else "нет",
		cap_day - west_day if cap_day >= 0 and west_day >= 0 else -1])
	# колонии и держатели
	var hold := {}
	for p in w.prov_count:
		var o := w.p_owner[p]
		if o < 0:
			continue
		var tg: String = w.nation_tags[o]
		if tg in ["VIC", "FFR", "FRA"]:
			hold[tg] = int(hold.get(tg, 0)) + 1
	print("Провинции: %s" % [hold])
	for tg in ["VIC", "FFR"]:
		var n := w.nation_tags.find(tg)
		if n >= 0 and w.nations[n].alive:
			var nat: World.Nation = w.nations[n]
			var dv := 0
			for d in w.divisions:
				if d.alive and d.owner == n:
					dv += 1
			print("  %s: столица %s, дивизий %d, гражд. %d, воен. %d, фракция %d, войны %s" % [tg, w.p_name[nat.capital] if nat.capital >= 0 else "-",
				dv, nat.civ, nat.mil, nat.faction, nat.at_war.keys().map(func(x): return w.nation_tags[x])])
	for tg in ["VIC", "FFR"]:
		var n := w.nation_tags.find(tg)
		var fl := 0
		var ships := 0
		for f in w.fleets:
			if f.alive and f.owner == n:
				fl += 1
				ships += f.ships[0] + f.ships[1] + f.ships[2]
		print("  %s флотов %d, кораблей %d" % [tg, fl, ships])
	quit(0)
