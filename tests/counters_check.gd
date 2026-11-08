extends SceneTree
## Ядро стопок фишек (World.k_counters): C++ и GDScript дают одно и то же.
##   godot --headless --path . --script res://tests/counters_check.gd


func _init() -> void:
	Native.init()
	if Native.core == null:
		print("C++-ядро не загружено — сравнивать не с чем")
		quit(0)
		return
	var world := World.new()
	MapLoader.load_world(world)
	world.ai_wars = true
	var sim := Simulation.new(world)
	var ok := true
	var t_c := 0
	var t_g := 0
	for i in 200:
		sim.tick()
		if i % 20 != 19:
			continue
		var core = Native.core
		var t0 := Time.get_ticks_usec()
		var a: Array = world.k_counters()
		t_c += Time.get_ticks_usec() - t0
		Native.core = null
		t0 = Time.get_ticks_usec()
		var b: Array = world.k_counters()
		t_g += Time.get_ticks_usec() - t0
		Native.core = core
		for j in a.size():
			if a[j] != b[j]:
				push_error("день %d: поле %d различается" % [world.day, j])
				ok = false
	print("Стопки фишек: %s; C++ %.2f мс, GDScript %.2f мс за вызов" % ["OK" if ok else "РАЗЛИЧИЯ", t_c / 10000.0, t_g / 10000.0])
	world.dispose()
	quit(0 if ok else 1)
