class_name Native
extends RefCounted
## Необязательное нативное ядро (C++, GDExtension, исходники в native/).
## Если библиотека собрана и подключена — горячие циклы идут через неё, иначе
## тот же алгоритм на GDScript. Результаты обязаны совпадать (sim_bench).

static var core: Object = null
static var _checked := false


## Вызывать один раз из главного потока (MapLoader/Simulation при создании мира).
static func init() -> void:
	if _checked:
		return
	_checked = true
	if ClassDB.class_exists("MeowqCore") and not OS.has_feature("no_native"):
		core = ClassDB.instantiate("MeowqCore")
		print("Нативное ядро: ", core.call("version"))


static func available() -> bool:
	return core != null
