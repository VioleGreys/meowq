class_name MapLoader
extends RefCounted
## Загрузка исторической карты, собранной tools/build_map.py.
## Файлы лежат в data/<сценарий>/: map.json, provinces.png.bin, relief.png.bin.
## (Расширение .bin — чтобы Godot не импортировал PNG как текстуры: нам нужны
## точные значения пикселей, а при экспорте файлы включаются фильтром data/*.)

const DEFAULT_DIR := "res://data/europe1936"


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
		nat.equipment = 300.0
		nat.manpower = 60.0
		world.nations.append(nat)
		world.nation_tags.append(nm["tag"])
		tag_index[nm["tag"]] = i

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
		# Временная экономика из численности городов (настоящие данные 1936 г. — этап 2)
		var pop := float(p["pop"])
		var civ := int(round(pop / 900000.0))
		if civ == 0 and rng.randf() < 0.25:
			civ = 1
		world.p_civ[i] = mini(civ, 12) if land else 0
		world.p_mil[i] = mini(int(round(civ * 0.5 + (0.6 if rng.randf() < 0.15 else 0.0))), 8) if land else 0
		world.p_manpower[i] = int(12 + pop / 1000.0 * 0.04) if land else 0
	timings["provinces"] = Time.get_ticks_usec() - t

	world.build_caches()
	_spawn_armies(world, rng)
	world.rebuild_prov_divs()
	world.palette_dirty = true
	return timings


## Временные армии по размеру страны (исторический состав армий — этап 2).
static func _spawn_armies(world: World, rng: RandomNumberGenerator) -> void:
	world.divisions.clear()
	world.prov_divs.resize(world.prov_count)
	for p in world.prov_count:
		world.prov_divs[p] = []
	for nat in world.nations:
		var owned: Array = []
		var border: Array = []
		for p in world.prov_count:
			if world.p_owner[p] != nat.id:
				continue
			owned.append(p)
			for q in world.p_adj[p]:
				if world.p_land[q] == 1 and world.p_owner[q] != nat.id:
					border.append(p)
					break
		if owned.is_empty():
			nat.alive = false
			continue
		var count := clampi(2 + owned.size() / 8, 2, 60)
		for k in count:
			var where: int = nat.capital
			if not border.is_empty() and k % 3 != 0:
				where = border[rng.randi() % border.size()]
			world.spawn_division(nat.id, where)
