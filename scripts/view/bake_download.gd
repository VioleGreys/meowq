class_name BakeDownload
extends Node
## Докачка пакетов заготовок карты ближних масштабов (решение пользователя, ноябрь
## 2026: APK без них, файлы — в ветке bake-data репозитория на GitHub, скачивание —
## кнопкой в «Настройках»). Список — res://data/bake_remote.json (пишет
## tools/bake_split.py при сборке APK): зеркала (raw.githubusercontent.com и CDN
## jsDelivr — тот же GitHub), файлы пакетов, их части (≤ 19 МБ — предел jsDelivr
## 20 МБ) с размером и SHA-256.
## Части качаются по SLOTS сразу (одно соединение на телефоне — ~50–80 КБ/с,
## ноябрь 2026) в MapBake.DL_DIR; зеркало для следующей части — быстрейшее по
## замеру (непроверенные — сначала). Проверенная часть переименовывается в своё
## имя — после обрыва качаются только недостающие. Когда части файла все, рабочий
## поток склеивает их в пакет; MapBake читает его наравне с пакетами APK (версию
## и сетку проверяет сам — пакет от другой сборки не возьмёт).

signal changed                  # состояние или прогресс (не чаще ~2 раз в секунду)
signal finished                 # все пакеты на месте — перечитать (MapView.bake_reload)

const MANIFEST := "res://data/bake_remote.json"
const SLOTS := 4
const RETRIES := 3              # попыток на часть на каждом зеркале

var state := "idle"             # idle | run | done | error
var error := ""
var _m := {}
var _mirrors: Array = []        # адреса папок
var _mir_bytes: PackedFloat64Array
var _mir_time: PackedFloat64Array
var _slots: Array = []          # {http, item: [файл, часть] или [], tries, mir, t0}
var _queue: Array = []          # [файл, часть] — осталось скачать
var _join_task := -1
var _join_file := {}
var _last_emit := 0
var _rate := 0.0                # байт/с, сглаженная
var _rate_t := 0
var _rate_b := 0


static func get_in(host: Node) -> BakeDownload:
	var n := host.get_node_or_null("BakeDownload") as BakeDownload
	if n == null:
		n = BakeDownload.new()
		n.name = "BakeDownload"
		host.add_child(n)
	return n


static func manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	return d if d is Dictionary else {}


func _ready() -> void:
	_m = manifest()
	set_mirrors(_m.get("mirrors", [_m.get("base", "")]) as Array)
	for i in SLOTS:
		var h := HTTPRequest.new()
		h.use_threads = true
		h.download_chunk_size = 1 << 20
		add_child(h)
		h.request_completed.connect(_on_done.bind(i))
		_slots.append({"http": h, "item": [], "tries": 0, "mir": i, "t0": 0})
	set_process(false)
	if available() and have_bytes() >= total_bytes():
		state = "done"


## Зеркала (для проверки — локальный сервер).
func set_mirrors(list: Array) -> void:
	_mirrors = list.duplicate()
	_mir_bytes = PackedFloat64Array()
	_mir_bytes.resize(_mirrors.size())
	_mir_time = PackedFloat64Array()
	_mir_time.resize(_mirrors.size())


func available() -> bool:
	return not _m.is_empty() and not (_m.get("files", []) as Array).is_empty() and not _mirrors.is_empty()


func total_bytes() -> int:
	var t := 0
	for f in _m.get("files", []):
		t += int(f["size"])
	return t


## Скачано: готовые пакеты, проверенные части, текущие части.
func have_bytes() -> int:
	var t := 0
	for f in _m.get("files", []):
		var p: String = MapBake.DL_DIR + str(f["name"])
		if _size(p) == int(f["size"]):
			t += int(f["size"])
			continue
		for part in f["parts"]:
			if _size(MapBake.DL_DIR + str(part["name"])) == int(part["size"]):
				t += int(part["size"])
	return t + _inflight()


func _inflight() -> int:
	var t := 0
	if state == "run":
		for sl in _slots:
			if not (sl["item"] as Array).is_empty():
				t += maxi((sl["http"] as HTTPRequest).get_downloaded_bytes(), 0)
	return t


## Скорость, МБ в минуту (сглаженная).
func speed_mb_min() -> float:
	return _rate * 60.0 / 1048576.0


## Место на диске под скачанное (готовые пакеты и части).
func disk_bytes() -> int:
	var t := 0
	var d := DirAccess.open(MapBake.DL_DIR)
	if d == null:
		return 0
	for fn in d.get_files():
		t += _size(MapBake.DL_DIR + fn)
	return t


static func _size(p: String) -> int:
	if not FileAccess.file_exists(p):
		return -1
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_length() if f != null else -1


func _part_ok(part: Dictionary) -> bool:
	return _size(MapBake.DL_DIR + str(part["name"])) == int(part["size"])


func _file_ok(f: Dictionary) -> bool:
	return _size(MapBake.DL_DIR + str(f["name"])) == int(f["size"])


func start() -> void:
	if not available() or state == "run":
		return
	DirAccess.make_dir_recursive_absolute(MapBake.DL_DIR)
	if _join_task >= 0:
		# склейка пишет .tmp — не удалить его как чужой файл
		WorkerThreadPool.wait_for_task_completion(_join_task)
		_join_task = -1
	_clean_foreign()
	error = ""
	_queue.clear()
	for f in _m["files"]:
		if _file_ok(f):
			continue
		for part in f["parts"]:
			if not _part_ok(part):
				_queue.append([f, part])
	state = "run"
	_rate = 0.0
	_rate_t = Time.get_ticks_msec()
	_rate_b = have_bytes()
	set_process(true)
	for i in SLOTS:
		_feed(i)
	changed.emit()


## Файлы прежней сборки (не из этого списка) — удалить: место и путаница.
func _clean_foreign() -> void:
	var keep := {}
	for f in _m["files"]:
		keep[str(f["name"])] = true
		for part in f["parts"]:
			keep[str(part["name"])] = true
	var d := DirAccess.open(MapBake.DL_DIR)
	if d == null:
		return
	for fn in d.get_files():
		if not keep.has(fn):
			d.remove(fn)


func stop() -> void:
	if state != "run":
		return
	_cancel_all()
	state = "idle"
	changed.emit()


func _cancel_all() -> void:
	for i in SLOTS:
		var sl: Dictionary = _slots[i]
		(sl["http"] as HTTPRequest).cancel_request()
		sl["item"] = []
		DirAccess.remove_absolute(_tmp(i))


func _tmp(i: int) -> String:
	return MapBake.DL_DIR + "dl%d.tmp" % i


## Удалить скачанное (карта сразу переходит на пакеты APK и рисование на телефоне).
func remove_all(view: MapView) -> void:
	stop()
	if _join_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_join_task)
		_join_task = -1
	if view != null and view.bake != null:
		view.bake._wait_jobs()      # загрузки тайлов из пакетов — до удаления файлов
	var d := DirAccess.open(MapBake.DL_DIR)
	if d != null:
		for fn in d.get_files():
			d.remove(fn)
	state = "idle"
	if view != null:
		view.bake_reload()
	changed.emit()


## Зеркало для новой части: непроверенное, иначе быстрейшее по замеру.
func _pick_mirror(prefer: int) -> int:
	var n := _mirrors.size()
	var probing := {}           # непроверенное, но его уже пробует другой поток
	for sl in _slots:
		if not (sl["item"] as Array).is_empty():
			probing[int(sl["mir"])] = true
	for j in n:
		var m := (prefer + j) % n
		if _mir_time[m] <= 0.0 and not probing.has(m):
			return m
	# все проверяются — пока нет замера, на любом проверенном или своём
	var known := false
	for m in n:
		known = known or _mir_time[m] > 0.0
	if not known:
		return prefer % n
	var best := prefer % n
	for m in n:
		if _mir_bytes[m] / _mir_time[m] > _mir_bytes[best] / _mir_time[best]:
			best = m
	return best


func _feed(i: int) -> void:
	var sl: Dictionary = _slots[i]
	sl["item"] = []
	if state != "run" or _queue.is_empty():
		return
	sl["item"] = _queue.pop_front()
	sl["tries"] = 0
	sl["mir"] = _pick_mirror(i)
	_request(i)


func _request(i: int) -> void:
	var sl: Dictionary = _slots[i]
	var part: Dictionary = sl["item"][1]
	var h: HTTPRequest = sl["http"]
	h.download_file = _tmp(i)
	sl["t0"] = Time.get_ticks_msec()
	var err := h.request(str(_mirrors[sl["mir"]]) + str(part["name"]))
	if err != OK:
		_fail("не удалось начать загрузку (%d)" % err)


func _on_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, i: int) -> void:
	var sl: Dictionary = _slots[i]
	if state != "run" or (sl["item"] as Array).is_empty():
		return
	var part: Dictionary = sl["item"][1]
	var tmp := _tmp(i)
	var why := ""
	if result != HTTPRequest.RESULT_SUCCESS:
		why = _result_text(result)
	elif code != 200:
		why = "сервер ответил %d" % code
	elif _size(tmp) != int(part["size"]):
		why = "часть не того размера"
	elif FileAccess.get_sha256(tmp) != str(part["sha256"]):
		why = "часть повреждена"
	var m: int = sl["mir"]
	if why != "":
		DirAccess.remove_absolute(tmp)
		sl["tries"] = int(sl["tries"]) + 1
		if int(sl["tries"]) >= RETRIES * _mirrors.size():
			_fail(why)
			return
		# следующая попытка — на другом зеркале; плохому — штраф в замере
		_mir_time[m] += 30.0
		_mir_bytes[m] += 1.0
		sl["mir"] = (m + 1) % _mirrors.size()
		var tries: int = sl["tries"]
		get_tree().create_timer(1.0 * tries).timeout.connect(func():
			if state == "run" and not (sl["item"] as Array).is_empty():
				_request(i))
		return
	_mir_bytes[m] += float(part["size"])
	_mir_time[m] += maxf((Time.get_ticks_msec() - int(sl["t0"])) / 1000.0, 0.05)
	DirAccess.rename_absolute(tmp, MapBake.DL_DIR + str(part["name"]))
	_feed(i)


static func _result_text(r: int) -> String:
	match r:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "не удалось соединиться (нет доступа к сети?)"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "не найден сервер (DNS)"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "связь оборвалась"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "ошибка защищённого соединения"
		HTTPRequest.RESULT_TIMEOUT:
			return "истекло время ожидания"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "не удалось записать файл (мало места?)"
	return "нет связи (код %d)" % r


func _fail(why: String) -> void:
	_cancel_all()
	error = why
	state = "error"
	changed.emit()


## Рабочий поток: части → пакет (через .tmp и переименование — недоклеенный файл
## под именем пакета не остаётся), части удаляются.
func _join(f: Dictionary) -> void:
	var out := MapBake.DL_DIR + str(f["name"])
	var w := FileAccess.open(out + ".tmp", FileAccess.WRITE)
	if w == null:
		return
	for part in f["parts"]:
		var r := FileAccess.open(MapBake.DL_DIR + str(part["name"]), FileAccess.READ)
		if r == null:
			w.close()
			DirAccess.remove_absolute(out + ".tmp")
			return
		while r.get_position() < r.get_length():
			w.store_buffer(r.get_buffer(4 << 20))
	w.close()
	if _size(out + ".tmp") != int(f["size"]):
		DirAccess.remove_absolute(out + ".tmp")
		return
	DirAccess.rename_absolute(out + ".tmp", out)
	for part in f["parts"]:
		DirAccess.remove_absolute(MapBake.DL_DIR + str(part["name"]))


func _process(_dt: float) -> void:
	# склейка: по одному файлу, у которого все части на месте
	if _join_task >= 0 and WorkerThreadPool.is_task_completed(_join_task):
		WorkerThreadPool.wait_for_task_completion(_join_task)
		_join_task = -1
		if not _file_ok(_join_file):
			_fail("не удалось собрать %s (мало места?)" % _join_file["name"])
	if _join_task < 0 and state == "run":
		for f in _m["files"]:
			if _file_ok(f):
				continue
			var all := true
			for part in f["parts"]:
				if not _part_ok(part):
					all = false
					break
			if all:
				_join_file = f
				_join_task = WorkerThreadPool.add_task(_join.bind(f))
				break
	var busy := _join_task >= 0
	for sl in _slots:
		busy = busy or not (sl["item"] as Array).is_empty()
	if state == "run" and _queue.is_empty() and not busy:
		_finish()
		return
	if state != "run" and _join_task < 0:
		set_process(false)
	var now := Time.get_ticks_msec()
	if now - _rate_t >= 2000:
		var b := have_bytes()
		var r := maxf(b - _rate_b, 0.0) * 1000.0 / (now - _rate_t)
		_rate = r if _rate <= 0.0 else _rate * 0.6 + r * 0.4
		_rate_t = now
		_rate_b = b
	if now - _last_emit > 500:
		_last_emit = now
		changed.emit()


func _finish() -> void:
	for f in _m["files"]:
		if not _file_ok(f):
			_fail("не все файлы собраны")
			return
	state = "done"
	set_process(false)
	finished.emit()
	changed.emit()
