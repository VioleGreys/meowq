class_name Spec
extends RefCounted
## Упреждающие (спекулятивные) расчёты на устаревших на день данных.
##
## То, что не требует ежедневного анализа по свежему состоянию, считается
## заранее: в фазе ИИ дня D каждый модуль снимает копию нужных данных
## (только Packed-массивы и числа) и добавляет задачи на день D+1; задачи идут
## в фоне на всех ядрах одной группой вместе с военными планами ИИ, группа
## ждётся в конце дня (Simulation._finish_ai). В день D+1 модуль берёт готовый
## результат, а если его нет (первый день, другой набор стран) — считает сразу.
## Результат зависит только от снимка, а не от потоков, — игра детерминирована.
##
## Сейчас так считаются:
##  * торговля — рейтинг покупателей и план раздачи экспорта (Economy.spec);
##  * шкала сил и «естественные» отношения для сдвига репутации (Relations.spec);
##  * пересмотр военных заводов у стран, чья очередь завтра (Military.spec);
##  * поле подачи снабжения при снабжении по узлам районов (Supply.spec);
##  * сухопутные соседи стран для решений ИИ флота, авиации и высадок (Forces.spec).
## Бои, движение, раздача снабжения по дивизиям, восстановление, выпуск —
## каждый день по свежим
## данным, без упреждения.


static func start(world: World) -> void:
	finish(world)
	var jobs: Array = []
	var _pt := Time.get_ticks_usec()
	Economy.spec(world, jobs)
	Prof.add("уп:торговля", _pt); _pt = Time.get_ticks_usec()
	Relations.spec(world, jobs)
	Prof.add("уп:отношения", _pt); _pt = Time.get_ticks_usec()
	Military.spec(world, jobs)
	Prof.add("уп:заводы", _pt); _pt = Time.get_ticks_usec()
	Supply.spec(world, jobs)
	Prof.add("уп:снабжение", _pt); _pt = Time.get_ticks_usec()
	Forces.spec(world, jobs)
	Prof.add("уп:соседи", _pt)
	if jobs.is_empty():
		return
	world.spec_gid = Parallel.start(jobs.size(), func(i: int): (jobs[i] as Callable).call(), "упреждение", 2)


## Дождаться фоновых задач (конец дня или перед чтением результата).
static func finish(world: World) -> void:
	if world.spec_gid >= 0:
		Parallel.finish(world.spec_gid)
		world.spec_gid = -1
