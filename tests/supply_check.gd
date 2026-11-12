extends SceneTree
## Узлы снабжения: нагрузка по узлам (ближайший — основная, соседи — остаток),
## улучшение узла, присоединение захваченного, доставка грузовиками.
##   godot --headless --path . --script res://tests/supply_check.gd

var errors := 0


func check(cond: bool, msg: String) -> void:
	if not cond:
		errors += 1
		push_error("ПРОВАЛ: " + msg)
	else:
		print("  ok: ", msg)


func _init() -> void:
	var w := World.new()
	MapLoader.load_world(w)
	var sim := Simulation.new(w)
	var GER := w.nation_tags.find("GER")
	var POL := w.nation_tags.find("POL")
	var ger: World.Nation = w.nations[GER]
	ger.is_player = true
	for i in 3:
		sim.tick()
	var s := Supply.side(w, GER)
	var nr := w.region_count
	# провинция Германии не у столицы: узел её района
	var p := -1
	var k0 := -1
	for q in w.prov_count:
		if w.p_controller[q] == GER and w.p_land[q] == 1 and w.p_region[q] != w.p_region[ger.capital] \
				and w.p_mass[q] == w.p_mass[ger.capital] and _inland(w, q, GER):
			var k := s * nr + w.p_region[q]
			if w.node_prov[k] >= 0 and w.node_prov[k] != q and w.node_f[k] > 0.0:
				p = q
				k0 = k
				break
	if p < 0:
		push_error("ПРОВАЛ: не нашлась провинция для проверки")
		quit()
		return
	print("Нагрузка по узлам (%s, узел %s):" % [w.p_name[p], w.p_name[w.node_prov[k0]]])
	var before := w.node_used.duplicate()
	for i in 60:
		w.spawn_division(GER, p, Military.T_INF)
	for i in 2:
		sim.tick()
	var cap0 := w.node_f[k0] * Supply.BUDGET_K
	check(w.node_used[k0] >= w.node_f[k0] * 0.5, "ближайший узел взял основную нагрузку (%.1f, бюджет %.1f; в одну провинцию — не больше подачи с затуханием)" % [w.node_used[k0], cap0])
	var extra := 0.0
	for k in w.node_keys:
		if k != k0:
			extra += maxf(0.0, w.node_used[k] - (before[k] if k < before.size() else 0.0))
	check(extra > 1.0, "остаток взяли соседние узлы (+%.1f)" % extra)
	var sup := 0.0
	var cnt := 0
	for i in w.d_alive.size():
		if w.d_alive[i] == 1 and w.d_prov[i] == p:
			sup += w.d_sup[i]
			cnt += 1
	check(sup / cnt < 0.9, "60 дивизий в одной провинции не накормить (%.0f%%)" % (sup / cnt * 100.0))

	print("Улучшение узла и грузовики:")
	var hub := w.node_prov[k0]
	var f0 := w.node_f[k0]
	w.p_node_lvl[hub] = 2
	for i in 2:
		sim.tick()
	check(w.node_f[k0] > f0 * 1.45, "уровень 2: подача узла +50%% (%.1f → %.1f)" % [f0, w.node_f[k0]])
	var f1 := w.node_f[k0]
	ger.truck_mode = 2
	ger.stock[Military.EQ_TRUCK] = 1000.0
	for i in 3:
		sim.tick()
	check(w.node_f[k0] > f1 * 1.35, "грузовики: подача +40%% (%.1f → %.1f)" % [f1, w.node_f[k0]])
	check(ger.truck_use > 0.0 and ger.truck_ok >= 1.0, "грузовики расходуются (%.2f в день)" % ger.truck_use)
	var tc := ger.stock[Military.EQ_TRUCK]
	var jobs_before := ger.sup_jobs.size()
	check(Supply.order(w, ger, hub, Supply.JOB_UP) and ger.sup_jobs.size() == jobs_before + 1, "заказ на улучшение узла принят")
	var lv := w.p_node_lvl[hub]
	for i in 60:
		sim.tick()
	check(w.p_node_lvl[hub] == lv + 1, "за 60 дней стройка подняла уровень узла (%d → %d)" % [lv, w.p_node_lvl[hub]])

	print("Захваченный узел:")
	# без войны: контроль меняем сами, чтобы Польша не отбила район за время проверки
	# польский район у германской границы: все его польские провинции — Германии
	var reg := -1
	for r in w.region_count:
		if w.r_hub[r] >= 0 and w.p_owner[w.r_hub[r]] == POL:
			reg = r
			break
	for q in w.prov_count:
		if w.p_land[q] == 1 and w.p_controller[q] == POL:
			w.p_controller[q] = GER
	ger.sup_auto = false
	for i in 3:
		sim.tick()
	var kg := s * nr + reg
	check(w.node_hub[kg] >= 0 and not Supply.node_ok(w, s, w.node_hub[kg]) and w.node_prov[kg] != w.node_hub[kg], "взятый узел %s не работает без присоединения" % w.p_name[w.node_hub[kg]])
	ger.sup_jobs.clear()
	check(Supply.order(w, ger, w.node_hub[kg], Supply.JOB_JOIN), "заказ на присоединение принят")
	for i in 10:
		sim.tick()
	check(Supply.node_ok(w, s, w.node_hub[kg]) and w.node_prov[kg] >= 0, "после присоединения узел работает (подача %.1f)" % w.node_f[kg])
	print("Итог: ", "OK" if errors == 0 else "ошибок %d" % errors)
	quit()


## Все сухопутные соседи — свои (не у границы, не анклав).
func _inland(w: World, q: int, n: int) -> bool:
	for e in w.p_adj[q]:
		if w.p_land[e] == 1 and w.p_controller[e] != n:
			return false
	return true
