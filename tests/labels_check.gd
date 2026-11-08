extends SceneTree
## Подписи стран: C++ (MeowqCore.label_regions) и GDScript дают те же места.
##   godot --headless --path . --script res://tests/labels_check.gd


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
	for i in 120:
		sim.tick()
	var ul := UnitLayer.new()
	ul.world = world
	var core = Native.core
	var t0 := Time.get_ticks_usec()
	ul._rebuild_labels()
	var t_c := Time.get_ticks_usec() - t0
	var a: Array = ul._labels.duplicate(true)
	Native.core = null
	t0 = Time.get_ticks_usec()
	ul._rebuild_labels()
	var t_g := Time.get_ticks_usec() - t0
	var b: Array = ul._labels.duplicate(true)
	Native.core = core
	var ok := a.size() == b.size()
	var by_name := {}
	for l in b:
		by_name[l[1]] = l
	var worst := 0.0
	for l in a:
		if not by_name.has(l[1]):
			ok = false
			continue
		var m: Array = by_name[l[1]]
		worst = maxf(worst, (l[0] - m[0]).length())
		if absf(l[2] - m[2]) > 0.01 or absf(l[3] - m[3]) > 0.01:
			ok = false
	ok = ok and worst < 0.5
	print("Подписи: %s (%d шт., расхождение мест %.4f пикс.); C++ %.2f мс, GDScript %.2f мс" % [
		"OK" if ok else "РАЗЛИЧИЯ", a.size(), worst, t_c / 1000.0, t_g / 1000.0])
	ul.free()
	world.dispose()
	quit(0 if ok else 1)
