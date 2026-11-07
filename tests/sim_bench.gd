extends SceneTree
## Безголовый прогон: загружает карту Европы 1936 г. (или генерирует
## процедурную), гоняет симуляцию в однопоточном и многопоточном режимах,
## проверяет детерминизм и печатает замеры.
##   godot --headless --path . --script res://tests/sim_bench.gd
##   ... -- --procedural [--large]   процедурная карта
## ИИ-войны в тесте включены принудительно, чтобы нагрузить бои и движение.

const DAYS := 400


var cell := 22
var nation_count := 12
var procedural := false


func _init() -> void:
	print("Ядер: ", OS.get_processor_count())
	procedural = "--procedural" in OS.get_cmdline_user_args()
	if "--large" in OS.get_cmdline_user_args():
		cell = 13
		nation_count = 24
	var single := _run(false)
	var multi := _run(true)
	print("Однопоточно: загрузка %.0f мс, %d дней за %.0f мс" % [single[0], DAYS, single[1]])
	print("Многопоточно: загрузка %.0f мс, %d дней за %.0f мс" % [multi[0], DAYS, multi[1]])
	print("Ускорение симуляции: x%.2f" % (single[1] / maxf(1.0, multi[1])))
	if single[2] != multi[2]:
		push_error("Результаты различаются! %s vs %s" % [single[2], multi[2]])
		quit(1)
		return
	print("Детерминизм: OK (", multi[2], ")")
	quit(0)


func _run(parallel: bool) -> Array:
	Parallel.enabled = parallel
	var world := World.new()
	var t := Time.get_ticks_msec()
	var timings := {}
	if procedural:
		timings = MapGen.generate(world, 12345, 800, 500, cell, nation_count)
	else:
		timings = MapLoader.load_world(world)
	world.ai_wars = true
	var gen_ms := Time.get_ticks_msec() - t
	if parallel:
		print("Провинций: %d (суша %d), стран: %d, дивизий: %d" % [world.prov_count, world.land_count, world.nations.size(), world.divisions.size()])
		print("Фазы генерации (мкс): ", timings)
	var sim := Simulation.new(world)
	t = Time.get_ticks_msec()
	for i in DAYS:
		sim.tick()
	var sim_ms := Time.get_ticks_msec() - t
	var alive := 0
	for n in world.nations:
		if n.alive:
			alive += 1
	var wars := 0
	for n in world.nations:
		wars += n.at_war.size()
	if parallel:
		for e in world.events.slice(maxi(0, world.events.size() - 12)):
			print("  · ", e)
		print("Фазы последнего тика (мкс): ", sim.phase_usec)
	var signature := "живых=%d войн=%d дивизий=%d день=%d хэш=%d" % [alive, wars / 2, world.divisions.size(), world.day, hash(world.p_controller)]
	return [gen_ms, sim_ms, signature]
