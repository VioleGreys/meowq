class_name Diplomacy
extends RefCounted
## Дипломатия: фракции, гарантии, пакты о ненападении, обоснование претензий,
## объявление войны со сторонами, мирные договоры и мировая напряжённость.
## Всё выполняется в главном потоке (решения редкие и дешёвые).

const FACTION_COLORS := {
	"Союзники": Color(0.27, 0.45, 0.85),
	"Ось": Color(0.22, 0.22, 0.24),
	"Коминтерн": Color(0.80, 0.16, 0.14),
	"Малая Антанта": Color(0.25, 0.65, 0.62),
}

# Порог мировой напряжённости для обоснования претензий по идеологии
const JUSTIFY_TENSION := {"democracy": 50.0, "authoritarian": 25.0, "fascism": 0.0, "communism": 0.0}


# --- Справка ---------------------------------------------------------------------

static func is_major(world: World, n: int) -> bool:
	var nat: World.Nation = world.nations[n]
	return nat.major or (not world.diplomacy and nat.civ + nat.mil >= 20)


static func root(world: World, n: int) -> int:
	var guard := 0
	while world.nations[n].overlord >= 0 and guard < 8:
		n = world.nations[n].overlord
		guard += 1
	return n


## Союзники в широком смысле: одна фракция или отношения сюзерен—марионетка.
static func same_side(world: World, a: int, b: int) -> bool:
	if a == b:
		return true
	var ra := root(world, a)
	var rb := root(world, b)
	if ra == rb:
		return true
	var fa: int = world.nations[ra].faction
	return fa >= 0 and fa == world.nations[rb].faction


static func faction_members(world: World, f: int) -> Array:
	var res: Array = []
	if f < 0:
		return res
	for nat in world.nations:
		if nat.alive and nat.faction == f:
			res.append(nat.id)
	return res


static func puppets_of(world: World, n: int) -> Array:
	var res: Array = []
	for nat in world.nations:
		if nat.alive and nat.overlord == n:
			res.append(nat.id)
	return res


static func faction_name(world: World, n: int) -> String:
	var f: int = world.nations[root(world, n)].faction
	return world.factions[f].name if f >= 0 else ""


## Грубая оценка силы стороны: дивизии + военная промышленность.
static func side_power(world: World, n: int, include_guarantors: bool) -> float:
	var members := {}
	var r := root(world, n)
	members[r] = true
	for p in puppets_of(world, r):
		members[p] = true
	for m in faction_members(world, world.nations[r].faction):
		members[m] = true
	if include_guarantors:
		for nat in world.nations:
			if nat.alive and nat.guarantees.has(n):
				members[nat.id] = true
	var s := 0.0
	for m in members:
		s += _power(world, m)
	return s


static func _power(world: World, n: int) -> float:
	var nat: World.Nation = world.nations[n]
	return nat.division_count * 1.0 + nat.mil * 2.0 + nat.civ * 0.3


static func add_tension(world: World, amount: float) -> void:
	world.tension = clampf(world.tension + amount, 0.0, 100.0)


# --- Обоснование претензий и объявление войны ------------------------------

## Пустая строка — можно; иначе причина, почему нельзя.
static func can_justify(world: World, a: int, b: int) -> String:
	var na: World.Nation = world.nations[a]
	var nb: World.Nation = world.nations[b]
	if a == b or not nb.alive or not na.alive:
		return "невозможно"
	if na.overlord >= 0:
		return "марионетка не ведёт свою внешнюю политику"
	if world.is_at_war(a, b):
		return "уже идёт война"
	if same_side(world, a, b):
		return "это союзник"
	if na.pacts.has(b):
		return "действует пакт о ненападении"
	if na.wargoals.has(b):
		return "претензии уже обоснованы"
	if na.justify_target >= 0:
		return "уже обосновываем претензии к стране %s" % world.nations[na.justify_target].name
	var need: float = JUSTIFY_TENSION.get(na.ideology, 25.0)
	if world.tension < need:
		return "%s: нужна мировая напряжённость %d%% (сейчас %d%%)" % [
			world.ideology_names.get(na.ideology, na.ideology), need, world.tension]
	return ""


static func justify_days(world: World, b: int) -> int:
	var base := 90.0 if is_major(world, b) else 60.0
	return int(round(base * (1.0 - world.tension / 200.0)))


static func start_justify(world: World, a: int, b: int) -> bool:
	if can_justify(world, a, b) != "":
		return false
	var na: World.Nation = world.nations[a]
	na.justify_target = b
	na.justify_days = justify_days(world, b)
	na.justify_total = na.justify_days
	add_tension(world, 0.5)
	if na.is_player or world.nations[b].is_player or is_major(world, a):
		world.log_event("%s обосновывает претензии к стране %s" % [na.name, world.nations[b].name])
	return true


static func can_declare(world: World, a: int, b: int) -> String:
	var na: World.Nation = world.nations[a]
	if not world.nations[b].alive or not na.alive:
		return "невозможно"
	if na.overlord >= 0:
		return "марионетка не ведёт свою внешнюю политику"
	if world.is_at_war(a, b):
		return "уже идёт война"
	if same_side(world, a, b):
		return "это союзник"
	if na.pacts.has(b):
		return "действует пакт о ненападении"
	if not world.diplomacy:
		return ""
	if not na.wargoals.has(b):
		return "сначала обоснуйте претензии"
	return ""


## Объявление войны. Атакующая сторона: страна, её марионетки и согласные
## члены фракции. Защищающаяся: цель, её сюзерен и марионетки, фракция, гаранты.
static func declare_war(world: World, a: int, b: int) -> bool:
	if can_declare(world, a, b) != "":
		return false
	var na: World.Nation = world.nations[a]
	na.wargoals.erase(b)
	var attackers := {a: true}
	for p in puppets_of(world, a):
		attackers[p] = true
	var defenders := {b: true}
	var rb := root(world, b)
	# члены фракции атакующего: ИИ решает, присоединиться ли к наступательной войне
	var target_side := {}
	for m in faction_members(world, world.nations[rb].faction):
		target_side[m] = true
	for m in faction_members(world, na.faction):
		if m != a and not target_side.has(m) and m != b and m != rb and _joins_offensive(world, m, a, b):
			attackers[m] = true
	# защитники: замыкание по сюзеренам, марионеткам, фракциям и гарантам
	var changed := true
	while changed:
		changed = false
		for d in defenders.keys():
			var add: Array = [root(world, d)]
			add.append_array(puppets_of(world, root(world, d)))
			add.append_array(faction_members(world, world.nations[root(world, d)].faction))
			for nat in world.nations:
				if nat.alive and nat.guarantees.has(d) and not nat.pacts.has(a):
					add.append(nat.id)
			for x in add:
				if not defenders.has(x) and not attackers.has(x):
					defenders[x] = true
					changed = true
	for x in attackers:
		world.nations[x].war_activity_day = world.day
		for y in defenders:
			world.nations[y].war_activity_day = world.day
			if x != y and not attackers.has(y):
				world.set_war(x, y)
	add_tension(world, 8.0 if is_major(world, b) else (1.0 if world.nations[b].province_count <= 2 else 2.5))
	world.log_event("%s объявляет войну: %s!" % [na.name, world.nations[b].name])
	for y in defenders:
		if y != b and y != rb:
			world.log_event("%s вступает в войну на стороне страны %s" % [world.nations[y].name, world.nations[b].name])
	for x in attackers:
		if x != a:
			world.log_event("%s поддерживает страну %s" % [world.nations[x].name, na.name])
	return true


static func _joins_offensive(world: World, m: int, a: int, b: int) -> bool:
	var nm: World.Nation = world.nations[m]
	if nm.is_player or nm.pacts.has(b):
		return false
	if nm.ideology == "democracy":
		return world.tension >= 60.0
	return nm.ideology == world.nations[a].ideology


## Новый член стороны вступает во все войны лидера.
static func _inherit_wars(world: World, n: int, leader: int) -> void:
	for e in world.nations[leader].at_war.keys():
		if e != n and not same_side(world, n, e):
			world.set_war(n, e)


# --- Фракции, гарантии, пакты --------------------------------------------------

static func create_faction(world: World, n: int, name: String = "") -> int:
	var nat: World.Nation = world.nations[n]
	if nat.faction >= 0 or nat.overlord >= 0:
		return -1
	if name == "":
		match nat.ideology:
			"fascism":
				name = "Ось"
			"communism":
				name = "Коминтерн"
			"democracy":
				name = "Союзники"
			_:
				name = "Блок «%s»" % nat.name
		for f in world.factions:
			if f.alive and f.name == name:
				name = "Блок «%s»" % nat.name
	var f := World.Faction.new()
	f.id = world.factions.size()
	f.name = name
	f.leader = n
	f.color = FACTION_COLORS.get(name, nat.color.darkened(0.2))
	world.factions.append(f)
	nat.faction = f.id
	if nat.ideology == "fascism" or nat.ideology == "communism":
		add_tension(world, 2.0)
	world.log_event("%s создаёт фракцию «%s»" % [nat.name, f.name])
	world.palette_dirty = true
	return f.id


static func join_faction(world: World, n: int, f: int) -> void:
	var nat: World.Nation = world.nations[n]
	if f < 0 or nat.faction == f:
		return
	nat.faction = f
	nat.justify_target = -1
	_inherit_wars(world, n, world.factions[f].leader)
	world.log_event("%s вступает во фракцию «%s»" % [nat.name, world.factions[f].name])
	world.palette_dirty = true


static func leave_faction(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	var f := nat.faction
	if f < 0:
		return
	nat.faction = -1
	world.log_event("%s выходит из фракции «%s»" % [nat.name, world.factions[f].name])
	if world.factions[f].leader == n:
		var rest := faction_members(world, f)
		if rest.is_empty():
			world.factions[f].alive = false
		else:
			world.factions[f].leader = rest[0]
	world.palette_dirty = true


static func guarantee(world: World, a: int, b: int) -> void:
	world.nations[a].guarantees[b] = true
	world.log_event("%s гарантирует независимость страны %s" % [world.nations[a].name, world.nations[b].name])


static func sign_pact(world: World, a: int, b: int) -> void:
	world.nations[a].pacts[b] = true
	world.nations[b].pacts[a] = true
	world.nations[a].wargoals.erase(b)
	world.nations[b].wargoals.erase(a)
	for x in [[a, b], [b, a]]:
		if world.nations[x[0]].justify_target == x[1]:
			world.nations[x[0]].justify_target = -1
	world.log_event("%s и %s подписывают пакт о ненападении" % [world.nations[a].name, world.nations[b].name])


static func break_pact(world: World, a: int, b: int) -> void:
	world.nations[a].pacts.erase(b)
	world.nations[b].pacts.erase(a)
	add_tension(world, 3.0)
	world.log_event("%s расторгает пакт о ненападении со страной %s" % [world.nations[a].name, world.nations[b].name])


## Ответ ИИ на предложение: [согласие, причина].
static func ai_accepts(world: World, from: int, to: int, kind: String) -> Array:
	var a: World.Nation = world.nations[from]
	var t: World.Nation = world.nations[to]
	if world.is_at_war(from, to):
		return [false, "мы воюем"]
	var score := 0.0
	var why := ""
	var ia := a.ideology
	var it := t.ideology
	if ia == it:
		score += 30.0
	elif (ia == "democracy" and (it == "fascism" or it == "communism")) or (it == "democracy" and (ia == "fascism" or ia == "communism")):
		score -= 25.0
		why = "идеологические противники"
	match kind:
		"pact":
			score += 20.0
			if a.wargoals.has(to) or a.justify_target == to:
				return [false, "у вас претензии к нам"]
			if _power(world, from) > _power(world, to) * 1.5:
				score += 15.0
		"invite":   # from приглашает to в свою фракцию
			if t.faction >= 0:
				return [false, "уже во фракции «%s»" % world.factions[t.faction].name]
			if t.overlord >= 0:
				return [false, "марионетка"]
			score += world.tension * 0.6 - 15.0
			if not is_major(world, from):
				score -= 15.0
			if score <= 0.0 and why == "":
				why = "напряжённость слишком мала (%d%%)" % world.tension
		"join":     # from просится во фракцию to
			score += 25.0
			if ia != it and world.tension < 30.0:
				score -= 20.0
				if why == "":
					why = "пока не нужен союз (напряжённость %d%%)" % world.tension
	if score > 0.0:
		return [true, ""]
	return [false, why if why != "" else "не заинтересованы"]


# --- Мир ---------------------------------------------------------------------------

## Капитуляция: mode = "annex" (оккупанты забирают занятое, остальное — победитель)
## или "puppet" (проигравший сохраняет земли и становится марионеткой победителя).
static func make_peace(world: World, loser: int, winner: int, mode: String) -> void:
	var nl: World.Nation = world.nations[loser]
	var nw: World.Nation = world.nations[winner]
	for d in world.divisions:
		if d.owner == loser:
			d.alive = false
	nl.training.clear()
	nl.justify_target = -1
	nl.wargoals.clear()
	world.end_wars_of(loser)
	for p in puppets_of(world, loser):
		world.nations[p].overlord = -1
	if nl.faction >= 0:
		leave_faction(world, loser)
	if mode == "puppet":
		for p in world.prov_count:
			if world.p_owner[p] == loser:
				world.p_controller[p] = loser
			elif world.p_controller[p] == loser:
				world.p_controller[p] = world.p_owner[p]
		nl.overlord = root(world, winner)
		_inherit_wars(world, loser, nl.overlord)
		world.log_event("%s капитулирует и становится марионеткой страны %s" % [nl.name, world.nations[nl.overlord].name])
	else:
		for p in world.prov_count:
			if world.p_owner[p] == loser:
				if world.p_controller[p] == loser:
					world.p_controller[p] = winner
				world.p_owner[p] = world.p_controller[p]
			elif world.p_controller[p] == loser:
				world.p_controller[p] = world.p_owner[p]
		nl.alive = false
		for o in world.nations:
			o.guarantees.erase(loser)
			o.pacts.erase(loser)
			o.wargoals.erase(loser)
			if o.justify_target == loser:
				o.justify_target = -1
		add_tension(world, 1.5)
		world.log_event("%s капитулирует! Территория аннексирована (%s)" % [nl.name, nw.name])
	world.palette_dirty = true
	world.rebuild_prov_divs()


static func ai_peace_mode(world: World, winner: int) -> String:
	var ide: String = world.nations[winner].ideology
	return "puppet" if ide == "democracy" else "annex"


# --- Ежедневные процессы и ИИ ------------------------------------------------

static func daily(world: World) -> void:
	if world.day % 30 == 0:
		check_stalemates(world)
	for nat in world.nations:
		if not nat.alive or nat.justify_target < 0:
			continue
		if not world.nations[nat.justify_target].alive or nat.pacts.has(nat.justify_target):
			nat.justify_target = -1
			continue
		nat.justify_days -= 1
		if nat.justify_days <= 0:
			nat.wargoals[nat.justify_target] = true
			if nat.is_player or world.nations[nat.justify_target].is_player or is_major(world, nat.id):
				world.log_event("%s: претензии к стране %s обоснованы" % [nat.name, world.nations[nat.justify_target].name])
			nat.justify_target = -1


## Решения ИИ по дипломатии (раз в неделю на страну).
static func ai_turn(world: World, n: int, rng: RandomNumberGenerator) -> void:
	var nat: World.Nation = world.nations[n]
	if not nat.alive or nat.is_player or nat.overlord >= 0:
		return
	var neighbours := world.neighbours_of_nation(n)

	# 1. Фракции
	if nat.faction < 0 and not nat.neutral:
		var threatened := _threatened(world, n)
		var best := -1
		for f in world.factions:
			if not f.alive:
				continue
			var leader: World.Nation = world.nations[f.leader]
			if leader.is_player or _threat_from(world, n, f.leader):
				continue
			var ok := false
			if leader.ideology == nat.ideology and nat.ideology != "authoritarian":
				# свои по идеологии: державы — при напряжённости 20%, малые — только под угрозой
				ok = world.tension >= 20.0 and (nat.major or threatened)
			elif threatened and world.tension >= 30.0 and nat.ideology != "communism" and leader.ideology != "communism":
				# под угрозой ищут защиты у любой некоммунистической фракции
				ok = not (nat.ideology == "democracy" and leader.ideology == "fascism")
			if ok and ai_accepts(world, n, f.leader, "join")[0]:
				best = f.id
				break
		if best >= 0 and rng.randf() < 0.3:
			join_faction(world, n, best)
		elif best < 0 and nat.major and (nat.ideology == "fascism" or nat.ideology == "communism") \
				and world.tension >= 12.0 and world.day >= 200:
			# держава той же идеологии уже ведёт фракцию — вступаем к ней, а не создаём свою
			var same := -1
			for f in world.factions:
				if f.alive and world.nations[f.leader].ideology == nat.ideology and not world.nations[f.leader].is_player:
					same = f.id
			if same >= 0:
				join_faction(world, n, same)
			else:
				create_faction(world, n)

	# 2. Гарантии: демократические державы защищают соседей агрессоров
	if nat.ideology == "democracy" and nat.major and world.tension >= 25.0:
		for o in world.nations:
			if not o.alive or o.id == n or nat.guarantees.has(o.id) or o.overlord >= 0 or same_side(world, n, o.id):
				continue
			if o.ideology == "fascism" or o.ideology == "communism":
				continue
			if _threatened(world, o.id) and rng.randf() < 0.3:
				guarantee(world, n, o.id)

	# 3. Агрессия: фашисты и коммунисты обосновывают претензии к слабым соседям
	if not world.ai_wars or not nat.at_war.is_empty():
		return
	if nat.ideology != "fascism" and nat.ideology != "communism":
		return
	# пока нет исторических событий (этап 5), ИИ-агрессия нарастает с напряжённостью
	if nat.ideology == "communism" and world.tension < 45.0:
		return
	if nat.ideology == "fascism" and world.tension < 20.0 and world.day < 540:
		return
	# готовая претензия — объявляем, если перевес сохранился
	for t in nat.wargoals.keys():
		if not world.nations[t].alive:
			nat.wargoals.erase(t)
			continue
		if side_power(world, n, false) > side_power(world, t, true) * 1.3 and rng.randf() < 0.5:
			declare_war(world, n, t)
			return
	if nat.justify_target >= 0 or not nat.wargoals.is_empty() or world.day < 90 or rng.randf() > 0.15:
		return
	var my := side_power(world, n, false)
	var best_t := -1
	var best_score := 0.0
	for t in reachable_neighbours(world, n):
		if can_justify(world, n, t) != "":
			continue
		var their := side_power(world, t, true)
		if my < their * 1.6:
			continue
		# демократии трогаем только при высокой напряжённости — иначе мир ответит
		if world.nations[t].ideology == "democracy" and world.tension < 45.0:
			continue
		var score := my / maxf(their, 1.0) + rng.randf()
		if score > best_score:
			best_score = score
			best_t = t
	if best_t >= 0:
		start_justify(world, n, best_t)


## Соседи, до которых армия может дойти по своей территории от столицы
## (без морских высадок): Восточная Пруссия отрезана коридором, Ливия — морем.
static func reachable_neighbours(world: World, n: int) -> Dictionary:
	var res := {}
	var cap: int = world.nations[n].capital
	if world.p_controller[cap] != n:
		return res
	var seen := {cap: true}
	var stack := [cap]
	while not stack.is_empty():
		var p: int = stack.pop_back()
		for q in world.p_adj[p]:
			if world.p_land[q] == 0:
				continue
			var c := world.p_controller[q]
			if c == n:
				if not seen.has(q):
					seen[q] = true
					stack.append(q)
			elif c >= 0:
				res[c] = true
	return res


## Белый мир: война без продвижения больше года между странами ИИ.
static func check_stalemates(world: World) -> void:
	for nat in world.nations:
		if not nat.alive or nat.is_player or nat.at_war.is_empty():
			continue
		if world.day - nat.war_activity_day < 365:
			continue
		for e in nat.at_war.keys():
			var ne: World.Nation = world.nations[e]
			if ne.is_player or world.day - ne.war_activity_day < 365:
				continue
			nat.at_war.erase(e)
			ne.at_war.erase(nat.id)
			world.war[nat.id * world.nation_count + e] = 0
			world.war[e * world.nation_count + nat.id] = 0
			world.log_event("%s и %s заключают белый мир" % [nat.name, ne.name])
		for p in world.prov_count:
			# оккупированное возвращается владельцам, если войны между ними больше нет
			var o := world.p_owner[p]
			var c := world.p_controller[p]
			if o >= 0 and c != o and not world.is_at_war(o, c):
				world.p_controller[p] = o
				world.palette_dirty = true


## Угрожает ли страна x стране n (обосновывает или обосновала претензии).
static func _threat_from(world: World, n: int, x: int) -> bool:
	var o: World.Nation = world.nations[x]
	return o.justify_target == n or o.wargoals.has(n) or world.is_at_war(n, x)


## Страна под угрозой: к ней обосновывают претензии или они уже обоснованы.
static func _threatened(world: World, n: int) -> bool:
	for o in world.nations:
		if o.alive and (o.justify_target == n or o.wargoals.has(n)):
			return true
	return false


# --- Начальное состояние 1936 г. ---------------------------------------------

static func load_setup(world: World, path: String) -> void:
	world.diplomacy = true
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		push_error("Не удалось прочитать " + path)
		return
	world.tension = float(d.get("tension", 0.0))
	for fd in d.get("factions", []):
		var leader := world.nation_tags.find(fd["leader"])
		if leader < 0:
			continue
		var f := World.Faction.new()
		f.id = world.factions.size()
		f.name = fd["name"]
		f.leader = leader
		f.color = FACTION_COLORS.get(f.name, world.nations[leader].color)
		world.factions.append(f)
		for tag in fd["members"]:
			var m := world.nation_tags.find(tag)
			if m >= 0:
				world.nations[m].faction = f.id
	for g in d.get("guarantees", []):
		var a := world.nation_tags.find(g[0])
		var b := world.nation_tags.find(g[1])
		if a >= 0 and b >= 0:
			world.nations[a].guarantees[b] = true
	for p in d.get("pacts", []):
		var a := world.nation_tags.find(p[0])
		var b := world.nation_tags.find(p[1])
		if a >= 0 and b >= 0:
			world.nations[a].pacts[b] = true
			world.nations[b].pacts[a] = true
