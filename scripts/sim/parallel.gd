class_name Parallel
extends RefCounted
## Тонкая обёртка над WorkerThreadPool.
##
## Правила для тел задач:
##  * не трогать дерево сцен;
##  * читать общее состояние можно, писать — только в «свой» слот заранее
##    выделенного массива результатов (results[i]) или в поля «своего» объекта;
##  * случайность — только через Parallel.rng(...), чтобы результат не зависел
##    от того, в каком порядке потоки выполнили задачи (детерминизм);
##  * не читать константные Array/Dictionary скриптов (const X := [...]) —
##    в Godot 4.3 это даёт гонки и падения; нужные таблицы заранее
##    копируются в Packed-массивы мира;
##  * массивы чужих объектов (world.p_controller) выносить в локальную
##    переменную один раз на задачу — иначе каждое обращение атомарно
##    трогает общий счётчик ссылок и ядра мешают друг другу.
##
## Запуск группы задач стоит ~50 мкс, поэтому мелкую работу выгоднее делать в
## одном потоке: параметр min_count задаёт порог распараллеливания.

static var enabled := true


static func thread_count() -> int:
	return maxi(1, OS.get_processor_count())


## Фоновая группа задач (start/finish) занимает пул: пока она идёт, обычные
## run() выполняются в главном потоке — ждать свободных потоков дольше.
static var _background := 0


## Вызывает body(i) для i в [0, count) на всех ядрах и ждёт завершения.
static func run(count: int, body: Callable, label: String = "", min_count: int = 2) -> void:
	if count <= 0:
		return
	if not enabled or _background > 0 or count < maxi(2, min_count):
		for i in count:
			body.call(i)
		return
	var gid := WorkerThreadPool.add_group_task(body, count, -1, true, label)
	WorkerThreadPool.wait_for_group_task_completion(gid)


## Запускает body(i) в фоне на ядрах (кроме одного — оно остаётся главному
## потоку) и сразу возвращает номер группы; результат ждать через finish().
## Без потоков (enabled = false) выполняет всё сразу — результат тот же.
static func start(count: int, body: Callable, label: String = "", min_count: int = 2) -> int:
	if count <= 0:
		return -1
	if not enabled or count < maxi(2, min_count) or thread_count() < 2:
		for i in count:
			body.call(i)
		return -1
	_background += 1
	return WorkerThreadPool.add_group_task(body, count, maxi(1, thread_count() - 1), true, label)


static func finish(gid: int) -> void:
	if gid < 0:
		return
	WorkerThreadPool.wait_for_group_task_completion(gid)
	_background -= 1


## Делит [0, count) на крупные куски и вызывает body(start, end) параллельно.
## Подходит для дешёвой поэлементной работы (пиксели, провинции).
static func run_chunked(count: int, body: Callable, label: String = "") -> void:
	if count <= 0:
		return
	var chunks := 1
	if enabled:
		chunks = mini(count, thread_count() * 4)
	var size := int(ceil(float(count) / float(chunks)))
	var task := func(c: int) -> void:
		var s := c * size
		var e := mini(count, s + size)
		if s < e:
			body.call(s, e)
	run(chunks, task, label)


## Детерминированный ГСЧ для задачи: зависит только от аргументов.
static func rng(seed_value: int, a: int, b: int = 0) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([seed_value, a, b])
	return r
