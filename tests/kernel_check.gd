extends SceneTree
## Сверка ядер C++ и двойников GDScript (convoy_danger, depots_scan, convoy_day, contracts_sig, border_counts, fog_table, side_provs — с 1936 г. в каждый день ИИ) по дням 1939–41 гг.
##   godot --headless --path . --script res://tests/kernel_check.gd
func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var from := w.day_of("1939-08-20")
	var until := w.day_of("1941-09-01")
	Convoys.kernel_check = [0, 0]
	World.fog_check = [0, 0]
	AIPlanner.wl_check = [0, 0]
	var checks := 0
	var bad := 0
	while w.day < until:
		if not w.pending_peace.is_empty():
			sim.resolve_peace("annex")
		sim.tick()
		w.events.clear()
		if w.day < from or (w.day % 3 != 0):
			continue
		var qn := PackedInt32Array()
		var qb := PackedInt32Array()
		for nat in w.nations:
			if nat.alive and not nat.conv_routes.is_empty() and not nat.at_war.is_empty():
				for bi in nat.conv_basins:
					qn.append(nat.id)
					qb.append(int(bi))
		if not qn.is_empty():
			var t := Convoys._danger_t(w, qn, qb)
			var a: Array = Native.core.call("convoy_danger", t)
			var b: Array = Convoys._danger_gd(t)
			checks += 1
			if var_to_bytes(a) != var_to_bytes(b):
				bad += 1
				print("РАСХОЖДЕНИЕ danger ", w.date_string() if w.has_method("date_string") else w.day)
		checks += 1
		var sa: float = Native.core.call("contracts_sig", w.contracts)
		if sa != Convoys.contracts_sig_gd(w.contracts):
			bad += 1
			print("РАСХОЖДЕНИЕ подписи договоров, день ", w.day)
		checks += 1
		var ba: PackedInt32Array = Native.core.call("border_counts", w.p_controller, w.adj_start, w.adj_list, w.nation_count)
		if ba != Simulation.border_gd(w.p_controller, w.adj_start, w.adj_list, w.nation_count):
			bad += 1
			print("РАСХОЖДЕНИЕ border_counts, день ", w.day)
		var dl: PackedInt32Array = Depots.mask_list(w)[1]
		var t2 := Depots._scan_t(w, dl)
		var a2: Array = Native.core.call("depots_scan", t2)
		var b2: Array = Depots._scan_gd(t2)
		checks += 1
		if var_to_bytes(a2) != var_to_bytes(b2):
			bad += 1
			for i in a2.size():
				if var_to_bytes(a2[i]) != var_to_bytes(b2[i]):
					print("РАСХОЖДЕНИЕ scan день ", w.day, " поле ", i)
	print("СВЕРКА fog_table: проверок %d, расхождений %d" % [World.fog_check[0], World.fog_check[1]])
	print("СВЕРКА side_provs: проверок %d, расхождений %d" % [AIPlanner.wl_check[0], AIPlanner.wl_check[1]])
	print("СВЕРКА convoy_day: проверок %d, расхождений %d" % [Convoys.kernel_check[0], Convoys.kernel_check[1]])
	print("СВЕРКА ЯДЕР: проверок %d, расхождений %d" % [checks, bad])
	w.dispose()
	quit()
