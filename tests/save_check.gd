extends SceneTree
## Сохранение и загрузка: партия после загрузки обязана идти день в день так же,
## как без неё. Мир доводится до нескольких дат, в каждой сохраняется; затем
## сохранение загружается в новый мир, оба идут ещё STEP дней, и сравнивается
## всё состояние (SaveGame.encode), а не подпись.
##   godot --headless --path . --script res://tests/save_check.gd [-- --dates=1936-03-01,1939-10-01 --step=40 --nation=SWE]

var step := 40


func _arg(name: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return def


func _init() -> void:
	step = int(_arg("step", "40"))
	var dates := _arg("dates", "1936-02-10,1937-06-01,1939-10-15,1940-06-01").split(",")
	var world := World.new()
	MapLoader.load_world(world)
	var sim := Simulation.new(world)
	var player := world.nation_tags.find(_arg("nation", "GER"))
	world.nations[player].is_player = true
	var bad := 0
	for date in dates:
		var target := world.day_of(date)
		while world.day < target and world.game_over == "":
			_answer(world, sim)
			sim.tick()
		if world.game_over != "":
			# страна «игрока» в тесте никем не управляется и может пасть — дальше дни не идут
			print("%s: партия закончилась (%s) — для дальних дат взять нейтральную страну (--nation=SWE)" % [world.date_string(), world.game_over])
			break
		var t0 := Time.get_ticks_msec()
		var err := SaveGame.write("_check", world, sim, {"title": "проверка"})
		var t1 := Time.get_ticks_msec()
		if err != "":
			push_error("Запись: " + err)
			quit(1)
			return
		var meta := SaveGame.read_meta("_check")
		var w2 := World.new()
		MapLoader.load_world(w2)
		var sim2 := Simulation.new(w2, false)
		var t2 := Time.get_ticks_msec()
		var res := SaveGame.load_into("_check", w2, sim2)
		var t3 := Time.get_ticks_msec()
		if res["err"] != "":
			push_error("Загрузка: " + str(res["err"]))
			quit(1)
			return
		print("%s: дивизий %d, файл %.0f КБ, запись %d мс, чтение %d мс" % [meta["date"], world.divisions.size(),
			int(meta["size"]) / 1024.0, t1 - t0, t3 - t2])
		var d0 := _diff(world, sim, w2, sim2)
		if not d0.is_empty():
			print("  сразу после загрузки отличается: ", d0)
			bad += 1
		# копия идёт вперёд; основная партия — тоже, и их состояния обязаны совпасть
		for i in step:
			_answer(w2, sim2)
			sim2.tick()
		for i in step:
			_answer(world, sim)
			sim.tick()
		var d1 := _diff(world, sim, w2, sim2)
		if d1.is_empty():
			print("  через %d дней после загрузки состояние совпадает" % step)
		else:
			print("  через %d дней после загрузки отличается: " % step, d1)
			bad += 1
		w2.dispose()
	SaveGame.remove("_check")
	if bad > 0:
		push_error("Сохранение не воспроизводит партию")
		quit(1)
		return
	print("Сохранение и загрузка: OK")
	quit(0)


## Ответы за игрока, чтобы ход не останавливался.
func _answer(w: World, s: Simulation) -> void:
	w.info_events.clear()
	w.info_option.clear()
	while not w.pending_events.is_empty():
		s.resolve_event(0)
	while not w.pending_peace.is_empty():
		s.resolve_peace("annex")


## Названия полей мира, которые различаются.
func _diff(a: World, sa: Simulation, b: World, sb: Simulation) -> Array:
	var ea := SaveGame.new().encode(a, sa)
	var eb := SaveGame.new().encode(b, sb)
	var res: Array = []
	for part in ["world", "sim"]:
		var da: Dictionary = ea[part]
		var db: Dictionary = eb[part]
		for k in da:
			if var_to_bytes(da[k]) != var_to_bytes(db.get(k)):
				res.append(k)
	return res
