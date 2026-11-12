class_name Claims
extends RefCounted
## Национальные территории (претензии; решение пользователя, ноябрь 2026).
## У каждой страны с начала 1936 г. — свои земли (кроме колоний) и
## исторические претензии из claims.json; ещё — по фокусам (эффект claim). На
## мирных переговорах национальная земля присоединяется за полцены и сразу
## интегрирована: без сопротивления и с полной отдачей. Занятая в войне своя
## национальная земля сопротивления тоже не знает.
## Хранение: world.cores — провинция * 4096 + страна -> true.

const ANNEX_DISCOUNT := 0.5


static func is_core(world: World, n: int, p: int) -> bool:
	return n >= 0 and world.cores.has(p * 4096 + n)


static func add(world: World, n: int, provs: Array) -> int:
	var added := 0
	for p in provs:
		var k: int = int(p) * 4096 + n
		if not world.cores.has(k):
			world.cores[k] = true
			added += 1
	return added


## Кто считает провинцию своей национальной землёй.
static func claimants(world: World, p: int) -> Array:
	var r: Array = []
	for n in world.nation_count:
		if world.cores.has(p * 4096 + n):
			r.append(n)
	return r


## Провинции страны целиком (кроме колоний).
static func nation_provs(world: World, t: int) -> Array:
	var r: Array = []
	var col := world.p_colony.size() == world.prov_count
	for p in world.prov_count:
		if world.p_owner[p] == t and world.p_land[p] == 1 and not (col and world.p_colony[p] == 1):
			r.append(p)
	return r


## Начало партии: свои земли всех стран и претензии из claims.json.
static func init(world: World, dir: String) -> void:
	world.cores = {}
	for nat in world.nations:
		add(world, nat.id, nation_provs(world, nat.id))
	var path := dir + "/claims.json"
	if not FileAccess.file_exists(path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		return
	for tag in d:
		var n := History.tag_id(world, tag)
		if n < 0:
			continue
		var c: Dictionary = d[tag]
		for ar in c.get("areas", []):
			add(world, n, History.area(world, ar))
		for t in c.get("nations", []):
			var tn := History.tag_id(world, t)
			if tn >= 0:
				add(world, n, nation_provs(world, tn))


## Эффект фокуса или события: {"t": "claim", "area": имя} или {"t": "claim", "target": TAG}.
static func apply_effect(world: World, n: int, e: Dictionary) -> void:
	var provs: Array = []
	var what := ""
	if e.has("area"):
		provs = History.area(world, e["area"])
		what = String(world.areas.get(e["area"], {}).get("name", e["area"]))
	elif e.has("target"):
		var t := History.tag_id(world, e["target"])
		if t >= 0:
			provs = nation_provs(world, t)
			what = world.nations[t].name
	if add(world, n, provs) > 0 and (world.nations[n].is_player or world.nations[n].major):
		world.log_event("%s: претензии на национальную территорию — %s" % [world.nations[n].name, what])


## Доля провинций участка — национальная земля страны n.
static func share(world: World, n: int, provs: PackedInt32Array) -> float:
	if provs.is_empty():
		return 0.0
	var c := 0
	for p in provs:
		if world.cores.has(p * 4096 + n):
			c += 1
	return float(c) / float(provs.size())
