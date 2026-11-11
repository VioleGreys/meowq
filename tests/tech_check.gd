extends SceneTree
## Наука: целостность дерева и темп исследований в игре без игрока.
##   godot --headless --path . --script res://tests/tech_check.gd [-- --until=1946-01-01 --tags=GER,SOV,POL]

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func _init() -> void:
	var until := "1942-01-01"
	var tags := ["GER", "SOV", "USA", "ENG", "ITA", "POL", "ROM", "BUL", "SWI"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--tags="):
			tags = Array(a.split("=")[1].split(","))
	print("Дерево:")
	var ids := {}
	var bad := ""
	var cells := {}
	for t in Tech.all():
		if ids.has(t["id"]):
			bad += " повтор " + t["id"]
		ids[t["id"]] = true
		var cell := "%s/%d/%d" % [t["cat"], t["row"], t["year"]]
		if cells.has(cell):
			bad += " одна клетка: %s и %s" % [cells[cell], t["id"]]
		cells[cell] = t["id"]
		for k in t["bonus"]:
			if not Tech.BONUS_NAMES.has(k) and not String(k).begins_with("synth_"):
				bad += " бонус без названия: " + k
	for t in Tech.all():
		if t["req"] != "":
			var r := Tech.get_tech(t["req"])
			if r.is_empty():
				bad += " нет требования %s у %s" % [t["req"], t["id"]]
			elif int(r["year"]) > int(t["year"]):
				bad += " требование позже: " + t["id"]
	check(bad == "", "%d технологий, ссылки и клетки в порядке%s" % [Tech.all().size(), bad])
	for bt in Military.BATTALIONS:
		if bt["req"] != "":
			check(not Tech.get_tech(bt["req"]).is_empty(), "батальон «%s» открывается существующей технологией" % bt["name"])
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var ger: World.Nation = w.nations[w.nation_tags.find("GER")]
	var bul: World.Nation = w.nations[w.nation_tags.find("BUL")]
	check(ger.research.size() == 3 and bul.research.size() == 2, "слоты: Германия %d, Болгария %d" % [ger.research.size(), bul.research.size()])
	var t41 := Tech.get_tech("mt2")
	check(Tech.ahead_mult(w, t41) > 10.0, "технология 1941 г. в 1936-м — срок ×%.1f" % Tech.ahead_mult(w, t41))
	var d0 := Tech.days_left(w, ger, "ind1")
	ger.bonus["research"] = float(ger.bonus.get("research", 0.0)) + 0.5
	check(Tech.days_left(w, ger, "ind1") < d0, "бонус науки сокращает срок (%d → %d дн.)" % [d0, Tech.days_left(w, ger, "ind1")])
	ger.bonus["research"] = float(ger.bonus["research"]) - 0.5
	print("Темп (изучено технологий на 1 января):")
	var end_day := w.day_of(until)
	var year := 1936
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		if w.day == w.day_of("%d-01-01" % (year + 1)):
			year += 1
			var line := "  %d:" % year
			for tag in tags:
				var n: World.Nation = w.nations[w.nation_tags.find(tag)]
				line += "  %s %d" % [tag, n.techs.size()]
			print(line)
	for tag in tags:
		var n: World.Nation = w.nations[w.nation_tags.find(tag)]
		var by := {}
		for id in n.techs:
			var c: String = Tech.get_tech(id).get("cat", "?")
			by[c] = int(by.get(c, 0)) + 1
		var keys: Array = []
		for k in ["attack", "defense", "org", "speed", "inf_attack", "inf_defense", "tank_attack", "art_attack", "industry", "construction", "research"]:
			keys.append("%s %+d%%" % [k, roundi(n.b(k) * 100.0)])
		print("  %s: %s\n     %s" % [tag, by, ", ".join(keys)])
	print("Наука: ", "OK" if errors == 0 else "ПРОВАЛОВ: %d" % errors)
	quit(1 if errors > 0 else 0)
