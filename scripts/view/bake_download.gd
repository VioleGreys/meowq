class_name BakeDownload
extends Node
## Докачка пакетов заготовок карты ближних масштабов (решение пользователя, ноябрь
## 2026: APK без них, файлы — в ветке bake-data репозитория на GitHub, скачивание —
## кнопкой в «Настройках»). Список — res://data/bake_remote.json (пишет
## tools/bake_split.py при сборке APK): адрес папки, файлы пакетов, их части
## (≤ 50 МБ — предел GitHub 100 МБ) с размером и SHA-256.
## Части качаются по одной в MapBake.DL_DIR; проверенная часть переименовывается
## в своё имя — после обрыва качаются только недостающие. Когда части файла все,
## рабочий поток склеивает их в пакет; MapBake читает его наравне с пакетами APK
## (версию и сетку проверяет сам — пакет от другой сборки не возьмёт).

signal changed                  # состояние или прогресс (не чаще ~2 раз в секунду)
signal finished                 # все пакеты на месте — перечитать (MapView.bake_reload)

const MANIFEST := "res://data/bake_remote.json"
const TMP := "dl.tmp"
const RETRIES := 3

var state := "idle"             # idle | run | join | done | error
var error := ""
var _m := {}
var _http: HTTPRequest
var _queue: Array = []          # [файл, часть] — осталось скачать
var _cur: Array = []
var _tries := 0
var _join_task := -1
var _join_file := {}
var _last_emit := 0


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
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.download_chunk_size = 1 << 20
	add_child(_http)
	_http.request_completed.connect(_on_done)
	set_process(false)
	if available() and have_bytes() >= total_bytes():
		state = "done"


func available() -> bool:
	return not _m.is_empty() and not (_m.get("files", []) as Array).is_empty()


func total_bytes() -> int:
	var t := 0
	for f in _m.get("files", []):
		t += int(f["size"])
	return t


## Скачано: готовые пакеты, проверенные части, текущая часть.
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
	if state == "run" and not _cur.is_empty():
		t += maxi(_http.get_downloaded_bytes(), 0)
	return t


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


func start() -> void:
	if not available() or state == "run" or state == "join":
		return
	DirAccess.make_dir_recursive_absolute(MapBake.DL_DIR)
	_clean_foreign()
	error = ""
	_queue.clear()
	for f in _m["files"]:
		if _size(MapBake.DL_DIR + str(f["name"])) == int(f["size"]):
			continue
		for part in f["parts"]:
			if _size(MapBake.DL_DIR + str(part["name"])) != int(part["size"]):
				_queue.append([f, part])
	state = "run"
	set_process(true)
	_next()


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
	_http.cancel_request()
	_cur = []
	DirAccess.remove_absolute(MapBake.DL_DIR + TMP)
	state = "idle"
	set_process(false)
	changed.emit()


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


func _next() -> void:
	# файлы, у которых все части на месте, — склеить (по одному, рабочим потоком)
	if _join_task < 0:
		for f in _m["files"]:
			if _size(MapBake.DL_DIR + str(f["name"])) == int(f["size"]):
				continue
			var all := true
			for part in f["parts"]:
				if _size(MapBake.DL_DIR + str(part["name"])) != int(part["size"]):
					all = false
					break
			if all:
				_join_file = f
				_join_task = WorkerThreadPool.add_task(_join.bind(f))
				break
	if _queue.is_empty():
		_cur = []
		if _join_task < 0:
			_finish()
		else:
			state = "join"
		changed.emit()
		return
	_cur = _queue[0]
	_tries = 0
	_request()


func _request() -> void:
	var part: Dictionary = _cur[1]
	_http.download_file = MapBake.DL_DIR + TMP
	var url: String = str(_m["base"]) + str(part["name"])
	var err := _http.request(url)
	if err != OK:
		_fail("не удалось начать загрузку (%d)" % err)


func _on_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if state != "run" or _cur.is_empty():
		return
	var part: Dictionary = _cur[1]
	var tmp := MapBake.DL_DIR + TMP
	var why := ""
	if result != HTTPRequest.RESULT_SUCCESS:
		why = "нет связи (%d)" % result
	elif code != 200:
		why = "сервер ответил %d" % code
	elif _size(tmp) != int(part["size"]):
		why = "часть не того размера"
	elif FileAccess.get_sha256(tmp) != str(part["sha256"]):
		why = "часть повреждена"
	if why != "":
		DirAccess.remove_absolute(tmp)
		_tries += 1
		if _tries >= RETRIES:
			_fail(why)
		else:
			get_tree().create_timer(2.0 * _tries).timeout.connect(func():
				if state == "run":
					_request())
		return
	DirAccess.rename_absolute(tmp, MapBake.DL_DIR + str(part["name"]))
	_queue.pop_front()
	_next()


func _fail(why: String) -> void:
	_cur = []
	error = why
	state = "error"
	set_process(_join_task >= 0)
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
	if _join_task >= 0 and WorkerThreadPool.is_task_completed(_join_task):
		WorkerThreadPool.wait_for_task_completion(_join_task)
		_join_task = -1
		if _size(MapBake.DL_DIR + str(_join_file["name"])) != int(_join_file["size"]):
			_fail("не удалось собрать %s (мало места?)" % _join_file["name"])
			return
		if state == "join" or state == "run":
			if state == "join" or _queue.is_empty():
				_next()
			else:
				_next_join_only()
		elif state == "error":
			set_process(false)
	var now := Time.get_ticks_msec()
	if now - _last_emit > 500:
		_last_emit = now
		changed.emit()


## Скачивание идёт — только поставить склейку следующего готового файла.
func _next_join_only() -> void:
	for f in _m["files"]:
		if _size(MapBake.DL_DIR + str(f["name"])) == int(f["size"]):
			continue
		var all := true
		for part in f["parts"]:
			if _size(MapBake.DL_DIR + str(part["name"])) != int(part["size"]):
				all = false
				break
		if all:
			_join_file = f
			_join_task = WorkerThreadPool.add_task(_join.bind(f))
			return


func _finish() -> void:
	for f in _m["files"]:
		if _size(MapBake.DL_DIR + str(f["name"])) != int(f["size"]):
			_fail("не все файлы собраны")
			return
	state = "done"
	set_process(false)
	finished.emit()
