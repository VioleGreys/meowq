extends SceneTree
## Докачка пакетов заготовок (BakeDownload) против локального сервера:
##   python3 -m http.server 8765 -d export/bake-data/<версия> &   (или любая папка частей)
##   godot --headless --path . --script res://tests/bake_dl_check.gd -- --base=http://127.0.0.1:8765/
## Список — data/bake_remote.json (tools/bake_split.py). Проверяет: скачивание с
## остановкой посередине и продолжением, склейку, совпадение пакетов с data/bake
## (SHA-256), ошибку на неверном адресе.

var dl: BakeDownload
var base := ""
var phase := 0
var t0 := 0
var stops := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--base="):
			base = a.substr(7)
	if base == "" or BakeDownload.manifest().is_empty():
		print("bake_dl_check: нужен --base=URL и data/bake_remote.json")
		quit(1)
		return


func _begin() -> void:
	DirAccess.make_dir_recursive_absolute(MapBake.DL_DIR)
	var d := DirAccess.open(MapBake.DL_DIR)
	for fn in d.get_files():
		d.remove(fn)
	dl = BakeDownload.new()
	root.add_child(dl)
	dl._m["base"] = base
	dl.finished.connect(_on_finished)
	t0 = Time.get_ticks_msec()
	dl.start()


func _process(_dt: float) -> bool:
	if dl == null:
		_begin()     # в _initialize узлы ещё не в дереве — HTTPRequest не начнёт
		return false
	if phase == 0 and dl.state == "run" and dl.have_bytes() > 40 << 20 and stops == 0:
		stops = 1
		dl.stop()
		print("остановлено на %.1f МБ, продолжаем" % (dl.have_bytes() / 1048576.0))
		dl.start()
	if dl.state == "error":
		if phase == 2:
			print("неверный адрес → ошибка: %s — OK" % dl.error)
			print("bake_dl_check: OK")
			quit(0)
		else:
			print("ОШИБКА: %s" % dl.error)
			quit(1)
	if Time.get_ticks_msec() - t0 > 600000:
		print("ОШИБКА: не успели за 10 мин")
		quit(1)
	return false


func _on_finished() -> void:
	if phase != 0:
		return
	phase = 1
	print("скачано %.1f МБ за %.1f с" % [dl.total_bytes() / 1048576.0, (Time.get_ticks_msec() - t0) / 1000.0])
	var bad := 0
	for f in dl._m["files"]:
		var a := FileAccess.get_sha256(MapBake.DL_DIR + str(f["name"]))
		var b := FileAccess.get_sha256(MapBake.PACK_DIR + str(f["name"]))
		if a != b:
			bad += 1
			print("  НЕ СОВПАЛ: %s" % f["name"])
	var left := DirAccess.get_files_at(MapBake.DL_DIR).size()
	print("пакеты совпали с data/bake: %s; файлов в папке: %d (ждали %d)" % [bad == 0, left, (dl._m["files"] as Array).size()])
	if bad != 0 or left != (dl._m["files"] as Array).size():
		quit(1)
		return
	# неверный адрес: удалить один пакет и качать с несуществующей папки
	phase = 2
	DirAccess.remove_absolute(MapBake.DL_DIR + str(dl._m["files"][0]["name"]))
	dl._m["base"] = base + "nope/"
	dl.start()
