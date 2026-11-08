class_name Report
extends RefCounted
## Отчёт для разработки: устройство, настройки, замеры за последние 30 с и
## ошибки из журнала Godot (user://logs, запись включена в project.godot).
## Кнопка в «Настройках» копирует его в буфер обмена.

const KEEP := 30   # секунд истории замеров

# история: каждую секунду — [FPS, тик, логика, фишки, ГП карта, дн/с]
static var _hist: Array = []
static var _last_msec := 0
const FIELDS := ["FPS", "тик, мс", "логика, мс", "фишки, мс", "ГП карта, мс", "дн/с"]


static func sample(fps: float, tick_ms: float, logic_ms: float, units_ms: float, gpu_map_ms: float, dps: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_msec < 1000:
		return
	_last_msec = now
	_hist.append([fps, tick_ms, logic_ms, units_ms, gpu_map_ms, dps])
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
	L.append("Ядро: %s · версия Godot %s" % ["C++" if Native.available() else "GDScript", Engine.get_version_info().string])
	L.append("Настройки: качество %s · разрешение %s (сейчас %d%%) · кадры %s · упрощать при сдвиге %s" % [
		Settings.QUALITY_NAMES[Settings.map_quality()], Settings.RES_NAMES[Settings.map_res()],
		int(game.map_view.res_scale * 100), Settings.FPS_NAMES[Settings.fps_cap()],
		"да" if Settings.motion_lite() else "нет"])
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
	L.append("")
	L.append("Ошибки в текущем журнале:")
	L.append_array(_log_errors(_current_log(), 15))
	var prev := _previous_log()
	if prev != "":
		L.append("")
		L.append("Конец прошлого журнала (%s) — если игра вылетела, причина здесь:" % prev.get_file())
		L.append_array(_tail(prev, 25))
	return "\n".join(L)


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
