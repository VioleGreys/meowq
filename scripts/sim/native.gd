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
	if ClassDB.class_exists("MeowqCore") and not OS.get_cmdline_user_args().has("--no-native"):
		core = ClassDB.instantiate("MeowqCore")
		print("Нативное ядро: ", core.call("version"))


static func available() -> bool:
	return core != null


# --- Выборка элементов по индексам (уплотнение массивов дивизий) ---

static func gather_f64(a: PackedFloat64Array, idx: PackedInt32Array) -> PackedFloat64Array:
	if core != null:
		return core.call("gather_f64", a, idx)
	var r := PackedFloat64Array()
	r.resize(idx.size())
	for j in idx.size():
		r[j] = a[idx[j]]
	return r


static func gather_i32(a: PackedInt32Array, idx: PackedInt32Array) -> PackedInt32Array:
	if core != null:
		return core.call("gather_i32", a, idx)
	var r := PackedInt32Array()
	r.resize(idx.size())
	for j in idx.size():
		r[j] = a[idx[j]]
	return r


static func gather_u8(a: PackedByteArray, idx: PackedInt32Array) -> PackedByteArray:
	if core != null:
		return core.call("gather_u8", a, idx)
	var r := PackedByteArray()
	r.resize(idx.size())
	for j in idx.size():
		r[j] = a[idx[j]]
	return r
