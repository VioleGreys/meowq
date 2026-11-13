extends SceneTree
## Ход кампаний против исторических дат: когда ключевые города меняют хозяина,
## капитуляции, фокусы сторон, раз в месяц — дивизии и доля своих очков победы.
##   --front=east  — Германия против СССР (с 1941 г.);
##   --front=china — Япония против Китая (с 1937 г.).
##   godot --headless --path . --script res://tests/campaign_diag.gd -- --front=east [--until=1945-06-01 --seed=N --brief]

const FRONTS := {
	"east": {
		"from": "1941-06-01", "until": "1943-03-01",
		"tags": ["GER", "SOV", "FIN", "ROM", "HUN", "ITA"],
		"focus": ["GER", "SOV"],
		# город: историческая дата падения (или «не пал»)
		"cities": [["Брест", ""], ["Вильно", "24.06.41"], ["Минск", "28.06.41"], ["Рига", "01.07.41"], ["Львов", "30.06.41"],
			["Витебск", "11.07.41"], ["Смоленск", "16.07.41"], ["Таллин", "28.08.41"], ["Киев 1", "19.09.41"],
			["Одесса", "16.10.41"], ["Ленинград", "не пал"], ["Тихвин", "08.11.41"], ["Вязьма", "07.10.41"],
			["Калинин", "14.10.41"], ["Харьков", "24.10.41"], ["Сталино", "21.10.41"], ["Ростов-на-Дону", "21.11.41"],
			["Тула", "не пала"], ["Москва", "не пала"], ["Севастополь", "04.07.42"], ["Воронеж", "07.42 (часть)"],
			["Краснодар", "09.08.42"], ["Сталинград", "не пал"], ["Баку", "не пал"], ["Варшава", ""], ["Кёнигсберг", "09.04.45"],
			["Бухарест", "31.08.44"], ["Будапешт", "13.02.45"], ["Берлин", "02.05.45"]],
	},
	"china": {
		"from": "1937-06-01", "until": "1942-01-01",
		"tags": ["JAP", "MAN", "CHI", "PRC", "SHX", "GXC", "YUN", "XSM", "SIK"],
		"focus": ["JAP", "CHI"],
		"cities": [["Бэйпин", "29.07.37"], ["Тяньцзинь", "30.07.37"], ["Датун", "13.09.37"], ["Тайюань", "08.11.37"],
			["Шанхай", "26.11.37"], ["Уси", "25.11.37"], ["Нанкин", "13.12.37"], ["Ханчжоу", "24.12.37"], ["Циндао", "10.01.38"],
			["Цзаочжуан", "05.38 (Сюйчжоу)"], ["Чжэнчжоу", "1944"], ["Кантон", "21.10.38"], ["Ханькоу", "25.10.38"],
			["Юэян", "11.11.38"], ["Наньчан", "27.03.39"], ["Наньнин", "24.11.39"], ["Ичан", "12.06.40"], ["Чанша", "18.06.44"],
			["Хэнъян", "08.08.44"], ["Гуйлинь", "10.11.44"], ["Чунцин 1", "не пал"], ["Сиань", "не пал"], ["Куньмин", "не пал"],
			["Юйлинь", "не пал (Яньань)"]],
	},
}


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var front := "east"
	for a in args:
		if a.begins_with("--front="):
			front = a.split("=")[1]
	var cfg: Dictionary = FRONTS[front]
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var until: String = cfg["until"]
	var from: String = cfg["from"]
	var brief := "--brief" in args
	for a in args:
		if a.begins_with("--until="):
			until = a.split("=")[1]
		if a.begins_with("--from="):
			from = a.split("=")[1]
		if a.begins_with("--seed="):
			w.seed_value = int(a.split("=")[1])
	var end_day := w.day_of(until)
	var from_day := w.day_of(from)
	var names := Array(w.p_name)
	var cps: Array = []
	var ctrl: Array = []
	var first: Array = []
	for c in cfg["cities"]:
		var p: int = names.find(c[0])
		if p < 0:
			print("нет провинции: ", c[0])
		cps.append(p)
		ctrl.append(w.p_controller[p] if p >= 0 else -1)
		first.append("")
	var tags: Array = cfg["tags"]
	var ftags: Array = []
	for t in cfg["focus"]:
		ftags.append(w.nation_tags.find(t))
	var fdone := {}
	print("ФРОНТ %s, зерно %d, %s – %s" % [front, w.seed_value, from, until])
	while w.day < end_day:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("auto")
		sim.tick()
		var watching := w.day >= from_day
		for e in w.events:
			if watching and ("капитулирует" in e or "объявляет войну" in e or "план" in e or "переезжает" in e or "столиц" in e or "высадк" in e or "переправ" in e):
				print("  %s — %s" % [w.date_short(), e])
		w.events.clear()
		for n2 in ftags:
			if n2 < 0:
				continue
			for f in w.nations[n2].focus_done:
				if not fdone.has(f):
					fdone[f] = true
					if watching and not brief:
						print("  %s  фокус %s %s" % [w.date_short(), w.nation_tags[n2], f])
		for i in cps.size():
			var p: int = cps[i]
			if p < 0:
				continue
			var c := w.p_controller[p]
			if c != ctrl[i]:
				ctrl[i] = c
				var who := w.nation_tags[c] if c >= 0 else "-"
				if first[i] == "":
					first[i] = "%s→%s" % [w.date_short(), who]
				if watching:
					print("  %s  %s → %s   (история: %s)" % [w.date_short(), cfg["cities"][i][0], who, cfg["cities"][i][1]])
		if not watching or not w.date_short().begins_with("01."):
			continue
		var parts: Array = []
		for tg in tags:
			var n := w.nation_tags.find(tg)
			if n < 0 or not w.nations[n].alive:
				continue
			var divs := 0
			for d in w.divisions:
				if d.alive and d.owner == n:
					divs += 1
			var vt := 0
			var vh := 0
			for p in w.prov_count:
				if w.p_owner[p] == n and w.p_vp[p] > 0:
					vt += w.p_vp[p]
					if w.p_controller[p] == n or (w.p_controller[p] >= 0 and Diplomacy.same_side(w, w.p_controller[p], n)):
						vh += w.p_vp[p]
			parts.append("%s %dд ОП%d%%%s%s" % [tg, divs, roundi(100.0 * vh / maxf(vt, 1)),
				"*" if not w.nations[n].at_war.is_empty() else "", " кап" if w.nations[n].capitulated else ""])
		print("%s  %s" % [w.date_short(), "  ".join(parts)])
	var sum: Array = []
	for i in cps.size():
		sum.append("%s %s" % [cfg["cities"][i][0], first[i] if first[i] != "" else "держится"])
	print("ИТОГ seed=%d: %s" % [w.seed_value, "; ".join(sum)])
	quit(0)
