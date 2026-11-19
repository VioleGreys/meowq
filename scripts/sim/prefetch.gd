class_name ImgPrefetch
extends RefCounted
## Распаковка картинок карты при запуске — в рабочих потоках.
## PNG карты (5664×5250 и 5632×2625) распаковываются по 0,15–0,25 с каждый на
## ПК (на телефоне в 4–5 раз дольше); раньше главный поток распаковывал их
## подряд, и загрузка мира ждала сумму (~1,7 с на ПК). Теперь `main.new_world`
## заранее ставит задачи на все файлы (`MapLoader.prefetch`, `MapView.prefetch`),
## а места загрузки забирают готовое (`image`, `take`); не запущено — распаковка
## на месте, как раньше. Задачи только читают файлы и свои картинки.
## Задачи — высокого приоритета: задачам низкого пул отдаёт ~30 % потоков
## (замер: 4 PNG в пуле с низким приоритетом 813 мс, в потоках — 265, подряд 835).

static var _tasks := {}    # ключ -> id задачи пула
static var _out := {}      # ключ -> Image (пишет задача, под _mx)
static var _mx := Mutex.new()


## Поставить задачу: fn() -> Image вызывается в рабочем потоке.
static func run(key: String, fn: Callable) -> void:
	if _tasks.has(key):
		return
	_tasks[key] = WorkerThreadPool.add_task(_job.bind(key, fn), true, "Prefetch " + key.get_file())


static func _job(key: String, fn: Callable) -> void:
	var img: Image = fn.call()
	_mx.lock()
	_out[key] = img
	_mx.unlock()


## Файл картинки заранее (см. decode).
static func file(path: String, fmt: int = -1, mips: bool = false) -> void:
	run(path, decode.bind(path, fmt, mips))


## Готовая картинка задачи (ждёт её); null — задачи не было или не вышло.
static func take(key: String) -> Image:
	if not _tasks.has(key):
		return null
	WorkerThreadPool.wait_for_task_completion(_tasks[key])
	_tasks.erase(key)
	_mx.lock()
	var img: Image = _out.get(key)
	_out.erase(key)
	_mx.unlock()
	return img


## Картинка файла: из задачи, если ставилась (с теми же fmt и mips), иначе сразу.
static func image(path: String, fmt: int = -1, mips: bool = false) -> Image:
	if _tasks.has(path):
		return take(path)
	return decode(path, fmt, mips)


## Распаковать PNG (или JPG — «.jpg.bin»), привести к формату fmt (≥ 0) и
## построить mip-уровни. null — файла нет или он не читается.
static func decode(path: String, fmt: int = -1, mips: bool = false) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	var buf := FileAccess.get_file_as_bytes(path)
	var err := img.load_jpg_from_buffer(buf) if path.ends_with(".jpg.bin") or path.ends_with(".jpg") \
		else img.load_png_from_buffer(buf)
	if err != OK:
		return null
	if fmt >= 0:
		img.convert(fmt as Image.Format)
	if mips and not img.has_mipmaps():
		img.generate_mipmaps()
	return img


## Дождаться и выбросить всё незабранное (смена карты, процедурный мир).
static func drop_all() -> void:
	for k in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(_tasks[k])
	_tasks.clear()
	_mx.lock()
	_out.clear()
	_mx.unlock()
