class_name Forces
extends RefCounted
## Флот и авиация: корабли и флоты в морских зонах, морские бои, господство на
## море, блокада портов, рейды подлодок по торговле, морские высадки;
## авиакрылья над воздушными районами: превосходство, поддержка войск,
## стратегические бомбардировки, удары по флоту.

# категории кораблей (решение пользователя): подлодки, крейсеры (все надводные
# боевые корабли), авианосцы; проекты — ShipDesigns
const SHIP_SS := 0
const SHIP_CR := 1
const SHIP_CV := 2
const SHIP_NAMES := ["Подлодки", "Крейсеры", "Авианосцы"]
const SHIP_ONE := ["подлодка", "крейсер", "авианосец"]
const FLEET_MAX := 30         # кораблей в одном соединении (решение пользователя)
const NAVY_WIDTH := 10        # соединений одной стороны в морском бою (по умолчанию; решение пользователя)
const NAVY_DMG := 0.035       # урон за день: огонь стороны × NAVY_DMG
const NAVY_AA := 20.0         # ПВО цели ослабляет удар авиагрупп: × NAVY_AA / (NAVY_AA + ПВО)
const NAVY_ASW := 1.5         # ПЛО против подлодок (огонь надводных по ним — ×NAVY_SUB_GUN)
const NAVY_SUB_GUN := 0.3
const NAVY_SUB_ATK := 0.5     # торпеды подлодок против боевых кораблей (не конвоев) — вполсилы
const NAVY_ESCORT := 2.0      # охранение торговли: ПЛО × 2 + надводных кораблей × 2 (эсминец ≈ 3–3,6)
const WING_MAX := 100.0       # самолётов в крыле (решение пользователя)
const AIR_PACK := 100.0       # в бою неполные крылья стороны сливаются в пачки до 100
const AIR_WIDTH := 10         # пачек одной стороны в бою над районом (потом — от ширины района)
const AIR_KILL := 0.015
const AIR_LOSS_MAX := 0.02    # потери пачки за день — не больше 2 % (решение пользователя: 1–2 %)
const AIR_DETECT := 0.6       # шанс пачки обнаружить противника днём (радары — бонус air_detect)
const CAS_MAX := 0.15         # надбавка штурмовиков к силе своих войск в бою — до 15 % (решение пользователя)
const AIR_NIGHT := 0.5        # ночью обнаружение и координация — вдвое ниже       # сбитых за день: самолёты в бою × атака × AIR_KILL / защита цели
const AIR_SUP_PENALTY := 0.3   # сила войск при полном господстве противника в воздухе: −30 %
const AIR_SUP_FULL := 3000.0   # сила истребителей обеих сторон (самолёты × (атака + защита)) для полного эффекта
# стратегические бомбардировки: повреждения провинции (0..1) снижают её
# пропускную способность снабжения до −BOMB_SUPPLY и чинятся по BOMB_REPAIR в день
const BOMB_SUPPLY := 0.6
const BOMB_REPAIR := 0.01
const BOMB_HUB := 0.3          # удар по узлу снабжения района (главный город)
const BOMB_RAIL := 0.2         # удар по железной дороге и инфраструктуре провинции
# бомбардировщики бьют только по постройкам; войска не трогают (решение
# пользователя), максимум — людской ресурс: потери от налёта на завод или
# город = население провинции (тыс.) × BOMB_MANPOWER
const BOMB_MANPOWER := 0.001
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
			ShipDesigns.ai_update(world, nat)   # стартовые проекты: корпуса без технологий
			_setup_navy(world, nat, navy, fd.get("squadrons", []), base_provs.get(nat.tag, []))
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
	Convoys.setup(world, data)
	Convoys.setup_straits(world, d.get("straits", []) if typeof(d) == TYPE_DICTIONARY else [])
	_refresh_cache(world)


## Стартовый флот страны: надводные корабли (bb/cr/dd/cv) — по базам
## (squadrons: доли), подлодки (ss) — у главной базы; каждое соединение — не
## больше FLEET_MAX кораблей (лишние — в следующие соединения той же базы).
static func _setup_navy(world: World, nat: World.Nation, navy: Dictionary, squads: Array, bl2: Array) -> void:
	var home := home_zone(world, nat.id)
	if home < 0:
		return
	var keys := ["bb", "cr", "cv", "dd"]
	var surface := PackedInt32Array()
	for key in keys:
		surface.append(int(navy.get(key, 0)))
	var total := 0
	for v in surface:
		total += v
	if total > 0:
		if squads.is_empty():
			squads = [["Основной флот", -1, 1.0]]
		# деление по базам: доля кораблей каждого типа, остаток — первой базе
		var left := surface.duplicate()
		var made: Array = []
		for i in squads.size():
			var sq: Array = squads[i]
			var zone := home
			var bi := int(sq[1])
			if bi >= 0 and bi < bl2.size() and int(bl2[bi]) >= 0:
				for q in world.p_adj[int(bl2[bi])]:
					if world.p_land[q] == 0:
						zone = q
						break
			var part := PackedInt32Array()
			part.resize(keys.size())
			if i > 0:
				for t in keys.size():
					part[t] = mini(left[t], int(round(surface[t] * float(sq[2]))))
					left[t] -= part[t]
			made.append([zone, part, String(sq[0]), float(sq[2])])
		made[0][1] = left
		for m in made:
			var pairs: Array = []
			var pp: PackedInt32Array = m[1]
			for t in keys.size():
				var did: int = nat.ship_role[ShipDesigns.ROLE_OF_KEY[keys[t]]]
				if pp[t] > 0 and did >= 0:
					pairs.append([did, pp[t]])
			_make_formations(world, nat.id, int(m[0]), pairs, String(m[2]), float(m[3]), "patrol")
	var ss := int(navy.get("ss", 0))
	if ss > 0 and nat.ship_role[3] >= 0:
		_make_formations(world, nat.id, home, [[nat.ship_role[3], ss]], "Подводные силы", 1.0, "raid")


## Корабли [[проект, число], …] — в соединения по FLEET_MAX: корабли раздаются
## по кругу (у каждого соединения — свой набор всех типов); доля базы делится.
static func _make_formations(world: World, n: int, zone: int, pairs: Array, name: String, share: float, mission: String) -> void:
	var total := 0
	for pr in pairs:
		total += int(pr[1])
	if total <= 0:
		return
	var k := (total + FLEET_MAX - 1) / FLEET_MAX
	var fl: Array = []
	for i in k:
		var f := create_fleet(world, n, zone, name if i == 0 else "%s, %d-е соединение" % [name, i + 1])
		f.share = share / k
		f.mission = mission
		fl.append(f)
	var idx := 0
	for pr in pairs:
		for j in int(pr[1]):
			add_ships(world, fl[idx % k], int(pr[0]), 1)
			idx += 1


## Сохранение версии 1 (корабли — 4 типа без проектов): флотам — основные
## проекты ролей, очереди верфей — пустые.
static func migrate_v1(world: World) -> void:
	for nat in world.nations:
		if nat.alive and nat.ship_role[0] < 0:
			ShipDesigns.ai_update(world, nat)
		nat.ship_queue = []
	var roles := [2, 1, 0, 3]   # линкоры, крейсеры, эсминцы, подлодки
	for f in world.fleets:
		if f.designs.is_empty() and f.ships.size() == 4:
			var old: PackedInt32Array = f.ships
			f.ships = PackedInt32Array([0, 0, 0])
			for k in 4:
				var did: int = world.nations[f.owner].ship_role[roles[k]]
				if old[k] > 0 and did >= 0:
					f.designs.append(did)
					f.counts.append(old[k])
			recount(world, f)
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


static func create_fleet(world: World, n: int, zone: int, name: String) -> World.Fleet:
	var f := World.Fleet.new()
	f.id = world.fleets.size()
	f.owner = n
	f.zone = zone
	f.home = zone
	f.name = name
	world.fleets.append(f)
	return f


## Добавить cnt кораблей проекта did в соединение (без проверки FLEET_MAX).
static func add_ships(world: World, f: World.Fleet, did: int, cnt: int) -> void:
	var i := f.designs.find(did)
	if i < 0:
		f.designs.append(did)
		f.counts.append(cnt)
	else:
		f.counts[i] += cnt
	recount(world, f)


## Пересчитать сводку соединения по составу; пустые проекты убираются.
static func recount(world: World, f: World.Fleet) -> void:
	var nd := PackedInt32Array()
	var nc := PackedInt32Array()
	var ships := PackedInt32Array([0, 0, 0])
	var pw := 0.0
	var spw := 0.0
	var atk := 0.0
	var air := 0.0
	var asw := 0.0
	var aa := 0.0
	var raid := 0.0
	var st := 0.0
	var satk := 0.0
	var fam := PackedFloat64Array()
	fam.resize(ShipDesigns.FAMS)
	for i in f.designs.size():
		var c: int = f.counts[i]
		if c <= 0:
			continue
		nd.append(f.designs[i])
		nc.append(c)
		var d: Dictionary = world.ship_designs[f.designs[i]]
		var k: int = d["kind"]
		ships[k] += c
		pw += float(d["power"]) * c
		fam[int(d["fam"])] += float(d["power"]) * c
		atk += float(d["atk"]) * c
		air += float(d["air"]) * c
		asw += float(d["asw"]) * c
		aa += float(d["aa"]) * c
		raid += float(d["raid"]) * c
		if k == SHIP_SS:
			spw += float(d["power"]) * c
			satk += float(d["atk"]) * c
			st += float(d["stealth"]) * c
	f.designs = nd
	f.counts = nc
	f.ships = ships
	f.power = pw
	f.fam_power = fam
	f.sub_power = spw
	f.atk = atk
	f.sub_atk = satk
	f.air = air
	f.asw = asw
	f.aa = aa
	f.raid = raid
	f.stealth = st / ships[SHIP_SS] if ships[SHIP_SS] > 0 else 0.0
	if ships[0] + ships[1] + ships[2] == 0 and f.alive:
		f.alive = false


static func create_wing(world: World, n: int, kind: int, region: int) -> World.AirWing:
	var w := World.AirWing.new()
	w.id = world.wings.size()
	w.owner = n
	w.kind = kind
	w.region = region
	w.design = world.nations[n].air_design[kind]
	var cnt := 1
	for o in world.wings:
		if o.owner == n and o.kind == kind:
			cnt += 1
	w.name = "%d-е %s" % [cnt, "истребительное крыло" if kind == 0 else "бомбардировочное крыло"]
	world.wings.append(w)
	return w


static func fleet_power(f: World.Fleet) -> float:
	return f.power


## Боевая сила с учётом готовности (после боёв — ниже, пока флот не на базе).
static func combat_power(f: World.Fleet) -> float:
	return fleet_power(f) * f.quality * (0.3 + 0.7 * f.readiness)


## Качество флотов по технологиям страны: среднее по силе кораблей каждого рода.
static func refresh_quality(world: World) -> void:
	var ns := world.n_ship
	var nf := ShipDesigns.FAMS
	if ns.size() != world.nation_count * nf:
		return
	for f in world.fleets:
		if not f.alive:
			continue
		var fp: PackedFloat64Array = f.fam_power
		if fp.size() != nf:
			recount(world, f)
			fp = f.fam_power
		var base := 0.0
		var q := 0.0
		var o: int = f.owner * nf
		for k in nf:
			base += fp[k]
			q += fp[k] * ns[o + k]
		f.quality = q / base if base > 0.0 else 1.0


static func fleet_size(f: World.Fleet) -> int:
	return f.ships[0] + f.ships[1] + f.ships[2]


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
	Convoys.build(world)
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
		if f.readiness < 1.0:
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
		# в бою у стороны — не больше NAVY_WIDTH соединений (самые сильные)
		side_a = _battle_line(side_a)
		side_b = _battle_line(side_b)
		var sa := _side_fire(side_a)
		var sb := _side_fire(side_b)
		var pa: float = sa[0]
		var pb: float = sb[0]
		var r := world.p_region[zone]
		var nc := world.nation_count
		var ra := rng.randf_range(0.7, 1.3) * world.cas_mult[r * nc + side_b[0].owner]
		var rb := rng.randf_range(0.7, 1.3) * world.cas_mult[r * nc + a.owner]
		# урон по надводным: огонь + удар авиагрупп (ослаблен ПВО цели);
		# по подлодкам: ПЛО и немного огня, минус скрытность
		var da_s: float = (float(sb[1]) + float(sb[2]) * NAVY_AA / (NAVY_AA + float(sa[4]))) * NAVY_DMG * ra
		var db_s: float = (float(sa[1]) + float(sa[2]) * NAVY_AA / (NAVY_AA + float(sb[4]))) * NAVY_DMG * rb
		var da_u: float = (float(sb[3]) * NAVY_ASW + float(sb[1]) * NAVY_SUB_GUN) * NAVY_DMG * ra * (1.0 - float(sa[5]))
		var db_u: float = (float(sa[3]) * NAVY_ASW + float(sa[1]) * NAVY_SUB_GUN) * NAVY_DMG * rb * (1.0 - float(sb[5]))
		_take_losses(world, side_a, da_s, rng, 0)
		_take_losses(world, side_a, da_u, rng, 1)
		_take_losses(world, side_b, db_s, rng, 0)
		_take_losses(world, side_b, db_u, rng, 1)
		var da := da_s + da_u
		var db := db_s + db_u
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
	Convoys.daily(world, rng)
	Depots.daily(world)   # пункты снабжения: участки, склады за морем, подвоз снаряжения
	_refresh_cache(world)
	Prof.add("флот:торговля", _pt)


## Соединения стороны в бою: не больше NAVY_WIDTH, самые сильные (при
## равенстве — меньший номер); остальные в зоне этот день не дерутся.
static func _battle_line(side: Array) -> Array:
	if side.size() <= NAVY_WIDTH:
		return side
	var s := side.duplicate()
	s.sort_custom(func(x, y):
		var px := combat_power(x)
		var py := combat_power(y)
		return px > py or (px == py and x.id < y.id))
	return s.slice(0, NAVY_WIDTH)


## Сводка стороны: [сила, огонь, авиагруппы, ПЛО, ПВО, скрытность подлодок]
## (с качеством и готовностью); соединения отмечаются участниками боя.
static func _side_fire(side: Array) -> Array:
	var pw := 0.0
	var gun := 0.0
	var air := 0.0
	var asw := 0.0
	var aa := 0.0
	var st := 0.0
	var subs := 0
	for f in side:
		f.in_battle = true
		var rf: float = f.quality * (0.3 + 0.7 * f.readiness)
		pw += f.power * rf
		gun += (f.atk - f.sub_atk * (1.0 - NAVY_SUB_ATK)) * rf
		air += f.air * rf
		asw += f.asw * rf
		aa += f.aa * rf
		st += f.stealth * f.ships[SHIP_SS]
		subs += f.ships[SHIP_SS]
	return [pw, gun, air, asw, aa, st / subs if subs > 0 else 0.0]


## Потери стороны: урон dmg «съедает» корабли по живучести — сначала эскорты
## и подлодки, потом крейсеры, линкоры и авианосцы (очередь корпуса).
## target: 0 — надводные, 1 — подлодки, -1 — все.
static func _take_losses(world: World, side: Array, dmg: float, rng: RandomNumberGenerator, target := -1) -> void:
	while dmg > 0.0:
		var hit := false
		for level in 4:
			for f in side:
				if not f.alive:
					continue
				var changed := false
				for i in f.designs.size():
					if dmg <= 0.0 or f.counts[i] <= 0:
						continue
					var d: Dictionary = world.ship_designs[f.designs[i]]
					if int(d["prio"]) != level or (target == 0 and int(d["kind"]) == SHIP_SS) or (target == 1 and int(d["kind"]) != SHIP_SS):
						continue
					var cost: float = d["def"]
					if dmg >= cost or rng.randf() < dmg / cost:
						f.counts[i] -= 1
						hit = true
						changed = true
					dmg -= cost
				if changed:
					recount(world, f)
					if not f.alive:
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
			# ИИ: эсминцы, подлодки, крейсеры; великие державы — ещё линкоры и
			# авианосцы (если они уже есть или изучена технология авианосцев)
			var cycle := [0, 3, 0, 1]
			if nat.major:
				cycle.append(2)
				if nat.techs.has("cv1") or _has_kind(world, nat.id, SHIP_CV):
					cycle.append(0)
					cycle.append(4)
			var did: int = nat.ship_role[cycle[(world.day / 7 + nat.id) % cycle.size()]]
			if did >= 0:
				nat.ship_queue.append(did)
		if nat.ship_queue.is_empty():
			continue
		var did0: int = nat.ship_queue[0]
		if did0 < 0 or did0 >= world.ship_designs.size():
			nat.ship_queue.pop_front()
			continue
		var d: Dictionary = world.ship_designs[did0]
		var cost: float = float(d["cost"]) / (1.0 + maxf(0.0, nat.b("shipyard")))   # технологии верфей
		if nat.stock[Military.EQ_SHIP] < cost:
			continue
		nat.stock[Military.EQ_SHIP] -= cost
		nat.ship_queue.pop_front()
		var target := place_ship(world, nat.id, did0)
		if nat.is_player and target != null:
			world.log_event("Спущен на воду: %s «%s» (%s)" % [SHIP_ONE[int(d["kind"])], d["name"], target.name])


static func _has_kind(world: World, n: int, kind: int) -> bool:
	for f in world.fleets:
		if f.alive and f.owner == n and f.ships[kind] > 0:
			return true
	return false


## Новый корабль — в соединение своего рода (подлодки — к рейдерам), где ещё
## есть место (FLEET_MAX) и меньше всего сил относительно доли базы; все полны —
## новое соединение у базы самого слабого из них.
static func place_ship(world: World, n: int, did: int) -> World.Fleet:
	var sub: bool = int(world.ship_designs[did]["kind"]) == SHIP_SS
	var target: World.Fleet = null
	var full: World.Fleet = null
	var tp := INF
	var fpf := INF
	for f in world.fleets:
		if f.alive and f.owner == n and (sub == (f.mission == "raid")):
			var fp := fleet_power(f) / maxf(0.05, f.share)
			if fleet_size(f) < FLEET_MAX:
				if fp < tp:
					tp = fp
					target = f
			elif fp < fpf:
				fpf = fp
				full = f
	if target == null:
		var home := home_zone(world, n) if full == null else full.home
		if home < 0:
			return null
		var base := ("Подводные силы" if sub else "Основной флот") if full == null else full.name.get_slice(",", 0)
		var cnt := 1
		for f in world.fleets:
			if f.alive and f.owner == n and f.name.get_slice(",", 0) == base:
				cnt += 1
		target = create_fleet(world, n, home, base if cnt == 1 else "%s, %d-е соединение" % [base, cnt])
		if full != null:
			target.share = full.share
			target.zone = full.home
		if sub:
			target.mission = "raid"
	add_ships(world, target, did, 1)
	return target


## Разделить соединение: половина кораблей каждого проекта — в новое
## соединение в той же зоне. Пусто — null.
static func split_fleet(world: World, f: World.Fleet) -> World.Fleet:
	if fleet_size(f) < 2:
		return null
	var base := f.name.get_slice(",", 0)
	var cnt := 1
	for o in world.fleets:
		if o.alive and o.owner == f.owner and o.name.get_slice(",", 0) == base:
			cnt += 1
	var nf := create_fleet(world, f.owner, f.zone, "%s, %d-е соединение" % [base, cnt])
	nf.home = f.home
	nf.mission = f.mission
	nf.readiness = f.readiness
	nf.quality = f.quality
	nf.share = f.share * 0.5
	f.share *= 0.5
	var moved := 0
	var half := fleet_size(f) / 2
	for i in f.designs.size():
		var take := f.counts[i] / 2
		if moved + take > half:
			take = half - moved
		if take > 0:
			f.counts[i] -= take
			nf.designs.append(f.designs[i])
			nf.counts.append(take)
			moved += take
	# все корабли одного проекта по одному — отдаём первый
	if moved == 0:
		f.counts[0] -= 1
		nf.designs.append(f.designs[0])
		nf.counts.append(1)
	recount(world, f)
	recount(world, nf)
	return nf


## Влить в f соединения владельца из той же зоны — пока в f есть место
## (FLEET_MAX). Возвращает, сколько кораблей перешло.
static func merge_here(world: World, f: World.Fleet) -> int:
	var moved := 0
	for o in world.fleets:
		if o == f or not o.alive or o.owner != f.owner or o.zone != f.zone:
			continue
		for i in o.designs.size():
			var room := FLEET_MAX - fleet_size(f)
			if room <= 0:
				break
			var take := mini(room, o.counts[i])
			if take <= 0:
				continue
			o.counts[i] -= take
			add_ships(world, f, o.designs[i], take)
			moved += take
		recount(world, o)
		if not o.alive:
			f.share += o.share
	f.readiness = minf(f.readiness, 1.0)
	_refresh_cache(world)
	return moved


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
	# соединения одной базы действуют вместе: сила группы — сумма их сил
	var group := {}
	for f in world.fleets:
		if f.alive and f.owner == n and f.mission != "raid":
			group[f.home] = float(group.get(f.home, 0.0)) + fleet_power(f)
	var dists := {}   # зона -> sea_dist (у соединений одной базы зоны общие)
	# силы противника по зонам: без рейдеров и все (флоты противника в этом
	# проходе не меняются — считаем один раз); «рядом с базой» — по базам
	var en_nr := {}
	var en_all := {}
	var raiders := {}   # свои торговые зоны с рейдерами противника — охота соединениями с ПЛО
	if not nat.at_war.is_empty():
		var own_tz := trade_zones(world, n).duplicate()
		for z in nat.conv_zone_set:
			own_tz[z] = true   # и на путях своих конвоев
		for z in world.zone_fleets:
			var a := 0.0
			var b := 0.0
			var rd := false
			for o in world.zone_fleets[z]:
				if world.is_at_war(n, o.owner):
					b += fleet_power(o)
					if o.mission != "raid":
						a += fleet_power(o)
					else:
						rd = true
			if b > 0.0:
				en_all[z] = b
				if a > 0.0:
					en_nr[z] = a
				if rd and own_tz.has(z):
					raiders[z] = true
	var near := {}
	var paths := {}   # (откуда, куда) -> путь: соединения одной зоны идут вместе
	for f in world.fleets:
		if not f.alive or f.owner != n or not f.path.is_empty() or f.task_until >= world.day:
			continue
		if nat.at_war.is_empty():
			if f.zone != f.home:
				f.path = _cached_path(world, paths, f.zone, f.home)
			f.mission = "raid" if f.ships[SHIP_SS] > 0 and f.ships[SHIP_SS] == fleet_size(f) else "patrol"
			continue
		if f.mission == "port" and f.zone == f.home:
			f.mission = "raid" if f.sub_power >= fleet_power(f) * 0.9 else "patrol"
		var best := -1
		var best_len := 1 << 20
		if not dists.has(f.zone):
			dists[f.zone] = sea_dist(world, f.zone)
		var from_here: PackedInt32Array = dists[f.zone]
		# слабый флот отстаивается в порту, пока рядом сильный враг («флот как угроза»)
		if f.mission != "raid":
			if not dists.has(f.home):
				dists[f.home] = sea_dist(world, f.home)
			var from_home: PackedInt32Array = dists[f.home]
			if not near.has(f.home):
				var ne := 0.0
				for z in en_nr:
					var fh: int = from_home[z]
					if fh >= 0 and fh <= 8:
						ne += float(en_nr[z])
				near[f.home] = ne
			var near_enemy: float = near[f.home]
			if near_enemy > float(group.get(f.home, fleet_power(f))):
				if f.zone != f.home:
					f.path = _cached_path(world, paths, f.zone, f.home)
				f.mission = "port"
				continue
		if f.mission == "port" and f.zone == f.home:
			f.mission = "raid" if f.sub_power >= fleet_power(f) * 0.9 else "patrol"
		if f.mission == "raid":
			# рейдеры — на пути конвоев противника (нет путей — к его портам)
			for e in nat.at_war:
				for z in Convoys.target_zones(world, e):
					var l: int = from_here[z] if from_here[z] >= 0 else 1 << 20
					if l < best_len and l <= 12:
						best_len = l
						best = z
		else:
			# охота — в своём районе (до 8 зон от базы), без цели — блокада
			# ближайших к базе вражеских портов (держит дальнюю блокаду торговли)
			var mine := float(group.get(f.home, fleet_power(f)))
			if not dists.has(f.home):
				dists[f.home] = sea_dist(world, f.home)
			var from_base: PackedInt32Array = dists[f.home]
			# флот, поделённый по базам (доля < 1), держит свой район — 5 зон
			var reach_n := 8 if f.share >= 0.99 else 5
			for z in en_nr:
				var l: int = from_here[z] if from_here[z] >= 0 else 1 << 20
				if l >= best_len or from_base[z] < 0 or from_base[z] > reach_n:
					continue
				var enemy: float = en_nr[z]
				if mine > enemy * 1.2:
					best_len = l
					best = z
			# рейдеры у своих портов: идут соединения с ПЛО (если надводный
			# противник там не сильнее)
			if best < 0 and f.asw > 0.0:
				for z in raiders:
					var l: int = from_here[z] if from_here[z] >= 0 else 1 << 20
					if l < best_len and l <= 12 and float(en_nr.get(z, 0.0)) * 1.2 < mine:
						best_len = l
						best = z
			if best < 0:
				var bl3 := reach_n + 1
				for e in nat.at_war:
					for z in trade_zones(world, e):
						var dz: int = from_base[z]
						if dz >= 0 and dz < bl3:
							# не лезть под более сильный флот противника
							var enemy2: float = en_all.get(z, 0.0)
							if enemy2 * 1.2 < mine:
								bl3 = dz
								best = z
			if best < 0 and f.zone != f.home:
				best = f.home
		if best >= 0 and best != f.zone:
			f.path = _cached_path(world, paths, f.zone, best)


static func _cached_path(world: World, cache: Dictionary, from: int, to: int) -> PackedInt32Array:
	var key := from * 1048576 + to
	if not cache.has(key):
		cache[key] = sea_path(world, from, to)
	# копия: упакованные массивы передаются по ссылке, а путь флота укорачивается на месте
	return (cache[key] as PackedInt32Array).duplicate()


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
## колонии), куда не дойти по суше от столицы. Обычно — до 3 дивизий за раз из
## домашних портов. С чертой `expedition` (доля армии на заморском фронте —
## японские армии в Китае) — сколько нужно фронту, до EXP_BATCH за раз, из
## любых своих тыловых портов (метрополия, Корея, Тайвань), пока дома остаётся
## больше (1 − доля) армии.
const EXP_BATCH := 12
const EXP_PORT := 4
const EXP_MIN_ZONE := 6

static func ai_transfers(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	if nat.at_war.is_empty():
		return
	var exp_share := clampf(nat.b("expedition"), 0.0, 0.95)
	# провинции, связанные со столицей по суше
	var home: PackedByteArray = own_reach(world, n, nat.capital)[0]
	var ctrl := world.p_controller
	var a_start := world.adj_start
	var a_list := world.adj_list
	var war := world.war
	var nc := world.nation_count
	# заморские порты на фронте и сколько им не хватает
	var dests: Array = []   # [нужно, порт]
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
		if exp_share > 0.0:
			# экспедиция: участок у порта — до ёмкости снабжения, но не в малый
			# плацдарм (меньше EXP_MIN_ZONE своих провинций по суше): там без пути
			# отхода гибнет всё, что туда привезли (Нинбо, 1938 г.: 21 дивизия);
			# союзные провинции считаются — туда можно отступить (Тяньцзинь у Маньчжоу-го)
			var zn := _side_zone(world, n, p, EXP_MIN_ZONE)
			if zn >= EXP_MIN_ZONE:
				var cap := int(world.p_supcap[p]) if p < world.p_supcap.size() else 0
				need = maxi(need, cap + enemies - mine)
		if need > 0:
			dests.append([need, p])
	if dests.is_empty():
		return
	dests.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	# свободные дивизии в тыловых портах: дома, а с экспедицией — и в других своих
	# землях без фронта, откуда до цели не дойти по суше
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
	var at_home := 0
	var total := 0
	for i in own.size():
		if own[i] != n or alive[i] == 0:
			continue
		total += 1
		if home[dprov[i]] == 1:
			at_home += 1
		if nxt[i] >= 0 or tr[i] != 0 or inv[i] >= 0 or resv[i] >= day or bt[i] != 0 or not is_port(world, dprov[i]):
			continue
		if home[dprov[i]] == 0 and (exp_share <= 0.0 or ctrl[dprov[i]] != n):
			continue
		var d: World.Division = world.divisions[i]
		if not _at_front(world, d):
			if not by_port.has(d.prov):
				by_port[d.prov] = []
			by_port[d.prov].append(d)
	if exp_share <= 0.0:
		var dest: int = dests[0][1]
		var dest_need: int = dests[0][0]
		for port in by_port:
			var group: Array = by_port[port].slice(0, mini(dest_need, 3))
			if sea_transfer(world, group, dest) == "":
				if Diplomacy.is_major(world, n) or nat.is_player:
					world.log_event("%s: переправа %d див. → %s" % [nat.name, group.size(), world.p_name[dest]])
				return
		return
	# экспедиция: дома держим (1 − доля) армии
	var spare := at_home - int(ceil(float(total) * (1.0 - exp_share)))
	var budget := mini(EXP_BATCH, spare)
	if budget <= 0:
		return
	var ports := by_port.keys()
	ports.sort()
	var sent := 0
	for dd in dests:
		var dest: int = dd[1]
		var need: int = dd[0]
		# до цели по суше не дойти — иначе дивизии и так дойдут сами
		var reach_d: PackedByteArray = own_reach(world, n, dest)[0]
		for port in ports:
			if need <= 0 or budget <= 0:
				break
			if reach_d[port] == 1:
				continue
			var lst: Array = by_port[port]
			if lst.is_empty():
				continue
			var k := mini(mini(need, budget), EXP_PORT)
			var group: Array = lst.slice(0, k)
			if sea_transfer(world, group, dest) == "":
				by_port[port] = lst.slice(k)
				need -= k
				budget -= k
				sent += k
		if budget <= 0:
			break
	if sent > 0 and (Diplomacy.is_major(world, n) or nat.is_player):
		world.log_event("%s: переправа %d див. на заморский фронт" % [nat.name, sent])


static func _own_divs(world: World, n: int, p: int) -> int:
	var k := 0
	var h := world.pl_head[p]
	while h >= 0:
		if world.d_owner[h] == n:
			k += 1
		h = world.d_nx[h]
	return k


## Сколько провинций своей стороны (свои и союзные) связано по суше с p — до limit.
static func _side_zone(world: World, n: int, p: int, limit: int) -> int:
	var seen := {p: true}
	var queue: Array = [p]
	var head := 0
	while head < queue.size() and seen.size() < limit:
		var x: int = queue[head]
		head += 1
		for q in world.p_adj[x]:
			if seen.has(q) or world.p_land[q] == 0:
				continue
			var c := world.p_controller[q]
			if c >= 0 and (c == n or Diplomacy.same_side(world, c, n)):
				seen[q] = true
				queue.append(q)
	return seen.size()


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


static var _air_job := {}
static var _air_res: Array = []
static var _air_gid := -1


## Воздушная фаза за день целиком (тесты и разовые вызовы).
static func daily_air(world: World, rng: RandomNumberGenerator) -> void:
	air_begin(world)
	air_finish(world, rng)


## Начало воздушной фазы (главный поток, после фазы флота): ремонт после
## бомбёжек, пополнение крыльев, снимок крыльев районов, где воюют, в плоские
## массивы и запуск расчёта районов в фоне (ядро C++ или GDScript-двойник).
static func air_begin(world: World) -> void:
	repair_bombing(world)
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
					# пополнение больше половины крыла — крыло переходит на новый проект
					if add >= w.planes:
						w.design = nat.air_design[kind]
					w.planes += add
					nat.stock[eq] -= add
			var full := true
			for w in own:
				if w.kind == kind and w.planes < WING_MAX - 1.0:
					full = false
					break
			if not nat.is_player and full and nat.stock[eq] >= WING_MAX:
				var nw := create_wing(world, nat.id, kind, world.p_region[nat.capital])
				nw.planes = minf(WING_MAX, nat.stock[eq])
				nat.stock[eq] -= nw.planes
				nw.mission = "sup" if kind == 0 else "cas"
	Prof.add("авиа:пополнение", _pt)
	_pt = Time.get_ticks_usec()
	var nc := world.nation_count
	var by_region := {}
	for w in world.wings:
		if w.alive and w.planes >= 1.0 and w.region >= 0:
			if not by_region.has(w.region):
				by_region[w.region] = []
			by_region[w.region].append(w)
	var qa := world.n_air   # качество авиации по технологиям: страна×4
	var regions := PackedInt32Array()
	var rstart := PackedInt32Array([0])
	var seeds := PackedInt64Array()
	var wl: Array = []
	var ow := PackedInt32Array()
	var kd := PackedInt32Array()
	var wid := PackedInt32Array()
	var pl := PackedFloat64Array()
	var ae := PackedFloat64Array()   # атака × манёвренность × 1,5 × качество
	var de := PackedFloat64Array()   # защита × манёвренность × 1,5
	var co := PackedFloat64Array()   # координация
	var gr := PackedFloat64Array()   # удар по войскам (только на задании «поддержка»)
	var dcache := {}
	for r in by_region:
		var here: Array = by_region[r]
		# в районе никто не воюет — ни боёв, ни поправок к бою (по умолчанию)
		var hostile := false
		for w in here:
			if not world.nations[w.owner].at_war.is_empty():
				hostile = true
				break
		if not hostile:
			continue
		regions.append(r)
		seeds.append(hash([world.seed_value, world.day, 7000 + int(r)]))
		for w in here:
			var key: int = (w.design + 1) * 1048576 + w.owner * 2 + w.kind
			if not dcache.has(key):
				var d := Designs.of_wing(world, w)
				var agi: float = float(d["agi"]) * Designs.MAN_MULT
				var nat_w: World.Nation = world.nations[w.owner]
				dcache[key] = [float(d["atk"]) * agi * qa[w.owner * 4], maxf(0.5, float(d["def"]) * agi),
					clampf(float(d["coord"]) + nat_w.b("air_coord"), 0.0, 1.0),
					float(d["ground"]) / 6.0 * qa[w.owner * 4 + 1]]
			var c: Array = dcache[key]
			wl.append(w)
			ow.append(w.owner)
			kd.append(w.kind)
			wid.append(w.id)
			pl.append(w.planes)
			ae.append(c[0])
			de.append(c[1])
			co.append(c[2])
			gr.append(c[3] if w.mission == "cas" else 0.0)
		rstart.append(wl.size())
	var det := PackedFloat64Array()
	det.resize(nc)
	for n in world.nations:
		det[n.id] = clampf(AIR_DETECT + n.b("air_detect"), 0.05, 0.95)
	var t := {"nc": nc, "ally": world.ally.duplicate(), "war": world.war.duplicate(), "det": det,
		"kk": PackedFloat64Array([AIR_PACK, AIR_WIDTH, AIR_KILL, AIR_LOSS_MAX, AIR_NIGHT, AIR_SUP_PENALTY, AIR_SUP_FULL, CAS_MAX]),
		"rstart": rstart, "seeds": seeds, "ow": ow, "kd": kd, "wid": wid, "pl": pl, "ae": ae, "de": de, "co": co, "gr": gr}
	_air_job = {"t": t, "regions": regions, "wl": wl}
	_air_res = []
	_air_res.resize(regions.size())
	var res := _air_res
	var native: Object = Native.core
	_air_gid = Parallel.start(regions.size(), func(i: int):
		res[i] = native.call("air_region", t, i) if native != null else air_region_gd(t, i), "авиация", 4)
	Prof.add("авиа:снимок", _pt)


## Конец воздушной фазы (главный поток, до сухопутных боёв): дождаться расчёта
## районов, записать потери крыльев, превосходство и поправки к бою; налёты
## на постройки и удары по флоту; боевой опыт.
static func air_finish(world: World, rng: RandomNumberGenerator) -> void:
	var _pt := Time.get_ticks_usec()
	Parallel.finish(_air_gid)
	_air_gid = -1
	Prof.add("авиа:ожидание", _pt)
	_pt = Time.get_ticks_usec()
	var nc := world.nation_count
	if world.cas_mult.size() != world.region_count * nc:
		world.cas_mult.resize(world.region_count * nc)
		world.air_sup.resize(world.region_count * nc)
	world.cas_mult.fill(1.0)
	world.air_sup.fill(0.5)
	if _air_job.is_empty():
		return
	var regions: PackedInt32Array = _air_job["regions"]
	var wl: Array = _air_job["wl"]
	var rstart: PackedInt32Array = _air_job["t"]["rstart"]
	var qa := world.n_air
	var axp := PackedFloat64Array()   # боевой опыт авиации за день (Doctrine)
	axp.resize(nc)
	for i in regions.size():
		var r: int = regions[i]
		var out: PackedFloat64Array = _air_res[i]
		var s0 := rstart[i]
		var cnt := rstart[i + 1] - s0
		for j in cnt:
			var w: World.AirWing = wl[s0 + j]
			w.planes = out[j]
			axp[w.owner] += Doctrine.AIR_PER_WING * out[cnt + j]
		for k in range(2 * cnt, out.size(), 3):
			var n := int(out[k])
			world.air_sup[r * nc + n] = out[k + 1]
			world.cas_mult[r * nc + n] = out[k + 2]
		for j in cnt:
			var w: World.AirWing = wl[s0 + j]
			if w.alive and w.planes < 1.0:
				w.alive = false
				if world.nations[w.owner].is_player:
					world.log_event("Уничтожено: %s" % w.name)
		# стратегические бомбардировки и удары по флоту
		for j in cnt:
			var w: World.AirWing = wl[s0 + j]
			if w.kind != 1 or not w.alive:
				continue
			# задание бомбардировщиков на войне — тоже боевой опыт (без воздушного боя)
			if (w.mission == "bomb" or w.mission == "naval") and not world.nations[w.owner].at_war.is_empty():
				axp[w.owner] += Doctrine.AIR_PER_WING * 0.5
			var sup: float = world.air_sup[r * nc + w.owner]
			var d2 := Designs.of_wing(world, w)
			if w.mission == "bomb":
				_strategic_raid(world, w, r, (0.5 + sup) * 0.5 * maxf(float(d2["bomb"]), float(d2["ground"]) * 0.5) / 8.0, rng)
			elif w.mission == "naval":
				var strike: float = maxf(float(d2["naval"]), maxf(float(d2["ground"]), float(d2["bomb"])) * 0.5) / 8.0
				var dmg: float = w.planes * 0.002 * (0.5 + sup) * 0.5 * qa[w.owner * 4 + 3] * strike
				for zone in world.zone_fleets:
					if world.p_region[zone] != r:
						continue
					var targets: Array = []
					var aa := 0.0
					for f in world.zone_fleets[zone]:
						if world.is_at_war(w.owner, f.owner):
							targets.append(f)
							aa += f.aa
					if not targets.is_empty():
						# ПВО кораблей зоны ослабляет удар
						_take_losses(world, targets, dmg * NAVY_AA / (NAVY_AA + aa), rng)
	_air_job = {}
	_air_res = []
	for n in nc:
		if axp[n] > 0.0:
			Doctrine.gain(world.nations[n], 2, minf(Doctrine.AIR_CAP, axp[n]))
	Prof.add("авиа:применение", _pt)


## Воздушный бой района i снимка t (чистая функция — идёт в фоне; двойник —
## MeowqCore.air_region в native/src/air.cpp, результаты совпадают до бита).
## Крылья стороны (союзники) сливаются в пачки по AIR_PACK, у стороны не
## больше AIR_WIDTH пачек; превосходство — сила истребителей в бою; бой днём и
## ночью: пачка бьёт, только если обнаружила противника; координация — доля
## самолётов, что бьют согласованно, и шанс бить цель предыдущей пачки.
## Результат: самолёты крыльев после боя (cnt), опыт крыльев (cnt), затем
## тройки (страна, превосходство, множитель боя).
static func air_region_gd(t: Dictionary, i: int) -> PackedFloat64Array:
	var nc: int = t["nc"]
	var ally: PackedByteArray = t["ally"]
	var war: PackedByteArray = t["war"]
	var det: PackedFloat64Array = t["det"]
	var kk: PackedFloat64Array = t["kk"]
	var rstart: PackedInt32Array = t["rstart"]
	var seeds: PackedInt64Array = t["seeds"]
	var ow0: PackedInt32Array = t["ow"]
	var kd0: PackedInt32Array = t["kd"]
	var wid0: PackedInt32Array = t["wid"]
	var pl0: PackedFloat64Array = t["pl"]
	var ae0: PackedFloat64Array = t["ae"]
	var de0: PackedFloat64Array = t["de"]
	var co0: PackedFloat64Array = t["co"]
	var gr0: PackedFloat64Array = t["gr"]
	var pack_n: float = kk[0]
	var width := int(kk[1])
	var kill: float = kk[2]
	var loss_max: float = kk[3]
	var night_k: float = kk[4]
	var pen: float = kk[5]
	var full: float = kk[6]
	var cas_max: float = kk[7]
	var s0 := rstart[i]
	var cnt := rstart[i + 1] - s0
	var rng := RandomNumberGenerator.new()
	rng.seed = seeds[i]
	var ow := ow0.slice(s0, s0 + cnt)
	var kd := kd0.slice(s0, s0 + cnt)
	var wid := wid0.slice(s0, s0 + cnt)
	var pl := pl0.slice(s0, s0 + cnt)
	var ae := ae0.slice(s0, s0 + cnt)
	var de := de0.slice(s0, s0 + cnt)
	var co := co0.slice(s0, s0 + cnt)
	var gr := gr0.slice(s0, s0 + cnt)
	# стороны: союзники — одна сторона (номер — меньший из союзных владельцев)
	var side := PackedInt32Array()
	side.resize(cnt)
	for j in cnt:
		side[j] = ow[j]
		for k in cnt:
			if ow[k] < side[j] and ally[ow[j] * nc + ow[k]] == 1:
				side[j] = ow[k]
	var order: Array = []
	for j in cnt:
		order.append(j)
	order.sort_custom(func(a, b):
		if side[a] != side[b]:
			return side[a] < side[b]
		if kd[a] != kd[b]:
			return kd[a] < kd[b]   # истребители первыми
		if pl[a] != pl[b]:
			return pl[a] > pl[b]
		return wid[a] < wid[b])
	# пачки
	var pk_side := PackedInt32Array()
	var pk_pl := PackedFloat64Array()
	var pk_at := PackedFloat64Array()
	var pk_de := PackedFloat64Array()
	var pk_co := PackedFloat64Array()
	var c_pk := PackedInt32Array()
	var c_w := PackedInt32Array()
	var c_take := PackedFloat64Array()
	var eng := PackedFloat64Array()
	eng.resize(cnt)
	var count_side := {}
	for j in order:
		var left: float = pl[j]
		while left > 0.001:
			var np := pk_side.size()
			if np == 0 or pk_side[np - 1] != side[j] or pk_pl[np - 1] >= pack_n - 0.001:
				if int(count_side.get(side[j], 0)) >= width:
					break
				pk_side.append(side[j])
				pk_pl.append(0.0)
				pk_at.append(0.0)
				pk_de.append(0.0)
				pk_co.append(0.0)
				count_side[side[j]] = int(count_side.get(side[j], 0)) + 1
				np += 1
			var take: float = minf(left, pack_n - pk_pl[np - 1])
			pk_pl[np - 1] += take
			pk_at[np - 1] += take * ae[j]
			pk_de[np - 1] += take * de[j]
			pk_co[np - 1] += take * co[j]
			c_pk.append(np - 1)
			c_w.append(j)
			c_take.append(take)
			eng[j] += take
			left -= take
	var npk := pk_side.size()
	for b in npk:
		if pk_pl[b] > 0.0:
			pk_at[b] = pk_at[b] / pk_pl[b]
			pk_de[b] = pk_de[b] / pk_pl[b]
			pk_co[b] = pk_co[b] / pk_pl[b]
	var out := PackedFloat64Array()
	out.resize(2 * cnt)
	# превосходство и поправки к сухопутному бою
	var mark := PackedByteArray()
	mark.resize(nc)
	for j in cnt:
		mark[ow[j]] = 1
	for j in cnt:
		for n2 in nc:
			if war[ow[j] * nc + n2] == 1:
				mark[n2] = 1
	for n in nc:
		if mark[n] == 0:
			continue
		var own_f := 0.0
		var en_f := 0.0
		var own_b := 0.0
		for j in cnt:
			var o := ow[j]
			if kd[j] == 0:
				var pw: float = eng[j] * (ae[j] + de[j])
				if ally[n * nc + o] == 1:
					own_f += pw
				elif n != o and war[n * nc + o] == 1:
					en_f += pw
			elif ally[n * nc + o] == 1:
				own_b += pl[j] * gr[j]
		var sup := 0.5 if own_f + en_f <= 0.0 else own_f / (own_f + en_f)
		# бомбардировщики сильнее при своём превосходстве и слабее при чужом
		var m := 1.0 + minf(cas_max, own_b * (0.5 + sup) / 900.0)
		# противник господствует в воздухе: до −pen к силе войск
		if sup < 0.5:
			var presence := minf(1.0, (own_f + en_f) / full)
			m -= pen * (0.5 - sup) * 2.0 * presence
		out.append(float(n))
		out.append(sup)
		out.append(m)
	# бой днём и ночью
	var loss := PackedFloat64Array()
	loss.resize(npk)
	var xpw := PackedFloat64Array()
	xpw.resize(cnt)
	var foes := PackedInt32Array()
	for phase in 2:
		var night: float = 1.0 if phase == 0 else night_k
		var prev_target := {}
		var ci := 0   # вклады пачек идут подряд по номеру пачки
		for a in npk:
			var c0 := ci
			while ci < c_pk.size() and c_pk[ci] == a:
				ci += 1
			foes.resize(0)
			for b in npk:
				if war[pk_side[a] * nc + pk_side[b]] == 1:
					foes.append(b)
			if foes.is_empty():
				continue
			if phase == 0:
				for c in range(c0, ci):
					xpw[c_w[c]] += c_take[c] / pack_n
			if rng.randf() >= det[pk_side[a]] * night:
				continue
			var coord: float = pk_co[a] * night
			var tg: int = foes[rng.randi() % foes.size()]
			var pt: int = int(prev_target.get(pk_side[a], -1))
			if pt >= 0 and foes.has(pt) and rng.randf() < coord:
				tg = pt
			prev_target[pk_side[a]] = tg
			var engaged: float = pk_pl[a] * (0.5 + 0.5 * coord)
			loss[tg] += 0.5 * engaged * pk_at[a] * kill * rng.randf_range(0.7, 1.3) / maxf(0.5, pk_de[tg])
	# потери пачек — по крыльям пачки
	for j in cnt:
		out[j] = pl[j]
		out[cnt + j] = xpw[j]
	for c in c_pk.size():
		var b := c_pk[c]
		if loss[b] <= 0.0:
			continue
		var frac := minf(loss_max, loss[b] / maxf(1.0, pk_pl[b]))
		var wj := c_w[c]
		out[wj] = maxf(0.0, out[wj] - c_take[c] * frac)
	return out


## Ремонт повреждений от бомбёжек (раз в день, главный поток).
static func repair_bombing(world: World) -> void:
	if world.bombed.is_empty():
		return
	var keys: Array = world.bombed.keys()
	keys.sort()
	for p in keys:
		var pi: int = p
		world.p_bomb[pi] = maxf(0.0, world.p_bomb[pi] - BOMB_REPAIR)
		world.apply_bomb(pi)
		if world.p_bomb[pi] <= 0.0:
			world.bombed.erase(pi)


static func _damage(world: World, p: int, v: float) -> void:
	world.p_bomb[p] = minf(1.0, world.p_bomb[p] + v)
	world.bombed[p] = true
	world.apply_bomb(p)


## Стратегический налёт крыла на район: завод, узел снабжения (главный город
## района) или железная дорога и инфраструктура провинции противника.
static func _strategic_raid(world: World, w: World.AirWing, r: int, sup: float, rng: RandomNumberGenerator) -> void:
	if rng.randf() > w.planes / 1500.0 * sup * world.n_air[w.owner * 4 + 2]:
		return
	var enemy: Array = []
	var factories: Array = []
	var hub := -1
	for p in world.region_provs[r]:
		if world.p_land[p] == 1 and world.is_at_war(w.owner, world.p_controller[p]):
			enemy.append(p)
			if world.p_civ[p] + world.p_mil[p] > 0:
				factories.append(p)
			if hub < 0 or world.p_vp[p] > world.p_vp[hub] or (world.p_vp[p] == world.p_vp[hub] and world.p_population[p] > world.p_population[hub]):
				hub = p
	if enemy.is_empty():
		return
	var roll := rng.randf()
	var kind := 0 if roll < 0.4 else (1 if roll < 0.7 else 2)
	if kind == 0 and factories.is_empty():
		kind = 1
	var p: int = factories[rng.randi() % factories.size()] if kind == 0 else (hub if kind == 1 else enemy[rng.randi() % enemy.size()])
	# радары и зенитки защищающегося срывают часть налётов
	var adef: float = world.n_air_def[world.p_controller[p]]
	if adef > 0.0 and rng.randf() < adef:
		return
	var what := ""
	match kind:
		0:
			if world.p_mil[p] > 0:
				world.p_mil[p] -= 1
			else:
				world.p_civ[p] -= 1
			what = "разрушен завод"
		1:
			_damage(world, p, BOMB_HUB)
			what = "разбит узел снабжения"
		_:
			_damage(world, p, BOMB_RAIL)
			what = "разрушены железная дорога и склады"
	var victim: int = world.p_controller[p]
	if kind <= 1 and world.p_population.size() == world.prov_count:
		var vn: World.Nation = world.nations[victim]
		var lost := minf(vn.manpower, world.p_population[p] * BOMB_MANPOWER * (1.0 if kind == 1 else 0.5))
		vn.manpower -= lost
		if lost >= 0.5:
			what += ", погибло %d тыс." % roundi(lost)
	if world.nations[victim].is_player or world.nations[w.owner].is_player:
		world.log_event("Бомбардировка: %s — %s" % [what, world.p_name[p]])

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
	# стратегические налёты при сухопутном фронте: доля бомбардировщиков — на
	# самый ценный район противника в радиусе (заводы, крупные города, узлы)
	var bombers := 0
	for w in world.wings:
		if w.alive and w.owner == n and w.kind == 1:
			bombers += 1
	var raid_n := 0
	var raid_target := -1
	if bomb_target < 0 and not front_count.is_empty() and bombers > 0:
		var share := 0.5 if Doctrine.pref(nat, "air") == "bmb" else 0.25
		raid_n = int(floor(bombers * share))
		if raid_n > 0:
			raid_target = _raid_region(world, n)
	var reach := regions_in_range(world, n) if bomb_target >= 0 else {}
	Prof.add("авиаИИ:радиус", _pt)
	var k2 := 0
	var raids := 0
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
		elif w.kind == 1 and raid_target >= 0 and raids < raid_n:
			raids += 1
			w.region = raid_target
			w.mission = "bomb"
		else:
			w.region = target
			w.mission = "sup" if w.kind == 0 else "cas"


## Цель стратегических налётов: район противника в радиусе с наибольшей
## ценностью (заводы + очки победы городов); -1 — нет.
static func _raid_region(world: World, n: int) -> int:
	var reach := regions_in_range(world, n)
	var value := {}
	var war := world.war
	var nc := world.nation_count
	var ctrl := world.p_controller
	for p in world.prov_count:
		var c := ctrl[p]
		if c < 0 or war[n * nc + c] == 0 or world.p_land[p] == 0:
			continue
		var r := world.p_region[p]
		if not reach.has(r):
			continue
		value[r] = float(value.get(r, 0.0)) + world.p_civ[p] + world.p_mil[p] * 1.5 + world.vp_ai()[p] * 0.5
	var best := -1
	var best_v := 0.0
	for r in value:
		if float(value[r]) > best_v or (float(value[r]) == best_v and int(r) < best):
			best_v = value[r]
			best = r
	return best


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
	# цель высадки по истории (эффект landing): взята нами или союзником — снята
	var goal := nat.landing_goal
	if goal >= 0:
		var gc := world.p_controller[goal]
		if gc < 0 or gc == n or Diplomacy.same_side(world, gc, n):
			nat.landing_goal = -1
			goal = -1
		elif world.is_at_war(n, gc):
			enemy = gc
			if nat.inv_target != goal:
				nat.inv_target = goal
				nat.inv_port = -1
	for e in nat.at_war.keys() + nat.wargoals.keys() + nat.planned_wars.keys():
		if enemy >= 0:
			break
		if not world.nations[e].alive or reach.has(e) or nat.division_count <= world.nations[e].division_count * 1.5:
			continue
		# рубеж операций (war_limit): на этих землях — только исторические высадки (landing)
		if not nat.war_limit.is_empty() and world.nations[e].capital >= 0 and world.p_adm0[world.nations[e].capital] == String(nat.war_limit[0]):
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
				# прикрытие — соединения базы первого надводного (до NAVY_WIDTH)
				var sent := 0
				var base := -1
				for f in world.fleets:
					if sent >= NAVY_WIDTH:
						break
					if f.alive and f.owner == n and f.mission != "raid" and f.ships[SHIP_SS] < fleet_size(f) \
							and (base < 0 or f.home == base):
						base = f.home
						sent += 1
						f.mission = "patrol"
						f.task_until = world.day + 25
						for q in world.p_adj[plan.target]:
							if world.p_land[q] == 0:
								if f.zone != q and f.path.is_empty():
									f.path = sea_path(world, f.zone, q)
								break
			return
	# цель и порт посадки выбираются один раз на операцию
	var best := nat.inv_target
	if goal >= 0:
		best = goal
	elif best < 0 or world.p_controller[best] != enemy:
		best = -1
		var best_score := INF
		for p in world.prov_count:
			if world.p_controller[p] != enemy or world.p_coastal[p] == 0:
				continue
			# порты в приоритете: без порта плацдарм останется без снабжения
			var score: float = world.divs_count(p) * 25.0 - world.vp_ai()[p] * 2.0 - (8.0 if world.p_vp[p] >= 3 else 0.0) + rng.randf()
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
		# порт посадки — в метрополии (связан со столицей по суше) или там, где уже
		# стоят хотя бы 3 наших дивизии: иначе войскам до него не дойти (для Шанхая
		# ближайшим своим портом был Порт-Артур — десант не собирался никогда)
		var home_m: PackedByteArray = own_reach(world, n, nat.capital)[0]
		for p in world.prov_count:
			if world.p_controller[p] == n and world.p_owner[p] == n and is_port(world, p) \
					and (home_m[p] == 1 or _own_divs(world, n, p) >= 3):
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
