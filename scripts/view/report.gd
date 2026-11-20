class_name Report
extends RefCounted
## Отчёт для разработки: устройство, настройки, замеры за последние 30 с и
## ошибки из журнала Godot (user://logs, запись включена в project.godot).
## Кнопка в «Настройках» копирует его в буфер обмена.

const KEEP := 30   # секунд истории замеров

# история: каждую секунду — [FPS, тик, логика, фишки, ГП карта, дн/с, худший кадр,
# полных перерисовок карты, частичных]
static var _hist: Array = []
static var _last_msec := 0
const FIELDS := ["FPS (в покое кадры не рисуются — меньше нормально)", "тик, мс", "логика, мс", "фишки, мс", "ГП карта, мс", "дн/с",
	"худший кадр за с, мс", "полных перерисовок карты за с", "частичных перерисовок за с",
	"кадров нарисовано за с", "шагов игры за с"]
static var _frame_max := 0.0
static var _rd_full := 0
static var _rd_part := 0


## Каждый кадр (MapView._process): худший кадр и перерисовки карты за секунду.
static var _frame_usec := 0
static var _drawn_prev := 0
static var _frames_iter := 0


static func frame(_dt: float, full_redraws: int, part_redraws: int) -> void:
	# по часам, а не по delta движка (её ограничивают сверху)
	var now := Time.get_ticks_usec()
	_frames_iter += 1
	var dt_us := now - _frame_usec if _frame_usec > 0 else 0
	_frame_usec = now
	_frame_max = maxf(_frame_max, dt_us / 1000.0)
	_rd_full = full_redraws
	_rd_part = part_redraws


static var _prof: Array = []   # по секундам: [участок → мкс за с, участок → худший замер]
static var _rd_full_prev := 0
static var _rd_part_prev := 0


static func sample(fps: float, tick_ms: float, logic_ms: float, units_ms: float, gpu_map_ms: float, dps: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_msec < 1000:
		return
	_last_msec = now
	FrameProf.roll()
	var drawn := Engine.get_frames_drawn()
	var fps_drawn := float(drawn - _drawn_prev)
	_drawn_prev = drawn
	_hist.append([fps, tick_ms, logic_ms, units_ms, gpu_map_ms, dps, _frame_max,
		float(_rd_full - _rd_full_prev), float(_rd_part - _rd_part_prev), fps_drawn, float(_frames_iter)])
	_frames_iter = 0
	_prof.append([FrameProf.last_sum, FrameProf.last_max])
	while _prof.size() > KEEP:
		_prof.pop_front()
	_frame_max = 0.0
	_rd_full_prev = _rd_full
	_rd_part_prev = _rd_part
	while _hist.size() > KEEP:
		_hist.pop_front()


static func build(game) -> String:
	var L: Array = []
	L.append("=== Отчёт Meowq ===")
	L.append("Время: %s" % Time.get_datetime_string_from_system())
	L.append("Устройство: %s · %s %s" % [OS.get_model_name(), OS.get_name(), OS.get_version()])
	L.append("Процессор: %s · ядер %d" % [OS.get_processor_name(), OS.get_processor_count()])
	L.append("Видео: %s · %s · API %s" % [RenderingServer.get_video_adapter_name(),
		RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_api_version()])
	L.append("Рендерер: %s" % ProjectSettings.get_setting_with_override("rendering/renderer/rendering_method"))
	var scr := DisplayServer.screen_get_size()
	L.append("Экран: %dx%d, %.0f Гц · окно %s" % [scr.x, scr.y, DisplayServer.screen_get_refresh_rate(),
		str(DisplayServer.window_get_size())])
	L.append("Ядро: %s · версия Godot %s · потоков симуляции %d" % ["C++" if Native.available() else "GDScript",
		Engine.get_version_info().string, Parallel.thread_count()])
	L.append("Настройки: качество %s · разрешение %s (сейчас %d%%) · кадры %s · упрощать при сдвиге %s · лёгкая карта %s" % [
		Settings.QUALITY_NAMES[Settings.map_quality()], Settings.RES_NAMES[Settings.map_res()],
		int(game.map_view.res_scale * 100), Settings.FPS_NAMES[Settings.fps_cap()],
		"да" if Settings.motion_lite() else "нет", "да" if Settings.phone_map() else "нет"])
	var mv = game.map_view
	if mv != null and mv.bake != null:
		var bk = mv.bake
		L.append("Заготовки карты: %s · пакетов APK — тайлов %d · кэш %d МБ из %s · плотность %.2f · кадров из заготовок %d, живых %d · тайлов нарисовано %d, загружено %d" % [
			"вкл" if mv._bake_ok() else "выкл", bk._pack.size(), roundi(bk.cache_mb()),
			Settings.BAKE_CACHE_NAMES[Settings.bake_cache()], bk.r_cls, mv.baked_draws, mv.live_draws,
			bk.baked_tiles, bk.loaded_tiles])
	if game.world != null:
		var w = game.world
		var me: int = game.player()
		L.append("Игра: %s · %s · скорость %d · дивизий в мире %d · масштаб %.2f" % [
			w.nations[me].name if me >= 0 else "-", w.date_string(), game.speed, w.divisions.size(),
			game.map_view.zoom_level()])
	L.append("")
	L.append("Замеры за %d с (мин / сред / макс):" % _hist.size())
	for f in FIELDS.size():
		if _hist.is_empty():
			break
		var lo := INF
		var hi := -INF
		var sum := 0.0
		for row in _hist:
			var v: float = row[f]
			lo = minf(lo, v)
			hi = maxf(hi, v)
			sum += v
		L.append("  %s: %.1f / %.1f / %.1f" % [FIELDS[f], lo, sum / _hist.size(), hi])
	L.append_array(prof_lines())
	L.append("")
	L.append("Ошибки в текущем журнале:")
	L.append_array(_log_errors(_current_log(), 15))
	var prev := _previous_log()
	if prev != "":
		L.append("")
		L.append("Конец прошлого журнала (%s) — если игра вылетела, причина здесь:" % prev.get_file())
		L.append_array(_tail(prev, 25))
	return "\n".join(L)


## Главный поток по участкам: мс за секунду в среднем и худший одиночный замер.
## main — весь _process игры (буфер, действия, интерфейс — его части); карта и
## фишки — отдельно. Остаток кадра — отрисовка движком (на GLES не замерить).
static func prof_lines() -> Array:
	var out: Array = []
	if _prof.is_empty():
		return out
	var tot := {}
	var worst := {}
	for row in _prof:
		for k in row[0]:
			tot[k] = int(tot.get(k, 0)) + int(row[0][k])
		for k in row[1]:
			worst[k] = maxi(int(worst.get(k, 0)), int(row[1][k]))
	var keys: Array = tot.keys()
	keys.sort_custom(func(a, b): return int(tot[a]) > int(tot[b]))
	out.append("")
	out.append("Главный поток, мс за секунду (сред) · худший раз, мс:")
	for k in keys:
		out.append("  %s: %.1f · %.1f" % [k, int(tot[k]) / 1000.0 / _prof.size(), int(worst[k]) / 1000.0])
	return out


static func _current_log() -> String:
	return ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")


## Прошлый журнал: Godot при запуске переименовывает старый godot.log в
## godot<дата>.log — берём самый свежий из них.
static func _previous_log() -> String:
	var dir := _current_log().get_base_dir()
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var best := ""
	for f in d.get_files():
		if f.ends_with(".log") and f != _current_log().get_file() and f > best:
			best = f
	return dir.path_join(best) if best != "" else ""


static func _read_lines(path: String) -> PackedStringArray:
	if path == "" or not FileAccess.file_exists(path):
		return PackedStringArray()
	return FileAccess.get_file_as_string(path).split("\n")


static func _log_errors(path: String, limit: int) -> Array:
	var lines := _read_lines(path)
	var out: Array = []
	for i in lines.size():
		var l := lines[i]
		if l.contains("ERROR") or l.contains("WARNING") or l.contains("crash") or l.contains("signal"):
			out.append("  " + l.strip_edges())
			if i + 1 < lines.size() and lines[i + 1].strip_edges().begins_with("at:"):
				out.append("    " + lines[i + 1].strip_edges())
	if out.is_empty():
		return ["  нет"]
	return out.slice(maxi(0, out.size() - limit))


static func _tail(path: String, n: int) -> Array:
	var lines := _read_lines(path)
	var out: Array = []
	for l in lines.slice(maxi(0, lines.size() - n)):
		if l.strip_edges() != "":
			out.append("  " + l)
	return out
