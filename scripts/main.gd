extends Node
## Корень игры: создаёт мир, гоняет время, связывает карту, фишки и интерфейс.

# Скорости как в стратегиях жанра: 1 — неспешно, 5 — «сколько потянет
# процессор». Игровых дней в секунду; INF — максимум.
# Скорость 5 — фиксированные 8 дней/с: плавность важнее предельной скорости
# (неограниченный режим — только для замеров: -- --speed=6).
const SPEEDS := [0.0, 0.5, 1.0, 2.0, 4.0, 8.0, INF]
# Симуляция идёт в фоновом потоке; очередь не больше MAX_PENDING дней: если
# телефон не успевает, игра идёт медленнее, а картинка остаётся плавной.
const MAX_PENDING := 3
const MAX_PENDING_INF := 8   # на максимальной скорости

var world: World
var sim: Simulation
var map_view: MapView
var unit_layer: UnitLayer
var hud: Hud

var state := "loading"           # loading / select / play / over
var speed := 0
var _accum := 0.0
var days_per_sec := 0.0          # фактическая скорость, для индикатора
var selected_prov := -1
var selected_divs: Array = []
var selected_group := -1         # выбранная армия: касание карты задаёт ей цель
var selected_fleet := -1         # выбранный флот: касание моря — куда идти
var selected_wing := -1          # выбранное авиакрыло: касание карты — район задачи
var pick_nation := -1

# --- Фоновый поток симуляции --------------------------------------------------
# Мир меняет только поток симуляции (под sim_mutex). Главный поток читает мир
# только под тем же мьютексом: интерфейс и список отрисовки обновляются, когда
# мьютекс свободен (try_lock), а действия игрока ждут конца текущего дня.
var sim_thread: Thread
var sim_mutex := Mutex.new()       # рекурсивный: вложенные блокировки безопасны
var sim_sem := Semaphore.new()     # один post — один игровой день
var _pending_mutex := Mutex.new()
var _pending := 0
var _quitting := false
var ticks_done := 0
var _ticks_seen := 0
var _rate_time := 0.0
var _rate_ticks := 0
var _layer_dirty := true
var large_map := false
var procedural := false          # старая процедурная карта (для тестов): -- --procedural


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.09, 0.18, 0.29))
	map_view = MapView.new()
	add_child(map_view)
	var units_canvas := CanvasLayer.new()
	units_canvas.layer = 1
	add_child(units_canvas)
	unit_layer = UnitLayer.new()
	units_canvas.add_child(unit_layer)
	hud = Hud.new()
	hud.game = self
	add_child(hud)
	map_view.province_tapped.connect(_on_province_tapped)
	procedural = "--procedural" in OS.get_cmdline_user_args()
	# -- --single: всё в одном потоке (для сравнения с многоядерным режимом)
	single_thread = "--single" in OS.get_cmdline_user_args()
	if _arg("slow_tick") != "":
		_slow_tick_usec = int(float(_arg("slow_tick")) * 1000.0)
	if single_thread or "--no-parallel" in OS.get_cmdline_user_args():
		Parallel.enabled = false   # --no-parallel: фоновый поток есть, задачи внутри дня — нет
	if not single_thread:
		sim_thread = Thread.new()
		sim_thread.start(_sim_loop)
	await new_world(randi() % 100000 if _arg("seed") == "" else int(_arg("seed")))
	if _arg("screenshot") != "":
		_auto_screenshot(_arg("screenshot"))
	elif _arg("bench_rt") != "":
		_bench_realtime(float(_arg("bench_rt")))


func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return ""


## Отладка/CI: godot -- --screenshot=out.png [--days=N] [--zoom=Z] [--select]
## Замер в реальном времени: игра на максимальной скорости, время кадра главного
## потока (без отрисовки) и дни в секунду. -- --bench_rt=15 [--nation=GER] [--from=1939-09-01]
var _rt_cpu := 0.0
var _rt_gpu := 0.0


func _bench_realtime(seconds: float) -> void:
	var me := nation_by_tag(_arg("nation")) if _arg("nation") != "" else 0
	world_lock()
	start_as(me)
	if _arg("from") != "":
		while world.day < world.day_of(_arg("from")):
			if not world.pending_peace.is_empty():
				sim.resolve_peace("annex")
			world.pending_events.clear()
			sim.tick()
		world.events.clear()
	world_unlock()
	if _arg("zoom") != "":
		map_view.camera.zoom = Vector2.ONE * float(_arg("zoom"))
		map_view.center_on(world.nations[me].capital)
	speed = SPEEDS.size() - 1 if _arg("speed") == "" else int(_arg("speed"))
	var bench_speed := speed
	_ui_last = 0
	_ui_gap_max = 0
	_ui_count = 0
	var start_day := ticks_done
	var t0 := Time.get_ticks_msec()
	var frames := 0
	var worst := 0
	var total := 0
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		var f0 := Time.get_ticks_usec()
		if "--pan" in OS.get_cmdline_user_args():
			# замер сдвига и масштаба: камера ходит по кругу и «дышит»
			var tt := frames * 0.05
			map_view.camera.position += Vector2(cos(tt), sin(tt)) * 6.0 / map_view.camera.zoom.x
			map_view.camera.zoom = Vector2.ONE * clampf(map_view.camera.zoom.x * (1.0 + 0.01 * sin(tt * 0.7)), 0.3, 4.0)
			map_view._on_view_changed()
		await get_tree().process_frame
		var ft := Time.get_ticks_usec() - f0
		var vrid := get_viewport().get_viewport_rid()
		_rt_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vrid)
		_rt_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vrid)
		frames += 1
		total += ft
		worst = maxi(worst, ft)
		if ft > 30000:
			print("  долгий кадр %d: %.1f мс (день %d)" % [frames, ft / 1000.0, ticks_done - start_day])
		if not world.pending_events.is_empty() or not world.pending_peace.is_empty():
			world_lock()
			if not world.pending_events.is_empty():
				sim.resolve_event(0)
			if not world.pending_peace.is_empty():
				sim.resolve_peace("annex")
			world_unlock()
			speed = bench_speed
	var days := ticks_done - start_day
	print("BENCH_RT: %.1f с, дней %d (%.1f дн/с), кадров %d, средний кадр %.2f мс, худший %.2f мс, ядер %d" % [
		seconds, days, days / seconds, frames, total / 1000.0 / maxi(1, frames), worst / 1000.0, Parallel.thread_count()])
	print("  интерфейс: обновлений %d (%.1f в с), самая долгая пауза %.0f мс" % [_ui_count, _ui_count / seconds, _ui_gap_max / 1000.0])
	print("  отрисовка экрана: ЦП %.2f мс, ГП %.2f мс в среднем за кадр" % [_rt_cpu / maxi(1, frames), _rt_gpu / maxi(1, frames)])
	print("  карта: разрешение %d%%, цена полной перерисовки %.1f мс" % [int(map_view.res_scale * 100), map_view.last_cost_ms])
	print("  палитра обновлялась %d раз; слой фишек рисовался %d раз, в среднем %.2f мс" % [map_view.palette_version,
		unit_layer.draw_count, unit_layer.draw_total_usec / 1000.0 / maxi(1, unit_layer.draw_count)])
	var names := ["панели дня", "палитра", "список фишек", "верхняя строка"]
	for i in 4:
		print("  %s: всего %.0f мс за прогон, худшее %.1f мс" % [names[i], ui_prof_sum[i] / 1000.0, ui_prof_max[i] / 1000.0])
	speed = 0
	_shutdown()
	get_tree().quit()


func _auto_screenshot(path: String) -> void:
	world_lock()
	_auto_screenshot_locked()
	world_unlock()
	if "--nohud" in OS.get_cmdline_user_args():
		hud.visible = false   # для макетов оформления: только карта и фишки
	for i in 10:
		await get_tree().process_frame
	world_lock()
	hud.refresh_top()
	unit_layer.rebuild(selected_fleet, selected_wing)
	world_unlock()
	await get_tree().process_frame
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	if "--report" in OS.get_cmdline_user_args():
		print(Report.build(self))
	_shutdown()
	get_tree().quit()


func _auto_screenshot_locked() -> void:
	var days := int(_arg("days")) if _arg("days") != "" else 0
	var me := 0
	if _arg("nation") != "" and nation_by_tag(_arg("nation")) >= 0:
		me = nation_by_tag(_arg("nation"))
	if _arg("pick") == "":
		start_as(me)
		set_speed(0)
		var war_on := nation_by_tag(_arg("war")) if _arg("war") != "" else -1
		if "--group" in OS.get_cmdline_user_args():
			select_all()
			create_group_from_selection()
			if war_on >= 0:
				world.groups[selected_group].enemy = war_on
		var war_day := int(_arg("warday")) if _arg("warday") != "" else 0
		for i in days:
			if i == war_day and war_on >= 0:
				world.nations[me].pacts.erase(war_on)
				world.nations[war_on].pacts.erase(me)
				world.nations[me].wargoals[war_on] = true
				Diplomacy.declare_war(world, me, war_on)
				if selected_group >= 0:
					var g: World.ArmyGroup = world.groups[selected_group]
					g.mode = "attack"
					g.objective = world.nations[war_on].capital
			sim.tick()
		if selected_group >= 0:
			select_group(selected_group)
		hud.on_tick()
		if _arg("zoom") != "":
			map_view.camera.zoom = Vector2.ONE * float(_arg("zoom"))
			map_view.center_on(world.nations[me].capital)
		if _arg("center") != "" and nation_by_tag(_arg("center")) >= 0:
			map_view.center_on(world.nations[nation_by_tag(_arg("center"))].capital)
		if _arg("at") != "":   # -- --at=долгота,широта: центр на ближайшей провинции
			var ll := _arg("at").split(",")
			var target := Vector2(float(ll[0]), float(ll[1]))
			var best := 0
			for p in world.prov_count:
				if world.p_lonlat[p].distance_squared_to(target) < world.p_lonlat[best].distance_squared_to(target):
					best = p
			map_view.center_on(best)
		if _arg("sel") == "fleet":
			for f in world.fleets:
				if f.alive and f.owner == me:
					select_fleet(f.id)
					break
		if _arg("sel") == "wing":
			for wg in world.wings:
				if wg.alive and wg.owner == me:
					select_wing(wg.id)
					break
		if _arg("card") != "":
			hud._card_nation = nation_by_tag(_arg("card"))
		if _arg("mapmode") != "":
			set_map_mode(int(_arg("mapmode")))
		if _arg("event") != "":
			world.pending_events.append(_arg("event"))
		if "--focus" in OS.get_cmdline_user_args():
			hud.focus_view.open(self, world, me)
		if _arg("peace") != "":
			world.pending_peace.append([nation_by_tag(_arg("peace")), me])
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))
		if "--select" in OS.get_cmdline_user_args():
			_on_province_tapped(world.nations[me].capital)
	else:
		pick(me)
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))



func new_world(seed_value: int) -> void:
	world_lock()
	state = "loading"
	speed = 0
	_accum = 0.0
	world_unlock()
	hud.show_loading()
	await get_tree().process_frame
	await get_tree().process_frame
	world_lock()
	if world != null:
		world.dispose()
	world = World.new()
	var t := Time.get_ticks_msec()
	if procedural:
		MapGen.generate(world, seed_value, 800, 500, 14 if large_map else 22, 22 if large_map else 12)
	else:
		MapLoader.load_world(world)
	var load_ms := Time.get_ticks_msec() - t
	sim = Simulation.new(world)
	map_view.setup(world)
	unit_layer.map = map_view
	unit_layer.world = world
	unit_layer.player = -1
	unit_layer._labels_day = -1
	selected_divs.clear()
	unit_layer.selected = selected_divs
	selected_prov = -1
	pick_nation = -1
	state = "select"
	unit_layer.rebuild()
	world_unlock()
	if procedural:
		hud.gen_info = "Карта #%d: %d провинций, сгенерирована за %d мс на %d ядрах" % [seed_value, world.prov_count, load_ms, Parallel.thread_count()]
	else:
		hud.gen_info = "Европа, 1 января 1936 г.: %d провинций суши, %d морских зон · загрузка %d мс" % [world.land_count, world.prov_count - world.land_count, load_ms]
	hud.show_select(-1)


func nation_by_tag(tag: String) -> int:
	var i := world.nation_tags.find(tag)
	return i


func pick(nid: int) -> void:
	pick_nation = nid
	map_view.set_highlight_nation(nid)
	hud.show_select(nid)


func start_as(nid: int) -> void:
	for n in world.nations:
		n.is_player = n.id == nid
	world.nations[nid].current_research = ""
	unit_layer.player = nid
	map_view.set_highlight_nation(-1)
	map_view.set_selected(-1)
	map_view.camera.zoom = Vector2.ONE * 0.9
	map_view.center_on(world.nations[nid].capital)
	state = "play"
	speed = 0   # как в жанре: игра начинается на паузе
	world.log_event("Вы правите страной %s. Удачи!" % world.nations[nid].name)
	hud.show_play()


func player() -> int:
	return unit_layer.player


func world_lock() -> void:
	sim_mutex.lock()


func world_unlock() -> void:
	_layer_dirty = true
	sim_mutex.unlock()


## Цикл фонового потока: ждёт заказанный день, считает его под мьютексом.
func _sim_loop() -> void:
	while true:
		sim_sem.wait()
		if _quitting:
			return
		sim_mutex.lock()
		# на паузе заказанные дни сбрасываются — остановка сразу
		if state == "play" and sim != null and speed > 0:
			sim.tick()
			if _slow_tick_usec > 0:   # отладка: имитация медленного телефона
				var t0 := Time.get_ticks_usec()
				while Time.get_ticks_usec() - t0 < _slow_tick_usec:
					pass
			ticks_done += 1
		sim_mutex.unlock()
		_pending_mutex.lock()
		_pending = maxi(0, _pending - 1)
		_pending_mutex.unlock()
		# интерфейс ждёт мир — уступаем ему окно, иначе на максимальной
		# скорости поток сразу берёт замок снова и экран не обновляется
		var waited := 0
		while _ui_waiting and not _quitting and waited < 100:
			OS.delay_usec(250)
			waited += 1


var single_thread := false
var _slow_tick_usec := 0      # -- --slow_tick=20: +20 мс к каждому дню (как на слабом телефоне)
const UI_MAX_GAP_USEC := 40000  # экран обновляется не реже ~25 раз в секунду
var _ui_waiting := false      # главный поток ждёт мир: фоновый уступает после дня
var _ui_last := 0             # замер: время последнего обновления интерфейса
var _ui_gap_max := 0
var _ui_count := 0
const SINGLE_BUDGET_USEC := 8000   # однопоточный режим: время симуляции на кадр


func _request_days(n: int) -> void:
	if single_thread:
		# без фонового потока: дни считаются прямо в кадре, пока есть бюджет
		var t0 := Time.get_ticks_usec()
		for i in n:
			if state == "play" and sim != null:
				sim.tick()
				ticks_done += 1
			if Time.get_ticks_usec() - t0 > SINGLE_BUDGET_USEC:
				break
		return
	_pending_mutex.lock()
	_pending += n
	_pending_mutex.unlock()
	for i in n:
		sim_sem.post()


func _pending_days() -> int:
	_pending_mutex.lock()
	var v := _pending
	_pending_mutex.unlock()
	return v


func _process(dt: float) -> void:
	if state != "play":
		return
	# заказ дней фоновому потоку по выбранной скорости
	if speed > 0:
		var unlimited: bool = SPEEDS[speed] == INF
		var pending := _pending_days()
		if unlimited:
			if single_thread:
				_request_days(1000)   # до исчерпания бюджета кадра
			elif pending < MAX_PENDING_INF:
				# с запасом: фоновый поток не должен простаивать до следующего кадра
				_request_days(MAX_PENDING_INF - pending)
		else:
			_accum += dt * SPEEDS[speed]
			var want := int(_accum)
			if want > 0:
				_accum -= want
				var room := maxi(0, MAX_PENDING - pending)
				if room > 0:
					_request_days(mini(want, room))
			_accum = minf(_accum, 1.0)   # не копим долг: отставшая симуляция идёт медленнее
	# фактическая скорость
	_rate_time += dt
	if _rate_time >= 1.0:
		var t := ticks_done
		days_per_sec = lerpf(days_per_sec, (t - _rate_ticks) / _rate_time, 0.5)
		_rate_ticks = t
		_rate_time = 0.0
	# интерфейс и список отрисовки — только когда мир не занят симуляцией
	if sim_mutex.try_lock():
		_ui_waiting = false
		_ui_update()
		sim_mutex.unlock()
		var now := Time.get_ticks_usec()
		if _ui_last > 0:
			_ui_gap_max = maxi(_ui_gap_max, now - _ui_last)
		_ui_last = now
		_ui_count += 1
	elif Time.get_ticks_usec() - _ui_last > UI_MAX_GAP_USEC:
		_ui_waiting = true   # давно не обновлялись — попросить окно у симуляции


const PALETTE_MIN_MSEC := 500
var _palette_msec := 0


func _ui_update() -> void:
	if world.game_over != "":
		state = "over"
		hud.show_game_over(world.game_over)
		return
	if not world.pending_events.is_empty():
		if hud.popup_tab != "event" or not hud.popup.visible:
			speed = 0
			_accum = 0.0
			hud.open_tab("event")
	elif not world.pending_peace.is_empty():
		if hud.popup_tab != "peace" or not hud.popup.visible:
			speed = 0
			_accum = 0.0
			hud.open_tab("peace")
	var new_day := ticks_done != _ticks_seen
	var t0 := Time.get_ticks_usec()
	if new_day:
		_ticks_seen = ticks_done
		_prune_selection()
		hud.on_tick()
	var t1 := Time.get_ticks_usec()
	# захваты перекрашивают карту не чаще двух раз в секунду: на высоком качестве
	# полная перерисовка дорогая, а в войну владельцы меняются почти каждый день
	if world.palette_dirty and (speed == 0 or Time.get_ticks_msec() - _palette_msec >= PALETTE_MIN_MSEC):
		_palette_msec = Time.get_ticks_msec()
		map_view.update_palette()
	var t2 := Time.get_ticks_usec()
	if new_day or _layer_dirty:
		unit_layer.rebuild(selected_fleet, selected_wing)
		_layer_dirty = false
	var t3 := Time.get_ticks_usec()
	hud.refresh_top()
	var t4 := Time.get_ticks_usec()
	_ui_prof_note(0, t1 - t0)
	_ui_prof_note(1, t2 - t1)
	_ui_prof_note(2, t3 - t2)
	_ui_prof_note(3, t4 - t3)


# Худшее время участков обновления интерфейса за последнюю секунду (мкс):
# панели дня, палитра карты, список фишек, верхняя строка — для нижней строки.
var ui_prof := PackedInt32Array([0, 0, 0, 0])
var _ui_prof_cur := PackedInt32Array([0, 0, 0, 0])
var _ui_prof_msec := 0


var ui_prof_sum := PackedInt64Array([0, 0, 0, 0])
var ui_prof_max := PackedInt32Array([0, 0, 0, 0])


func _ui_prof_note(i: int, usec: int) -> void:
	_ui_prof_cur[i] = maxi(_ui_prof_cur[i], usec)
	ui_prof_sum[i] += usec
	ui_prof_max[i] = maxi(ui_prof_max[i], usec)
	var now := Time.get_ticks_msec()
	if i == 3 and now - _ui_prof_msec >= 1000:
		_ui_prof_msec = now
		ui_prof = _ui_prof_cur.duplicate()
		_ui_prof_cur.fill(0)


func _prune_selection() -> void:
	var alive: Array = []
	for d in selected_divs:
		if d.alive:
			alive.append(d)
	if alive.size() != selected_divs.size():
		selected_divs.clear()
		selected_divs.append_array(alive)


# --- Ввод с карты ------------------------------------------------------------

func _on_province_tapped(p: int) -> void:
	world_lock()
	_on_province_tapped_locked(p)
	world_unlock()


func _on_province_tapped_locked(p: int) -> void:
	if state == "select":
		if world.p_land[p] == 1:
			pick(world.p_owner[p])
		return
	if state != "play":
		return
	var me := player()
	# выбран флот -> идёт в морскую зону (касание берега — в соседнюю зону)
	if selected_fleet >= 0:
		var f: World.Fleet = world.fleets[selected_fleet]
		var zone := p
		if world.p_land[p] == 1:
			zone = -1
			for q in world.p_adj[p]:
				if world.p_land[q] == 0:
					zone = q
					break
		if zone >= 0:
			var path := Forces.sea_path(world, f.zone, zone)
			if zone == f.zone or not path.is_empty():
				f.path = path
				if f.mission == "port":
					f.mission = "patrol"
				hud.toast("%s идёт: %s (%d дн.)" % [f.name, world.p_name[zone], path.size()])
			else:
				hud.toast("Туда флоту не дойти")
		hud.show_fleet(f)
		return
	# выбрано авиакрыло -> район задачи
	if selected_wing >= 0:
		var w: World.AirWing = world.wings[selected_wing]
		var r: int = world.p_region[p]
		if Forces.wing_in_range(world, w, r):
			w.region = r
			hud.toast("%s: район %s" % [w.name, world.region_name[r]])
		else:
			hud.toast("Слишком далеко от наших аэродромов")
		hud.show_wing(w)
		return
	# выбрана армия -> касание задаёт направление наступления
	if selected_group >= 0:
		var g: World.ArmyGroup = world.groups[selected_group]
		if world.p_land[p] == 1:
			g.objective = p
			if world.p_controller[p] != me:
				g.mode = "attack"
				if g.enemy < 0 and world.p_controller[p] >= 0 and world.is_at_war(me, world.p_controller[p]):
					g.enemy = world.p_controller[p]
			hud.toast("%s: цель — %s" % [g.name, world.p_name[p]])
			map_view.set_selected(p)
			hud.show_group(g)
		return
	# есть выделенные войска -> приказ на движение
	if not selected_divs.is_empty() and p != selected_prov:
		var ok := 0
		for d in selected_divs:
			if sim.order_move(d, p):
				ok += 1
				d.group = -1   # ручной приказ выводит дивизию из армии
		if ok > 0:
			hud.toast("Приказ отдан: %d дивизий → %s" % [ok, world.p_name[p]])
			selected_prov = p
			map_view.set_selected(p)
			hud.show_selection()
			return
		# по суше не пройти — переправа в свой/союзный порт или высадка с моря
		var ctl := world.p_controller[p]
		if world.p_land[p] == 1 and Forces.is_port(world, p) and ctl >= 0 and (ctl == me or world.ally[me * world.nation_count + ctl] == 1):
			var twhy := Forces.sea_transfer(world, selected_divs, p)
			if twhy == "":
				hud.toast("Переправа → %s: %d дн." % [world.p_name[p], selected_divs[0].transit_days])
				clear_selection()
			else:
				hud.toast("Переправа невозможна: " + twhy)
			return
		if world.p_land[p] == 1 and world.p_coastal[p] == 1:
			var why := Forces.plan_invasion(world, selected_divs, p)
			if why == "":
				var plan: World.InvasionPlan = world.invasions[world.invasions.size() - 1]
				hud.toast("Готовим высадку → %s: %d дн. Войска ждут в порту" % [world.p_name[p], plan.total])
				clear_selection()
				return
			hud.toast("Высадка невозможна: " + why)
		else:
			hud.toast("Туда не пройти: нужна война с владельцем")
	# повторное касание той же провинции снимает выделение
	if p == selected_prov and not selected_divs.is_empty():
		clear_selection()
		hud.show_province(p)
		return
	selected_prov = p
	map_view.set_selected(p)
	selected_divs.clear()
	for d in world.divs_in(p):
		if d.alive and d.owner == me:
			selected_divs.append(d)
	if selected_divs.is_empty():
		hud.show_province(p)
	else:
		hud.show_selection()


func clear_selection() -> void:
	selected_group = -1
	selected_fleet = -1
	selected_wing = -1
	selected_divs.clear()
	selected_prov = -1
	map_view.set_selected(-1)
	hud.hide_info()


func select_all() -> void:
	selected_group = -1
	selected_divs.clear()
	for d in world.divisions_of(player()):
		if not d.in_battle:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(-1)
	hud.show_selection()


# --- Армии -----------------------------------------------------------------

func create_group_from_selection() -> void:
	if selected_divs.is_empty():
		return
	var g := sim.create_group(player(), selected_divs)
	# по умолчанию — против ближайшего противника, иначе держать границу
	for e in world.nations[player()].at_war:
		g.enemy = e
		break
	select_group(g.id)
	hud.toast("Создана %s: %d дивизий" % [g.name, selected_divs.size()])


func select_fleet(id: int) -> void:
	clear_selection()
	selected_fleet = id
	hud.show_fleet(world.fleets[id])


func select_wing(id: int) -> void:
	clear_selection()
	selected_wing = id
	hud.show_wing(world.wings[id])


func select_group(id: int) -> void:
	var g: World.ArmyGroup = world.groups[id]
	selected_group = id
	selected_divs.clear()
	for d in world.divisions:
		if d.alive and d.group == id:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(g.objective)
	hud.show_group(g)


func group_divisions(id: int) -> Array:
	var res: Array = []
	for d in world.divisions:
		if d.alive and d.group == id:
			res.append(d)
	return res


## Противники для выбора фронта армии: страны в войне с нами и соседи.
func enemy_options() -> Array:
	var me := player()
	var opts: Array = [-1]
	for e in world.nations[me].at_war:
		opts.append(e)
	for nb in world.neighbours_of_nation(me):
		if not opts.has(nb) and not Diplomacy.same_side(world, me, nb):
			opts.append(nb)
	return opts


func stop_selected() -> void:
	for d in selected_divs:
		d.path = PackedInt32Array()
		d.progress = 0.0


# --- Действия игрока ---------------------------------------------------------

func set_speed(s: int) -> void:
	speed = clampi(s, 0, 5)   # 6 (без ограничения) — только для замеров


func train(count: int, tpl: int = Military.T_INF) -> int:
	var made := 0
	for i in count:
		if sim.train_division(player(), tpl):
			made += 1
	return made


func declare_war_on(target: int) -> void:
	Diplomacy.declare_war(world, player(), target)
	hud.on_tick()


func resolve_event(option: int) -> void:
	sim.resolve_event(option)
	hud.close_popup()
	hud.on_tick()
	if not world.pending_events.is_empty():
		hud.open_tab("event")


func resolve_peace(mode: String) -> void:
	sim.resolve_peace(mode)
	hud.close_popup()
	hud.on_tick()


## Что-то поменялось по действию игрока (дипломатия) — обновить карту и журнал.
func hud_changed() -> void:
	hud.on_tick()


func set_map_mode(m: int) -> void:
	map_view.set_map_mode(m)


func _shutdown() -> void:
	if sim_thread != null and sim_thread.is_started():
		_quitting = true
		sim_sem.post()
		sim_thread.wait_to_finish()
		sim_thread = null


func _exit_tree() -> void:
	_shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if hud != null and hud.close_popup():
			return
		if not selected_divs.is_empty():
			clear_selection()
