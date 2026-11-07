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
const REGION_CELL := 220.0                       # размер воздушного района, пикс. карты
const AIR_RANGE := 260.0                         # дальность от своей территории, пикс.


# --- Подготовка ----------------------------------------------------------------

static func setup(world: World, dir: String) -> void:
	_build_regions(world)
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/forces.json"))
	var data: Dictionary = d.get("nations", {}) if typeof(d) == TYPE_DICTIONARY else {}
	world.p_naval_base.resize(world.prov_count)
	world.p_naval_base.fill(0)
	for nat in world.nations:
		var fd0: Dictionary = data.get(nat.tag, {})
		for ll in fd0.get("bases", []):
			var best := -1
			var best_d := INF
			for p in world.prov_count:
				if world.p_land[p] == 1 and world.p_coastal[p] == 1 and world.p_owner[p] == nat.id:
					var dd := world.p_lonlat[p].distance_squared_to(Vector2(float(ll[0]), float(ll[1])))
					if dd < best_d:
						best_d = dd
						best = p
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
				if surface[0] + surface[1] + surface[2] > 0:
					create_fleet(world, nat.id, home, surface, "Основной флот")
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
	world.region_center.resize(world.region_count)
	world.region_name.resize(world.region_count)
	world.region_anchor.resize(world.region_count)
	world.region_provs = []
	for r in world.region_count:
		world.region_center[r] = sums[r][0] / maxf(1.0, sums[r][1])
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


## Морская зона у главной базы флота страны (база в метрополии с наибольшими
## очками победы; если баз нет — у крупнейшего порта).
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


## Ближайшая военно-морская база стороны страны n (морская зона рядом с ней).
static func base_zone(world: World, n: int, from_zone: int) -> int:
	var dist := sea_dist(world, from_zone) if from_zone >= 0 else {}
	var best := -1
	var best_d := 1 << 20
	for p in world.prov_count:
		if world.p_naval_base.size() <= p or world.p_naval_base[p] == 0:
			continue
		var c := world.p_controller[p]
		if c < 0 or (c != n and world.ally[n * world.nation_count + c] == 0):
			continue
		for q in world.p_adj[p]:
			if world.p_land[q] == 0:
				var d: int = dist.get(q, 1 << 19) if from_zone >= 0 else 0
				if d < best_d:
					best_d = d
					best = q
	return best


static func at_base(world: World, f: World.Fleet) -> bool:
	for q in world.p_adj[f.zone]:
		if world.p_land[q] == 1 and world.p_naval_base.size() > q and world.p_naval_base[q] == 1:
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
	return fleet_power(f) * (0.3 + 0.7 * f.readiness)


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
	_build_ships(world)
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
	_refresh_cache(world)
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
	_trade_war(world, rng)
	_refresh_cache(world)


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
					raid += f.ships[SHIP_SS] * SHIP_POWER[SHIP_SS]
					raiders.append(f)
				elif world.ally[nat.id * world.nation_count + f.owner] == 1 and f.mission != "port":
					escort += f.ships[SHIP_DD] + f.ships[SHIP_CR] * 2.0
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
		if nat.stock[Military.EQ_SHIP] < SHIP_COST[t]:
			continue
		nat.stock[Military.EQ_SHIP] -= SHIP_COST[t]
		nat.ship_queue.pop_front()
		var target: World.Fleet = null
		for f in world.fleets:
			if f.alive and f.owner == nat.id and ((t == SHIP_SS) == (f.mission == "raid")):
				target = f
				break
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
	var parent := {from: from}
	var queue := [from]
	var head := 0
	while head < queue.size():
		var p: int = queue[head]
		head += 1
		if p == to:
			break
		for q in world.p_adj[p]:
			if world.p_land[q] == 0 and not parent.has(q):
				parent[q] = p
				queue.append(q)
	if not parent.has(to):
		return PackedInt32Array()
	var path := PackedInt32Array()
	var cur := to
	while cur != from:
		path.append(cur)
		cur = parent[cur]
	path.reverse()
	return path


## Расстояния по морю от зоны до всех зон (один проход в ширину).
static func sea_dist(world: World, from: int) -> Dictionary:
	var dist := {from: 0}
	var queue := [from]
	var head := 0
	while head < queue.size():
		var p: int = queue[head]
		head += 1
		for q in world.p_adj[p]:
			if world.p_land[q] == 0 and not dist.has(q):
				dist[q] = int(dist[p]) + 1
				queue.append(q)
	return dist


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
				if int(from_home.get(z, 99)) > 8:
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
					var l: int = from_here.get(z, 1 << 20)
					if l < best_len and l <= 12:
						best_len = l
						best = z
		else:
			var mine := fleet_power(f)
			for z in world.zone_fleets:
				var l: int = from_here.get(z, 1 << 20)
				if l > 8 or l >= best_len:
					continue
				var enemy := 0.0
				for o in world.zone_fleets[z]:
					if world.is_at_war(n, o.owner) and o.mission != "raid":
						enemy += fleet_power(o)
				if enemy > 0.0 and mine > enemy * 1.2:
					best_len = l
					best = z
			if best < 0 and f.zone != f.home:
				best = f.home
		if best >= 0 and best != f.zone:
			f.path = sea_path(world, f.zone, best)


## Блокада: порт не снабжает, если во всех соседних морских зонах господство у врага.
static func port_blockaded(world: World, n: int, p: int) -> bool:
	if world.fleets.is_empty():
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
	var home := {}
	var stack := [nat.capital]
	home[nat.capital] = true
	while not stack.is_empty():
		var p: int = stack.pop_back()
		for q in world.p_adj[p]:
			if world.p_land[q] == 1 and world.p_controller[q] == n and not home.has(q):
				home[q] = true
				stack.append(q)
	# заморский порт на фронте, где мало наших войск
	var dest := -1
	var dest_need := 0
	for p in world.prov_count:
		if world.p_controller[p] != n or home.has(p) or not is_port(world, p):
			continue
		var enemies := 0
		for q in world.p_adj[p]:
			var c := world.p_controller[q]
			if c >= 0 and world.is_at_war(n, c):
				enemies += 1
		if enemies == 0:
			continue
		var mine := 0
		for d in world.prov_divs[p]:
			if d.owner == n:
				mine += 1
		var need := 3 + enemies - mine
		if need > dest_need:
			dest_need = need
			dest = p
	if dest < 0:
		return
	# свободные дивизии в домашних портах
	var by_port := {}
	for d in world.divisions:
		if d.alive and d.owner == n and home.has(d.prov) and is_port(world, d.prov) and d.path.is_empty() \
				and not d.in_battle and d.transit_days == 0 and d.inv_plan < 0 and d.reserved_until < world.day \
				and not _at_front(world, d):
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
	for d in world.divisions:
		if d.alive:
			by_id[d.id] = d
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
	for d in world.divisions:
		if not d.alive or d.transit_days <= 0:
			continue
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
	# пополнение крыльев из резерва, новые крылья ИИ
	for nat in world.nations:
		if not nat.alive:
			continue
		for kind in 2:
			var eq := Military.EQ_FIG if kind == 0 else Military.EQ_BOMB
			for w in world.wings:
				if w.alive and w.owner == nat.id and w.kind == kind and w.planes < WING_MAX and nat.stock[eq] > 0.0:
					var add := minf(WING_MAX - w.planes, nat.stock[eq])
					w.planes += add
					nat.stock[eq] -= add
			var full := true
			for w in world.wings:
				if w.alive and w.owner == nat.id and w.kind == kind and w.planes < WING_MAX - 1.0:
					full = false
					break
			if not nat.is_player and full and nat.stock[eq] >= 100.0:
				var nw := create_wing(world, nat.id, kind, world.p_region[nat.capital])
				nw.planes = minf(WING_MAX, nat.stock[eq])
				nat.stock[eq] -= nw.planes
				nw.mission = "sup" if kind == 0 else "cas"
	# районы с авиацией
	var by_region := {}
	for w in world.wings:
		if w.alive and w.planes >= 1.0 and w.region >= 0:
			if not by_region.has(w.region):
				by_region[w.region] = []
			by_region[w.region].append(w)
	for r in by_region:
		var here: Array = by_region[r]
		# для каждой страны: свои и вражеские истребители в районе
		var owners := {}
		for w in here:
			owners[w.owner] = true
		for n in owners:
			var own_f := 0.0
			var en_f := 0.0
			var own_b := 0.0
			for w in here:
				if w.kind == 0:
					if world.ally[n * nc + w.owner] == 1:
						own_f += w.planes
					elif world.is_at_war(n, w.owner):
						en_f += w.planes
				elif w.mission == "cas" and world.ally[n * nc + w.owner] == 1:
					own_b += w.planes
			var sup := 0.5 if own_f + en_f <= 0.0 else own_f / (own_f + en_f)
			world.air_sup[r * nc + n] = sup
			var m := 1.0 + minf(0.4, own_b * sup / 600.0)
			if sup < 0.3:
				m -= 0.15   # противник господствует в воздухе
			world.cas_mult[r * nc + n] = m
		# воздушные бои: потери от вражеских истребителей
		for w in here:
			var en_f := 0.0
			var own_f := 0.0
			for o in here:
				if o.kind == 0:
					if world.is_at_war(w.owner, o.owner):
						en_f += o.planes
					elif world.ally[w.owner * nc + o.owner] == 1:
						own_f += o.planes
			if en_f <= 0.0:
				continue
			var rate := 0.004 if w.kind == 0 else 0.008 * en_f / (en_f + own_f + 1.0)
			w.planes = maxf(0.0, w.planes - en_f * rate * rng.randf_range(0.6, 1.4) * (WING_MAX / maxf(WING_MAX, en_f + own_f)) * 3.0)
			if w.planes < 1.0:
				w.alive = false
				if world.nations[w.owner].is_player:
					world.log_event("Уничтожено: %s" % w.name)
		# стратегические бомбардировки и удары по флоту
		for w in here:
			if w.kind != 1:
				continue
			var sup: float = world.air_sup[r * nc + w.owner]
			if w.mission == "bomb":
				_bomb_factories(world, w, r, sup, rng)
			elif w.mission == "naval":
				var dmg: float = w.planes * 0.002 * sup
				for zone in world.zone_fleets:
					if world.p_region[zone] != r:
						continue
					var targets: Array = []
					for f in world.zone_fleets[zone]:
						if world.is_at_war(w.owner, f.owner):
							targets.append(f)
					if not targets.is_empty():
						_take_losses(world, targets, dmg, rng)


static func _bomb_factories(world: World, w: World.AirWing, r: int, sup: float, rng: RandomNumberGenerator) -> void:
	if rng.randf() > w.planes / 1500.0 * sup:
		return
	var cands: Array = []
	for p in world.region_provs[r]:
		if world.p_land[p] == 1 and world.is_at_war(w.owner, world.p_controller[p]) \
				and world.p_civ[p] + world.p_mil[p] > 0:
			cands.append(p)
	if cands.is_empty():
		return
	var p: int = cands[rng.randi() % cands.size()]
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
	var nat: World.Nation = world.nations[n]
	var has_wing := false
	for w in world.wings:
		if w.alive and w.owner == n:
			has_wing = true
			break
	if not has_wing:
		return
	var front_count := {}
	if not nat.at_war.is_empty():
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
	var regions := front_count.keys()
	regions.sort_custom(func(a, b): return front_count[a] > front_count[b])
	var reach := regions_in_range(world, n) if bomb_target >= 0 else {}
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
	var enemy := -1
	for e in nat.at_war.keys() + nat.wargoals.keys() + nat.planned_wars.keys():
		if world.nations[e].alive and not reach.has(e) and nat.division_count > world.nations[e].division_count * 1.5:
			enemy = e
			break
	if enemy < 0:
		return
	var my_navy := 0.0
	var their_navy := 0.0
	for f in world.fleets:
		if f.alive and f.owner == n:
			my_navy += fleet_power(f)
		elif f.alive and world.ally[enemy * world.nation_count + f.owner] == 1:
			their_navy += fleet_power(f)
	if my_navy <= 0.0 or their_navy > my_navy:
		return   # против сильного флота десант обречён
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
			var score: float = world.prov_divs[p].size() * 25.0 - world.p_vp[p] * 2.0 - (8.0 if world.p_vp[p] >= 3 else 0.0) + rng.randf()
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
				d.reserved_until = world.day + 40
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
