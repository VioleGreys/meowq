extends SceneTree
## Пути «многим сразу» (Pathfinder.paths_to) против поиска по одной дивизии:
## та же длина, каждый шаг — в соседнюю проходимую провинцию.
##   godot --headless --path . --script res://tests/paths_check.gd
func _init():
	var w := World.new()
	MapLoader.load_world(w)
	var _sim := Simulation.new(w)
	var nat := w.nation_tags.find("GER")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var own := PackedInt32Array()
	for p in w.prov_count:
		if w.p_controller[p] == nat:
			own.append(p)
	var bad := 0
	var total := 0
	var t_one := 0
	var t_many := 0
	for trial in 20:
		var to := own[rng.randi() % own.size()]
		var srcs := PackedInt32Array()
		for i in 60:
			srcs.append(own[rng.randi() % own.size()])
		var t0 := Time.get_ticks_usec()
		var many := Pathfinder.paths_to(w, nat, to, srcs)
		t_many += Time.get_ticks_usec() - t0
		for s in srcs:
			t0 = Time.get_ticks_usec()
			var one := Pathfinder.find_path(w, nat, s, to)
			t_one += Time.get_ticks_usec() - t0
			total += 1
			var m: PackedInt32Array = many.get(s, PackedInt32Array())
			if one.size() != m.size():
				bad += 1
				continue
			var prev := s
			for q in m:
				var adj := false
				for k in range(w.adj_start[prev], w.adj_start[prev + 1]):
					if w.adj_list[k] == q:
						adj = true
				if not adj or not w.can_enter(nat, q):
					bad += 1
					break
				prev = q
	print("путей %d, расхождений %d; по одной %.1f мс, все сразу %.1f мс" % [total, bad, t_one / 1000.0, t_many / 1000.0])
	print("Пути: OK" if bad == 0 else "Пути: ПРОВАЛ")
	quit(1 if bad > 0 else 0)
