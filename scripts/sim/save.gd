class_name SaveGame
extends RefCounted
## Сохранение и загрузка партии.
##
## Состояние мира записывается целиком и без ручного списка полей: все
## переменные World и его объектов (страны, дивизии, флоты…) обходятся по
## списку свойств, поэтому новое поле мира попадает в сохранение само. Картинки
## карты не пишутся — при загрузке мир сначала собирается обычным путём
## (MapLoader), потом поверх кладётся сохранённое.
##
## Проверка: tests/save_check.gd — партия после загрузки обязана идти день в
## день так же, как без неё (сравнивается всё состояние, а не подпись).
##
## Файл: MAGIC, заголовок (Dictionary — для списка сохранений, читается без
## распаковки мира), длина, сжатое (zstd) состояние. Пишется во временный файл
## и переименовывается: обрыв записи не портит прежнее сохранение.

const MAGIC := 0x3153514d        # «MQS1»
const VERSION := 2   # 2 — корабли по проектам (ShipDesigns), соединения до 30
const DIR := "user://saves"
const EXT := ".mqs"
const AUTO := "auto"             # имя автосохранения
const QUIT := "quit"             # сохранение при выходе/сворачивании

# поля World, которые не пишутся: картинки карты, номер фоновой группы и
# неизменяемые описания из файлов игры (деревья фокусов, события, области,
# черты — 40 % объёма; после обновления игры партия берёт новые тексты и правки)
const SKIP_WORLD := {"id_image": true, "height_image": true, "terrain_image": true, "spec_gid": true,
	"focus_trees": true, "focus_index": true, "event_defs": true, "areas": true, "spirit_defs": true}
# у дивизии пишутся только собственные поля: остальное — обёртки над World.d_*
const DIV_FIELDS := ["slot", "id", "group", "transit_total", "transit_from", "transit_target", "transfer", "_path"]

var errors: Array = []           # что не удалось записать/прочитать (пусто — всё хорошо)
var _world: World
var _ids := {}                   # запись: instance_id -> номер объекта
var _objs: Array = []            # чтение: номер -> объект
var _props := {}                 # кэш: имя класса -> имена полей


static func _classes() -> Dictionary:
	return {"Nation": World.Nation, "Faction": World.Faction, "Division": World.Division,
		"Fleet": World.Fleet, "InvasionPlan": World.InvasionPlan, "AirWing": World.AirWing,
		"ArmyGroup": World.ArmyGroup}


static func _script_vars(o: Object) -> PackedStringArray:
	var res := PackedStringArray()
	for p in o.get_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			res.append(p["name"])
	return res


# --- Запись ------------------------------------------------------------------

## Состояние мира и симуляции как дерево простых значений (для var_to_bytes).
func encode(world: World, sim: Simulation) -> Dictionary:
	_world = world
	_ids = {}
	Spec.finish(world)
	var w := {}
	for name in _script_vars(world):
		if SKIP_WORLD.has(name):
			continue
		w[name] = _enc(world.get(name), name)
	var s := {}
	if sim != null:
		s["land_totals"] = _enc(sim.land_totals, "sim.land_totals")
		s["land_totals_day"] = sim.land_totals_day
	return {"world": w, "sim": s}


func _enc(v: Variant, where: String) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var a: Array = v
			var res: Array = []
			res.resize(a.size())
			for i in a.size():
				res[i] = _enc(a[i], where)
			return res
		TYPE_DICTIONARY:
			var d: Dictionary = v
			var res := {}
			for k in d:
				res[k] = _enc(d[k], where)
			return res
		TYPE_OBJECT:
			return _enc_obj(v, where)
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			errors.append("%s: значение типа %d не сохраняется" % [where, typeof(v)])
			return null
	return v


func _enc_obj(o: Object, where: String) -> Variant:
	if o == null:
		return null
	if o == _world:
		return {"$w": 1}
	var iid := o.get_instance_id()
	if _ids.has(iid):
		return {"$r": _ids[iid]}
	var cls := ""
	var classes := _classes()
	for name in classes:
		if o.get_script() == classes[name]:
			cls = name
			break
	if cls == "":
		errors.append("%s: объект %s не сохраняется" % [where, o])
		return null
	_ids[iid] = _ids.size()
	var props := {}
	if cls == "Division":
		var dv: World.Division = o
		if dv.w != _world:
			# погибшая дивизия (ушла в «запись мёртвых»): в мире ссылок на неё быть не должно
			errors.append("%s: ссылка на погибшую дивизию %d" % [where, dv.id])
		for f in DIV_FIELDS:
			props[f] = o.get(f)
	else:
		if not _props.has(cls):
			_props[cls] = _script_vars(o)
		for f in _props[cls]:
			props[f] = _enc(o.get(f), where + "." + f)
	return {"$o": cls, "$p": props}


# --- Чтение ------------------------------------------------------------------

## Положить сохранённое состояние поверх мира (мир уже собран MapLoader).
func decode(data: Dictionary, world: World, sim: Simulation) -> void:
	_world = world
	_objs = []
	world.dispose()
	var names := {}
	for name in _script_vars(world):
		names[name] = true
	var w: Dictionary = data["world"]
	for name in w:
		if names.has(name) and not SKIP_WORLD.has(name):
			_assign(world, name, _dec(w[name]))
	world.spec_gid = -1
	world.palette_dirty = true
	# сохранение до брони танков: броня и бронебойность дивизий — пересчитать
	if world.d_armor.size() != world.d_id.size() or world.d_pierce.size() != world.d_id.size():
		world.d_armor.resize(world.d_id.size())
		world.d_pierce.resize(world.d_id.size())
		for d in world.divisions:
			if d.alive:
				Military.refresh_division(world, d)
	if sim != null:
		var s: Dictionary = data.get("sim", {})
		sim.land_totals = _dec(s.get("land_totals", []))
		sim.land_totals_day = int(s.get("land_totals_day", -100))


func _assign(o: Object, name: String, v: Variant) -> void:
	var cur: Variant = o.get(name)
	if typeof(cur) != typeof(v) and typeof(cur) != TYPE_NIL and v != null:
		if typeof(cur) == TYPE_FLOAT and typeof(v) == TYPE_INT or typeof(cur) == TYPE_INT and typeof(v) == TYPE_FLOAT:
			pass
		else:
			errors.append("%s: в сохранении другой тип (%d вместо %d)" % [name, typeof(v), typeof(cur)])
			return
	o.set(name, v)


func _dec(v: Variant) -> Variant:
	match typeof(v):
		TYPE_ARRAY:
			var a: Array = v
			for i in a.size():
				var t := typeof(a[i])
				if t == TYPE_ARRAY or t == TYPE_DICTIONARY:
					a[i] = _dec(a[i])
			return a
		TYPE_DICTIONARY:
			var d: Dictionary = v
			if d.has("$w"):
				return _world
			if d.has("$r"):
				return _objs[int(d["$r"])]
			if d.has("$o"):
				return _dec_obj(d)
			for k in d:
				var t := typeof(d[k])
				if t == TYPE_ARRAY or t == TYPE_DICTIONARY:
					d[k] = _dec(d[k])
			return d
	return v


func _dec_obj(d: Dictionary) -> Object:
	var cls: String = d["$o"]
	var script: Variant = _classes().get(cls)
	if script == null:
		errors.append("неизвестный класс %s" % cls)
		_objs.append(null)
		return null
	var o: Object = script.new()
	_objs.append(o)
	var props: Dictionary = d["$p"]
	if cls == "Division":
		o.set("w", _world)
		for f in props:
			o.set(f, props[f])
		return o
	if not _props.has(cls):
		var have := {}
		for f in _script_vars(o):
			have[f] = true
		_props[cls] = have
	var known: Dictionary = _props[cls]
	for f in props:
		if known.has(f):
			_assign(o, f, _dec(props[f]))
	return o


# --- Файлы -------------------------------------------------------------------

static func path_of(name: String) -> String:
	return "%s/%s%s" % [DIR, name, EXT]


## Отпечаток карты: сохранение подходит только к той же карте и набору стран.
static func fingerprint(world: World) -> String:
	return "%d/%d/%d/%d" % [world.prov_count, world.land_count, world.nation_count, hash(world.nation_tags)]


## Записать партию. meta — что показать в списке (страна, вид камеры и т. п.);
## дата, день и отпечаток карты добавляются сами. Возвращает текст ошибки или "".
static func write(name: String, world: World, sim: Simulation, meta: Dictionary) -> String:
	var sg := SaveGame.new()
	var data := sg.encode(world, sim)
	if not sg.errors.is_empty():
		return str(sg.errors[0])
	var raw := var_to_bytes(data)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var head := meta.duplicate()
	head["version"] = VERSION
	head["day"] = world.day
	head["date"] = world.date_string()
	head["map"] = fingerprint(world)
	head["time"] = int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := path_of(name)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "не удалось открыть файл (%s)" % error_string(FileAccess.get_open_error())
	f.store_32(MAGIC)
	f.store_var(head)
	f.store_32(raw.size())
	f.store_32(packed.size())
	f.store_buffer(packed)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return "ошибка записи (%s) — возможно, нет места" % error_string(err)
	err = DirAccess.rename_absolute(tmp, path)
	if err != OK:
		return "не удалось записать файл (%s)" % error_string(err)
	return ""


## Заголовок сохранения ({} — файл не читается). Мир не распаковывается.
static func read_meta(name: String) -> Dictionary:
	var f := FileAccess.open(path_of(name), FileAccess.READ)
	if f == null or f.get_length() < 16 or f.get_32() != MAGIC:
		return {}
	var head: Variant = f.get_var()
	if typeof(head) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = head
	d["name"] = name
	d["size"] = f.get_length()
	return d


## Загрузить партию в уже собранный мир. Возвращает {"err": текст или "", "meta"}.
## При ошибке мир может быть изменён наполовину — его надо собрать заново.
static func load_into(name: String, world: World, sim: Simulation) -> Dictionary:
	var f := FileAccess.open(path_of(name), FileAccess.READ)
	if f == null:
		return {"err": "файл не найден"}
	if f.get_length() < 16 or f.get_32() != MAGIC:
		return {"err": "это не сохранение игры"}
	var head: Variant = f.get_var()
	if typeof(head) != TYPE_DICTIONARY:
		return {"err": "файл повреждён"}
	var meta: Dictionary = head
	if int(meta.get("version", 0)) > VERSION:
		return {"err": "сохранение сделано более новой версией игры"}
	if str(meta.get("map", "")) != fingerprint(world):
		return {"err": "сохранение от другой версии карты"}
	var raw_size := f.get_32()
	var packed_size := f.get_32()
	if packed_size <= 0 or packed_size > f.get_length() or raw_size <= 0 or raw_size > 1 << 30:
		return {"err": "файл повреждён"}
	var packed := f.get_buffer(packed_size)
	if packed.size() != packed_size:
		return {"err": "файл обрезан"}
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return {"err": "файл повреждён"}
	var data: Variant = bytes_to_var(raw)
	if typeof(data) != TYPE_DICTIONARY or not (data as Dictionary).has("world"):
		return {"err": "файл повреждён"}
	var sg := SaveGame.new()
	sg.decode(data, world, sim)
	if not sg.errors.is_empty():
		return {"err": str(sg.errors[0]), "meta": meta}
	if int(meta.get("version", 0)) < 2:
		Forces.migrate_v1(world)
	for id in world.dyn_events:
		world.event_defs[id] = world.dyn_events[id]   # события партии (вызов гаранта)
	return {"err": "", "meta": meta}


## Все сохранения, свежие первыми: заголовки с полями name и size.
static func list() -> Array:
	var res: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return res
	for file in dir.get_files():
		if file.ends_with(EXT):
			var m := read_meta(file.trim_suffix(EXT))
			if not m.is_empty():
				res.append(m)
	res.sort_custom(func(a, b):
		if int(a.get("time", 0)) != int(b.get("time", 0)):
			return int(a.get("time", 0)) > int(b.get("time", 0))
		return str(a["name"]) < str(b["name"]))
	return res


static func remove(name: String) -> void:
	DirAccess.remove_absolute(path_of(name))


## Имя файла из названия, которое ввёл игрок (только безопасные знаки).
static func safe_name(title: String) -> String:
	var res := ""
	for ch in title.strip_edges():
		if ch in "\\/:*?\"<>|." or ch.unicode_at(0) < 32:
			res += "_"
		else:
			res += ch
	return res.substr(0, 40)
