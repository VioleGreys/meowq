class_name StressBench
extends Node
## Стенд нагрузки: игра идёт по сценарию «как играет человек», каждый кадр и
## каждый день записываются, в конце — где время и откуда фризы.
##   godot --path . -- --stress [--seg=5 --from=1941-06-22 --nation=GER --out=файл]
##   как на телефоне: taskset -c 0,1 godot ... -- --stress --phone
##   на самом телефоне: «Настройки» → «Проверка нагрузки» (партия сохраняется и
##   потом загружается обратно, отчёт — в буфер обмена и user://stress.txt)
## Отрезки: пауза; скорость 5; скорость 5 + сдвиг и масштаб; окна; выделение и
## приказы; режимы карты; сохранение; без ограничения скорости.
## Долгий кадр (> 50 мс) печатается с раскладкой: участки главного потока
## (FrameProf), отрисовка движком (ЦП/ГП), дней за кадр и действие сценария.
## Подробности и как читать — docs/notes/engine.md «Стенд нагрузки».

const LONG_MS := 50.0
const INSIDE_MAIN := ["буфер", "действия", "интерфейс", "панели дня", "палитра", "список фишек", "верхняя строка",
	"окно: сборка", "окна: заготовка"]
const SEGMENTS := ["пауза, карта стоит", "скорость 5 (8 дн/с)", "скорость 5 + сдвиг и масштаб",
	"скорость 5 + окна", "скорость 5 + выделение и приказы", "скорость 5 + режимы карты",
	"скорость 5 + сохранение", "без ограничения скорости"]
const TABS := ["army", "navy", "production", "diplomacy", "research", "build", "nations", "focus", ""]

# дни: пишет поток симуляции под замком мира, читается в конце под ним же
static var active := false
static var _seg_now := 0
static var _tick_us: Array = []      # по отрезкам: PackedInt32Array времени дня
static var _tick_worst: Array = []   # по отрезкам: [[мкс, дата, {фаза: мкс}], ...] — 6 худших


static func note_tick(sim: Simulation, world: World) -> void:
	if not active:
		return
	var us := sim.last_tick_usec
	_tick_us[_seg_now].append(us)
	var worst: Array = _tick_worst[_seg_now]
	if worst.size() < 6 or us > int(worst[-1][0]):
		worst.append([us, world.date_string(), sim.phase_usec.duplicate()])
		worst.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
		if worst.size() > 6:
			worst.pop_back()


var game
var _out: Array = []
var _action := ""
var _frames: Array = []   # по отрезкам: PackedFloat32Array времени кадра, мс
var _long: Array = []     # долгие кадры: [отрезок, мс, действие, дней, ЦП, ГП, {участок: мкс}]
var _seg_info: Array = [] # по отрезкам: {draws, cpu, gpu, script, drawn, days, sec, mem...}


func _p(s: String) -> void:
	print(s)
	_out.append(s)


var ingame := false   # из «Настроек» на идущей партии: потом партия загружается обратно
const BEFORE := "_stress_before"
const TMP := "_stress_tmp"


func run(g, in_game := false) -> void:
	game = g
	ingame = in_game
	var t_start := Time.get_ticks_msec()   # от запуска движка: загрузка + выбор страны
	var seg_sec := float(g._arg("seg")) if g._arg("seg") != "" else 5.0
	g.hud.patch_check = "--patchcheck" in OS.get_cmdline_user_args()
	var me: int
	var from := ""
	var t_ff := 0
	if ingame:
		me = g.player()
		g.world_lock()
		g.save_game(BEFORE, "Перед проверкой нагрузки")
		g.world_unlock()
		g.hud.close_popup()
	else:
		me = g.nation_by_tag(g._arg("nation")) if g._arg("nation") != "" else g.nation_by_tag("GER")
		from = g._arg("from") if g._arg("from") != "" else "1941-06-22"
		g.world_lock()
		g.start_as(me)
		var tf := Time.get_ticks_msec()
		while g.world.day < g.world.day_of(from):
			if not g.world.pending_peace.is_empty():
				g.sim.resolve_peace("annex")
			g.world.pending_events.clear()
			g.world.info_events.clear()
			g.sim.tick()
		g.world.events.clear()
		g.world_unlock()
		t_ff = Time.get_ticks_msec() - tf
		g.map_view.camera.zoom = Vector2.ONE * 1.4
		g.map_view.center_on(g.world.nations[me].capital)
	_tick_us.clear()
	_tick_worst.clear()
	for i in SEGMENTS.size():
		_tick_us.append(PackedInt32Array())
		_tick_worst.append([])
	_p("=== Стенд нагрузки Meowq ===")
	_p("Устройство: %s · %s · ядер %d · потоков симуляции %d · %s · ядро %s · Godot %s" % [
		OS.get_model_name(), OS.get_processor_name(), OS.get_processor_count(), Parallel.thread_count(),
		"ТЕЛЕФОН" if Device.mobile() else "ПК", "C++" if Native.available() else "GDScript",
		Engine.get_version_info().string])
	_p("Видео: %s · окно %s · карта: качество %s, разрешение %d%%, полосы %d" % [
		RenderingServer.get_video_adapter_name(), str(DisplayServer.window_get_size()),
		Settings.QUALITY_NAMES[Settings.map_quality()], int(g.map_view.res_scale * 100), g.map_view.strips])
	if g.boot_info != "":
		_p(g.boot_info)
	if ingame:
		_p("Партия: %s, %s, дивизий в мире %d" % [g.world.nations[me].name, g.world.date_string(), g.world.divisions.size()])
	else:
		_p("Запуск до выбора страны: %d мс; разгон до %s: %d мс; %s, дивизий %d" % [
			t_start, from, t_ff, g.world.nations[me].name, g.world.divisions.size()])
	# секунда покоя: заготовки и кэш движения строятся, как в игре до первого касания
	for i in 60:
		await get_tree().process_frame
	active = true
	for s in SEGMENTS.size():
		await _segment(s, seg_sec, me)
	active = false
	g.speed = 0
	_report()
	var text := "\n".join(_out) + "\n"
	var out: String = g._arg("out") if g._arg("out") != "" else ("user://stress.txt" if ingame else "")
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
	if ingame:
		SaveGame.remove(TMP)
		DisplayServer.clipboard_set(text)
		await g.load_game(BEFORE)
		SaveGame.remove(BEFORE)
		g.hud.toast("Проверка нагрузки окончена: отчёт скопирован в буфер обмена")
		queue_free()
		return
	g._shutdown()
	get_tree().quit()


func _segment(s: int, sec: float, me: int) -> void:
	var g = game
	g.world_lock()
	_seg_now = s
	g.speed = 0 if s == 0 else (6 if s == SEGMENTS.size() - 1 else 5)
	g.world_unlock()
	var ft := PackedFloat32Array()
	var info := {"draws": 0, "cpu": 0.0, "gpu": 0.0, "script": 0, "days0": g.ticks_done,
		"drawn0": Engine.get_frames_drawn()}
	var vrid: RID = get_viewport().get_viewport_rid()
	var t0 := Time.get_ticks_msec()
	var n := 0
	var last_act := -100000
	var step := 0
	var saved := false
	FrameProf.frame = {}
	var f_prev := Time.get_ticks_usec()
	while Time.get_ticks_msec() - t0 < sec * 1000.0:
		var now := Time.get_ticks_msec() - t0
		_action = ""
		match s:
			2:
				var tt := n * 0.05
				g.map_view.camera.position += Vector2(cos(tt), sin(tt)) * 6.0 / g.map_view.camera.zoom.x
				g.map_view.camera.zoom = Vector2.ONE * clampf(g.map_view.camera.zoom.x * (1.0 + 0.01 * sin(tt * 0.7)), 0.5, 3.0)
				g.map_view._moving = MapView.MOTION_SETTLE
				g.map_view._on_view_changed()
			3:
				if now - last_act >= 600:
					last_act = now
					var tab: String = TABS[step % TABS.size()]
					step += 1
					_action = "окно " + (tab if tab != "" else "закрыть")
					_timed(_action, func(): _open(tab, me))
			4:
				if now - last_act >= 500:
					last_act = now
					step += 1
					if step % 2 == 1:
						_action = "выделить всех"
						_timed(_action, func(): g.select_all())
					else:
						var cap: int = g.world.nations[me].capital
						var dst: int = g.world.p_adj[cap][step / 2 % g.world.p_adj[cap].size()]
						_action = "приказ всем"
						_timed(_action, func(): g._on_province_tapped_locked(dst))
						g.act(func(): g.clear_selection())
			5:
				if now - last_act >= 700:
					last_act = now
					step += 1
					var m: int = step % MapView.MapMode.size()
					_action = "режим карты %d" % m
					_timed(_action, func(): g.set_map_mode(m))
			6:
				if not saved and now >= sec * 400.0:
					saved = true
					_action = "сохранение"
					# заказ потоку симуляции: в кадре — только сам заказ, запись — фоном
					var t_s := Time.get_ticks_usec()
					g.save_game_bg(TMP, "Стенд нагрузки", func(_e: String):
						var bg: int = g.last_save_msec * 1000
						_acts["сохранение (фон)"] = [bg, bg, 1])
					var us_s := Time.get_ticks_usec() - t_s
					_acts[_action] = [us_s, us_s, 1]
		# события и мир — сразу, чтобы скорость не вставала на паузу
		if not g.world.event_front().is_empty() or not g.world.pending_peace.is_empty():
			g.act(func(): _clear_events())
		await get_tree().process_frame
		var f_now := Time.get_ticks_usec()
		var ms := (f_now - f_prev) / 1000.0
		f_prev = f_now
		var rc := RenderingServer.viewport_get_measured_render_time_cpu(vrid) + \
			RenderingServer.viewport_get_measured_render_time_cpu(g.map_view.map_vp.get_viewport_rid())
		var rg := RenderingServer.viewport_get_measured_render_time_gpu(vrid) + \
			RenderingServer.viewport_get_measured_render_time_gpu(g.map_view.map_vp.get_viewport_rid())
		var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		var scr := 0   # «main» уже включает свои части (буфер, интерфейс, палитра…)
		for k in FrameProf.frame:
			if not k in INSIDE_MAIN and k != "отрисовка движком (ЦП)":
				scr += int(FrameProf.frame[k])
		info["draws"] += dc
		info["cpu"] += rc
		info["gpu"] += rg
		info["script"] += scr
		if n > 0:   # первый кадр отрезка несёт смену скорости — не в счёт
			ft.append(ms)
			if ms > LONG_MS:
				_long.append([s, ms, _action, scr, rc, rg, FrameProf.frame.duplicate()])
		FrameProf.frame = {}
		n += 1
	if g.hud.popup.visible or g.hud.tech_view.visible or g.hud.focus_view.visible:
		g.act(func(): _open("", me))
	info["sec"] = (Time.get_ticks_msec() - t0) / 1000.0
	info["days"] = g.ticks_done - int(info["days0"])
	info["drawn"] = Engine.get_frames_drawn() - int(info["drawn0"])
	info["n"] = n
	info["mem"] = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	info["vram"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	info["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	info["objs"] = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_frames.append(ft)
	_seg_info.append(info)


var _acts := {}   # действие → [сумма мкс, худшее, раз]


## Действие через очередь игры (как кнопка): время выполнения на главном потоке.
func _timed(label: String, fn: Callable) -> void:
	game.act(func():
		var t := Time.get_ticks_usec()
		fn.call()
		var us := Time.get_ticks_usec() - t
		var r: Array = _acts.get(label, [0, 0, 0])
		_acts[label] = [int(r[0]) + us, maxi(int(r[1]), us), int(r[2]) + 1])


func _open(tab: String, me: int) -> void:
	var h = game.hud
	if tab == "":
		h.focus_view.hide()
		h.tech_view.hide()
		h.close_popup()
	elif tab == "focus":
		h.close_popup()
		h.focus_view.open(game, game.world, me)
	else:
		h.focus_view.hide()
		h.open_tab(tab)


func _clear_events() -> void:
	var w: World = game.world
	w.info_events.clear()
	w.info_option.clear()
	if not w.pending_events.is_empty():
		game.sim.resolve_event(0)
	if not w.pending_peace.is_empty():
		game.sim.resolve_peace("annex")
	game.speed = 0 if _seg_now == 0 else (6 if _seg_now == SEGMENTS.size() - 1 else 5)


static func _pct(a: PackedFloat32Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[clampi(int(q * (b.size() - 1)), 0, b.size() - 1)]


func _report() -> void:
	_p("")
	if game.hud.patch_check:
		_p("Сверка окон: проверок %d, расхождений %d" % [game.hud.patch_checks, game.hud.patch_fails])
	var mv = game.map_view
	if mv != null and mv.bake != null and mv.bake.ok:
		var bk = mv.bake
		_p("Заготовки карты: плотность %.2f · тайлов в пакетах %d (докачанных пакетов %d) · загружено %d, нарисовано %d · кадров из заготовок %d, живых %d" % [
			bk.r_cls, bk._pack.size(), DirAccess.get_files_at(MapBake.DL_DIR).size() if DirAccess.dir_exists_absolute(MapBake.DL_DIR) else 0,
			bk.loaded_tiles, bk.baked_tiles, mv.baked_draws, mv.live_draws])
	_p("Кадры (мс: медиана / 95% / 99% / худший; кадров > 33 / > 50 / > 100 мс):")
	for s in SEGMENTS.size():
		var a: PackedFloat32Array = _frames[s]
		var info: Dictionary = _seg_info[s]
		var c33 := 0
		var c50 := 0
		var c100 := 0
		for v in a:
			c33 += 1 if v > 33.0 else 0
			c50 += 1 if v > 50.0 else 0
			c100 += 1 if v > 100.0 else 0
		var n := maxi(1, int(info["n"]))
		_p("  %-34s %5.1f / %5.1f / %5.1f / %6.1f · %d / %d / %d из %d · %.0f к/с · дн/с %.1f" % [
			SEGMENTS[s], _pct(a, 0.5), _pct(a, 0.95), _pct(a, 0.99), _pct(a, 1.0), c33, c50, c100, a.size(),
			a.size() / maxf(0.001, float(info["sec"])), int(info["days"]) / maxf(0.001, float(info["sec"]))])
		_p("  %-34s скрипты кадра %.2f мс · движок ЦП %.2f / ГП %.2f мс · вызовов отрисовки %d · ОЗУ %.0f МБ, видео %.0f МБ, узлов %d, объектов %d" % [
			"", int(info["script"]) / 1000.0 / n, float(info["cpu"]) / n, float(info["gpu"]) / n,
			int(info["draws"]) / n, info["mem"], info["vram"], info["nodes"], info["objs"]])
	_p("")
	_p("Тик симуляции (мс: средний / 95% / худший; дней):")
	for s in SEGMENTS.size():
		var t: PackedInt32Array = _tick_us[s]
		if t.is_empty():
			continue
		var a := PackedFloat32Array()
		var sum := 0
		for v in t:
			a.append(v / 1000.0)
			sum += v
		_p("  %-34s %5.1f / %5.1f / %6.1f · %d" % [SEGMENTS[s], sum / 1000.0 / t.size(), _pct(a, 0.95), _pct(a, 1.0), t.size()])
	_p("")
	_p("Самые долгие дни (фазы > 1 мс):")
	var all: Array = []
	for s in SEGMENTS.size():
		all.append_array(_tick_worst[s])
	all.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	for i in mini(8, all.size()):
		var e: Array = all[i]
		_p("  %.1f мс, %s: %s" % [int(e[0]) / 1000.0, e[1], _top(e[2], 1000, 6)])
	_p("")
	_long.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	_p("Долгие кадры (> %.0f мс): %d. Худшие:" % [LONG_MS, _long.size()])
	for i in mini(15, _long.size()):
		var e: Array = _long[i]
		_p("  %6.1f мс · %s%s · движок ЦП %.1f / ГП %.1f · скрипты %.1f · %s" % [float(e[1]), SEGMENTS[int(e[0])],
			(" · " + str(e[2])) if str(e[2]) != "" else "", float(e[4]), float(e[5]), float(e[3]) / 1000.0, _top(e[6], 500, 5)])
	_p("  (кадр − скрипты − движок ЦП = ожидание: ГП, синхронизация, вытеснение потоками)")
	_p("")
	_p("Действия игрока (главный поток, мс: среднее / худшее, раз; без отрисовки нового окна):")
	var ak := _acts.keys()
	ak.sort_custom(func(a, b): return int(_acts[a][1]) > int(_acts[b][1]))
	for k in ak:
		var r: Array = _acts[k]
		_p("  %-28s %6.1f / %6.1f · %d" % [k, int(r[0]) / 1000.0 / maxi(1, int(r[2])), int(r[1]) / 1000.0, int(r[2])])
	_p("")
	for l in Report.prof_lines():
		_p(l)


static func _top(d: Dictionary, min_us: int, n: int) -> String:
	var keys := d.keys().filter(func(k): return k != "main" and int(d[k]) >= min_us)
	keys.sort_custom(func(a, b): return int(d[a]) > int(d[b]))
	var parts: Array = []
	for i in mini(n, keys.size()):
		parts.append("%s %.1f" % [keys[i], int(d[keys[i]]) / 1000.0])
	return ", ".join(parts) if not parts.is_empty() else "участки главного потока < %.1f мс" % (min_us / 1000.0)
