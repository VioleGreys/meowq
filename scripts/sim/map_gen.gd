class_name MapGen
extends RefCounted
## Процедурная генерация мира: рельеф -> провинции (диаграмма Вороного с
## искажением границ) -> соседство -> страны. Все тяжёлые попиксельные
## проходы выполняются параллельно на всех ядрах.

const NATION_NAMES := [
	"Арвения", "Борсланд", "Вестрия", "Гальдор", "Дорния", "Эстмарк",
	"Каструм", "Лорандия", "Мерев", "Нордвей", "Оствальд", "Сальвия",
	"Тарвен", "Ульмар", "Фалькмар", "Ирмения",
]
const SYL_A := ["ар", "бе", "ве", "го", "да", "ка", "ле", "мо", "на", "ор", "пе", "ро", "са", "та", "ус", "фе", "ха", "це", "ша", "яр"]
const SYL_B := ["ден", "мир", "град", "вин", "лос", "тан", "бург", "дол", "ница", "ско", "вель", "ран", "тис", "мар", "нов"]


static func generate(world: World, seed_value: int, w: int = 800, h: int = 500, cell: int = 22, nation_count: int = 12) -> Dictionary:
	var timings := {}
	var t := Time.get_ticks_usec()
	world.seed_value = seed_value
	world.width = w
	world.height = h

	# --- 1. Рельеф (параллельно по строкам) -----------------------------------
	var height_rows: Array = []
	height_rows.resize(h)
	var height_task := func(s: int, e: int) -> void:
		var noise := _make_noise(seed_value, 0.0045, 5)
		var detail := _make_noise(seed_value + 17, 0.02, 3)
		for y in range(s, e):
			var row := PackedFloat32Array()
			row.resize(w)
			for x in w:
				var nx := (float(x) / w) * 2.0 - 1.0
				var ny := (float(y) / h) * 2.0 - 1.0
				var edge := maxf(absf(nx), absf(ny) * 1.05)
				var falloff := smoothstep(0.55, 1.0, edge)
				var v := noise.get_noise_2d(x, y) * 0.9 + detail.get_noise_2d(x, y) * 0.18 + 0.12
				row[x] = v - falloff * 0.9
			height_rows[y] = row
	Parallel.run_chunked(h, height_task, "heights")
	var heights := PackedFloat32Array()
	for y in h:
		heights.append_array(height_rows[y])
	timings["heights"] = Time.get_ticks_usec() - t

	# --- 2. Центры провинций: суша — мелкая сетка, море — крупная -------------
	t = Time.get_ticks_usec()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var land_cell := cell
	var sea_cell := cell * 2
	var lgw := int(ceil(float(w) / land_cell))
	var lgh := int(ceil(float(h) / land_cell))
	var sgw := int(ceil(float(w) / sea_cell))
	var sgh := int(ceil(float(h) / sea_cell))
	var land_grid := PackedInt32Array()
	land_grid.resize(lgw * lgh)
	land_grid.fill(-1)
	var sea_grid := PackedInt32Array()
	sea_grid.resize(sgw * sgh)
	sea_grid.fill(-1)
	var seeds := PackedVector2Array()
	var seed_land := PackedByteArray()
	for gy in lgh:
		for gx in lgw:
			for attempt in 8:
				var p := Vector2(gx * land_cell + rng.randf() * land_cell, gy * land_cell + rng.randf() * land_cell)
				if p.x >= w or p.y >= h:
					continue
				if heights[int(p.y) * w + int(p.x)] > 0.0:
					land_grid[gy * lgw + gx] = seeds.size()
					seeds.append(p)
					seed_land.append(1)
					break
	for gy in sgh:
		for gx in sgw:
			for attempt in 8:
				var p := Vector2(gx * sea_cell + rng.randf() * sea_cell, gy * sea_cell + rng.randf() * sea_cell)
				if p.x >= w or p.y >= h:
					continue
				if heights[int(p.y) * w + int(p.x)] <= 0.0:
					sea_grid[gy * sgw + gx] = seeds.size()
					seeds.append(p)
					seed_land.append(0)
					break

	# --- 3. Попиксельное назначение провинций (параллельно) -------------------
	var id_rows: Array = []
	id_rows.resize(h)
	var assign_task := func(s: int, e: int) -> void:
		var warp := _make_noise(seed_value + 101, 0.03, 2)
		# личные копии: аргументы функций копируют Variant, а общий счётчик
		# ссылок, который дёргают все потоки разом, убивает масштабирование
		var my_seeds := seeds.duplicate()
		var my_land := land_grid.duplicate()
		var my_sea := sea_grid.duplicate()
		for y in range(s, e):
			var row := PackedInt32Array()
			row.resize(w)
			for x in w:
				var land := heights[y * w + x] > 0.0
				var wx := x + warp.get_noise_2d(x, y) * 9.0
				var wy := y + warp.get_noise_2d(x + 977, y + 331) * 9.0
				var id := -1
				if land:
					id = _nearest(my_seeds, my_land, lgw, lgh, land_cell, wx, wy)
				if id < 0:
					id = _nearest(my_seeds, my_sea, sgw, sgh, sea_cell, wx, wy)
				if id < 0:
					id = _nearest(my_seeds, my_land, lgw, lgh, land_cell, wx, wy)
				row[x] = maxi(id, 0)
			id_rows[y] = row
	Parallel.run_chunked(h, assign_task, "assign")
	timings["assign"] = Time.get_ticks_usec() - t

	# --- 4. Удаляем пустые провинции, перенумеровываем: сначала суша ----------
	t = Time.get_ticks_usec()
	var counts := PackedInt32Array()
	counts.resize(seeds.size())
	for y in h:
		var row: PackedInt32Array = id_rows[y]
		for x in w:
			counts[row[x]] += 1
	var remap := PackedInt32Array()
	remap.resize(seeds.size())
	remap.fill(-1)
	var next := 0
	for pass_land in [1, 0]:
		for i in seeds.size():
			if seed_land[i] == pass_land and counts[i] > 0:
				remap[i] = next
				next += 1
	var n_prov := next
	world.prov_count = n_prov
	world.p_land.resize(n_prov)
	for i in seeds.size():
		if remap[i] >= 0:
			world.p_land[remap[i]] = seed_land[i]
	world.land_count = 0
	for p in n_prov:
		world.land_count += world.p_land[p]

	# --- 5. Карта id, центроиды, соседство (параллельно по кускам строк) ------
	var chunk_results: Array = []
	var chunks := Parallel.thread_count() * 4
	chunk_results.resize(chunks)
	var rows_per := int(ceil(float(h) / chunks))
	var stats_task := func(c: int) -> void:
		var s := c * rows_per
		var e := mini(h, s + rows_per)
		var sum_x := PackedFloat64Array()
		sum_x.resize(n_prov)
		var sum_y := PackedFloat64Array()
		sum_y.resize(n_prov)
		var cnt := PackedInt32Array()
		cnt.resize(n_prov)
		var pairs := {}
		var ids := PackedInt32Array()
		var bytes := PackedByteArray()
		if s < e:
			ids.resize((e - s) * w)
			bytes.resize((e - s) * w * 2)
		for y in range(s, e):
			var row: PackedInt32Array = id_rows[y]
			var below: PackedInt32Array = id_rows[y + 1] if y + 1 < h else PackedInt32Array()
			for x in w:
				var id := remap[row[x]]
				var o := (y - s) * w + x
				ids[o] = id
				bytes[o * 2] = id & 255
				bytes[o * 2 + 1] = id >> 8
				sum_x[id] += x
				sum_y[id] += y
				cnt[id] += 1
				if x + 1 < w:
					var r := remap[row[x + 1]]
					if r != id:
						pairs[mini(id, r) * 65536 + maxi(id, r)] = true
				if not below.is_empty():
					var d := remap[below[x]]
					if d != id:
						pairs[mini(id, d) * 65536 + maxi(id, d)] = true
		chunk_results[c] = [sum_x, sum_y, cnt, pairs, ids, bytes]
	Parallel.run(chunks, stats_task, "stats")

	var sx := PackedFloat64Array()
	sx.resize(n_prov)
	var sy := PackedFloat64Array()
	sy.resize(n_prov)
	world.p_pixels.resize(n_prov)
	world.p_pixels.fill(0)
	var all_pairs := {}
	var img_bytes := PackedByteArray()
	world.province_ids = PackedInt32Array()
	for c in chunks:
		var r: Array = chunk_results[c]
		var csx: PackedFloat64Array = r[0]
		var csy: PackedFloat64Array = r[1]
		var ccnt: PackedInt32Array = r[2]
		for p in n_prov:
			sx[p] += csx[p]
			sy[p] += csy[p]
			world.p_pixels[p] += ccnt[p]
		all_pairs.merge(r[3])
		world.province_ids.append_array(r[4])
		img_bytes.append_array(r[5])
	world.id_image = Image.create_from_data(w, h, false, Image.FORMAT_RG8, img_bytes)

	world.p_center.resize(n_prov)
	for p in n_prov:
		var c := maxi(1, world.p_pixels[p])
		world.p_center[p] = Vector2(sx[p] / c, sy[p] / c)
	var adj_lists: Array = []
	adj_lists.resize(n_prov)
	for p in n_prov:
		adj_lists[p] = PackedInt32Array()
	for key in all_pairs:
		var a: int = key / 65536
		var b: int = key % 65536
		adj_lists[a].append(b)
		adj_lists[b].append(a)
	world.p_adj = adj_lists
	timings["stats"] = Time.get_ticks_usec() - t

	# --- 6. Рельеф для шейдера ------------------------------------------------
	t = Time.get_ticks_usec()
	var hbytes := PackedByteArray()
	hbytes.resize(w * h)
	for i in w * h:
		hbytes[i] = clampi(int((heights[i] * 0.5 + 0.5) * 255.0), 0, 255)
	world.height_image = Image.create_from_data(w, h, false, Image.FORMAT_L8, hbytes)

	# --- 7. Тип местности и экономика провинций -------------------------------
	var forest := _make_noise(seed_value + 55, 0.012, 3)
	world.p_terrain.resize(n_prov)
	world.p_vp.resize(n_prov)
	world.p_civ.resize(n_prov)
	world.p_mil.resize(n_prov)
	world.p_manpower.resize(n_prov)
	world.p_name.resize(n_prov)
	world.p_owner.resize(n_prov)
	world.p_controller.resize(n_prov)
	world.p_owner.fill(-1)
	world.p_controller.fill(-1)
	for p in n_prov:
		world.p_name[p] = _province_name(rng)
		if world.p_land[p] == 0:
			world.p_terrain[p] = World.T_SEA
			continue
		var c := world.p_center[p]
		var hv := heights[clampi(int(c.y), 0, h - 1) * w + clampi(int(c.x), 0, w - 1)]
		var terrain := World.T_PLAINS
		if hv > 0.5:
			terrain = World.T_MOUNTAIN
		elif hv > 0.33:
			terrain = World.T_HILLS
		elif forest.get_noise_2d(c.x, c.y) > 0.15:
			terrain = World.T_FOREST
		if rng.randf() < 0.08 and terrain != World.T_MOUNTAIN:
			terrain = World.T_URBAN
		world.p_terrain[p] = terrain
		var urban := terrain == World.T_URBAN
		world.p_vp[p] = 5 if urban else 1
		world.p_civ[p] = rng.randi_range(2, 4) if urban else (1 if rng.randf() < 0.35 else 0)
		world.p_mil[p] = rng.randi_range(1, 3) if urban else (1 if rng.randf() < 0.3 else 0)
		world.p_manpower[p] = rng.randi_range(60, 120) if urban else rng.randi_range(8, 40)

	_make_nations(world, rng, nation_count)
	world.build_caches()
	timings["nations"] = Time.get_ticks_usec() - t
	world.rebuild_prov_divs()
	world.palette_dirty = true
	return timings


static func _make_noise(s: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	return n


static func _nearest(seeds: PackedVector2Array, grid: PackedInt32Array, gw: int, gh: int, cs: int, x: float, y: float) -> int:
	var cx := int(x / cs)
	var cy := int(y / cs)
	var best := -1
	var best_d := INF
	for radius in [1, 2]:
		for gy in range(cy - radius, cy + radius + 1):
			if gy < 0 or gy >= gh:
				continue
			for gx in range(cx - radius, cx + radius + 1):
				if gx < 0 or gx >= gw:
					continue
				if radius == 2 and absi(gx - cx) < 2 and absi(gy - cy) < 2:
					continue
				var s := grid[gy * gw + gx]
				if s < 0:
					continue
				var p := seeds[s]
				var d := (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)
				if d < best_d:
					best_d = d
					best = s
		if best >= 0:
			return best
	return best


static func _province_name(rng: RandomNumberGenerator) -> String:
	var s: String = SYL_A[rng.randi() % SYL_A.size()]
	if rng.randf() < 0.5:
		s += SYL_A[rng.randi() % SYL_A.size()]
	s += SYL_B[rng.randi() % SYL_B.size()]
	return s.capitalize()


static func _make_nations(world: World, rng: RandomNumberGenerator, count: int) -> void:
	var n_prov := world.prov_count
	# Компоненты связности суши — столицы ставим только на крупных материках.
	var comp := PackedInt32Array()
	comp.resize(n_prov)
	comp.fill(-1)
	var comp_size: Array = []
	for p in n_prov:
		if world.p_land[p] == 0 or comp[p] >= 0:
			continue
		var cid := comp_size.size()
		var stack := [p]
		comp[p] = cid
		var size := 0
		while not stack.is_empty():
			var q: int = stack.pop_back()
			size += 1
			for r in world.p_adj[q]:
				if world.p_land[r] == 1 and comp[r] < 0:
					comp[r] = cid
					stack.append(r)
		comp_size.append(size)

	var candidates: Array = []
	for p in n_prov:
		if world.p_land[p] == 1 and comp_size[comp[p]] >= 12 and world.p_terrain[p] != World.T_MOUNTAIN:
			candidates.append(p)
	if candidates.is_empty():
		for p in n_prov:
			if world.p_land[p] == 1:
				candidates.append(p)
	count = mini(count, candidates.size())

	# Выбор столиц: максимально удалённые друг от друга точки.
	var capitals: Array = [candidates[rng.randi() % candidates.size()]]
	while capitals.size() < count:
		var best := -1
		var best_d := -1.0
		for p in candidates:
			var md := INF
			for c in capitals:
				md = minf(md, world.p_center[p].distance_squared_to(world.p_center[c]))
			md *= rng.randf_range(0.7, 1.0)
			if md > best_d:
				best_d = md
				best = p
		capitals.append(best)

	world.nations.clear()
	var names := NATION_NAMES.duplicate()
	for i in count:
		var nat := World.Nation.new()
		nat.id = i
		nat.name = names[i % names.size()]
		var hue := fmod(0.07 + i * 0.618034, 1.0)
		nat.color = Color.from_hsv(hue, rng.randf_range(0.38, 0.55), rng.randf_range(0.70, 0.85))
		nat.capital = capitals[i]
		nat.manpower = 60.0
		nat.build_mode = "civ" if rng.randf() < 0.5 else "mil"
		world.nations.append(nat)
		world.p_owner[capitals[i]] = i
		world.p_terrain[capitals[i]] = World.T_URBAN
		world.p_vp[capitals[i]] = 20
		world.p_civ[capitals[i]] = 5
		world.p_mil[capitals[i]] = 4
		world.p_manpower[capitals[i]] = 150

	# Рост стран по соседству по кругу с разной «скоростью».
	var frontier: Array = []
	var rate: Array = []
	for i in count:
		frontier.append([capitals[i]])
		rate.append(rng.randf_range(0.55, 1.0))
	var progress := true
	while progress:
		progress = false
		for i in count:
			if frontier[i].is_empty():
				continue
			progress = true
			if rng.randf() > rate[i]:
				continue
			var f: Array = frontier[i]
			var idx := rng.randi() % f.size()
			var p: int = f[idx]
			var options: Array = []
			for q in world.p_adj[p]:
				if world.p_land[q] == 1 and world.p_owner[q] < 0:
					options.append(q)
			if options.is_empty():
				f.remove_at(idx)
				continue
			var q: int = options[rng.randi() % options.size()]
			world.p_owner[q] = i
			f.append(q)

	# Острова и прочие остатки — ближайшей стране.
	for p in n_prov:
		if world.p_land[p] == 1 and world.p_owner[p] < 0:
			var best := 0
			var best_d := INF
			for q in n_prov:
				if world.p_owner[q] >= 0:
					var d := world.p_center[p].distance_squared_to(world.p_center[q])
					if d < best_d:
						best_d = d
						best = world.p_owner[q]
			world.p_owner[p] = best
	for p in n_prov:
		world.p_controller[p] = world.p_owner[p]

	# Стартовые армии.
	world.build_caches()
	world.prov_divs.resize(n_prov)
	for p in n_prov:
		world.prov_divs[p] = []
	for nat in world.nations:
		var owned: Array = []
		for p in n_prov:
			if world.p_owner[p] == nat.id:
				owned.append(p)
		var border: Array = []
		for p in owned:
			for q in world.p_adj[p]:
				if world.p_land[q] == 1 and world.p_owner[q] != nat.id:
					border.append(p)
					break
		var n_divs := 4 + owned.size() / 5
		for k in n_divs:
			var where: int = nat.capital
			if not border.is_empty() and k % 3 != 0:
				where = border[rng.randi() % border.size()]
			world.spawn_division(nat.id, where)
