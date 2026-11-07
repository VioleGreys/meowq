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
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/europe1936/nations.json"))["nations"]
	var sim := Simulation.new(w)
	var rows: Array = []
	for n in w.nations:
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
		check(n.leader != "" and n.ideology != "", n.tag + ": нет лидера/идеологии")
		check(w.p_owner[n.capital] == n.id, n.tag + ": столица не своя")
		rows.append([n.tag, n.name, pop / 1000.0, civ, mil, divs, n.manpower, n.daily_equipment, n.daily_manpower])
	rows.sort_custom(func(a, b): return a[3] + a[4] > b[3] + b[4])
	print("%-4s %-18s %7s %4s %4s %4s %8s %6s %6s" % ["тег", "страна", "нас.млн", "гр.", "воен", "див", "резерв к", "сн/д", "люд/д"])
	for r in rows:
		print("%-4s %-18s %7.1f %4d %4d %4d %8.0f %6.1f %6.2f" % r)
	var g := w.nation_tags.find("GER")
	var s := w.nation_tags.find("SOV")
	var f := w.nation_tags.find("FRA")
	var pl := w.nation_tags.find("POL")
	check(w.nations[s].division_count > w.nations[g].division_count, "армия СССР должна быть больше германской")
	check(w.nations[g].mil > w.nations[pl].mil * 2, "промышленность Германии должна быть намного больше польской")
	check(w.nations[f].division_count > w.nations[g].division_count, "армия Франции в 1936 г. больше германской")
	if errors == 0:
		print("Данные 1936 г.: OK")
	quit(1 if errors > 0 else 0)
