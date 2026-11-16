class_name FrameProf
extends RefCounted
## Раскладка времени главного потока по участкам (для отчёта с телефона):
## за каждую секунду — сумма по участку и самый долгий одиночный замер.
## add(имя, мкс) — из любого места главного потока; roll() — раз в секунду (Report).

static var _sum := {}
static var _max := {}
static var last_sum := {}   # прошлая секунда: участок → мкс за секунду
static var last_max := {}   # участок → худший одиночный замер, мкс


static func add(key: String, usec: int) -> void:
	_sum[key] = int(_sum.get(key, 0)) + usec
	_max[key] = maxi(int(_max.get(key, 0)), usec)


static func roll() -> void:
	last_sum = _sum
	last_max = _max
	_sum = {}
	_max = {}
