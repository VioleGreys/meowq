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
	if na.is_player and na.war_support < Politics.WS_JUSTIFY:
		return "нужна поддержка войны %d%% (сейчас %d%%)" % [roundi(Politics.WS_JUSTIFY * 100.0), roundi(na.war_support * 100.0)]
	return Politics.can_pay(world, na, Politics.COST_JUSTIFY)


static func justify_days(world: World, b: int) -> int:
	var base := 90.0 if is_major(world, b) else 60.0
	return int(round(base * (1.0 - world.tension / 200.0)))


static func start_justify(world: World, a: int, b: int) -> bool:
	if can_justify(world, a, b) != "":
		return false
	var na: World.Nation = world.nations[a]
	Politics.spend(world, na, Politics.COST_JUSTIFY)
	na.justify_target = b
	na.justify_days = justify_days(world, b)
	na.justify_total = na.justify_days
	add_tension(world, 0.5)
	Relations.add_aggression(world, a, 3.0)
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
static func declare_war(world: World, a: int, b: int, call_guarantors: bool = true) -> bool:
	if can_declare(world, a, b) != "":
		return false
	var na: World.Nation = world.nations[a]
	na.wargoals.erase(b)
	var attackers := {a: true}
	for p in puppets_of(world, a):
		attackers[p] = true
	var defenders := {b: true}
	var calls := {}   # гаранты-игроки: событие с выбором
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
			# гаранты — только за саму жертву (а не за всю её сторону: иначе
			# британская гарантия Румынии 1939 г. ставила Британию за Германию)
			if call_guarantors and d == b:
				for nat in world.nations:
					if nat.alive and nat.guarantees.has(d) and not nat.pacts.has(a):
						if nat.is_player:
							calls[nat.id] = true   # игрок решает сам (событие)
						elif world.nations[a].is_player and not nat.guar_hist.has(d):
							calls[nat.id] = true   # на игрока: ИИ взвешивает (событие)
						else:
							add.append(nat.id)
			for x in add:
				if not defenders.has(x) and not attackers.has(x) and not _hostile_to_any(world, x, defenders) \
						and not same_side(world, x, a):
					defenders[x] = true
					changed = true
	for x in attackers:
		world.nations[x].war_activity_day = world.day
		for y in defenders:
			world.nations[y].war_activity_day = world.day
			if x != y and not attackers.has(y):
				world.set_war(x, y)
	add_tension(world, 8.0 if is_major(world, b) else (1.0 if world.nations[b].province_count <= 2 else 2.5))
	Politics.on_declare(world, a, b)
	for g in calls:
		if not defenders.has(g) and not attackers.has(g) and not world.is_at_war(g, a):
			Politics.guarantee_call(world, g, b, a)
	Relations.on_war(world, a, b)
	world.focus_epoch += 1
	world.log_event("%s объявляет войну: %s!" % [na.name, world.nations[b].name])
	for y in defenders:
		if y != b and y != rb:
			Relations.add_diplo(world, y, 8.0)   # вступил в войну за жертву
			world.log_event("%s вступает в войну на стороне страны %s" % [world.nations[y].name, world.nations[b].name])
	for x in attackers:
		if x != a:
			Relations.add_aggression(world, x, 8.0)
			world.log_event("%s поддерживает страну %s" % [world.nations[x].name, na.name])
	return true


## Страна x воюет с кем-то из списка (за врага она не встанет).
static func _hostile_to_any(world: World, x: int, side: Dictionary) -> bool:
	for y in side:
		if world.is_at_war(x, y):
			return true
	return false


static func _joins_offensive(world: World, m: int, a: int, b: int) -> bool:
	var nm: World.Nation = world.nations[m]
	if nm.is_player or nm.pacts.has(b) or world.historical:
		return false   # в исторической игре союзники вступают в войны по фокусам и событиям
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
	Relations.add_diplo(world, n, 8.0)
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
	world.focus_epoch += 1
	nat.justify_target = -1
	Relations.add_diplo(world, n, 6.0)
	Relations.add_diplo(world, world.factions[f].leader, 3.0)
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


## Гарантию даёт только тот, кто намного сильнее (решение пользователя, ноябрь
## 2026): военная сила и промышленность — не меньше чем вдвое больше, чем у
## гарантируемой страны (исторические гарантии 1936–39 гг. — от ×2,1).
const GUAR_RATIO := 2.0


## Военная сила для гарантий: дивизии, военные заводы, корабли (по 0,25),
## самолёты (по 0,01).
static func military_strength(world: World, n: int) -> float:
	var ships := 0
	for f in world.fleets:
		if f.owner == n:
			for c in f.counts:
				ships += c
	var planes := 0.0
	for wg in world.wings:
		if wg.owner == n:
			planes += wg.planes
	var nat: World.Nation = world.nations[n]
	return nat.division_count + nat.mil + ships * 0.25 + planes / 100.0


## Пустая строка — можно гарантировать; иначе причина.
static func can_guarantee(world: World, a: int, b: int) -> String:
	var na: World.Nation = world.nations[a]
	var nb: World.Nation = world.nations[b]
	if not nb.alive or a == b or same_side(world, a, b) or world.is_at_war(a, b):
		return "невозможно"
	if na.overlord >= 0:
		return "марионетка не ведёт свою внешнюю политику"
	if world.day < na.guar_ban_until:
		return "«Позор нации»: гарантии запрещены ещё %d дн." % (na.guar_ban_until - world.day)
	var pp := Politics.can_pay(world, na, Politics.COST_GUARANTEE)
	if pp != "":
		return pp
	var ma := military_strength(world, a)
	var mb := military_strength(world, b)
	if ma < mb * GUAR_RATIO:
		return "нужна военная сила вдвое больше (%.0f против %.0f)" % [ma, mb]
	if na.civ + na.mil < (nb.civ + nb.mil) * GUAR_RATIO:
		return "нужна промышленность вдвое больше (%d против %d)" % [na.civ + na.mil, nb.civ + nb.mil]
	return ""


## historic — исторические гарантии (фокусы, события): без проверки перевеса.
static func guarantee(world: World, a: int, b: int, historic: bool = false) -> void:
	if world.day < world.nations[a].guar_ban_until:
		return   # «Позор нации»: запрет и на исторические гарантии
	if not historic:
		if can_guarantee(world, a, b) != "":
			return
		Politics.spend(world, world.nations[a], Politics.COST_GUARANTEE)
		world.nations[a].guar_hist.erase(b)
	else:
		world.nations[a].guar_hist[b] = true
	world.nations[a].guarantees[b] = true
	Relations.on_guarantee(world, a, b)
	Relations.add_diplo(world, a, 5.0)
	world.log_event("%s гарантирует независимость страны %s" % [world.nations[a].name, world.nations[b].name])


static func sign_pact(world: World, a: int, b: int) -> void:
	world.nations[a].pacts[b] = true
	world.nations[b].pacts[a] = true
	Relations.on_pact(world, a, b)
	Relations.add_diplo(world, a, 3.0)
	Relations.add_diplo(world, b, 3.0)
	world.nations[a].wargoals.erase(b)
	world.nations[b].wargoals.erase(a)
	for x in [[a, b], [b, a]]:
		if world.nations[x[0]].justify_target == x[1]:
			world.nations[x[0]].justify_target = -1
	world.log_event("%s и %s подписывают пакт о ненападении" % [world.nations[a].name, world.nations[b].name])


static func break_pact(world: World, a: int, b: int) -> void:
	world.nations[a].pacts.erase(b)
	world.nations[b].pacts.erase(a)
	Relations.on_break_pact(world, a, b)
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
	world.focus_epoch += 1
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
		Puppets.make(world, loser, root(world, winner))
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
		# флот и авиация аннексированной страны не достаются никому
		for f in world.fleets:
			if f.owner == loser:
				f.alive = false
		for wg in world.wings:
			if wg.owner == loser:
				wg.alive = false
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


const EXILE_VP := 10       # нужно свободных колоний, очков победы
const EXILE_POP := 2000    # и населения в них, тыс.


## Правительство в изгнании (решение пользователя, ноябрь 2026): вместо
## капитуляции страна, у которой остались свободные колонии и чьи союзники
## (кто воюет с победителем) продолжают войну, теряет только метрополию — она
## занята до мирных переговоров (Peace), — а сама переезжает в крупнейший
## колониальный город и воюет дальше: колонии, их гарнизоны, флот и авиация
## остаются. Колонии потом сдаются по одной (_cap_colonies), без последней —
## капитуляция (Peace.capitulate).
static func try_exile(world: World, loser: int, winner: int) -> bool:
	if world.p_colony.size() != world.prov_count:
		return false
	var nl: World.Nation = world.nations[loser]
	var best := -1
	var free_vp := 0
	var free_pop := 0
	for p in world.prov_count:
		if world.p_owner[p] == loser and world.p_controller[p] == loser and world.p_colony[p] == 1 and world.p_land[p] == 1:
			free_vp += world.p_vp[p]
			free_pop += world.p_population[p]
			if best < 0 or world.p_vp[p] > world.p_vp[best] or (world.p_vp[p] == world.p_vp[best] and world.p_population[p] > world.p_population[best]):
				best = p
	# только настоящая колониальная держава: клочок земли (Гренландия, Намибия,
	# отнятый у соседа порт) не держит правительство
	if best < 0 or free_vp < EXILE_VP or free_pop < EXILE_POP:
		return false
	var ally := false
	for o in world.nations:
		if o.alive and o.id != loser and o.id != winner and world.is_at_war(o.id, winner) and not world.is_at_war(o.id, loser):
			ally = true
			break
	if not ally:
		return false
	world.focus_epoch += 1
	# метрополия остаётся за страной, но занята до мирных переговоров (Peace)
	var moved := PackedByteArray()
	moved.resize(world.prov_count)
	for p in world.prov_count:
		if world.p_owner[p] != loser or world.p_colony[p] == 1:
			continue
		if world.p_controller[p] == loser:
			world.p_controller[p] = winner
		moved[p] = 1
	# войска в метрополии сдаются, за её пределами (колонии, фронт союзников) — воюют дальше
	for d in world.divisions:
		if d.alive and d.owner == loser and moved[d.prov] == 1:
			d.alive = false
	var old := nl.capital
	nl.capital = best
	nl.exile = true
	nl.training.clear()
	nl.justify_target = -1
	add_tension(world, 1.5)
	world.log_event("%s: метрополия потеряна (%s), правительство в изгнании продолжает войну из колоний — столица %s" \
			% [nl.name, world.p_name[old] if old >= 0 else "?", world.p_name[best]])
	world.palette_dirty = true
	world.rebuild_prov_divs()
	return true


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
	if not nat.alive or nat.is_player or nat.overlord >= 0 or nat.capitulated:
		return

	# 1. Фракции (в исторической игре союзы складываются только фокусами и событиями)
	if nat.faction < 0 and not nat.neutral and not world.historical:
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
		elif best < 0 and not world.historical and nat.major and (nat.ideology == "fascism" or nat.ideology == "communism") \
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
	if nat.ideology == "democracy" and nat.major and world.tension >= 25.0 and not world.historical:
		for o in world.nations:
			if not o.alive or o.id == n or nat.guarantees.has(o.id) or o.overlord >= 0 or same_side(world, n, o.id):
				continue
			if o.ideology == "fascism" or o.ideology == "communism":
				continue
			if _threatened(world, o.id) and rng.randf() < 0.3:
				guarantee(world, n, o.id)

	# 3. Агрессия: фашисты и коммунисты обосновывают претензии к слабым соседям
	if not world.ai_wars or not nat.at_war.is_empty() or world.historical:
		return   # в исторической игре войны начинаются фокусами и событиями
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
	# готовое со вчера (упреждение, Forces.spec) — для решений ИИ флота и высадок
	var job: Dictionary = world.reach_job
	if int(job.get("day", -1)) == world.day and job["reach"].has(n):
		Spec.finish(world)
		for c in job["reach"][n]:
			res[c] = true
		return res
	var cap: int = world.nations[n].capital
	if world.p_controller[cap] != n:
		return res
	if Native.core != null:
		var r := Forces.own_reach(world, n, cap)
		for c in r[1]:
			res[c] = true
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
		if not nat.alive or nat.is_player or nat.capitulated or nat.at_war.is_empty():
			continue
		if world.day - nat.war_activity_day < 365:
			continue
		for e in nat.at_war.keys():
			var ne: World.Nation = world.nations[e]
			if ne.is_player or ne.capitulated or world.day - ne.war_activity_day < 365:
				continue
			# гражданская война миром не кончается — только победой одной из сторон
			if nat.spirits.has("civil_war_attrition") and ne.spirits.has("civil_war_attrition"):
				continue
			# мировая война затуханием не кончается (ноябрь 2026): без сухопутного
			# фронта Британия и Германия мирились в 1943–44 гг., и Ось выигрывала
			# переговоры у одного СССР. Война великих держав и фракций — только
			# капитуляцией и мирной конференцией; белый мир — для местных войн.
			if is_major(world, nat.id) or is_major(world, e) \
					or (world.nations[root(world, nat.id)].faction >= 0 and world.nations[root(world, e)].faction >= 0):
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
			world.nations[a].guar_hist[b] = true
	for p in d.get("pacts", []):
		var a := world.nation_tags.find(p[0])
		var b := world.nation_tags.find(p[1])
		if a >= 0 and b >= 0:
			world.nations[a].pacts[b] = true
			world.nations[b].pacts[a] = true
	# марионетки: [сюзерен, марионетка]
	for pp in d.get("puppets", []):
		var a := world.nation_tags.find(pp[0])
		var b := world.nation_tags.find(pp[1])
		if a >= 0 and b >= 0:
			world.nations[b].overlord = a
	# войны, идущие на начало игры: [нападающий, жертва] (без союзников сторон)
	for w in d.get("wars", []):
		var a := world.nation_tags.find(w[0])
		var b := world.nation_tags.find(w[1])
		if a >= 0 and b >= 0 and world.nations[a].alive and world.nations[b].alive:
			world.set_war(a, b)
			world.nations[a].wargoals[b] = true
