class_name MapLoader
extends RefCounted
## Загрузка исторической карты, собранной tools/build_map.py, и данных
## государств из nations.json.
## Файлы лежат в data/<сценарий>/: map.json, nations.json, provinces.png.bin, relief.png.bin.
## (Расширение .bin — чтобы Godot не импортировал PNG как текстуры: нам нужны
## точные значения пикселей, а при экспорте файлы включаются фильтром data/*.)

const DEFAULT_DIR := "res://data/world1936"


static func load_world(world: World, dir: String = DEFAULT_DIR) -> Dictionary:
	var timings := {}
	var t := Time.get_ticks_usec()
	var text := FileAccess.get_file_as_string(dir + "/map.json")
	var meta = JSON.parse_string(text)
	if typeof(meta) != TYPE_DICTIONARY:
		push_error("Не удалось прочитать %s/map.json" % dir)
		return timings
	timings["json"] = Time.get_ticks_usec() - t

	t = Time.get_ticks_usec()
	var id_img := Image.new()
	id_img.load_png_from_buffer(FileAccess.get_file_as_bytes(dir + "/provinces.png.bin"))
	var rel_img := Image.new()
	rel_img.load_png_from_buffer(FileAccess.get_file_as_bytes(dir + "/relief.png.bin"))
	timings["images"] = Time.get_ticks_usec() - t

	t = Time.get_ticks_usec()
	world.seed_value = 1936
	world.width = int(meta["width"])
	world.height = int(meta["height"])
	world.id_image = id_img
	world.height_image = rel_img
	# подложка рельефа (спутниковый снимок NASA, tools/build_terrain.py) — только для вида
	if FileAccess.file_exists(dir + "/terrain.jpg.bin"):
		var t_img := Image.new()
		if t_img.load_jpg_from_buffer(FileAccess.get_file_as_bytes(dir + "/terrain.jpg.bin")) == OK:
			world.terrain_image = t_img
	world.province_ids = PackedInt32Array()
	world.ai_wars = false

	var provs: Array = meta["provinces"]
	var n := provs.size()
	world.prov_count = n
	world.land_count = int(meta["land_count"])
	world.p_land.resize(n)
	world.p_terrain.resize(n)
	world.p_center.resize(n)
	world.p_pixels.resize(n)
	world.p_owner.resize(n)
	world.p_controller.resize(n)
	world.p_vp.resize(n)
	world.p_civ.resize(n)
	world.p_mil.resize(n)
	world.p_manpower.resize(n)
	world.p_population.resize(n)
	world.p_colony.resize(n)
	world.p_adm0.resize(n)
	world.p_lonlat.resize(n)
	world.p_air_src.resize(n)
	world.air_region_names = PackedStringArray(meta.get("air_regions", []))
	world.p_name.resize(n)
	world.p_adj = []
	world.p_adj.resize(n)

	var tag_index := {}
	var nations_meta: Array = meta["nations"]
	world.nations.clear()
	world.nation_tags = PackedStringArray()
	for i in nations_meta.size():
		var nm: Dictionary = nations_meta[i]
		var nat := World.Nation.new()
		nat.id = i
		nat.name = nm["name"]
		var c: Array = nm["color"]
		nat.color = Color8(int(c[0]), int(c[1]), int(c[2]))
		nat.capital = int(nm["capital"])
		nat.manpower = 60.0
		world.nations.append(nat)
		world.nation_tags.append(nm["tag"])
		tag_index[nm["tag"]] = i

	var ndata = JSON.parse_string(FileAccess.get_file_as_string(dir + "/nations.json"))
	if typeof(ndata) != TYPE_DICTIONARY:
		push_error("Не удалось прочитать %s/nations.json" % dir)
		ndata = {"ideologies": {}, "nations": {}}
	# «спящие» государства — появятся по событиям (Нац. Испания, Словакия, Виши)
	for tag in ndata["nations"]:
		var dd: Dictionary = ndata["nations"][tag]
		if not dd.get("dormant", false) or tag_index.has(tag):
			continue
		var nat := World.Nation.new()
		nat.id = world.nations.size()
		nat.name = dd.get("name", tag)
		var cc: Array = dd.get("color", [150, 150, 150])
		nat.color = Color8(int(cc[0]), int(cc[1]), int(cc[2]))
		nat.capital = -1
		nat.alive = false
		nat.dormant = true
		var ll: Array = dd.get("capital_lonlat", [0, 0])
		nat.capital_lonlat = Vector2(float(ll[0]), float(ll[1]))
		world.nations.append(nat)
		world.nation_tags.append(tag)
		tag_index[tag] = nat.id
	var ideologies: Dictionary = ndata["ideologies"]
	for k in ideologies:
		world.ideology_names[k] = ideologies[k]["name"]
	for nat in world.nations:
		nat.tag = world.nation_tags[nat.id]
		var d: Dictionary = ndata["nations"].get(nat.tag, {})
		nat.full_name = d.get("full_name", nat.name)
		nat.ideology = d.get("ideology", "authoritarian")
		nat.leader = d.get("leader", "")
		nat.leader_title = d.get("title", "")
		nat.flag = d.get("flag", {"t": "h", "c": [nat.color.to_html(false)]})
		nat.population = float(d.get("population", 1.0))
		nat.major = bool(d.get("major", false))
		nat.neutral = bool(d.get("neutral", false))
		nat.capitulate_at = float(d.get("capitulate_at", 0.3))
		nat.manpower_rate = float(ideologies.get(nat.ideology, {}).get("manpower_rate", 0.015))
		for tech_id in d.get("techs", []):
			Tech.complete(nat, tech_id)
		var bon: Dictionary = d.get("bonus", {})
		for k in bon:
			nat.bonus[k] = float(nat.bonus.get(k, 0.0)) + float(bon[k])
		for sid in d.get("spirits", []):
			nat.spirits[String(sid)] = 1.0
		nat.research_slots = int(d.get("research_slots", 0))
		nat.doctrine_pref = d.get("doctrine", {}).duplicate()

	var rng := RandomNumberGenerator.new()
	rng.seed = 1936
	for i in n:
		var p: Dictionary = provs[i]
		var land := int(p["land"]) == 1
		world.p_land[i] = 1 if land else 0
		world.p_terrain[i] = int(p["terrain"])
		world.p_center[i] = Vector2(float(p["x"]), float(p["y"]))
		world.p_pixels[i] = int(p["px"])
		world.p_name[i] = p["name"]
		world.p_vp[i] = int(p["vp"])
		world.p_adj[i] = PackedInt32Array(p["adj"])
		var owner: int = tag_index.get(p["owner"], -1) if land else -1
		world.p_owner[i] = owner
		world.p_controller[i] = owner
		world.p_colony[i] = 1 if land and p.get("colony", false) else 0
		world.p_adm0[i] = p.get("adm0", "")
		world.p_lonlat[i] = Vector2(float(p.get("lon", 0.0)), float(p.get("lat", 0.0)))
		world.p_air_src[i] = int(p.get("air", -1))
		world.p_civ[i] = 0
		world.p_mil[i] = 0
		world.p_manpower[i] = 0
		world.p_population[i] = 0
	_distribute_economy(world, provs, ndata["nations"])
	timings["provinces"] = Time.get_ticks_usec() - t

	world.build_caches()
	_spawn_armies(world, rng, ndata["nations"])
	world.ai_wars = true
	Diplomacy.load_setup(world, dir + "/diplomacy.json")
	History.load(world, dir)
	Claims.init(world, dir)   # национальные территории 1936 г.
	_load_forts(world, dir + "/forts.json")
	Economy.load_resources(world, dir + "/resources.json")
	# национальные черты: определения и стартовые черты стран
	if FileAccess.file_exists(dir + "/spirits.json"):
		world.spirit_defs = JSON.parse_string(FileAccess.get_file_as_string(dir + "/spirits.json")).get("spirits", {})
	for nat in world.nations:
		world.recalc_spirits(nat)
	Politics.init(world)   # стабильность и поддержка войны по строю и чертам
	Relations.init(world)
	# марионетки известны только теперь: их отчисления сюзерену (Puppets) меняют
	# число заводов — линии подгоняются под них
	var inc := world.compute_all_income()
	Puppets.adjust_income(world, inc)
	for nat in world.nations:
		if nat.alive and (nat.mil != int(inc[nat.id][1]) or nat.civ != int(inc[nat.id][0])):
			nat.civ = inc[nat.id][0]
			nat.mil = inc[nat.id][1]
			Military.trim_lines(nat)
			Military.assign_free_factories(nat, Military.default_split(nat))
	world.build_caches()
	Forces.setup(world, dir)
	Leaders.init(world, dir)   # генералы и маршалы (commanders.json + безымянные под число дивизий)
	world.rebuild_prov_divs()
	world.palette_dirty = true
	return timings


## Население, призывники и фабрики страны распределяются по её провинциям:
## население — пополам по площади и по городскому населению; фабрики — по
## городскому населению (колонии почти без промышленности).
static func _distribute_economy(world: World, provs: Array, data: Dictionary) -> void:
	for nat in world.nations:
		var d: Dictionary = data.get(nat.tag, {})
		var home: Array = []
		var colonies := {}   # adm0 -> [провинции]
		for i in world.prov_count:
			if world.p_owner[i] != nat.id:
				continue
			if world.p_colony[i] == 1:
				var a: String = provs[i].get("adm0", "")
				if not colonies.has(a):
					colonies[a] = []
				colonies[a].append(i)
			else:
				home.append(i)
		if home.is_empty() and colonies.is_empty():
			continue
		# население
		_spread_population(world, provs, home, float(d.get("population", 1.0)) * 1000.0)
		var cpop: Dictionary = d.get("colony_pop", {})
		for a in colonies:
			_spread_population(world, provs, colonies[a], float(cpop.get(a, 0.05)) * 1000.0)
		# призывной резерв: доля населения по идеологии; в колониях — пятая часть
		for i in home:
			world.p_manpower[i] = int(world.p_population[i] * nat.manpower_rate)
		for a in colonies:
			for i in colonies[a]:
				world.p_manpower[i] = int(world.p_population[i] * nat.manpower_rate * 0.2)
		# фабрики: вес — городское население (+ немного за площадь), колонии x0.1
		var all: Array = home.duplicate()
		var weights := PackedFloat64Array()
		for i in home:
			weights.append(pow(float(provs[i]["pop"]) / 100000.0, 0.85) + 0.15)
		for a in colonies:
			for i in colonies[a]:
				all.append(i)
				weights.append((pow(float(provs[i]["pop"]) / 100000.0, 0.85) + 0.15) * 0.1)
		_allocate(world.p_civ, all, weights, int(d.get("civ", 1)))
		_allocate(world.p_mil, all, weights, int(d.get("mil", 0)))
		var mp_total := 0
		for i in all:
			mp_total += world.p_manpower[i]
		# часть резерва уже служит в армии
		nat.manpower = mp_total * 0.35
		# склад: запас на ~четверть армии + немного сверху
		nat.stock = PackedFloat32Array([2000.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])


static func _spread_population(world: World, provs: Array, list: Array, total_k: float) -> void:
	if list.is_empty():
		return
	var area := 0.0
	var city := 0.0
	for i in list:
		area += float(world.p_pixels[i])
		city += float(provs[i]["pop"])
	for i in list:
		var share := 0.5 * float(world.p_pixels[i]) / maxf(area, 1.0)
		share += 0.5 * (float(provs[i]["pop"]) / city if city > 0.0 else float(world.p_pixels[i]) / maxf(area, 1.0))
		world.p_population[i] = int(round(total_k * share))


## Раздаёт total единиц по провинциям пропорционально весам (метод наибольших
## остатков), не больше 12 на провинцию.
static func _allocate(target: PackedInt32Array, list: Array, weights: PackedFloat64Array, total: int) -> void:
	if list.is_empty() or total <= 0:
		return
	var sum := 0.0
	for w in weights:
		sum += w
	var rems: Array = []
	var given := 0
	for k in list.size():
		var exact := total * weights[k] / sum
		var whole := mini(int(floor(exact)), 12 - target[list[k]])
		target[list[k]] += whole
		given += whole
		rems.append([exact - whole, k])
	rems.sort_custom(func(a, b): return a[0] > b[0] if a[0] != b[0] else a[1] < b[1])
	var idx := 0
	while given < total and idx < rems.size() * 3:
		var k: int = rems[idx % rems.size()][1]
		if target[list[k]] < 12:
			target[list[k]] += 1
			given += 1
		idx += 1


## Армии 1936 г.: столица и крупные города + граница с соседями; часть — в колониях.
static func _spawn_armies(world: World, rng: RandomNumberGenerator, data: Dictionary) -> void:
	world.clear_divisions()
	for nat in world.nations:
		var d: Dictionary = data.get(nat.tag, {})
		var home: Array = []
		var border: Array = []
		var colony: Array = []
		for p in world.prov_count:
			if world.p_owner[p] != nat.id:
				continue
			if world.p_colony[p] == 1:
				colony.append(p)
				continue
			home.append(p)
			for q in world.p_adj[p]:
				if world.p_land[q] == 1 and world.p_owner[q] != nat.id and world.p_owner[q] >= 0:
					border.append(p)
					break
		if home.is_empty() and colony.is_empty():
			nat.alive = false
			continue
		# города по убыванию населения
		var cities := home.duplicate()
		cities.sort_custom(func(a, b): return world.p_population[a] > world.p_population[b])
		# состав армии по шаблонам; подвижные части — ближе к столице, пехота — на границах
		var army: Dictionary = d.get("army", {})
		var keys := {"inf": Military.T_INF, "mnt": Military.T_MNT, "cav": Military.T_CAV,
			"art": Military.T_ART, "mot": Military.T_MOT, "arm": Military.T_ARM}
		var tpls: Array = []
		for key in ["arm", "mot", "cav", "mnt", "art", "inf"]:
			for i in int(army.get(key, 0)):
				tpls.append(keys[key])
		var n_home := int(d.get("divisions", 2))
		while tpls.size() < n_home:
			tpls.append(Military.T_INF)
		for k in n_home:
			var where: int
			var tp: int = tpls[k]
			if tp == Military.T_MNT:
				where = _mountain_spot(world, nat.id, home, k)
			elif border.is_empty() or k % 5 < 2 or tp == Military.T_ARM or tp == Military.T_MOT:
				where = nat.capital if k == 0 else cities[(k / 2) % mini(cities.size(), 6)]
			else:
				where = border[(k * 7 + rng.randi() % 3) % border.size()]
			world.spawn_division(nat.id, where, tp)
		if not colony.is_empty():
			colony.sort_custom(func(a, b): return world.p_population[a] > world.p_population[b])
			for k in int(d.get("colony_divisions", 0)):
				world.spawn_division(nat.id, colony[k % mini(colony.size(), 8)])
	# производственные линии по доктрине и запас снаряжения по армии
	var income := world.compute_all_income()
	for nat in world.nations:
		if not nat.alive:
			continue
		nat.civ = income[nat.id][0]
		nat.mil = income[nat.id][1]
		Tech.grant_base(nat)
		Tech.fit_slots(nat)
		Designs.ai_update(world, nat)   # стартовые проекты самолётов по технологиям
		ShipDesigns.ai_update(world, nat)   # и кораблей (для постройки; стартовый флот — старых проектов)
		TankDesigns.ai_update(world, nat)   # и танков (броня, бронебойность, атака танковых батальонов)
		Military.assign_free_factories(nat, Military.default_split(nat))
		for line in nat.lines:
			line[2] = 0.8 * Military.eff_cap(nat)
		var need := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		for dv in world.divisions:
			if dv.owner == nat.id:
				var eq: Array = Military.tpl(world, dv.tpl)["eq"]
				for k in Military.EQ_COUNT:
					need[k] += eq[k]
		for k in Military.EQ_COUNT:
			nat.stock[k] += need[k] * 0.15


static func _mountain_spot(world: World, nid: int, home: Array, k: int) -> int:
	var hills: Array = []
	for p in home:
		if world.p_terrain[p] == World.T_MOUNTAIN or world.p_terrain[p] == World.T_HILLS:
			hills.append(p)
	if hills.is_empty():
		return world.nations[nid].capital
	return hills[(k * 5) % hills.size()]


## Укрепления (forts.json): провинции владельца в рамке [запад, юг, восток, север]
## (долгота/широта) или в исторической области получают добавку к обороне.
static func _load_forts(world: World, path: String) -> void:
	world.p_fort.resize(world.prov_count)
	world.p_fort.fill(0.0)
	if not FileAccess.file_exists(path):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for f in data.get("forts", []):
		var owner := world.nation_tags.find(String(f.get("owner", "")))
		var level := float(f.get("level", 0.3))
		var provs: Array = []
		if f.has("area"):
			provs = History.area(world, f["area"])
		elif f.has("box"):
			var b: Array = f["box"]
			for p in world.prov_count:
				var ll := world.p_lonlat[p]
				if world.p_owner[p] == owner and ll.x >= float(b[0]) and ll.y >= float(b[1]) \
						and ll.x <= float(b[2]) and ll.y <= float(b[3]):
					provs.append(p)
		for p in provs:
			world.p_fort[p] = maxf(world.p_fort[p], level)
	world._def_month = -1
	world.refresh_def_mult()
