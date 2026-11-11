class_name Forces
extends RefCounted
## Флот и авиация: корабли и флоты в морских зонах, морские бои, господство на
## море, блокада портов, рейды подлодок по торговле, морские высадки;
## авиакрылья над воздушными районами: превосходство, поддержка войск,
## стратегические бомбардировки, удары по флоту.

const SHIP_BB := 0
const SHIP_CR := 1
const SHIP_DD := 2
const SHIP_SS := 3
const SHIP_NAMES := ["Линкоры", "Крейсеры", "Эсминцы", "Подлодки"]
const SHIP_ONE := ["линкор", "крейсер", "эсминец", "подлодка"]
const SHIP_POWER := [10.0, 4.0, 1.0, 1.2]
const SHIP_COST := [3000.0, 900.0, 150.0, 120.0]   # очки судостроения
const WING_MAX := 300.0
const AIR_SUP_PENALTY := 0.3   # сила войск при полном господстве противника в воздухе: −30 %
const AIR_SUP_FULL := 300.0    # истребителей (с качеством) над районом для полного эффекта
const REGION_CELL := 160.0                       # размер воздушного района, пикс. карты
const AIR_RANGE := 190.0                         # дальность от своей территории, пикс.


# --- Подготовка ----------------------------------------------------------------

static func setup(world: World, dir: String) -> void:
	_build_regions(world)
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/forces.json"))
	var data: Dictionary = d.get("nations", {}) if typeof(d) == TYPE_DICTIONARY else {}
	world.p_naval_base.resize(world.prov_count)
	world.p_naval_base.fill(0)
	var base_provs := {}   # тег -> провинции баз по порядку списка (−1 — не нашлась)
	for nat in world.nations:
		var fd0: Dictionary = data.get(nat.tag, {})
		var bl: Array = []
		base_provs[nat.tag] = bl
		for ll in fd0.get("bases", []):
			var best := -1
			var best_d := INF
			for p in world.prov_count:
				if world.p_land[p] == 1 and world.p_coastal[p] == 1 and world.p_owner[p] == nat.id:
					var dd := world.p_lonlat[p].distance_squared_to(Vector2(float(ll[0]), float(ll[1])))
					if dd < best_d:
						best_d = dd
						best = p
			bl.append(best)
			if best >= 0:
				world.p_naval_base[best] = 1
	for nat in world.nations:
		if not nat.alive:
			continue
		var fd: Dictionary = data.get(nat.tag, {})
		nat.naval_share = float(fd.get("naval_share", 0.0))
		nat.air_share = float(fd.get("air_share", 0.05))
		var navy: Dictionary = fd.get("navy", {})
		if not navy.is_empty():
			var home := home_zone(world, nat.id)
			if home >= 0:
				var surface := PackedInt32Array([int(navy.get("bb", 0)), int(navy.get("cr", 0)), int(navy.get("dd", 0)), 0])
				var squads: Array = fd.get("squadrons", [])
				if surface[0] + surface[1] + surface[2] > 0 and squads.is_empty():
					create_fleet(world, nat.id, home, surface, "Основной флот")
				elif surface[0] + surface[1] + surface[2] > 0:
					# деление по базам: доля кораблей каждого типа, остаток — первому
					var left := surface.duplicate()
					var made: Array = []
					for i in squads.size():
						var sq: Array = squads[i]
						var zone := home
						var bl2: Array = base_provs.get(nat.tag, [])
						var bi := int(sq[1])
						if bi >= 0 and bi < bl2.size() and int(bl2[bi]) >= 0:
							for q in world.p_adj[int(bl2[bi])]:
								if world.p_land[q] == 0:
									zone = q
									break
						var part := PackedInt32Array([0, 0, 0, 0])
						if i > 0:
							for t in 3:
								part[t] = mini(left[t], int(round(surface[t] * float(sq[2]))))
								left[t] -= part[t]
						made.append([zone, part, String(sq[0]), float(sq[2])])
					made[0][1] = PackedInt32Array([left[0], left[1], left[2], 0])
					for m in made:
						var pp: PackedInt32Array = m[1]
						if pp[0] + pp[1] + pp[2] > 0:
							var nf := create_fleet(world, nat.id, int(m[0]), pp, String(m[2]))
							nf.share = float(m[3])
				if int(navy.get("ss", 0)) > 0:
					var subs := create_fleet(world, nat.id, home, PackedInt32Array([0, 0, 0, int(navy.get("ss", 0))]), "Подводные силы")
					subs.mission = "raid"
		var air: Dictionary = fd.get("air", {})
		var cap_region: int = world.p_region[nat.capital]
		for kind in 2:
			var planes := float(air.get("fig" if kind == 0 else "bomb", 0))
			while planes > 0.0:
				var take := minf(planes, WING_MAX)
				var w := create_wing(world, nat.id, kind, cap_region)
				w.planes = take
				w.mission = "sup" if kind == 0 else "cas"
				planes -= take
	_refresh_cache(world)


static func _build_regions(world: World) -> void:
	if world.p_air_src.size() == world.prov_count and world.prov_count > 0 and world.p_air_src[0] >= 0:
		_regions_from_map(world)
		return
	var cols := int(ceil(world.width / REGION_CELL))
	var cell_to_region := {}
	world.p_region.resize(world.prov_count)
	var sums: Array = []
	var best_vp: Array = []
	var names: Array = []
	for p in world.prov_count:
		var c := world.p_center[p]
		var cell := int(c.y / REGION_CELL) * cols + int(c.x / REGION_CELL)
		if not cell_to_region.has(cell):
			cell_to_region[cell] = sums.size()
			sums.append([Vector2.ZERO, 0])
			best_vp.append(-1)
			names.append(world.p_name[p])
		var r: int = cell_to_region[cell]
		world.p_region[p] = r
		sums[r][0] += c
		sums[r][1] += 1
		var v: int = world.p_vp[p] if world.p_land[p] == 1 else -1
		if v > best_vp[r]:
			best_vp[r] = v
			names[r] = world.p_name[p]
	world.region_count = sums.size()
	for r in world.region_count:
		sums[r] = sums[r][0] / maxf(1.0, sums[r][1])
	_finish_regions(world, sums, names)


## Районы из карты (как стратегические регионы жанра): группы соседних
## провинций, собранные tools/build_map.py; центр — среднее центров провинций.
static func _regions_from_map(world: World) -> void:
	world.p_region = world.p_air_src.duplicate()
	var n := 0
	for p in world.prov_count:
		n = maxi(n, world.p_region[p] + 1)
	world.region_count = n
	var sums: Array = []
	var cnt := PackedInt32Array()
	cnt.resize(n)
	for r in n:
		sums.append(Vector2.ZERO)
	for p in world.prov_count:
		var r := world.p_region[p]
		sums[r] += world.p_center[p]
		cnt[r] += 1
	var names: Array = []
	for r in n:
		sums[r] = sums[r] / maxf(1.0, cnt[r])
		names.append(world.air_region_names[r] if r < world.air_region_names.size() else "Район %d" % r)
	_finish_regions(world, sums, names)


static func _finish_regions(world: World, centers: Array, names: Array) -> void:
	world.region_center.resize(world.region_count)
	world.region_name.resize(world.region_count)
	world.region_anchor.resize(world.region_count)
	world.region_provs = []
	for r in world.region_count:
		world.region_center[r] = centers[r]
		world.region_name[r] = names[r]
		world.region_provs.append(PackedInt32Array())
	for p in world.prov_count:
		world.region_provs[world.p_region[p]].append(p)
	for r in world.region_count:
		var best := -1
		for p in world.region_provs[r]:
			if best < 0 or (world.p_land[p] > world.p_land[best]) or (world.p_land[p] == world.p_land[best] and world.p_vp[p] > world.p_vp[best]):
				best = p
		world.region_anchor[r] = best
	var n := world.region_count * maxi(1, world.nation_count)
	world.cas_mult.resize(n)
	world.cas_mult.fill(1.0)
	world.air_sup.resize(n)
	world.air_sup.fill(0.5)


static func home_zone(world: World, n: int) -> int:
	var best := -1
	var best_vp := -1
	for p in world.prov_count:
		if world.p_controller[p] != n or world.p_coastal[p] == 0:
			continue
		var v := world.p_vp[p] + (1000 if world.p_naval_base.size() > p and world.p_naval_base[p] == 1 else 0) \
			+ (100 if p == world.nations[n].capital else 0) - (500 if world.p_colony[p] == 1 else 0)
		if v > best_vp:
			best_vp = v
			best = p
	if best < 0:
		return -1
	for q in world.p_adj[best]:
		if world.p_land[q] == 0:
			return q
	return -1


## Порт — прибрежный город (точка снабжения и переправы), военно-морская база
## или действующий плацдарм высадки.
static func is_port(world: World, p: int) -> bool:
	if world.p_port.size() != world.prov_count:
		refresh_ports(world)
	if world.p_port[p] == 1:
		return true
	return not world.beachheads.is_empty() and world.beachheads.has(p) and int(world.beachheads[p]) >= world.day


static func refresh_ports(world: World) -> void:
	world.p_port.resize(world.prov_count)
	for p in world.prov_count:
		var base := world.p_naval_base.size() > p and world.p_naval_base[p] == 1
		world.p_port[p] = 1 if world.p_land[p] == 1 and world.p_coastal[p] == 1 and (world.p_vp[p] >= 3 or base) else 0
	world.port_list = PackedInt32Array()
	for p in world.prov_count:
		if world.p_port[p] == 1:
			world.port_list.append(p)


## Ближайшая военно-морская база стороны страны n (морская зона рядом с ней).
static func base_zone(world: World, n: int, from_zone: int) -> int:
	var dist := sea_dist(world, from_zone) if from_zone >= 0 else PackedInt32Array()
	var best := -1
	var best_d := 1 << 20
	var ctrl := world.p_controller
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	for p in base_list(world):
		var c := ctrl[p]
		if c < 0 or (c != n and world.ally[n * world.nation_count + c] == 0):
			continue
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				var d: int = 0
				if from_zone >= 0:
					d = dist[q] if dist[q] >= 0 else 1 << 19
				if d < best_d:
					best_d = d
					best = q
	return best


## Провинции с военно-морскими базами по возрастанию номера (кэш).
static func base_list(world: World) -> PackedInt32Array:
	if world.naval_bases.is_empty() and world.p_naval_base.size() > 0:
		for p in world.p_naval_base.size():
			if world.p_naval_base[p] == 1:
				world.naval_bases.append(p)
	return world.naval_bases


static func at_base(world: World, f: World.Fleet) -> bool:
	var nb := world.p_naval_base
	var a_start := world.adj_start
	var a_list := world.adj_list
	for k in range(a_start[f.zone], a_start[f.zone + 1]):
		var q := a_list[k]
		if world.p_land[q] == 1 and nb.size() > q and nb[q] == 1:
			var c := world.p_controller[q]
			if c == f.owner or (c >= 0 and world.ally[f.owner * world.nation_count + c] == 1):
				return true
	return false


static func create_fleet(world: World, n: int, zone: int, ships: PackedInt32Array, name: String) -> World.Fleet:
	var f := World.Fleet.new()
	f.id = world.fleets.size()
	f.owner = n
	f.zone = zone
	f.home = zone
	f.ships = ships
	f.name = name
	world.fleets.append(f)
	return f


static func create_wing(world: World, n: int, kind: int, region: int) -> World.AirWing:
	var w := World.AirWing.new()
	w.id = world.wings.size()
	w.owner = n
	w.kind = kind
	w.region = region
	var cnt := 1
	for o in world.wings:
		if o.owner == n and o.kind == kind:
			cnt += 1
	w.name = "%d-е %s" % [cnt, "истребительное крыло" if kind == 0 else "бомбардировочное крыло"]
	world.wings.append(w)
	return w


static func fleet_power(f: World.Fleet) -> float:
	var s := 0.0
	for k in 4:
		s += f.ships[k] * SHIP_POWER[k]
	return s


## Боевая сила с учётом готовности (после боёв — ниже, пока флот не на базе).
static func combat_power(f: World.Fleet) -> float:
	return fleet_power(f) * f.quality * (0.3 + 0.7 * f.readiness)


## Качество флотов по технологиям страны: среднее по силе кораблей каждого рода.
static func refresh_quality(world: World) -> void:
	var ns := world.n_ship
	if ns.size() != world.nation_count * 4:
		return
	for f in world.fleets:
		if not f.alive:
			continue
		var base := 0.0
		var q := 0.0
		for k in 4:
			var pw: float = f.ships[k] * SHIP_POWER[k]
			base += pw
			q += pw * ns[f.owner * 4 + k]
		f.quality = q / base if base > 0.0 else 1.0


static func fleet_size(f: World.Fleet) -> int:
	return f.ships[0] + f.ships[1] + f.ships[2] + f.ships[3]


static func _refresh_cache(world: World) -> void:
	world.zone_fleets = {}
	for f in world.fleets:
		if not f.alive:
			continue
		if not world.zone_fleets.has(f.zone):
			world.zone_fleets[f.zone] = []
		world.zone_fleets[f.zone].append(f)


## Господство на море для страны в зоне: своя сторона / (своя + противники).
## Если флотов нет ни у кого — 0.5 (ничья: высадка возможна, но без прикрытия).
static func supremacy(world: World, n: int, zone: int) -> float:
	var mine := 0.0
	var enemy := 0.0
	var nc := world.nation_count
	for f in world.zone_fleets.get(zone, []):
		if f.mission == "port":
			continue
		var p := combat_power(f)
		if world.ally[n * nc + f.owner] == 1:
			mine += p
		elif world.is_at_war(n, f.owner):
			enemy += p
	if mine + enemy <= 0.0:
		return 0.5
	return mine / (mine + enemy)


# --- Ежедневный ход: флот ----------------------------------------------------------

static func daily_navy(world: World, rng: RandomNumberGenerator) -> void:
	var _pt := Time.get_ticks_usec()
	_build_ships(world)
	Prof.add("флот:верфи", _pt)
	_pt = Time.get_ticks_usec()
	# движение: зона в день; готовность восстанавливается на базе
	for f in world.fleets:
		if not f.alive:
			continue
		if not f.path.is_empty():
			f.zone = f.path[0]
			f.path.remove_at(0)
		if f.path.is_empty() and at_base(world, f):
			f.readiness = minf(1.0, f.readiness + (0.05 if f.mission == "port" else 0.02))
		else:
			f.readiness = minf(1.0, f.readiness + 0.002)
		# база потеряна — приписываем флот к ближайшей своей
		Prof.add("флот:движение-база", _pt)
		_pt = Time.get_ticks_usec()
		if world.day % 7 == f.id % 7 and f.home >= 0:
			var home_ok := false
			for q in world.p_adj[f.home]:
				if world.p_land[q] == 1 and world.p_naval_base.size() > q and world.p_naval_base[q] == 1:
					var c := world.p_controller[q]
					if c == f.owner or (c >= 0 and world.ally[f.owner * world.nation_count + c] == 1):
						home_ok = true
			if not home_ok:
				var b := base_zone(world, f.owner, f.zone)
				if b >= 0:
					f.home = b
		Prof.add("флот:движение-дом", _pt)
		_pt = Time.get_ticks_usec()
	Prof.add("флот:движение", _pt)
	_pt = Time.get_ticks_usec()
	_refresh_cache(world)
	refresh_quality(world)
	# морские бои
	for f in world.fleets:
		f.in_battle = false
	for zone in world.zone_fleets:
		var here: Array = world.zone_fleets[zone]
		if here.size() < 2:
			continue
		var a: World.Fleet = here[0]
		var side_a: Array = []
		var side_b: Array = []
		for f in here:
			if f.mission == "port":
				continue   # корабли в порту в бою не участвуют
			if f.owner == a.owner or world.ally[a.owner * world.nation_count + f.owner] == 1:
				side_a.append(f)
			elif world.is_at_war(a.owner, f.owner):
				side_b.append(f)
		if side_b.is_empty():
			continue
		var pa := 0.0
		var pb := 0.0
		for f in side_a:
			pa += combat_power(f)
			f.in_battle = true
		for f in side_b:
			pb += combat_power(f)
			f.in_battle = true
		var r := world.p_region[zone]
		var nc := world.nation_count
		var da := pb * 0.035 * rng.randf_range(0.7, 1.3) * world.cas_mult[r * nc + side_b[0].owner]
		var db := pa * 0.035 * rng.randf_range(0.7, 1.3) * world.cas_mult[r * nc + a.owner]
		_take_losses(world, side_a, da, rng)
		_take_losses(world, side_b, db, rng)
		for f in side_a:
			f.readiness = maxf(0.0, f.readiness - da / maxf(1.0, pa) * 0.6)
		for f in side_b:
			f.readiness = maxf(0.0, f.readiness - db / maxf(1.0, pb) * 0.6)
		_retreat_if_beaten(world, side_a, pb)
		_retreat_if_beaten(world, side_b, pa)
	# боевой опыт флота: соединения в морском бою и в рейдах на торговых путях
	var nxp := PackedFloat64Array()
	nxp.resize(world.nations.size())
	for f in world.fleets:
		if not f.alive:
			continue
		if f.in_battle:
			nxp[f.owner] += Doctrine.NAVY_PER_FLEET
		elif f.mission == "raid" and not world.nations[f.owner].at_war.is_empty():
			nxp[f.owner] += Doctrine.NAVY_PER_RAID
	for n in nxp.size():
		if nxp[n] > 0.0:
			Doctrine.gain(world.nations[n], 1, minf(Doctrine.NAVY_CAP, nxp[n]))
	Prof.add("флот:сражения", _pt)
	_pt = Time.get_ticks_usec()
	_trade_war(world, rng)
	_refresh_cache(world)
	Prof.add("флот:торговля", _pt)


static func _take_losses(world: World, side: Array, dmg: float, rng: RandomNumberGenerator) -> void:
	# сначала гибнут эскорты (эсминцы), потом подлодки, крейсеры, линкоры
	var order := [SHIP_DD, SHIP_SS, SHIP_CR, SHIP_BB]
	while dmg > 0.0:
		var hit := false
		for k in order:
			for f in side:
				if f.alive and f.ships[k] > 0 and dmg > 0.0:
					var cost: float = SHIP_POWER[k]
					if dmg >= cost or rng.randf() < dmg / cost:
						f.ships[k] -= 1
						hit = true
					dmg -= cost
					if fleet_size(f) == 0:
						f.alive = false
						world.log_event("%s: %s уничтожен" % [world.nations[f.owner].name, f.name])
		if not hit:
			break


static func _retreat_if_beaten(world: World, side: Array, enemy_power: float) -> void:
	var p := 0.0
	for f in side:
		if f.alive:
			p += fleet_power(f)
	if p < enemy_power * 0.4:
		for f in side:
			if f.alive:
				var b := base_zone(world, f.owner, f.zone)
				if b >= 0:
					f.home = b
				if f.zone != f.home:
					f.path = sea_path(world, f.zone, f.home)
				f.mission = "port"


## Рейды подлодок: вражеские подлодки у наших портов снижают выпуск; эсминцы
## их выбивают.
static func _trade_war(world: World, rng: RandomNumberGenerator) -> void:
	for nat in world.nations:
		nat.trade_penalty = 0.0
	if world.fleets.is_empty():
		return
	for nat in world.nations:
		if not nat.alive or nat.at_war.is_empty():
			continue
		var raid := 0.0
		var escort := 0.0
		var raiders: Array = []
		for zone in trade_zones(world, nat.id):
			for f in world.zone_fleets.get(zone, []):
				if f.mission == "raid" and world.is_at_war(nat.id, f.owner):
					raid += f.ships[SHIP_SS] * SHIP_POWER[SHIP_SS] * (1.0 + world.nations[f.owner].b("sub_raid"))
					raiders.append(f)
				elif world.ally[nat.id * world.nation_count + f.owner] == 1 and f.mission != "port":
					escort += (f.ships[SHIP_DD] + f.ships[SHIP_CR] * 2.0) * (1.0 + world.nations[f.owner].b("escort"))
		nat.trade_penalty = clampf((raid - escort * 0.7) * 0.004, 0.0, 0.3)
		if escort > 0.0 and not raiders.is_empty():
			_take_losses(world, raiders, escort * 0.01 * rng.randf_range(0.5, 1.5), rng)


static func trade_zones(world: World, n: int) -> Dictionary:
	var cached = world.trade_cache.get(n)
	if cached != null and int(cached[0]) > world.day - 30:
		return cached[1]
	var res := {}
	for p in world.prov_count:
		if world.p_owner[p] == n and world.p_coastal[p] == 1 and world.p_vp[p] >= 3 and world.p_colony[p] == 0:
			for q in world.p_adj[p]:
				if world.p_land[q] == 0:
					res[q] = true
	world.trade_cache[n] = [world.day, res]
	return res


static func _build_ships(world: World) -> void:
	for nat in world.nations:
		if not nat.alive:
			continue
		if nat.ship_queue.is_empty() and not nat.is_player and nat.naval_share > 0.0:
			var cycle := [SHIP_DD, SHIP_SS, SHIP_DD, SHIP_CR] + ([SHIP_BB] if nat.major else [])
			nat.ship_queue.append(cycle[(world.day / 7 + nat.id) % cycle.size()])
		if nat.ship_queue.is_empty():
			continue
		var t: int = nat.ship_queue[0]
		var cost: float = SHIP_COST[t] / (1.0 + maxf(0.0, nat.b("shipyard")))   # технологии верфей
		if nat.stock[Military.EQ_SHIP] < cost:
			continue
		nat.stock[Military.EQ_SHIP] -= cost
		nat.ship_queue.pop_front()
		# новый корабль — во флот своего рода, у которого меньше всего сил
		# относительно его доли (подлодки — к рейдерам)
		var target: World.Fleet = null
		var tp := INF
		for f in world.fleets:
			if f.alive and f.owner == nat.id and ((t == SHIP_SS) == (f.mission == "raid")):
				var fp := fleet_power(f) / maxf(0.05, f.share)
				if fp < tp:
					tp = fp
					target = f
		if target == null:
			var home := home_zone(world, nat.id)
			if home < 0:
				continue
			target = create_fleet(world, nat.id, home, PackedInt32Array([0, 0, 0, 0]), "Подводные силы" if t == SHIP_SS else "Основной флот")
			if t == SHIP_SS:
				target.mission = "raid"
		target.ships[t] += 1
		if nat.is_player:
			world.log_event("Спущен на воду: %s (%s)" % [SHIP_ONE[t], target.name])


## Путь по морским зонам (без from, с to).
static func sea_path(world: World, from: int, to: int) -> PackedInt32Array:
	if from == to or from < 0 or to < 0:
		return PackedInt32Array()
	if Native.core != null:
		return Native.core.call("sea_path", world.adj_start, world.adj_list, world.p_land, from, to)
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var parent := PackedInt32Array()
	parent.resize(world.prov_count)
	parent.fill(-1)
	parent[from] = from
	var queue := PackedInt32Array([from])
	var head := 0
	while head < queue.size():
		var p := queue[head]
		head += 1
		if p == to:
			break
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0 and parent[q] < 0:
				parent[q] = p
				queue.append(q)
	if parent[to] < 0:
		return PackedInt32Array()
	var path := PackedInt32Array()
	var cur := to
	while cur != from:
		path.append(cur)
		cur = parent[cur]
	path.reverse()
	return path


## Расстояния по морю от зоны from (в зонах); -1 — недостижимо.
static func sea_dist(world: World, from: int) -> PackedInt32Array:
	if Native.core != null:
		return Native.core.call("sea_bfs", world.adj_start, world.adj_list, world.p_land, from)
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	var dist := PackedInt32Array()
	dist.resize(world.prov_count)
	dist.fill(-1)
	if from < 0:
		return dist
	dist[from] = 0
	var queue := PackedInt32Array([from])
	var head := 0
	while head < queue.size():
		var p := queue[head]
		head += 1
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0 and dist[q] < 0:
				dist[q] = dist[p] + 1
				queue.append(q)
	return dist


## Своя территория страны n, связанная по суше с провинцией start (start —
## всегда), и страны-соседи этой территории в порядке первой встречи.
static func own_reach(world: World, n: int, start: int) -> Array:
	if Native.core != null:
		return Native.core.call("own_reach", world.adj_start, world.adj_list, world.p_land, world.p_controller, n, start, world.nation_count)
	var land := world.p_land
	var ctrl := world.p_controller
	var a_start := world.adj_start
	var a_list := world.adj_list
	var mask := PackedByteArray()
	mask.resize(world.prov_count)
	var neigh := PackedInt32Array()
	var seen := PackedByteArray()
	seen.resize(world.nation_count)
	mask[start] = 1
	var stack := PackedInt32Array([start])
	while not stack.is_empty():
		var p := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				continue
			var c := ctrl[q]
			if c == n:
				if mask[q] == 0:
					mask[q] = 1
					stack.append(q)
			elif c >= 0 and seen[c] == 0:
				seen[c] = 1
				neigh.append(c)
	return [mask, neigh]


## Упреждение (Spec): страны, у которых завтра решения ИИ флота, авиации и
## высадок (день + номер кратен 10), — в фоне по сегодняшнему снимку
## территории: с кем есть сухопутная граница от столицы (own_reach). Завтра
## Diplomacy.reachable_neighbours берёт готовое (world.reach_job).
static func spec(world: World, jobs: Array) -> void:
	world.reach_job = {}
	var due := PackedInt32Array()
	var caps := PackedInt32Array()
	for nat in world.nations:
		if nat.alive and not nat.is_player and (world.day + 1 + nat.id) % 10 == 0 \
				and (not nat.at_war.is_empty() or not nat.wargoals.is_empty() or not nat.planned_wars.is_empty()):
			due.append(nat.id)
			caps.append(nat.capital)
	if due.is_empty():
		return
	var t := {"adj_start": world.adj_start.duplicate(), "adj_list": world.adj_list.duplicate(),
		"land": world.p_land.duplicate(), "ctrl": world.p_controller.duplicate(), "nc": world.nation_count}
	var res := {}
	var job := {"day": world.day + 1, "reach": res}
	world.reach_job = job
	jobs.append(func():
		var ctrl: PackedInt32Array = t["ctrl"]
		for i in due.size():
			var n := due[i]
			var cap := caps[i]
			if cap < 0 or ctrl[cap] != n:
				res[n] = PackedInt32Array()
				continue
			if Native.core != null:
				var r: Array = Native.core.call("own_reach", t["adj_start"], t["adj_list"], t["land"], ctrl, n, cap, t["nc"])
				res[n] = r[1]
			else:
				res[n] = _reach_gd(t, n, cap))


## GDScript-вариант own_reach по снимку: соседние страны (по порядку обнаружения).
static func _reach_gd(t: Dictionary, n: int, start: int) -> PackedInt32Array:
	var land: PackedByteArray = t["land"]
	var ctrl: PackedInt32Array = t["ctrl"]
	var a_start: PackedInt32Array = t["adj_start"]
	var a_list: PackedInt32Array = t["adj_list"]
	var nc: int = t["nc"]
	var mask := PackedByteArray()
	mask.resize(ctrl.size())
	var neigh := PackedInt32Array()
	var seen := PackedByteArray()
	seen.resize(nc)
	mask[start] = 1
	var stack := PackedInt32Array([start])
	while not stack.is_empty():
		var p := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		for k in range(a_start[p], a_start[p + 1]):
			var q := a_list[k]
			if land[q] == 0:
				continue
			var c := ctrl[q]
			if c == n:
				if mask[q] == 0:
					mask[q] = 1
					stack.append(q)
			elif c >= 0 and seen[c] == 0:
				seen[c] = 1
				neigh.append(c)
	return neigh


## ИИ: главный флот ищет более слабого противника рядом, подлодки — торговлю врага.
static func ai_fleets(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	for f in world.fleets:
		if not f.alive or f.owner != n or not f.path.is_empty() or f.task_until >= world.day:
			continue
		if nat.at_war.is_empty():
			if f.zone != f.home:
				f.path = sea_path(world, f.zone, f.home)
			f.mission = "raid" if f.ships[SHIP_SS] > 0 and fleet_power(f) == f.ships[SHIP_SS] * SHIP_POWER[SHIP_SS] else "patrol"
			continue
		if f.mission == "port" and f.zone == f.home:
			f.mission = "raid" if f.ships[SHIP_SS] * SHIP_POWER[SHIP_SS] >= fleet_power(f) * 0.9 else "patrol"
		var best := -1
		var best_len := 1 << 20
		var from_here := sea_dist(world, f.zone)
		# слабый флот отстаивается в порту, пока рядом сильный враг («флот как угроза»)
		if f.mission != "raid":
			var from_home := sea_dist(world, f.home)
			var near_enemy := 0.0
			for z in world.zone_fleets:
				var fh: int = from_home[z]
				if fh < 0 or fh > 8:
					continue
				for o in world.zone_fleets[z]:
					if world.is_at_war(n, o.owner) and o.mission != "raid":
						near_enemy += fleet_power(o)
			if near_enemy > fleet_power(f):
				if f.zone != f.home:
					f.path = sea_path(world, f.zone, f.home)
				f.mission = "port"
				continue
		if f.mission == "port" and f.zone == f.home:
			f.mission = "raid" if f.ships[SHIP_SS] * SHIP_POWER[SHIP_SS] >= fleet_power(f) * 0.9 else "patrol"
		if f.mission == "raid":
			for e in nat.at_war:
				for z in trade_zones(world, e):
					var l: int = from_here[z] if from_here[z] >= 0 else 1 << 20
					if l < best_len and l <= 12:
						best_len = l
						best = z
		else:
			# охота — в своём районе (до 8 зон от базы), без цели — блокада
			# ближайших к базе вражеских портов (держит дальнюю блокаду торговли)
			var mine := fleet_power(f)
			var from_base := sea_dist(world, f.home)
			# флот, поделённый по базам (доля < 1), держит свой район — 5 зон
			var reach_n := 8 if f.share >= 0.99 else 5
			for z in world.zone_fleets:
				var l: int = from_here[z] if from_here[z] >= 0 else 1 << 20
				if l >= best_len or from_base[z] < 0 or from_base[z] > reach_n:
					continue
				var enemy := 0.0
				for o in world.zone_fleets[z]:
					if world.is_at_war(n, o.owner) and o.mission != "raid":
						enemy += fleet_power(o)
				if enemy > 0.0 and mine > enemy * 1.2:
					best_len = l
					best = z
			if best < 0:
				var bl3 := reach_n + 1
				for e in nat.at_war:
					for z in trade_zones(world, e):
						var dz: int = from_base[z]
						if dz >= 0 and dz < bl3:
							# не лезть под более сильный флот противника
							var enemy2 := 0.0
							for o in world.zone_fleets.get(z, []):
								if world.is_at_war(n, o.owner):
									enemy2 += fleet_power(o)
							if enemy2 * 1.2 < mine:
								bl3 = dz
								best = z
			if best < 0 and f.zone != f.home:
				best = f.home
		if best >= 0 and best != f.zone:
			f.path = sea_path(world, f.zone, best)


## Блокада: порт не снабжает, если во всех соседних морских зонах господство у врага.
static func port_blockaded(world: World, n: int, p: int) -> bool:
	if world.fleets.is_empty():
		return false
	# морская зона без флотов — господство 0.5, блокады нет (быстрая проверка)
	var zf := world.zone_fleets
	var land := world.p_land
	var a_start := world.adj_start
	var a_list := world.adj_list
	for k in range(a_start[p], a_start[p + 1]):
		var q := a_list[k]
		if land[q] == 0 and not zf.has(q):
			return false
	var any := false
	for q in world.p_adj[p]:
		if world.p_land[q] == 0:
			any = true
			if supremacy(world, n, q) >= 0.3:
				return false
	return any


# --- Морские высадки -------------------------------------------------------------

## Проверка высадки: [причина или "", дней в пути, зона высадки].
static func invasion_check(world: World, divs: Array, target: int) -> Array:
	if divs.is_empty() or world.p_land[target] == 0 or world.p_coastal[target] == 0:
		return ["цель должна быть на побережье", 0, -1]
	var n: int = divs[0].owner
	var c := world.p_controller[target]
	if c != n and not world.is_at_war(n, c) and world.ally[n * world.nation_count + c] == 0:
		return ["нет войны с владельцем провинции", 0, -1]
	var start_zones := {}
	for d in divs:
		if not is_port(world, d.prov) or world.p_controller[d.prov] != n:
			return ["дивизии должны стоять в своём порту", 0, -1]
		for q in world.p_adj[d.prov]:
			if world.p_land[q] == 0:
				start_zones[q] = true
	var best_zone := -1
	var best_sup := -1.0
	for q in world.p_adj[target]:
		if world.p_land[q] == 0:
			var s := supremacy(world, n, q)
			if s > best_sup:
				best_sup = s
				best_zone = q
	if best_zone < 0:
		return ["нет выхода к морю", 0, -1]
	if best_sup < 0.5:
		return ["нужно господство на море у цели (сейчас %d%%)" % (best_sup * 100.0), 0, -1]
	var best_len := 1 << 20
	for z in start_zones:
		var p := sea_path(world, z, best_zone)
		if z == best_zone or not p.is_empty():
			best_len = mini(best_len, p.size())
	if best_len >= 1 << 20:
		return ["нет морского пути", 0, -1]
	return ["", 5 + int(best_len * 1.2), best_zone]


## Переправа: дивизии морем из своего порта в свой/союзный порт (подкрепления на
## плацдарм, в колонии). Пустая строка — отправлены; иначе причина.
static func sea_transfer(world: World, divs: Array, target: int) -> String:
	if divs.is_empty():
		return "нет дивизий"
	var n: int = divs[0].owner
	var c := world.p_controller[target]
	if c < 0 or (c != n and world.ally[n * world.nation_count + c] == 0):
		return "порт назначения должен быть нашим или союзным"
	if not is_port(world, target):
		return "в провинции назначения нет порта"
	var port: int = divs[0].prov
	for d in divs:
		if d.prov != port:
			return "для переправы дивизии должны стоять в одном порту"
	if not is_port(world, port) or world.p_controller[port] != n:
		return "отправка только из своего порта"
	var dist := _sea_distance(world, port, target)
	if dist < 0:
		return "нет морского пути"
	var days := 2 + dist
	for d in divs:
		d.transit_days = days
		d.transit_total = days
		d.transit_from = port
		d.transit_target = target
		d.transfer = true
		d.path = PackedInt32Array()
		d.group = -1
		if d.inv_plan >= 0:
			_drop_from_plan(world, d)
	return ""


## ИИ: подкрепления морем на заморские участки фронта (захваченные порты,
## колонии), куда не дойти по суше от столицы.
static func ai_transfers(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	if nat.at_war.is_empty():
		return
	# провинции, связанные со столицей по суше
	var home: PackedByteArray = own_reach(world, n, nat.capital)[0]
	# заморский порт на фронте, где мало наших войск
	var dest := -1
	var dest_need := 0
	var ctrl := world.p_controller
	var a_start := world.adj_start
	var a_list := world.adj_list
	var war := world.war
	var nc := world.nation_count
	for p in world.prov_count:
		if ctrl[p] != n or home[p] == 1 or not is_port(world, p):
			continue
		var enemies := 0
		for k in range(a_start[p], a_start[p + 1]):
			var c := ctrl[a_list[k]]
			if c >= 0 and c != n and war[n * nc + c] == 1:
				enemies += 1
		if enemies == 0:
			continue
		var mine := 0
		var h := world.pl_head[p]
		while h >= 0:
			if world.d_owner[h] == n:
				mine += 1
			h = world.d_nx[h]
		var need := 3 + enemies - mine
		if need > dest_need:
			dest_need = need
			dest = p
	if dest < 0:
		return
	# свободные дивизии в домашних портах
	var by_port := {}
	var own := world.d_owner
	var dprov := world.d_prov
	var alive := world.d_alive
	var nxt := world.d_next
	var tr := world.d_transit
	var inv := world.d_inv
	var resv := world.d_resv
	var bt := world.d_battle
	var day := world.day
	for i in own.size():
		if own[i] != n or alive[i] == 0 or home[dprov[i]] == 0 or nxt[i] >= 0 or tr[i] != 0 or inv[i] >= 0 \
				or resv[i] >= day or bt[i] != 0 or not is_port(world, dprov[i]):
			continue
		var d: World.Division = world.divisions[i]
		if not _at_front(world, d):
			if not by_port.has(d.prov):
				by_port[d.prov] = []
			by_port[d.prov].append(d)
	for port in by_port:
		var group: Array = by_port[port].slice(0, mini(dest_need, 3))
		if sea_transfer(world, group, dest) == "":
			if Diplomacy.is_major(world, n) or nat.is_player:
				world.log_event("%s: переправа %d див. → %s" % [nat.name, group.size(), world.p_name[dest]])
			return


## Подготовка высадки. Пустая строка — план создан; иначе причина.
static func plan_invasion(world: World, divs: Array, target: int) -> String:
	if divs.is_empty():
		return "нет дивизий"
	var n: int = divs[0].owner
	if world.p_land[target] == 0 or world.p_coastal[target] == 0:
		return "цель должна быть на побережье"
	var c := world.p_controller[target]
	var nat_n: World.Nation = world.nations[n]
	if c == n or (not world.is_at_war(n, c) and not nat_n.wargoals.has(c) and not nat_n.planned_wars.has(c) and world.ally[n * world.nation_count + c] == 0):
		return "нужна война или обоснованные претензии к владельцу"
	var port: int = divs[0].prov
	for d in divs:
		if d.prov != port:
			return "для высадки дивизии должны стоять в одной прибрежной провинции"
	if not is_port(world, port) or world.p_controller[port] != n:
		return "посадка только в своём порту (прибрежный город или база)"
	var dist := _sea_distance(world, port, target)
	if dist < 0:
		return "нет морского пути"
	var plan := World.InvasionPlan.new()
	plan.id = world.invasions.size()
	plan.owner = n
	plan.port = port
	plan.target = target
	plan.total = clampi(30 + divs.size() * 3 + dist * 2, 30, 60)
	plan.days_left = plan.total
	for d in divs:
		if d.inv_plan >= 0:
			_drop_from_plan(world, d)
		plan.divs.append(d.id)
		d.inv_plan = plan.id
		d.path = PackedInt32Array()
		d.group = -1
	world.invasions.append(plan)
	if world.nations[n].is_player or world.nations[c].is_player or Diplomacy.is_major(world, n):
		world.log_event("%s готовит высадку: %s → %s, %d дн." % [world.nations[n].name, world.p_name[port], world.p_name[target], plan.total])
	return ""


static func _sea_distance(world: World, port: int, target: int) -> int:
	var best := -1
	for a in world.p_adj[port]:
		if world.p_land[a] != 0:
			continue
		for b in world.p_adj[target]:
			if world.p_land[b] != 0:
				continue
			var l := 0 if a == b else sea_path(world, a, b).size()
			if a == b or l > 0:
				if best < 0 or l < best:
					best = l
	return best


static func _drop_from_plan(world: World, d: World.Division) -> void:
	if d.inv_plan < 0 or d.inv_plan >= world.invasions.size():
		d.inv_plan = -1
		return
	var plan: World.InvasionPlan = world.invasions[d.inv_plan]
	plan.divs.erase(d.id)
	d.inv_plan = -1
	if plan.divs.is_empty():
		plan.alive = false


static func cancel_plan(world: World, plan: World.InvasionPlan) -> void:
	plan.alive = false
	for d in world.divisions:
		if d.inv_plan == plan.id:
			d.inv_plan = -1


## Ход подготовки: войска должны стоять в порту; по готовности — высадка при
## господстве на море (иначе ждём).
static func daily_plans(world: World) -> void:
	if world.invasions.is_empty():
		return
	var by_id := {}
	var ids := world.d_id
	var al := world.d_alive
	for plan in world.invasions:
		if plan.alive:
			for id in plan.divs:
				by_id[id] = null
	if by_id.is_empty():
		return
	for i in ids.size():
		if al[i] == 1 and by_id.has(ids[i]):
			by_id[ids[i]] = world.divisions[i]
	for plan in world.invasions:
		if not plan.alive:
			continue
		var divs: Array = []
		for id in plan.divs.duplicate():
			var d = by_id.get(id)
			if d == null or d.prov != plan.port or not d.path.is_empty() or d.transit_days > 0:
				plan.divs.erase(id)
				if d != null:
					d.inv_plan = -1
			else:
				divs.append(d)
		if divs.is_empty() or world.p_controller[plan.port] != plan.owner:
			cancel_plan(world, plan)
			continue
		var c := world.p_controller[plan.target]
		var po: World.Nation = world.nations[plan.owner]
		if c == plan.owner or (not world.is_at_war(plan.owner, c) and not po.wargoals.has(c) and not po.planned_wars.has(c) and world.ally[plan.owner * world.nation_count + c] == 0):
			cancel_plan(world, plan)
			continue
		if plan.days_left > 0:
			plan.days_left -= 1
			continue
		if invasion_check(world, divs, plan.target)[0] == "":
			launch_invasion(world, divs, plan.target)
			plan.alive = false
			for d in divs:
				d.inv_plan = -1


static func plan_status(world: World, plan: World.InvasionPlan) -> String:
	if plan.days_left > 0:
		return "подготовка: ещё %d дн." % plan.days_left
	if not world.is_at_war(plan.owner, world.p_controller[plan.target]) and world.ally[plan.owner * world.nation_count + world.p_controller[plan.target]] == 0:
		return "готово — ждём объявления войны"
	var divs: Array = []
	for d in world.divisions:
		if d.alive and d.inv_plan == plan.id:
			divs.append(d)
	var chk := invasion_check(world, divs, plan.target)
	return "готово — ждём: " + chk[0] if chk[0] != "" else "готово"


static func launch_invasion(world: World, divs: Array, target: int) -> int:
	var chk := invasion_check(world, divs, target)
	if chk[0] != "":
		return -1
	for d in divs:
		d.transit_days = chk[1]
		d.transit_total = chk[1]
		d.transit_from = d.prov
		d.transit_target = target
		d.path = PackedInt32Array()
		d.progress = 0.0
		d.group = -1
	var c := world.p_controller[target]
	if c >= 0 and c != divs[0].owner and (world.nations[c].is_player or world.nations[divs[0].owner].is_player or Diplomacy.is_major(world, divs[0].owner)):
		world.log_event("%s: морская высадка → %s (%d дн.)" % [world.nations[divs[0].owner].name, world.p_name[target], chk[1]])
	return chk[1]


## Дивизии в пути: потери при господстве врага; по прибытии — штурм с моря.
static func daily_transit(world: World) -> void:
	var tr := world.d_transit
	var al := world.d_alive
	for i in tr.size():
		if tr[i] <= 0 or al[i] == 0:
			continue
		var d: World.Division = world.divisions[i]
		var zone := -1
		for q in world.p_adj[d.transit_target]:
			if world.p_land[q] == 0:
				zone = q
				break
		if zone >= 0 and supremacy(world, d.owner, zone) < 0.4:
			d.strength = maxf(0.0, d.strength - 2.5)
			d.org = maxf(0.0, d.org - 3.0)
			if d.strength <= 5.0:
				d.alive = false
				continue
		d.transit_days -= 1
		if d.transit_days <= 0:
			if d.transfer:
				# переправа: в свой порт сразу; если порт потерян — обратно
				d.transfer = false
				var c := world.p_controller[d.transit_target]
				var ok: bool = c == d.owner or (c >= 0 and world.ally[d.owner * world.nation_count + c] == 1)
				d.prov = d.transit_target if ok else d.transit_from
				d.path = PackedInt32Array()
				d.progress = 0.0
				continue
			d.path = PackedInt32Array([d.transit_target])
			d.progress = 0.95
			d.landing = true


# --- Авиация -------------------------------------------------------------------------

static func wing_in_range(world: World, w: World.AirWing, region: int) -> bool:
	return regions_in_range(world, w.owner).has(region)


## Районы в радиусе действия авиации стороны (от своих и союзных провинций).
## Кэш на 10 дней: граница меняется медленно.
static func regions_in_range(world: World, n: int) -> Dictionary:
	var cached = world.air_range_cache.get(n)
	if cached != null and int(cached[0]) > world.day - 10:
		return cached[1]
	var res := _regions_in_range(world, n)
	world.air_range_cache[n] = [world.day, res]
	return res


static func _regions_in_range(world: World, n: int) -> Dictionary:
	var nc := world.nation_count
	if Native.core != null:
		var mask: PackedByteArray = Native.core.call("air_reach", world.p_land, world.p_controller, world.ally, nc, n,
				world.p_region, world.region_center, AIR_RANGE)
		var out := {}
		for r in mask.size():
			if mask[r] == 1:
				out[r] = true
		return out
	var own_regions := {}
	for p in world.prov_count:
		var o := world.p_controller[p]
		if world.p_land[p] == 1 and o >= 0 and world.ally[n * nc + o] == 1:
			own_regions[world.p_region[p]] = true
	var res := {}
	for r in world.region_count:
		for q in own_regions:
			if world.region_center[q].distance_to(world.region_center[r]) <= AIR_RANGE:
				res[r] = true
				break
	return res


static func daily_air(world: World, rng: RandomNumberGenerator) -> void:
	var nc := world.nation_count
	if world.cas_mult.size() != world.region_count * nc:
		world.cas_mult.resize(world.region_count * nc)
		world.air_sup.resize(world.region_count * nc)
	world.cas_mult.fill(1.0)
	world.air_sup.fill(0.5)
	var _pt := Time.get_ticks_usec()
	# пополнение крыльев из резерва, новые крылья ИИ (крылья заранее по странам)
	var by_owner := {}
	for w in world.wings:
		if w.alive:
			if not by_owner.has(w.owner):
				by_owner[w.owner] = []
			by_owner[w.owner].append(w)
	for nat in world.nations:
		if not nat.alive:
			continue
		var own: Array = by_owner.get(nat.id, [])
		for kind in 2:
			var eq := Military.EQ_FIG if kind == 0 else Military.EQ_BOMB
			for w in own:
				if w.kind == kind and w.planes < WING_MAX and nat.stock[eq] > 0.0:
					var add := minf(WING_MAX - w.planes, nat.stock[eq])
					w.planes += add
					nat.stock[eq] -= add
			var full := true
			for w in own:
				if w.kind == kind and w.planes < WING_MAX - 1.0:
					full = false
					break
			if not nat.is_player and full and nat.stock[eq] >= 100.0:
				var nw := create_wing(world, nat.id, kind, world.p_region[nat.capital])
				nw.planes = minf(WING_MAX, nat.stock[eq])
				nat.stock[eq] -= nw.planes
				nw.mission = "sup" if kind == 0 else "cas"
	Prof.add("авиа:пополнение", _pt)
	_pt = Time.get_ticks_usec()
	# районы с авиацией
	var by_region := {}
	for w in world.wings:
		if w.alive and w.planes >= 1.0 and w.region >= 0:
			if not by_region.has(w.region):
				by_region[w.region] = []
			by_region[w.region].append(w)
	var ally := world.ally
	var war := world.war
	var air_sup := world.air_sup
	var cas_mult := world.cas_mult
	var qa := world.n_air   # качество авиации по технологиям: страна×4
	var axp := PackedFloat64Array()   # боевой опыт авиации за день (Doctrine)
	axp.resize(nc)
	for r in by_region:
		var here: Array = by_region[r]
		# снимок полей крыльев района в локальные массивы
		var cnt := here.size()
		var ow := PackedInt32Array()
		var kd := PackedInt32Array()
		var pl := PackedFloat64Array()
		var cas_m := PackedByteArray()
		ow.resize(cnt)
		kd.resize(cnt)
		pl.resize(cnt)
		cas_m.resize(cnt)
		for j in cnt:
			var w: World.AirWing = here[j]
			ow[j] = w.owner
			kd[j] = w.kind
			pl[j] = w.planes
			cas_m[j] = 1 if w.mission == "cas" else 0
		# для каждой страны: свои и вражеские истребители в районе. Считаем и для
		# стран без своей авиации здесь, но воюющих с хозяевами крыльев: их войска
		# тоже страдают от чужого господства в воздухе.
		var owners := {}
		for j in cnt:
			owners[ow[j]] = true
		var sides := owners.duplicate()
		for o in owners:
			for n2 in nc:
				if war[int(o) * nc + n2] == 1:
					sides[n2] = true
		var side_list: Array = sides.keys()
		side_list.sort()   # порядок однозначный
		for n in side_list:
			var own_f := 0.0
			var en_f := 0.0
			var own_b := 0.0
			for j in cnt:
				var o := ow[j]
				if kd[j] == 0:
					if ally[n * nc + o] == 1:
						own_f += pl[j] * qa[o * 4]
					elif n != o and war[n * nc + o] == 1:
						en_f += pl[j] * qa[o * 4]
				elif cas_m[j] == 1 and ally[n * nc + o] == 1:
					own_b += pl[j] * qa[o * 4 + 1]
			var sup := 0.5 if own_f + en_f <= 0.0 else own_f / (own_f + en_f)
			air_sup[r * nc + n] = sup
			var m := 1.0 + minf(0.4, own_b * sup / 600.0)
			# противник господствует в воздухе: до −AIR_SUP_PENALTY к силе войск,
			# в меру того, сколько истребителей над районом (AIR_SUP_FULL — полная сила)
			if sup < 0.5:
				var presence := minf(1.0, (own_f + en_f) / AIR_SUP_FULL)
				m -= AIR_SUP_PENALTY * (0.5 - sup) * 2.0 * presence
			cas_mult[r * nc + n] = m
		# воздушные бои: потери от вражеских истребителей
		for j in cnt:
			var w: World.AirWing = here[j]
			var en_f := 0.0
			var own_f := 0.0
			var wo := w.owner
			for k in cnt:
				if kd[k] == 0:
					var o := ow[k]
					var p_k: float = here[k].planes * qa[o * 4]   # уже с потерями этого дня, как раньше
					if wo != o and war[wo * nc + o] == 1:
						en_f += p_k
					elif ally[wo * nc + o] == 1:
						own_f += p_k
			if en_f <= 0.0:
				continue
			axp[wo] += Doctrine.AIR_PER_WING
			var rate := 0.004 if kd[j] == 0 else 0.008 * en_f / (en_f + own_f + 1.0)
			w.planes = maxf(0.0, w.planes - en_f * rate * rng.randf_range(0.6, 1.4) * (WING_MAX / maxf(WING_MAX, en_f + own_f)) * 3.0)
			if w.planes < 1.0:
				w.alive = false
				if world.nations[w.owner].is_player:
					world.log_event("Уничтожено: %s" % w.name)
		# стратегические бомбардировки и удары по флоту
		for w in here:
			if w.kind != 1:
				continue
			# задание бомбардировщиков на войне — тоже боевой опыт (без воздушного боя)
			if (w.mission == "bomb" or w.mission == "naval") and not world.nations[w.owner].at_war.is_empty():
				axp[w.owner] += Doctrine.AIR_PER_WING * 0.5
			var sup: float = air_sup[r * nc + w.owner]
			if w.mission == "bomb":
				_bomb_factories(world, w, r, sup, rng)
			elif w.mission == "naval":
				var dmg: float = w.planes * 0.002 * sup * qa[w.owner * 4 + 3]
				for zone in world.zone_fleets:
					if world.p_region[zone] != r:
						continue
					var targets: Array = []
					for f in world.zone_fleets[zone]:
						if world.is_at_war(w.owner, f.owner):
							targets.append(f)
					if not targets.is_empty():
						_take_losses(world, targets, dmg, rng)
	world.air_sup = air_sup
	world.cas_mult = cas_mult
	for n in nc:
		if axp[n] > 0.0:
			Doctrine.gain(world.nations[n], 2, minf(Doctrine.AIR_CAP, axp[n]))


static func _bomb_factories(world: World, w: World.AirWing, r: int, sup: float, rng: RandomNumberGenerator) -> void:
	if rng.randf() > w.planes / 1500.0 * sup * world.n_air[w.owner * 4 + 2]:
		return
	var cands: Array = []
	for p in world.region_provs[r]:
		if world.p_land[p] == 1 and world.is_at_war(w.owner, world.p_controller[p]) \
				and world.p_civ[p] + world.p_mil[p] > 0:
			cands.append(p)
	if cands.is_empty():
		return
	var p: int = cands[rng.randi() % cands.size()]
	# радары и зенитки защищающегося срывают часть налётов
	var adef: float = world.n_air_def[world.p_controller[p]]
	if adef > 0.0 and rng.randf() < adef:
		return
	if world.p_mil[p] > 0:
		world.p_mil[p] -= 1
	else:
		world.p_civ[p] -= 1
	var victim: int = world.p_owner[p]
	if world.nations[victim].is_player or world.nations[w.owner].is_player:
		world.log_event("Бомбардировка: разрушен завод — %s" % world.p_name[p])


## ИИ авиации: истребители и штурмовики над главным участком фронта,
## бомбардировщики — по заводам врага, до которого не дойти по суше.
static func ai_air(world: World, n: int) -> void:
	var _pt := Time.get_ticks_usec()
	var nat: World.Nation = world.nations[n]
	var has_wing := false
	for w in world.wings:
		if w.alive and w.owner == n:
			has_wing = true
			break
	if not has_wing:
		return
	var front_count := {}
	if not nat.at_war.is_empty() and Native.core != null:
		var fr: PackedInt32Array = Native.core.call("front_regions", world.p_controller, world.adj_start,
				world.adj_list, world.war, world.nation_count, world.p_region, n)
		for k in range(0, fr.size(), 2):
			front_count[fr[k]] = fr[k + 1]
	elif not nat.at_war.is_empty():
		var ctrl := world.p_controller
		var a_start := world.adj_start
		var a_list := world.adj_list
		var war := world.war
		var nc := world.nation_count
		var region := world.p_region
		for p in world.prov_count:
			if ctrl[p] != n:
				continue
			for k in range(a_start[p], a_start[p + 1]):
				var c := ctrl[a_list[k]]
				if c >= 0 and c != n and war[n * nc + c] == 1:
					var r: int = region[p]
					front_count[r] = int(front_count.get(r, 0)) + 1
					break
	Prof.add("авиаИИ:фронт", _pt)
	_pt = Time.get_ticks_usec()
	var main := world.p_region[nat.capital]
	var best := 0
	for r in front_count:
		if front_count[r] > best:
			best = front_count[r]
			main = r
	# цель стратегических бомбардировок — столица врага за морем (только если нет фронта)
	var bomb_target := -1
	if front_count.is_empty() and not nat.at_war.is_empty():
		var land_enemies := Diplomacy.reachable_neighbours(world, n)
		for e in nat.at_war:
			if not land_enemies.has(e) and world.nations[e].alive:
				bomb_target = world.p_region[world.nations[e].capital]
				break
	Prof.add("авиаИИ:цель", _pt)
	_pt = Time.get_ticks_usec()
	var regions := front_count.keys()
	regions.sort_custom(func(a, b): return front_count[a] > front_count[b])
	var reach := regions_in_range(world, n) if bomb_target >= 0 else {}
	Prof.add("авиаИИ:радиус", _pt)
	var k2 := 0
	for w in world.wings:
		if not w.alive or w.owner != n:
			continue
		var target := main
		if regions.size() > 1:
			target = regions[k2 % mini(3, regions.size())]
		k2 += 1
		if bomb_target >= 0 and reach.has(bomb_target):
			w.region = bomb_target
			w.mission = "bomb" if w.kind == 1 else "sup"
		else:
			w.region = target
			w.mission = "sup" if w.kind == 0 else "cas"


## ИИ: высадка на вражеское побережье, если до врага не дойти по суше.
static func ai_invasion(world: World, n: int, rng: RandomNumberGenerator) -> void:
	var nat: World.Nation = world.nations[n]
	if nat.at_war.is_empty() and nat.wargoals.is_empty() and nat.planned_wars.is_empty():
		return
	var reach := Diplomacy.reachable_neighbours(world, n)
	# только против заметно более слабой армии, до которой не дойти по суше;
	# готовиться можно заранее — к тем, к кому обоснованы претензии
	var my_navy := 0.0
	for f in world.fleets:
		if f.alive and f.owner == n:
			my_navy += fleet_power(f)
	if my_navy <= 0.0:
		return
	# первый подходящий противник: против сильного флота десант обречён — такого
	# пропускаем и смотрим следующего (Британия сильнее — значит, Норвегия)
	var enemy := -1
	for e in nat.at_war.keys() + nat.wargoals.keys() + nat.planned_wars.keys():
		if not world.nations[e].alive or reach.has(e) or nat.division_count <= world.nations[e].division_count * 1.5:
			continue
		var their_navy := 0.0
		for f in world.fleets:
			if f.alive and f.owner != n and world.ally[e * world.nation_count + f.owner] == 1:
				their_navy += fleet_power(f)
		if their_navy <= my_navy:
			enemy = e
			break
	if enemy < 0:
		return
	# уже готовим высадку — к концу подготовки подводим флот к зоне высадки
	for plan in world.invasions:
		if plan.alive and plan.owner == n:
			if plan.days_left <= 8:
				for f in world.fleets:
					if f.alive and f.owner == n and f.mission != "raid" and f.ships[SHIP_SS] < fleet_size(f):
						f.mission = "patrol"
						f.task_until = world.day + 25
						for q in world.p_adj[plan.target]:
							if world.p_land[q] == 0:
								if f.zone != q and f.path.is_empty():
									f.path = sea_path(world, f.zone, q)
								break
						break
			return
	# цель и порт посадки выбираются один раз на операцию
	var best := nat.inv_target
	if best < 0 or world.p_controller[best] != enemy:
		best = -1
		var best_score := INF
		for p in world.prov_count:
			if world.p_controller[p] != enemy or world.p_coastal[p] == 0:
				continue
			# порты в приоритете: без порта плацдарм останется без снабжения
			var score: float = world.divs_count(p) * 25.0 - world.p_vp[p] * 2.0 - (8.0 if world.p_vp[p] >= 3 else 0.0) + rng.randf()
			if score < best_score:
				best_score = score
				best = p
		nat.inv_target = best
		nat.inv_port = -1
	if best < 0:
		return
	var port := nat.inv_port
	if port < 0 or world.p_controller[port] != n:
		port = -1
		var port_d := INF
		for p in world.prov_count:
			if world.p_controller[p] == n and world.p_owner[p] == n and is_port(world, p):
				var dd := world.p_center[p].distance_squared_to(world.p_center[best])
				if dd < port_d:
					port_d = dd
					port = p
		nat.inv_port = port
	if port < 0:
		return
	var ready: Array = []
	for d in world.divisions:
		if d.alive and d.owner == n and d.prov == port and d.path.is_empty() and not d.in_battle \
				and d.transit_days == 0 and d.org > d.max_org * 0.5:
			ready.append(d)
	# уже собравшиеся в порту ждут остальных — фронт их не забирает
	for d in ready:
		d.reserved_until = maxi(d.reserved_until, world.day + 20)
	if ready.size() < 3:
		# собираем десант: ближайшие свободные дивизии не с фронта идут в порт
		var on_way := 0
		for d in world.divisions:
			if d.alive and d.owner == n and d.reserved_until >= world.day and not d.path.is_empty():
				on_way += 1
		var need := 4 - ready.size() - on_way
		if need <= 0:
			return
		var cands: Array = []
		for d in world.divisions:
			if d.alive and d.owner == n and d.path.is_empty() and not d.in_battle and d.transit_days == 0 \
					and d.prov != port and d.reserved_until < world.day and not _at_front(world, d):
				cands.append(d)
		cands.sort_custom(func(x, y): return world.p_center[x.prov].distance_squared_to(world.p_center[port]) < world.p_center[y.prov].distance_squared_to(world.p_center[port]))
		for d in cands:
			if need <= 0:
				break
			var path := Pathfinder.find_path(world, n, d.prov, port)
			if not path.is_empty() and path.size() <= 10:
				d.path = path
				d.progress = 0.0
				d.group = -1
				# резерв — на дорогу (пехота идёт ~0,28 провинции в день) и сбор
				d.reserved_until = world.day + int(path.size() * 1.5 / maxf(0.05, d.spd)) + 20
				need -= 1
		return
	var group := ready.slice(0, mini(6, ready.size()))
	if plan_invasion(world, group, best) == "":
		nat.inv_target = -1
		nat.inv_port = -1


static func _at_front(world: World, d: World.Division) -> bool:
	for q in world.p_adj[d.prov]:
		var c := world.p_controller[q]
		if c >= 0 and world.is_at_war(d.owner, c):
			return true
	return false
