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

var state := "loading"           # loading / menu / select / play / over
var world_fresh := false         # мир только что собран (1 января 1936 г.), партия не начата
var speed := 0
var _accum := 0.0
var days_per_sec := 0.0          # фактическая скорость, для индикатора
var selected_prov := -1
var selected_divs: Array = []
var selected_group := -1         # выбранная армия: касание карты задаёт ей цель
var selected_front := -1         # выбранная группа армий (World.fronts): цель — всем её армиям
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
var _frame_mutex := Mutex.new()   # конвейер экрана (_publish/_take_frame)
var _frame_top := {}
var _frame_list: Array = []
var _frame_day := -1
var _frame_taken := true
var _frame_new := false
var _cmds: Array = []             # действия игрока, ждущие границы дня (act)
var _cmd_mutex := Mutex.new()
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
	map_view.province_painted.connect(_on_province_painted)
	autosave_on = Settings.autosave()
	if _arg("autosave_sec") != "":
		autosave_usec = int(float(_arg("autosave_sec")) * 1000000.0)
	procedural = "--procedural" in OS.get_cmdline_user_args()
	# -- --single: всё в одном потоке (для сравнения с многоядерным режимом)
	single_thread = "--single" in OS.get_cmdline_user_args()
	if _arg("slow_tick") != "":
		_slow_tick_usec = int(float(_arg("slow_tick")) * 1000.0)
	if single_thread or "--no-parallel" in OS.get_cmdline_user_args():
		Parallel.enabled = false   # --no-parallel: фоновый поток есть, задачи внутри дня — нет
	if not single_thread:
		sim_thread = Thread.new()
		# на телефоне — пониже главного потока: кадры важнее, запас по дням есть
		sim_thread.start(_sim_loop, Thread.PRIORITY_LOW if Device.mobile() else Thread.PRIORITY_NORMAL)
	# инструменты (скриншот, замер) идут сразу к выбору страны, игрок — в главное меню
	var tool := _arg("screenshot") != "" or _arg("bench_rt") != "" or "--stress" in OS.get_cmdline_user_args()
	# кадр рисуется, только когда на экране что-то изменилось (решение
	# пользователя, ноябрь 2026: телефон меньше греется — дольше держит частоты);
	# в инструментах — только с -- --lowproc
	_lowproc = not tool or "--lowproc" in OS.get_cmdline_user_args()
	OS.low_processor_usage_mode = _lowproc
	await new_world(randi() % 100000 if _arg("seed") == "" else int(_arg("seed")), "select" if tool else "menu")
	if _arg("screenshot") != "":
		_auto_screenshot(_arg("screenshot"))
	elif _arg("bench_rt") != "":
		_bench_realtime(float(_arg("bench_rt")))
	elif "--stress" in OS.get_cmdline_user_args():
		var sb := StressBench.new()
		add_child(sb)
		if "--ingame" in OS.get_cmdline_user_args():   # проверка пути кнопки «Проверка нагрузки»
			world_lock()
			start_as(nation_by_tag(_arg("nation")) if _arg("nation") != "" else 0)
			world_unlock()
			await sb.run(self, true)
			print("STRESS_INGAME: партия %s, %s" % [world.nations[player()].name, world.date_string()])
			_shutdown()
			get_tree().quit()
		else:
			sb.run(self)


func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return ""


## Отладка/CI: godot -- --screenshot=out.png [--days=N] [--zoom=Z] [--select]
## Замер в реальном времени: игра на максимальной скорости, время кадра главного
## потока (без отрисовки) и дни в секунду. -- --bench_rt=15 [--nation=GER] [--from=1939-09-01]
var _rt_cpu := 0.0
var _drawn0 := 0
var _lowproc := false   # «не рисовать без изменений»: включено, пока карта стоит
var _dbg_noui := false
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
			world.info_events.clear()
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
	_fresh_count = 0
	_fresh_gap = 0
	_fresh_last = 0
	if "--nounits" in OS.get_cmdline_user_args():
		unit_layer.visible = false
	if "--nohud" in OS.get_cmdline_user_args():
		hud.visible = false
	if "--pan" in OS.get_cmdline_user_args():
		for i in 60:   # карта стоит секунду (как в игре до первого сдвига): кэш движения строится
			await get_tree().process_frame
	_dbg_noui = "--noui" in OS.get_cmdline_user_args()
	if "--nounitproc" in OS.get_cmdline_user_args():
		unit_layer.set_process(false)
	if "--nomapproc" in OS.get_cmdline_user_args():
		map_view.set_process(false)
	if "--nomeasure" in OS.get_cmdline_user_args():
		RenderingServer.viewport_set_measure_render_time(map_view.map_vp.get_viewport_rid(), false)
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)
	var start_day := ticks_done
	_drawn0 = Engine.get_frames_drawn()
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
			if not "--nozoom" in OS.get_cmdline_user_args():
				map_view.camera.zoom = Vector2.ONE * clampf(map_view.camera.zoom.x * (1.0 + 0.01 * sin(tt * 0.7)), 0.3, 4.0)
			map_view._moving = MapView.MOTION_SETTLE   # как при касании
			map_view._on_view_changed()
		# действие игрока каждые 10 кадров: по очереди — прежним способом
		# (ждать мир под замком) и через очередь act; копим, сколько стоял
		# главный поток и через сколько действие выполнилось
		if frames % 10 == 0 and not "--noact" in OS.get_cmdline_user_args():
			var ta := Time.get_ticks_usec()
			if (frames / 10) % 2 == 0:
				world_lock()
				world_unlock()
				var b := Time.get_ticks_usec() - ta
				_act_old.append(b)
			else:
				var rec := _act_new
				act(func(): rec.append(Time.get_ticks_usec() - ta))
				_act_block.append(Time.get_ticks_usec() - ta)
		await get_tree().process_frame
		var ft := Time.get_ticks_usec() - f0
		if not "--nomeasure" in OS.get_cmdline_user_args():
			var vrid := get_viewport().get_viewport_rid()
			_rt_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vrid)
			_rt_gpu += RenderingServer.viewport_get_measured_render_time_gpu(vrid)
		frames += 1
		total += ft
		worst = maxi(worst, ft)
		if ft > 30000:
			print("  долгий кадр %d: %.1f мс (день %d)" % [frames, ft / 1000.0, ticks_done - start_day])
		if not world.event_front().is_empty() or not world.pending_peace.is_empty():
			world_lock()
			world.info_events.clear()
			world.info_option.clear()
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
	print("  свежие данные на экране (под замком или из буфера симуляции): %d кадров (%.1f в с), самая долгая пауза %.0f мс" % [
		_fresh_count, _fresh_count / seconds, _fresh_gap / 1000.0])
	print("  отрисовка экрана: ЦП %.2f мс, ГП %.2f мс в среднем за кадр" % [_rt_cpu / maxi(1, frames), _rt_gpu / maxi(1, frames)])
	print("  карта: разрешение %d%%, цена полной перерисовки %.1f мс" % [int(map_view.res_scale * 100), map_view.last_cost_ms])
	print("  палитра обновлялась %d раз; слой фишек рисовался %d раз, в среднем %.2f мс" % [map_view.palette_version,
		unit_layer.draw_count, unit_layer.draw_total_usec / 1000.0 / maxi(1, unit_layer.draw_count)])
	print("  действия игрока: ждать мир — главный поток стоит %s; очередь — стоит %s, выполнено через %s" % [
		_stat(_act_old), _stat(_act_block), _stat(_act_new)])
	if saves_done > 0:
		print("  автосохранений: %d, последнее — %d мс" % [saves_done, last_save_msec])
	var names := ["панели дня", "палитра", "список фишек", "верхняя строка"]
	for i in 4:
		print("  %s: всего %.0f мс за прогон, худшее %.1f мс" % [names[i], ui_prof_sum[i] / 1000.0, ui_prof_max[i] / 1000.0])
	print("  кадров нарисовано движком: %d из %d" % [Engine.get_frames_drawn() - _drawn0, frames])
	print("  кэш движения: рисовался %d раз; карта целиком %d, частично %d, полосами %d" % [map_view.cache_draws,
		map_view.redraws - map_view.part_redraws - map_view.strip_redraws, map_view.part_redraws, map_view.strip_redraws])
	for l in Report.prof_lines():
		print(l)
	speed = 0
	_shutdown()
	get_tree().quit()


var _act_old: Array = []
var _act_new: Array = []
var _act_block: Array = []


func _stat(a: Array) -> String:
	if a.is_empty():
		return "—"
	var s := 0
	var m := 0
	for v in a:
		s += int(v)
		m = maxi(m, int(v))
	return "сред %.1f / макс %.1f мс" % [s / 1000.0 / a.size(), m / 1000.0]


func _auto_screenshot(path: String) -> void:
	world_lock()
	_auto_screenshot_locked()
	# --save=имя: записать партию; --load=имя: загрузить её (после выхода в меню)
	if _arg("save") != "":
		print("Сохранение: ", save_game(SaveGame.safe_name(_arg("save")), _arg("save")), " ", last_save_msec, " мс")
	world_unlock()
	if _arg("load") != "":
		to_menu()
		await load_game(_arg("load"))
		print("Загружено: ", world.date_string(), ", страна ", world.nations[player()].tag, ", состояние ", state)
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))
	if "--nohud" in OS.get_cmdline_user_args():
		hud.visible = false   # для макетов оформления: только карта и фишки
	for i in 10:
		await get_tree().process_frame
	if _arg("scroll") != "":
		# --scroll=N: прокрутить лист окна на N пикселей (низ длинных окон)
		(hud.popup_body.get_parent() as ScrollContainer).scroll_vertical = int(_arg("scroll"))
		await get_tree().process_frame
	world_lock()
	hud.refresh_top()
	map_view.set_day(world.day)
	unit_layer.rebuild(selected_fleet, selected_wing)
	world_unlock()
	await get_tree().process_frame
	await get_tree().process_frame
	if "--parttest" in OS.get_cmdline_user_args():
		await _part_test(path)
	if "--motiontest" in OS.get_cmdline_user_args():
		await _motion_test(path)
	if "--baketest" in OS.get_cmdline_user_args():
		await _bake_test(path)
	if _arg("bake_sample") != "":
		await map_view.bake.sample_packs(_arg("bake_sample"), [6, 7, 8, 9, 10], 24)
	if _arg("bake_pack") != "":
		await map_view.bake.build_packs(_arg("bake_pack"))
	get_viewport().get_texture().get_image().save_png(path)
	if "--report" in OS.get_cmdline_user_args():
		print(Report.build(self))
	_shutdown()
	get_tree().quit()


## Дождаться, пока кадр карты рисуется с заготовками (если они включены).
func _bake_warm() -> void:
	if not map_view._bake_ok():
		return
	var n := 0
	while not map_view._full_baked and n < 400:
		if n % 20 == 0:
			map_view.redraw()
		for i in 3:
			await get_tree().process_frame
		n += 1


## Проверка заготовок карты (-- --baketest): буфер карты живым шейдером
## (*_live.png) и с заготовками (*_baked.png, тайлы рисуются фоном) — сравнить.
func _bake_test(path: String) -> void:
	map_view._bake_off = true
	map_view.redraw()
	for i in 12:
		await get_tree().process_frame
	map_view.map_vp.get_texture().get_image().save_png(path.replace(".png", "_live.png"))
	map_view._bake_off = false
	var t0 := Time.get_ticks_msec()
	var n := 0
	var bk := map_view.bake
	# тайлы рисуются, пока карта стоит (_bake_still): перерисовка — раз в 60 кадров
	while not map_view._full_baked and n < 400:
		if n % 20 == 0:
			map_view.redraw()
		for i in 3:
			await get_tree().process_frame
		n += 1
		if n % 50 == 1:
			print("baketest: ok %s можно %s, нужно %d, в атласе %d, ждут %d, грузятся %d, рисуется %s, нарисовано %d" % [bk.ok,
				map_view._bake_ok(), map_view._screen_keys.size(), bk.key_slot.size(), bk._wish.size(), bk._jobs.size(),
				not bk._pending.is_empty(), bk.baked_tiles])
	print("baketest: тайлов нарисовано %d, загружено %d, за %.1f с, кадр с заготовками: %s" % [map_view.bake.baked_tiles,
		map_view.bake.loaded_tiles, (Time.get_ticks_msec() - t0) / 1000.0, map_view._full_baked])
	for i in 12:
		await get_tree().process_frame
	map_view.map_vp.get_texture().get_image().save_png(path.replace(".png", "_baked.png"))
	# цена полного кадра карты: живой против заготовок (время кадра с перерисовкой)
	var tq: Array = []
	for i in 32:
		var f0 := Time.get_ticks_usec()
		await get_tree().process_frame
		if i >= 2:
			tq.append(Time.get_ticks_usec() - f0)
	tq.sort()
	print("baketest: кадр без перерисовки карты: %.1f мс (медиана)" % (tq[tq.size() / 2] / 1000.0))
	var variants := [[true, ""], [false, ""], [true, ""], [false, ""]]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bakeoff="):   # что выключить в обоих: has_rivers,…
			for k in a.split("=")[1].split(","):
				variants.append([true, k])
				variants.append([false, k])
	for vv in variants:
		var off: bool = vv[0]
		if vv[1] != "":
			map_view._param(vv[1], false)
		map_view._bake_off = off
		var ts: Array = []
		for i in 32:
			map_view.redraw()
			var f0 := Time.get_ticks_usec()
			await get_tree().process_frame
			if i >= 2:
				ts.append(Time.get_ticks_usec() - f0)
		ts.sort()
		print("baketest: кадр с перерисовкой карты, %s %s: %.1f мс (медиана)" % ["живой" if off else "заготовки", vv[1], ts[ts.size() / 2] / 1000.0])
	map_view._bake_off = false


## Проверка частичной перерисовки карты (-- --parttest): сменить владельца у
## провинций у центра экрана, дать нарисовать только их область, сохранить буфер
## карты (*_part.png); затем перерисовать целиком (*_full.png) — должны совпасть.
func _part_test(path: String) -> void:
	var shot := func(tag: String) -> void:
		for i in 12:
			await get_tree().process_frame
		map_view.map_vp.get_texture().get_image().save_png(path.replace(".png", "_" + tag + ".png"))
	var full := func(tag: String) -> void:
		map_view.redraw()
		await shot.call(tag)
	# заготовки: дождаться тайлов вида (и для сезона — обоих), иначе частичная
	# и полная могли бы выйти в разных режимах (живой / с заготовками)
	await _bake_warm()
	await shot.call("before")
	var c := map_view.screen_to_world(get_viewport().get_visible_rect().size * 0.5) / MapView.SCALE
	world_lock()
	var near: Array = []
	for p in world.prov_count:
		if world.p_land[p] == 1 and world.p_center[p].distance_to(c) < 60.0:
			near.append(p)
	for p in near.slice(0, near.size() / 2):
		world.p_controller[p] = world.p_controller[near[near.size() - 1]]
		world.p_owner[p] = world.p_owner[near[near.size() - 1]]
	world.palette_dirty = true
	map_view.update_palette()
	world_unlock()
	var r0 := map_view.part_redraws
	await shot.call("part")
	print("parttest: владельцы — провинций ", near.size() / 2, ", частичных ", map_view.part_redraws - r0)
	await full.call("full")
	# выбор провинции (обводка области)
	r0 = map_view.part_redraws
	map_view.set_selected(near[0])
	await shot.call("selpart")
	map_view.set_selected(near[near.size() - 1])
	await shot.call("selpart")
	print("parttest: выбор — частичных ", map_view.part_redraws - r0)
	await full.call("selfull")
	# фронт: отметки на части провинций, потом другие
	r0 = map_view.part_redraws
	var marks := {}
	for p in near.slice(0, near.size() / 3):
		marks[p] = [1, Color(0.9, 0.2, 0.2)]
	for p in near.slice(near.size() / 3, near.size() / 2):
		marks[p] = [2, Color(0.2, 0.2, 0.9)]
	map_view.set_front(marks)
	await full.call("front0")
	var marks2 := marks.duplicate()
	for p in near.slice(near.size() / 2, near.size() * 2 / 3):
		marks2[p] = [8, Color(0.9, 0.8, 0.2)]
	marks2.erase(near[0])
	map_view.set_front(marks2)
	await shot.call("frontpart")
	print("parttest: фронт — частичных ", map_view.part_redraws - r0)
	await full.call("frontfull")
	# смена сезона полосами под снимком
	map_view.strips = 4
	if map_view._bake_ok():
		# тайлы другого сезона — заранее (полосы и полный кадр — в одном режиме)
		var vp := get_viewport().get_visible_rect().size
		var bkeys := map_view.bake.need(map_view.camera.position, map_view.camera.zoom.x, map_view.tilt(),
			map_view.cam_focal(), vp, 1 - map_view._season())
		var n := 0
		while not map_view.bake.want(bkeys) and n < 600:
			await get_tree().process_frame
			n += 1
	var s0 := map_view.strip_redraws
	map_view.set_day(world.day + 182)
	for i in 200:
		await get_tree().process_frame
		if map_view._season_step == 0:
			break
	await shot.call("season")
	print("parttest: сезон — полос ", map_view.strip_redraws - s0)
	await full.call("seasonfull")
	await full.call("full2")
	# сдвиг с упрощённым кадром, потом скрытые полосы и проявление
	map_view.motion_lite = true
	s0 = map_view.strip_redraws
	for i in 10:
		map_view.camera.position += Vector2(3, 1)
		map_view._moving = 0.2
		map_view._on_view_changed()
		await get_tree().process_frame
	for i in 120:
		await get_tree().process_frame
		if map_view._full_alpha >= 1.0 and not map_view.lite_sprite.visible:
			break
	await shot.call("moved")
	print("parttest: после сдвига — полос ", map_view.strip_redraws - s0, ", кадр виден ", map_view._full_alpha)
	await full.call("movedfull")


## Проверка кэша движения (-- --motiontest): кадр во время сдвига (из кэша)
## против точного кадра с той же камерой; сколько раз рисовался кэш и карта.
func _motion_test(path: String) -> void:
	unit_layer.visible = "--units" in OS.get_cmdline_user_args()
	hud.visible = false
	map_view.motion_lite = not "--nolite" in OS.get_cmdline_user_args()
	var grab := func(tag: String) -> void:
		get_viewport().get_texture().get_image().save_png(path.replace(".png", "_" + tag + ".png"))
	for i in 30:
		await get_tree().process_frame
	grab.call("start")
	if _arg("setres") != "":
		map_view.set_res_scale(float(_arg("setres")))
		for i in 30:
			await get_tree().process_frame
		grab.call("setres")
		map_view.map_vp.get_texture().get_image().save_png(path.replace(".png", "_setres_vp.png"))
		print("motiontest: setres vp ", map_view.map_vp.size, " full ", map_view._full_size, " alpha ", map_view._full_alpha, " vis ", map_view.view_sprite.visible, " scale ", map_view.view_sprite.scale, " pos ", map_view.view_sprite.position, " strip ", map_view._strip_n, " hid ", map_view._strip_hidden)
	print("motiontest: кэш готов ", map_view._cache_front().valid, " размер ", map_view._cache_front().size, " масштаб ", map_view._cache_front().zoom, " / ", map_view.camera.zoom.x)
	var r0 := map_view.redraws
	var c0 := map_view.cache_draws
	var u0 := unit_layer.draw_count
	var mz := float(_arg("mzoom")) if _arg("mzoom") != "" else 1.0   # масштаб за кадр (отдаление < 1)
	for i in 40:
		if not "--nopan" in OS.get_cmdline_user_args():
			var step := float(_arg("panpx")) if _arg("panpx") != "" else 7.3   # пикс. экрана за кадр
			map_view.camera.position += Vector2(step, step * 0.29) / map_view.camera.zoom.x
		map_view.camera.zoom *= mz
		map_view._moving = 0.3
		map_view._on_view_changed()
		await get_tree().process_frame
		if mz != 1.0 and i % 8 == 7:
			grab.call("m%d" % i)
			print("motiontest: кадр %d — края с заготовками %s, кэш %s, упрощённый %s, масштаб %.2f" % [i, map_view.lite_quad.material == map_view.mat_b, map_view.cache_rect.visible,
				map_view.lite_sprite.visible, map_view.camera.zoom.x])
	await get_tree().process_frame
	grab.call("moving")
	map_view._cache_front().vp.get_texture().get_image().save_png(path.replace(".png", "_cache.png"))
	print("motiontest: камера ", map_view.camera.position, " кэш ", map_view._cache_front().cam, " окно ", map_view._cache_front().n)
	print("motiontest: за 40 кадров сдвига — перерисовок карты ", map_view.redraws - r0, ", кэша ", map_view.cache_draws - c0,
		", показан кэш ", map_view.cache_rect.visible, ", упрощённый ", map_view.lite_sprite.visible,
		", слой фишек рисовался ", unit_layer.draw_count - u0)
	map_view._moving = 0.001
	for i in 60:
		await get_tree().process_frame
	grab.call("still")
	# слой фишек заново при той же камере — для сравнения с перенесённым
	unit_layer._dirty = true
	for i in 10:
		await get_tree().process_frame
	grab.call("fresh")


func _auto_screenshot_locked() -> void:
	var days := int(_arg("days")) if _arg("days") != "" else 0
	var me := 0
	if _arg("nation") != "" and nation_by_tag(_arg("nation")) >= 0:
		me = nation_by_tag(_arg("nation"))
	if _arg("menu") != "":
		# --menu=main — главное меню; --menu=load|settings — окно из него
		state = "menu"
		hud.show_menu()
		if _arg("menu") != "main":
			hud.open_tab(_arg("menu"))
		return
	if _arg("pick") == "":
		start_as(me)
		set_speed(0)
		var war_on := nation_by_tag(_arg("war")) if _arg("war") != "" else -1
		if "--group" in OS.get_cmdline_user_args():
			select_all()
			create_group_from_selection()
			if war_on >= 0:
				for g in world.groups:
					if g.alive and g.owner == me:
						g.enemy = war_on
		var war_day := int(_arg("warday")) if _arg("warday") != "" else 0
		for i in days:
			if i == war_day and war_on >= 0:
				world.nations[me].pacts.erase(war_on)
				world.nations[war_on].pacts.erase(me)
				world.nations[me].wargoals[war_on] = true
				Diplomacy.declare_war(world, me, war_on)
				for g in world.groups:
					if g.alive and g.owner == me:
						g.mode = "attack"
						g.objective = world.nations[war_on].capital
				if _arg("frontsel") != "":
					# --frontsel=K: участок фронта — K чужих провинций соприкосновения,
					# ближайших к столице противника (проверка кисти без человека)
					var cands: Array = []
					for p in world.prov_count:
						if world.p_controller[p] == war_on and Simulation.is_contact(world, me, p):
							cands.append(p)
					var cp: Vector2 = world.p_center[world.nations[war_on].capital]
					cands.sort_custom(func(a, b): return world.p_center[a].distance_to(cp) < world.p_center[b].distance_to(cp))
					var sel := PackedInt32Array(cands.slice(0, int(_arg("frontsel"))))
					if selected_front >= 0:
						_set_front_sel(world.fronts[selected_front], sel)
					else:
						for g in world.groups:
							if g.alive and g.owner == me:
								g.front_sel = sel
								_front_enemy(g)
			sim.tick()
		if selected_front >= 0:
			select_front(selected_front)
		elif selected_group >= 0:
			select_group(selected_group)
		if "--frontedit" in OS.get_cmdline_user_args():
			if selected_front >= 0:
				start_front_edit_f(selected_front)
			elif selected_group >= 0:
				start_front_edit(selected_group)
		hud.on_tick()
		if "--notilt" in OS.get_cmdline_user_args():
			map_view.set_tilt_enabled(false)
		if "--provsel" in OS.get_cmdline_user_args():   # выбрать провинцию столицы (обводка области)
			map_view.set_selected(world.nations[me].capital)
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
		if _arg("occupy") != "":
			# скриншоты: страна сдаётся нам, её земли — под нашей оккупацией
			var occ_t := nation_by_tag(_arg("occupy"))
			for p in world.prov_count:
				if world.p_owner[p] == occ_t:
					world.p_controller[p] = me
			Peace.capitulate(world, occ_t, me)
			Occupation.step(world)
		if _arg("dippage") != "":
			hud._dip_page = _arg("dippage")   # world / politics / advisors
		if _arg("hire") != "":
			for aid in _arg("hire").split(","):   # скриншоты: нанять советников
				world.nations[me].pol_power = maxf(world.nations[me].pol_power, Politics.COST_POL_ADV)
				world.nations[me].command_power = maxf(world.nations[me].command_power, Politics.COST_MIL_ADV)
				Politics.hire(world, world.nations[me], aid)
		if _arg("prodpage") != "":
			hud._prod_page = _arg("prodpage")   # factories / trade / lands
		if _arg("occ") != "":
			hud._occ_key = Occupation.tkey(me, nation_by_tag(_arg("occ")))
		if _arg("card") != "":
			hud._card_nation = nation_by_tag(_arg("card"))
		if _arg("mapmode") != "":
			set_map_mode(int(_arg("mapmode")))
		if _arg("event") != "":
			var eid := _arg("event")
			if History.event_has_choice(world.event_defs.get(eid, {})):
				world.pending_events.append(eid)
			else:
				world.info_events.append(eid)   # лист применённого события (без выбора)
		if "--focus" in OS.get_cmdline_user_args():
			hud.focus_view.open(self, world, me)
			if _arg("fsel") != "":
				hud.focus_view._select(_arg("fsel"))   # карточка фокуса с прогнозом шансов
		if _arg("tech") != "":
			# дерево науки: --tech=категория[:технология]; свободные слоты заполняются для показа
			var tn: World.Nation = world.nations[me]
			Tech.fit_slots(tn)
			while Tech.free_slot(tn) >= 0:
				var tp := Tech.ai_pick(world, tn)
				if tp == "" or not Tech.start(tn, Tech.free_slot(tn), tp):
					break
			var ta := _arg("tech").split(":")
			hud.open_tab("research")
			hud.tech_view.set_cat(ta[0])
			if ta.size() > 1:
				hud.tech_view._select(ta[1])
		if _arg("peace") != "":
			Peace.debug_start(world, nation_by_tag(_arg("peace")), me)
		if _arg("retrain") != "":
			# переучивание: --retrain=1 — все дивизии игрока (свой шаблон с ротами — для списка)
			var mine: Array = []
			for d in world.divisions:
				if d.alive and d.owner == me:
					mine.append(d)
			Military.save_template(world, me, "Пехотная с ротами", [9, 0, 0, 2, 0, 0, 0], -1, ["eng", "art", "med"])
			hud._open_retrain(mine)
		elif _arg("tpl") != "":
			# конструктор шаблонов: --tpl=N (на основе шаблона N) или --tpl=new
			hud.open_tab("army")
			hud._open_tpl_editor(world, -1 if _arg("tpl") == "new" else int(_arg("tpl")), false)
		elif _arg("tank") != "":
			# конструктор танка: --tank=N (копия проекта N), --tank=new или --tank=cur (выпускаемый)
			hud.open_tab("army")
			var ta := _arg("tank")
			hud._open_tank_editor(world, -1 if ta == "new" else (world.nations[me].tank_design if ta == "cur" else int(ta)))
		elif _arg("plane") != "":
			# конструктор самолёта: --plane=N (копия проекта N), --plane=new или --plane=fig|bmb (выпускаемый)
			hud.open_tab("navy")
			var pa := _arg("plane")
			var pd: int = -1 if pa == "new" else (world.nations[me].air_design[0 if pa == "fig" else 1] if pa in ["fig", "bmb"] else int(pa))
			hud._open_plane_editor(world, pd)
		elif _arg("ship") != "":
			# конструктор корабля: --ship=N (копия проекта N), --ship=new или --ship=ss|cr|cv|bb|dd (основной проект роли)
			hud.open_tab("navy")
			var sa := _arg("ship")
			var sd: int = -1 if sa == "new" else (world.nations[me].ship_role[ShipDesigns.ROLE_OF_KEY[sa]] if ShipDesigns.ROLE_OF_KEY.has(sa) else int(sa))
			hud._open_ship_editor(world, sd)
		elif _arg("tab") != "":
			if _arg("trade") != "":
				hud._prod_page = "trade"   # --trade=1: «Внешняя экономика»; --trade=oil и т. п. — выбор продавца
				var rn := ["oil", "steel", "aluminium", "rubber", "tungsten", "chromium"].find(_arg("trade"))
				hud._buy_res = rn
			hud.open_tab(_arg("tab"))
		if "--select" in OS.get_cmdline_user_args():
			_on_province_tapped(world.nations[me].capital)
	else:
		pick(me)
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))



func new_world(seed_value: int, then := "select") -> void:
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
		# картинки мира и карты распаковываются в рабочих потоках, пока главный
		# разбирает данные (ImgPrefetch)
		MapLoader.prefetch()
		MapView.prefetch()
		MapLoader.load_world(world)
		ImgPrefetch.run("relief", MapView._relief_layer.bind(world.height_image))
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
	state = then
	world_fresh = true
	_play_usec = 0
	unit_layer.rebuild()
	world_unlock()
	if procedural:
		hud.gen_info = "Карта #%d: %d провинций, сгенерирована за %d мс на %d ядрах" % [seed_value, world.prov_count, load_ms, Parallel.thread_count()]
	else:
		hud.gen_info = "Мир, 1 января 1936 г.: %d провинций суши, %d морских зон · загрузка %d мс" % [world.land_count, world.prov_count - world.land_count, load_ms]
	if then == "menu":
		hud.show_menu()
	else:
		hud.show_select(-1)


# --- Главное меню, сохранение и загрузка -------------------------------------

## Новая партия: к выбору страны (мир пересобирается, если в нём уже играли).
func new_game() -> void:
	if world_fresh:
		state = "select"
		pick_nation = -1
		map_view.set_highlight_nation(-1)
		hud.show_select(-1)
	else:
		await new_world(randi() % 100000, "select")


## Выйти в главное меню. Идущая партия сохраняется в автосохранение.
func to_menu() -> void:
	if state == "play":
		autosave()
	clear_selection()
	hud.close_popup()
	state = "menu"
	speed = 0
	hud.show_menu()


## Записать партию (мир под замком: из game.act или после world_lock).
## Возвращает текст ошибки или "".
func save_game(name: String, title: String, auto := false) -> String:
	if world == null or sim == null or player() < 0 or world.game_over != "":
		return "нет идущей партии"
	var n: World.Nation = world.nations[player()]
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		_note_camera()
	var meta := {"title": title, "auto": auto, "tag": n.tag, "nation": n.name, "flag": n.flag,
		"historical": world.historical, "cam": [_cam_x, _cam_y, _cam_zoom], "mapmode": _cam_mode}
	var t0 := Time.get_ticks_msec()
	var err := SaveGame.write(name, world, sim, meta)
	last_save_msec = Time.get_ticks_msec() - t0
	if err == "":
		_play_usec = 0
		saves_done += 1
	else:
		push_warning("Сохранение «%s»: %s" % [name, err])
	return err


var last_save_msec := 0
var saves_done := 0
var autosave_on := true          # копия Settings.autosave(): её читает и поток симуляции
var _cam_x := 0.0                # вид камеры и режим карты для сохранения (их читает
var _cam_y := 0.0
var _cam_zoom := 1.0
var _cam_mode := 0               # и поток симуляции — узлы сцены ему трогать нельзя)
var _play_usec := 0              # сколько шла партия с последнего сохранения
var autosave_usec := 300 * 1000000    # автосохранение — раз в 5 минут игры (не на паузе); -- --autosave_sec=N


func _note_camera() -> void:
	_cam_x = map_view.camera.position.x
	_cam_y = map_view.camera.position.y
	_cam_zoom = map_view.camera.zoom.x
	_cam_mode = map_view.map_mode


## Автосохранение (при выходе в меню, сворачивании, закрытии; мир — под замком).
func autosave() -> void:
	if state != "play" or not autosave_on:
		return
	world_lock()
	save_game(SaveGame.AUTO, "Автосохранение", true)
	sim_mutex.unlock()


## Автосохранение по времени — из потока симуляции сразу после дня (мир уже
## под его замком, экран не замирает).
func _autosave_tick(day_usec: int) -> void:
	_play_usec += day_usec
	if _play_usec >= autosave_usec and autosave_on:
		_play_usec = 0
		save_game(SaveGame.AUTO, "Автосохранение", true)


## Загрузить партию: мир собирается заново (если в нём уже играли), сверху
## кладётся сохранённое состояние. При ошибке — главное меню с сообщением.
func load_game(name: String) -> void:
	world_lock()
	state = "loading"
	speed = 0
	_accum = 0.0
	world_unlock()
	hud.close_popup()
	hud.show_loading("Загрузка партии…")
	await get_tree().process_frame
	await get_tree().process_frame
	world_lock()
	clear_selection()
	if not world_fresh:
		world.dispose()
		world = World.new()
		MapLoader.load_world(world)
	sim = Simulation.new(world, false)
	var res := SaveGame.load_into(name, world, sim)
	world_fresh = false
	if res["err"] != "":
		world_unlock()
		await new_world(randi() % 100000, "menu")
		hud.toast("Не удалось загрузить: %s" % res["err"])
		return
	var meta: Dictionary = res["meta"]
	map_view.setup(world)
	unit_layer.map = map_view
	unit_layer.world = world
	unit_layer._labels_day = -1
	unit_layer.selected = selected_divs
	var me := world.player_nation()
	unit_layer.player = me
	pick_nation = -1
	map_view.set_highlight_nation(-1)
	map_view.set_selected(-1)
	var cam: Array = meta.get("cam", [])
	if cam.size() == 3:
		map_view.camera.zoom = Vector2.ONE * float(cam[2])
		map_view.camera.position = Vector2(float(cam[0]), float(cam[1]))
		map_view._on_view_changed()
	elif me >= 0:
		map_view.center_on(world.nations[me].capital)
	set_map_mode(int(meta.get("mapmode", 0)))
	_event_seen = ""
	_frame_mutex.lock()
	_frame_list = []
	_frame_taken = true
	_frame_new = false
	_frame_day = -1
	_frame_mutex.unlock()
	_play_usec = 0
	state = "play"
	speed = 0
	hud.show_play()
	unit_layer.rebuild()
	world_unlock()
	hud.toast("Загружено: %s" % world.date_string())


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
	# исследования, начатые ИИ, остаются в слотах — игрок может их сменить
	unit_layer.player = nid
	map_view.set_highlight_nation(-1)
	map_view.set_selected(-1)
	map_view.camera.zoom = Vector2.ONE * 0.9
	map_view.center_on(world.nations[nid].capital)
	state = "play"
	speed = 0   # как в жанре: игра начинается на паузе
	world_fresh = false
	_play_usec = 0
	world.log_event("Вы правите страной %s. Удачи!" % world.nations[nid].name)
	hud.show_play()


func player() -> int:
	return unit_layer.player


## Конвейер экрана: сразу после дня поток симуляции (мир ещё под его замком)
## снимает цифры верхней строки и, если интерфейс забрал прежний, собирает новый
## список фишек; интерфейс в своём кадре подменяет буфер, не трогая мир
## (_take_frame). Выделение и приказы по-прежнему пересобирают список сразу.
func _publish() -> void:
	if hud == null or world == null or state != "play":
		return
	var top := Hud.top_snapshot(world, player(), sim)
	_frame_mutex.lock()
	var want := _frame_taken
	_frame_mutex.unlock()
	var r: Array = []
	if want:
		r = unit_layer.build(selected_fleet, selected_wing)
	_frame_mutex.lock()
	_frame_top = top
	if want:
		_frame_list = r
		_frame_day = world.day
		_frame_taken = false
	_frame_new = true
	_frame_mutex.unlock()


func _take_frame() -> void:
	_frame_mutex.lock()
	if _frame_new:
		hud.top_data = _frame_top
		if not _frame_taken and not _frame_list.is_empty():
			unit_layer.take(_frame_list[0], _frame_list[1], _frame_list[2])
			_frame_taken = true
			_frame_list = []
		_fresh_note()
		_frame_new = false
	_frame_mutex.unlock()
	hud.show_top()


## Действие игрока без ожидания (конвейер ввода): если мир свободен — сразу,
## иначе в очередь; очередь выполняется в главном потоке на границе дней
## (_process, когда мьютекс свободен), поток симуляции уступает окно после
## своего дня. Порядок действий сохраняется. Интерфейс не замирает на время
## дня (на телефоне — до 100 мс на нажатие).
func act(cb: Callable) -> void:
	_cmd_mutex.lock()
	var queued := not _cmds.is_empty()
	if queued or single_thread or not sim_mutex.try_lock():
		_cmds.append(cb)
		_cmd_mutex.unlock()
		_ui_waiting = true
		if single_thread:
			_run_cmds()
		return
	_cmd_mutex.unlock()
	cb.call()
	_layer_dirty = true
	sim_mutex.unlock()


## Выполнить накопленные действия (мьютекс мира уже взят или поток один).
func _run_cmds() -> void:
	_cmd_mutex.lock()
	var list := _cmds
	_cmds = []
	_cmd_mutex.unlock()
	for cb in list:
		(cb as Callable).call()
	if not list.is_empty():
		_layer_dirty = true


func pending_actions() -> int:
	_cmd_mutex.lock()
	var n := _cmds.size()
	_cmd_mutex.unlock()
	return n


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
			StressBench.note_tick(sim, world)
			if _slow_tick_usec > 0:   # отладка: имитация медленного телефона
				var t0 := Time.get_ticks_usec()
				while Time.get_ticks_usec() - t0 < _slow_tick_usec:
					pass
			ticks_done += 1
			_publish()
			_autosave_tick(int(1000000.0 / maxf(0.5, SPEEDS[mini(speed, 5)])))
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
var _fresh_last := 0          # замер свежести экрана: новый день или новое состояние показано
var _fresh_gap := 0
var _fresh_count := 0
var _fresh_tick := -1


func _fresh_note() -> void:
	if ticks_done == _fresh_tick:
		return
	_fresh_tick = ticks_done
	var now := Time.get_ticks_usec()
	if _fresh_last > 0:
		_fresh_gap = maxi(_fresh_gap, now - _fresh_last)
	_fresh_last = now
	_fresh_count += 1
const SINGLE_BUDGET_USEC := 8000   # однопоточный режим: время симуляции на кадр


func _request_days(n: int) -> void:
	if single_thread:
		# без фонового потока: дни считаются прямо в кадре, пока есть бюджет
		var t0 := Time.get_ticks_usec()
		for i in n:
			if state == "play" and sim != null:
				sim.tick()
				StressBench.note_tick(sim, world)
				ticks_done += 1
				_publish()
				_autosave_tick(int(1000000.0 / maxf(0.5, SPEEDS[mini(speed, 5)])))
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
		# меню и выбор страны: мир стоит, но действия из очереди выполнить надо
		if pending_actions() > 0 and sim_mutex.try_lock():
			_run_cmds()
			sim_mutex.unlock()
		return
	if _dbg_noui:
		return
	if _lowproc:
		# в этом режиме движок спит ~7 мс после каждого шага — пока карту двигают,
		# режим выключен (кадры идут подряд), стоит — включён
		var still: bool = map_view._moving <= 0.0 and map_view._touches.is_empty()
		if OS.low_processor_usage_mode != still:
			OS.low_processor_usage_mode = still
	var tp0 := Time.get_ticks_usec()
	_note_camera()
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
	# готовое от симуляции (верхняя строка, список фишек) — каждый кадр, без замка
	var tp1 := Time.get_ticks_usec()
	_take_frame()
	var tp2 := Time.get_ticks_usec()
	FrameProf.add("буфер", tp2 - tp1)
	# интерфейс и список отрисовки — только когда мир не занят симуляцией
	if sim_mutex.try_lock():
		_ui_waiting = false
		_run_cmds()
		var tp3 := Time.get_ticks_usec()
		FrameProf.add("действия", tp3 - tp2)
		_ui_update()
		sim_mutex.unlock()
		FrameProf.add("интерфейс", Time.get_ticks_usec() - tp3)
		var now := Time.get_ticks_usec()
		if _ui_last > 0:
			_ui_gap_max = maxi(_ui_gap_max, now - _ui_last)
		_ui_last = now
		_ui_count += 1
		_fresh_note()
	elif Time.get_ticks_usec() - _ui_last > UI_MAX_GAP_USEC or pending_actions() > 0:
		_ui_waiting = true   # давно не обновлялись или ждут действия — попросить окно у симуляции
	FrameProf.add("main", Time.get_ticks_usec() - tp0)


const PALETTE_MIN_MSEC := 500
var _palette_msec := 0


var _event_seen := ""   # событие, на которое уже поставлена пауза
var _speed_prev := 0


func _ui_update() -> void:
	if world.game_over != "":
		state = "over"
		hud.show_game_over(world.game_over)
		return
	var ef := world.event_front()
	if not ef.is_empty():
		# новое событие: пауза и окно; если игрок закрыл окно и снял паузу,
		# событие с выбором ждёт ответа до срока (окно вернётся на паузе)
		var front: String = ef[0]
		if front != _event_seen:
			_event_seen = front
			speed = 0
			_accum = 0.0
			hud.open_tab("event")
		elif not hud.event_open() and speed == 0 and _speed_prev > 0 and not hud.popup.visible:
			hud.open_tab("event")
	elif hud.event_open():
		_event_seen = ""
		hud.close_popup()
	if ef.is_empty():
		_event_seen = ""
	if ef.is_empty() and not world.pending_peace.is_empty():
		if hud.popup_tab != "peace" or not hud.popup.visible:
			speed = 0
			_accum = 0.0
			hud.open_tab("peace")
	_speed_prev = speed
	var new_day := ticks_done != _ticks_seen
	var t0 := Time.get_ticks_usec()
	if new_day:
		_ticks_seen = ticks_done
		_prune_selection()
		hud.on_tick()
		map_view.set_day(world.day)
	var t1 := Time.get_ticks_usec()
	# захваты перекрашивают карту не чаще двух раз в секунду: на высоком качестве
	# полная перерисовка дорогая, а в войну владельцы меняются почти каждый день
	if world.palette_dirty and (speed == 0 or Time.get_ticks_msec() - _palette_msec >= PALETTE_MIN_MSEC):
		_palette_msec = Time.get_ticks_msec()
		map_view.update_palette()
	var t2 := Time.get_ticks_usec()
	# список фишек нового дня уже собрал поток симуляции (_publish); здесь —
	# только после выделения/приказов или если симуляция его не собирала
	if _layer_dirty or (new_day and _frame_day != world.day):
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


const _UI_PROF_KEYS := ["панели дня", "палитра", "список фишек", "верхняя строка"]


func _ui_prof_note(i: int, usec: int) -> void:
	FrameProf.add(_UI_PROF_KEYS[i], usec)
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
	act(func(): _on_province_tapped_locked(p))


func _on_province_tapped_locked(p: int) -> void:
	if editing_front():
		return   # правка участка фронта: касание уже отработала кисть
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
	# выбрана группа армий -> касание задаёт цель всем её армиям
	if selected_front >= 0:
		var f: World.ArmyFront = world.fronts[selected_front]
		if world.p_land[p] == 1:
			var en := -1
			for g in Leaders.armies_of_front(world, f):
				en = g.enemy
				break
			if world.p_controller[p] != me and en < 0 and world.p_controller[p] >= 0 and world.is_at_war(me, world.p_controller[p]):
				en = world.p_controller[p]
			# цель — только направление главного удара; в атаку — кнопкой «Наступать»
			var fmode := "hold"
			for g in Leaders.armies_of_front(world, f):
				fmode = g.mode
				break
			Leaders.front_order(world, f, fmode, en, p)
			hud.toast("%s: направление удара — %s%s" % [f.name, world.p_name[p], "" if fmode == "attack" else " (в атаку — «Наступать»)"])
			map_view.set_selected(p)
			hud.show_front(f)
		return
	# выбрана армия -> касание задаёт направление наступления
	if selected_group >= 0:
		var g: World.ArmyGroup = world.groups[selected_group]
		if world.p_land[p] == 1:
			# цель — только направление главного удара; в атаку — кнопкой «Наступать»
			g.objective = p
			if world.p_controller[p] != me and g.front_sel.is_empty():
				if g.enemy < 0 and world.p_controller[p] >= 0 and world.is_at_war(me, world.p_controller[p]):
					g.enemy = world.p_controller[p]
			hud.toast("%s: направление удара — %s%s" % [g.name, world.p_name[p], "" if g.mode == "attack" else " (в атаку — «Наступать»)"])
			map_view.set_selected(p)
			hud.show_group(g)
		return
	# есть выделенные войска -> приказ на движение
	if not selected_divs.is_empty() and p != selected_prov:
		# пути всем выделенным — одним поиском от цели (Simulation.order_move_many)
		var ok := sim.order_move_many(selected_divs, p)
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


# --- Участок фронта кистью (как в жанре) ---------------------------------------

var front_edit := -1          # армия, чей участок фронта правится кистью
var front_edit_f := -1        # или группа армий (участок делится между её армиями)
var _paint_erase := false     # мазок стирает (начат на уже выделенной провинции)


## Начать правку участка армии: один палец рисует (провинции соприкосновения с
## противником — свои и чужие), два — двигают карту; касание — одна провинция.
func start_front_edit(id: int) -> void:
	front_edit = id
	front_edit_f = -1
	map_view.paint_mode = true
	_edit_marks()
	hud.show_front_edit(world.groups[id].name, world.groups[id].front_sel.size())


## Начать правку участка группы армий: выделение делится между армиями вдоль
## линии фронта (Simulation.split_sel).
func start_front_edit_f(id: int) -> void:
	front_edit = -1
	front_edit_f = id
	map_view.paint_mode = true
	_edit_marks()
	hud.show_front_edit(world.fronts[id].name, world.fronts[id].front_sel.size())


func editing_front() -> bool:
	return front_edit >= 0 or front_edit_f >= 0


func _edit_marks() -> void:
	var ids := {}
	var sel := PackedInt32Array()
	if front_edit >= 0:
		ids[front_edit] = true
		sel = world.groups[front_edit].front_sel
	elif front_edit_f >= 0:
		var f: World.ArmyFront = world.fronts[front_edit_f]
		for g in Leaders.armies_of_front(world, f):
			ids[g.id] = true
		sel = f.front_sel
	unit_layer.edit_ids = ids
	unit_layer.edit_sel = sel
	_layer_dirty = true


func _end_edit_marks() -> void:
	front_edit = -1
	front_edit_f = -1
	unit_layer.edit_ids = {}
	unit_layer.edit_sel = PackedInt32Array()
	map_view.paint_mode = false
	_layer_dirty = true


func stop_front_edit() -> void:
	var g := front_edit
	var f := front_edit_f
	_end_edit_marks()
	if g >= 0 and world.groups[g].alive:
		select_group(g)
	elif f >= 0 and world.fronts[f].alive:
		select_front(f)


## Готово и в атаку: армия (или все армии группы) наступает со своего участка.
func front_edit_attack() -> void:
	var g := front_edit
	var f := front_edit_f
	act(func():
		if g >= 0:
			world.groups[g].mode = "attack"
		elif f >= 0:
			for a in Leaders.armies_of_front(world, world.fronts[f]):
				a.mode = "attack")
	stop_front_edit()
	hud.toast("Наступление со своего участка")


## Очистить выделение: армия (или группа) снова держит весь фронт с противником.
func clear_front_sel() -> void:
	act(func():
		if front_edit >= 0:
			world.groups[front_edit].front_sel = PackedInt32Array()
			_front_enemy(world.groups[front_edit])
		elif front_edit_f >= 0:
			_set_front_sel(world.fronts[front_edit_f], PackedInt32Array())
		_edit_marks())


func _on_province_painted(provs: PackedInt32Array, first: bool) -> void:
	if not editing_front():
		return
	act(func(): _paint_locked(provs, first))


func _paint_locked(provs: PackedInt32Array, first: bool) -> void:
	if not editing_front() or state != "play":
		return
	var owner := player()
	var sel: PackedInt32Array
	if front_edit >= 0:
		if not world.groups[front_edit].alive:
			return
		sel = world.groups[front_edit].front_sel
	else:
		if not world.fronts[front_edit_f].alive:
			return
		sel = world.fronts[front_edit_f].front_sel
	if first:
		# мазок, начатый на выделенной провинции, стирает; иначе — добавляет
		_paint_erase = not provs.is_empty() and sel.has(provs[0])
	var changed := false
	for p in provs:
		if not Simulation.is_contact(world, owner, p):
			continue
		var i := sel.find(p)
		if _paint_erase and i >= 0:
			sel.remove_at(i)
			changed = true
		elif not _paint_erase and i < 0:
			sel.append(p)
			changed = true
	if not changed:
		return
	if front_edit >= 0:
		var g: World.ArmyGroup = world.groups[front_edit]
		g.front_sel = sel
		_front_enemy(g)
		hud.show_front_edit(g.name, sel.size())
	else:
		var f: World.ArmyFront = world.fronts[front_edit_f]
		_set_front_sel(f, sel)
		hud.show_front_edit(f.name, sel.size())
	_edit_marks()


## Участок группы армий: делится между её армиями вдоль линии фронта.
func _set_front_sel(f: World.ArmyFront, sel: PackedInt32Array) -> void:
	f.front_sel = sel
	var armies := Leaders.armies_of_front(world, f)
	var parts := Simulation.split_sel(world, sel, armies.size())
	for k in armies.size():
		var g: World.ArmyGroup = armies[k]
		g.front_sel = parts[k] if k < parts.size() else PackedInt32Array()
		_front_enemy(g)


## Противник армии по выделению: одна страна (в войне с нами) — она, иначе все.
func _front_enemy(g: World.ArmyGroup) -> void:
	var en := -2
	for p in g.front_sel:
		var c := world.p_controller[p]
		if c == g.owner:
			continue
		if en == -2:
			en = c
		elif en != c:
			en = -1
	g.enemy = en if en >= 0 and world.is_at_war(g.owner, en) else -1


func clear_selection() -> void:
	if editing_front():
		_end_edit_marks()
	selected_group = -1
	selected_front = -1
	selected_fleet = -1
	selected_wing = -1
	selected_divs.clear()
	selected_prov = -1
	map_view.set_selected(-1)
	hud.hide_info()


func select_all() -> void:
	selected_group = -1
	selected_front = -1
	selected_divs.clear()
	for d in world.divisions_of(player()):
		if not d.in_battle:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(-1)
	hud.show_selection()


# --- Армии -----------------------------------------------------------------

## Армии по Leaders.ARMY_MAX дивизий; несколько армий — сразу в группы армий
## по Leaders.FRONT_MAX. Генералы и маршалы — лучшие свободные.
func create_group_from_selection() -> void:
	if selected_divs.is_empty():
		return
	var divs: Array = []
	for d in selected_divs:
		if d.group >= 0:
			var old: World.ArmyGroup = world.groups[d.group]
			if old.alive:
				continue
		divs.append(d)
	if divs.is_empty():
		hud.toast("Все выделенные дивизии уже в армиях")
		return
	var made: Array = []
	for i in range(0, divs.size(), Leaders.ARMY_MAX):
		var g := sim.create_group(player(), divs.slice(i, i + Leaders.ARMY_MAX))
		# по умолчанию — против ближайшего противника, иначе держать границу
		for e in world.nations[player()].at_war:
			g.enemy = e
			break
		Leaders.auto_general(world, g)
		made.append(g)
	if made.size() >= 2:
		for i in range(0, made.size(), Leaders.FRONT_MAX):
			Leaders.create_front(world, player(), made.slice(i, i + Leaders.FRONT_MAX))
		select_front(made[0].front)
		hud.toast("Создано армий: %d (%d дивизий), групп армий: %d" % [made.size(), divs.size(), ceili(made.size() / float(Leaders.FRONT_MAX))])
		return
	select_group(made[0].id)
	hud.toast("Создана %s: %d дивизий" % [made[0].name, divs.size()])


## Выделенные дивизии — в армию (сколько влезет до Leaders.ARMY_MAX).
func join_group(id: int) -> int:
	var g: World.ArmyGroup = world.groups[id]
	var room := Leaders.ARMY_MAX - group_divisions(id).size()
	var n := 0
	for d in selected_divs:
		if n >= room:
			break
		if d.group != id:
			d.group = id
			n += 1
	world.lead_ver += 1
	return n


func select_front(id: int) -> void:
	var f: World.ArmyFront = world.fronts[id]
	selected_group = -1
	selected_front = id
	selected_divs.clear()
	for g in Leaders.armies_of_front(world, f):
		selected_divs.append_array(group_divisions(g.id))
	selected_prov = -1
	var obj := -1
	for g in Leaders.armies_of_front(world, f):
		obj = g.objective
		break
	map_view.set_selected(obj)
	hud.show_front(f)


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
	selected_front = -1
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
	_after_event()


## Лист уже применённого события прочитан.
func dismiss_info_event() -> void:
	if not world.info_events.is_empty():
		world.info_option.erase(world.info_events.pop_front())
	_after_event()


func _after_event() -> void:
	hud.close_popup()
	hud.on_tick()
	if not world.event_front().is_empty():
		hud.open_tab("event")


func resolve_peace(kind: String, arg: int = -1) -> void:
	sim.resolve_peace(kind, arg)   # ход стоит, пока переговоры ждут игрока
	if world.pending_peace.is_empty():
		hud.close_popup()
	else:
		hud.open_tab("peace")
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
		if hud == null:
			return
		if hud.focus_view.visible:
			hud.focus_view.hide()
			return
		if hud.tech_view.visible:
			hud.tech_view.hide()
			hud._set_side_active("")
			return
		if hud.close_popup():
			return
		if not selected_divs.is_empty() or selected_group >= 0 or selected_front >= 0 or selected_fleet >= 0 or selected_wing >= 0:
			clear_selection()
		elif state == "play":
			hud.open_tab("menu")   # «назад» на пустом экране — меню партии
		elif state == "select":
			to_menu()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		# свернули или закрывают: телефон может выгрузить игру без предупреждения
		autosave()
