extends SceneTree
## Доктрины: таблица школ, правила выбора и рост боевого опыта по годам
## в игре без игрока (кто воюет раньше — раньше берёт ступени).
##   godot --headless --path . --script res://tests/doctrine_check.gd [-- --until=1943-01-01 --tags=GER,SOV]

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func _init() -> void:
	var until := "1943-01-01"
	var tags := ["GER", "SOV", "JAP", "CHI", "ENG", "FRA", "ITA", "USA", "NSP", "FIN"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
	print("Таблица:")
	var bad := ""
	var ids := {}
	for s in Doctrine.SCHOOLS:
		if Doctrine.branch_index(s["branch"]) < 0:
			bad += " род сил " + s["id"]
		if s["steps"].size() != Doctrine.COSTS[s["branch"]].size():
			bad += " ступеней %s" % s["id"]
		for r in s["steps"]:
			if ids.has(r[0]):
				bad += " повтор " + r[0]
			ids[r[0]] = true
			for k in r[2]:
				if not Tech.BONUS_NAMES.has(k):
					bad += " бонус " + k
	check(bad == "", "%d школ, %d ступеней%s" % [Doctrine.SCHOOLS.size(), ids.size(), bad])
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var nd: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world1936/nations.json"))["nations"]
	var badp := ""
	for tag in nd:
		var p: Dictionary = nd[tag].get("doctrine", {})
		for br in p:
			if Doctrine.get_school(p[br]).get("branch", "") != br:
				badp += " %s:%s=%s" % [tag, br, p[br]]
	check(badp == "", "исторические школы в nations.json существуют%s" % badp)
	var ger: World.Nation = w.nations[w.nation_tags.find("GER")]
	check(ger.doctrines.is_empty() and ger.xp[0] == 0.0, "на старте опыта и доктрин нет")
	check(Doctrine.pref(ger, "land") == "mob" and Doctrine.pref(w.nations[w.nation_tags.find("SOV")], "land") == "mass", "Германия — подвижная война, СССР — массированный удар")
	# правила: без опыта нельзя; первая ступень закрывает другие школы
	var t: World.Nation = w.nations[w.nation_tags.find("BUL")]
	check(not Doctrine.buy(t, "l_fire1"), "без опыта ступень не принять")
	t.xp[0] = 200.0
	check(not Doctrine.can_buy(t, "l_fire2"), "вторую ступень — только после первой")
	check(Doctrine.buy(t, "l_fire1") and not Doctrine.can_buy(t, "l_meth1") and Doctrine.can_buy(t, "l_fire2"), "первая ступень выбирает школу, другие закрыты")
	check(is_equal_approx(t.xp[0], 200.0 - Doctrine.cost("land", 0)), "опыт списан")
	# откатить пробу
	t.doctrines.clear()
	t.bonus["art_attack"] = float(t.bonus["art_attack"]) - 0.05
	t.xp[0] = 0.0
	print("Опыт и ступени (армия/флот/авиация) на 1 января:")
	var end_day := w.day_of(until)
	var year := 1936
	var first := {}
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		for tag in tags:
			var n: World.Nation = w.nations[w.nation_tags.find(tag)]
			if not first.has(tag) and not n.doctrines.is_empty():
				first[tag] = w.date_short()
		var mid := w.day == w.day_of("%d-07-01" % year)
		if w.day == w.day_of("%d-01-01" % (year + 1)) or mid:
			if not mid:
				year += 1
			var line := "  %s:" % w.date_short()
			for tag in tags:
				var n: World.Nation = w.nations[w.nation_tags.find(tag)]
				var c: Array = []
				for br in Doctrine.BRANCHES:
					var sc := Doctrine.school_of(n, br)
					c.append(str(Doctrine.steps_done(n, sc)) if sc != "" else "0")
				line += "  %s %s (%d)" % [tag, "/".join(c), roundi(n.xp[0])]
			print(line)
	print("Первая доктрина: ", first)
	var sov: World.Nation = w.nations[w.nation_tags.find("SOV")]
	print("  Германия: ", ger.doctrines.keys(), "\n  СССР: ", sov.doctrines.keys())
	print("Доктрины: ", "OK" if errors == 0 else "ПРОВАЛОВ: %d" % errors)
	quit(1 if errors > 0 else 0)
