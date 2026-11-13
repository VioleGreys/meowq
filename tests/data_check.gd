extends SceneTree
## Проверка стартовых данных 1936 г.: печатает таблицу сил и проверяет, что
## распределение по провинциям сходится с nations.json, а соотношение держав
## примерно историческое.
##   godot --headless --path . --script res://tests/data_check.gd

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)


func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/world1936/nations.json"))["nations"]
	var sim := Simulation.new(w)
	var rows: Array = []
	for n in w.nations:
		if n.dormant:
			continue
		var pop := 0
		var civ := 0
		var mil := 0
		for p in w.prov_count:
			if w.p_owner[p] == n.id:
				pop += w.p_population[p]
				civ += w.p_civ[p]
				mil += w.p_mil[p]
		var d: Dictionary = data.get(n.tag, {})
		check(not d.is_empty(), "нет данных для " + n.tag)
		check(civ == int(d.get("civ", -1)), "%s: гражд. фабрик %d, ожидалось %d" % [n.tag, civ, d.get("civ", -1)])
		check(mil == int(d.get("mil", -1)), "%s: воен. фабрик %d, ожидалось %d" % [n.tag, mil, d.get("mil", -1)])
		var divs := w.divisions_of(n.id).size()
		check(divs == int(d.get("divisions", 0)) + int(d.get("colony_divisions", 0)), "%s: дивизий %d" % [n.tag, divs])
		var army: Dictionary = d.get("army", {})
		if not army.is_empty():
			var arm := 0
			for dv in w.divisions_of(n.id):
				if dv.tpl == Military.T_ARM:
					arm += 1
			check(arm == int(army.get("arm", 0)), "%s: танковых дивизий %d" % [n.tag, arm])
		check(n.leader != "" and n.ideology != "", n.tag + ": нет лидера/идеологии")
		check(w.p_owner[n.capital] == n.id, n.tag + ": столица не своя")
		var out := 0.0
		for line in n.lines:
			out += float(line[1])
		check(Military.assigned_factories(n) == n.mil, n.tag + ": все военные заводы на линиях")
		rows.append([n.tag, n.name, pop / 1000.0, civ, mil, divs, n.manpower, out, n.daily_manpower])
	rows.sort_custom(func(a, b): return a[3] + a[4] > b[3] + b[4])
	print("%-4s %-18s %7s %4s %4s %4s %8s %6s %6s" % ["тег", "страна", "нас.млн", "гр.", "воен", "див", "резерв к", "линии", "люд/д"])
	for r in rows:
		print("%-4s %-18s %7.1f %4d %4d %4d %8.0f %6.1f %6.2f" % r)
	var g := w.nation_tags.find("GER")
	var s := w.nation_tags.find("SOV")
	var f := w.nation_tags.find("FRA")
	var pl := w.nation_tags.find("POL")
	check(w.nations[s].division_count > w.nations[g].division_count, "армия СССР должна быть больше германской")
	check(w.nations[g].mil > w.nations[pl].mil * 2, "промышленность Германии должна быть намного больше польской")
	check(w.nations[f].division_count > w.nations[g].division_count, "армия Франции в 1936 г. больше германской")
	# фокусы: длительность 35 или 70 дней, до 150 — в крайнем случае; ссылки на
	# существующие фокусы; координаты не совпадают
	for tag in w.focus_trees:
		var ids := {}
		var cells := {}
		for fd in w.focus_trees[tag]:
			ids[fd["id"]] = true
		for fd in w.focus_trees[tag]:
			var dd := int(fd.get("days", 70))
			check(dd == 35 or dd == 70 or (dd > 70 and dd <= 150), "%s/%s: длительность %d дн." % [tag, fd["id"], dd])
			for key in ["requires", "requires_any", "exclusive"]:
				for r in fd.get(key, []):
					check(ids.has(r), "%s/%s: нет фокуса %s" % [tag, fd["id"], r])
			var cell := "%d,%d" % [int(fd["x"]), int(fd["y"])]
			check(not cells.has(cell), "%s/%s: та же клетка, что у %s" % [tag, fd["id"], cells.get(cell, "")])
			cells[cell] = fd["id"]
	# шансы событий: известные условия и существующие страны (иначе в тексте «?»)
	for id in w.event_defs:
		var ev: Dictionary = w.event_defs[id]
		var ctx := History.event_ctx(w, id, 0)
		var specs: Array = []
		if ev.has("chance"):
			specs.append(ev["chance"])
		for o in ev.get("options", []):
			for e in o.get("effects", []):
				if e.get("t", "") == "roll":
					specs.append(e.get("chance", {}))
		for spec in specs:
			for m in spec.get("mods", []):
				var r := Relations.cond(w, m.get("if", {}), ctx)
				check(not String(r[1]).contains("?"), "%s: непонятное условие %s" % [id, JSON.stringify(m.get("if", {}))])
		if ev.has("chance"):
			check(History.event_has_choice(ev), "%s: шанс у события без выбора" % id)
	# черты: стартовые и из эффектов фокусов и событий — все есть в spirits.json
	# (раздел "spirits"; черта вне раздела загрузчиком не читается)
	for tag in data:
		for sid in data[tag].get("spirits", []):
			check(w.spirit_defs.has(sid), "%s: нет черты %s" % [tag, sid])
	var eff_lists: Array = []
	for tree in w.focus_trees.values():
		for fd in tree:
			eff_lists.append([String(fd["id"]), fd.get("effects", [])])
	for id2 in w.event_defs:
		for o in w.event_defs[id2].get("options", []):
			eff_lists.append([String(id2), o.get("effects", [])])
	while not eff_lists.is_empty():
		var item: Array = eff_lists.pop_back()
		for e in item[1]:
			var t := String(e.get("t", ""))
			if t in ["spirit_add", "spirit_timed", "spirit_remove", "spirit_scale"]:
				check(w.spirit_defs.has(String(e.get("id", ""))), "%s: нет черты %s" % [item[0], e.get("id", "")])
			for k in ["effects", "ok", "fail"]:
				if e.has(k):
					eff_lists.append([item[0], e[k]])
	if errors == 0:
		print("Данные 1936 г.: OK")
	quit(1 if errors > 0 else 0)
