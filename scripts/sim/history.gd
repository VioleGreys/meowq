class_name History
extends RefCounted
## Фокусы, исторические события и их эффекты. Данные — data/<сценарий>/
## focuses.json, events.json, areas.json. Всё выполняется в главном потоке.


static func load(world: World, dir: String) -> void:
	var f = JSON.parse_string(FileAccess.get_file_as_string(dir + "/focuses.json"))
	if typeof(f) == TYPE_DICTIONARY:
		world.focus_trees = f.get("trees", {})
	var e = JSON.parse_string(FileAccess.get_file_as_string(dir + "/events.json"))
	if typeof(e) == TYPE_DICTIONARY:
		world.event_defs = e.get("events", {})
		world.capitulation_rules = e.get("capitulation", [])
	var a = JSON.parse_string(FileAccess.get_file_as_string(dir + "/areas.json"))
	if typeof(a) == TYPE_DICTIONARY:
		world.areas = a


static func tree_of(world: World, n: int) -> Array:
	var tag: String = world.nation_tags[n]
	if world.focus_trees.has(tag):
		return world.focus_trees[tag]
	return world.focus_trees.get("_generic", [])


static func focus_def(world: World, n: int, id: String) -> Dictionary:
	for fd in tree_of(world, n):
		if fd["id"] == id:
			return fd
	return {}


static func tag_id(world: World, tag: String) -> int:
	return world.nation_tags.find(tag)


# --- Условия -------------------------------------------------------------------

## Пустая строка — условие выполнено; иначе понятная причина.
## ahead — сколько дней займёт фокус: дата в условии фокуса означает «завершить
## не раньше», поэтому начать его можно заранее.
static func check(world: World, n: int, cond: Dictionary, ahead: int = 0) -> String:
	if cond.has("date") and world.day + ahead < world.day_of(cond["date"]):
		return "не раньше %s" % _date_text(world, cond["date"])
	if cond.has("alive"):
		var t := tag_id(world, cond["alive"])
		if t < 0 or not world.nations[t].alive:
			return "страны %s больше нет" % (world.nations[t].name if t >= 0 else cond["alive"])
	if cond.has("flag") and not world.flags.has(cond["flag"]):
		return "нужно событие «%s»" % cond["flag"]
	if cond.has("not_flag") and world.flags.has(cond["not_flag"]):
		return "уже произошло"
	if cond.has("tension") and world.tension < float(cond["tension"]):
		return "нужна напряжённость %d%%" % cond["tension"]
	if cond.has("at_war_pair"):
		var a := tag_id(world, cond["at_war_pair"][0])
		var b := tag_id(world, cond["at_war_pair"][1])
		if a < 0 or b < 0 or not world.is_at_war(a, b):
			return "нужна война: %s — %s" % [cond["at_war_pair"][0], cond["at_war_pair"][1]]
	return ""


static func _date_text(world: World, date: String) -> String:
	var saved := world.day
	world.day = world.day_of(date)
	var s := world.date_string()
	world.day = saved
	return s


static func focus_block(world: World, n: int, fd: Dictionary) -> String:
	var nat: World.Nation = world.nations[n]
	if nat.focus_done.has(fd["id"]):
		return "выполнен"
	if nat.focus_current == fd["id"]:
		return "выполняется"
	for r in fd.get("requires", []):
		if not nat.focus_done.has(r):
			return "сначала: «%s»" % focus_def(world, n, r).get("name", r)
	return check(world, n, fd.get("available", {}), int(fd.get("days", 70)))


static func start_focus(world: World, n: int, id: String) -> bool:
	var nat: World.Nation = world.nations[n]
	var fd := focus_def(world, n, id)
	if fd.is_empty() or nat.focus_current != "" or focus_block(world, n, fd) != "":
		return false
	nat.focus_current = id
	nat.focus_days = int(fd.get("days", 70))
	return true


# --- Ежедневный ход --------------------------------------------------------------

static func daily(world: World, rng: RandomNumberGenerator) -> void:
	if world.focus_trees.is_empty() and world.event_defs.is_empty():
		return
	# фокусы
	for nat in world.nations:
		if not nat.alive:
			continue
		if nat.focus_current != "":
			nat.focus_days -= 1
			if nat.focus_days <= 0:
				var id: String = nat.focus_current
				nat.focus_current = ""
				nat.focus_done[id] = true
				var fd := focus_def(world, nat.id, id)
				if nat.is_player or nat.major:
					world.log_event("%s: «%s»" % [nat.name, fd.get("name", id)])
				apply(world, nat.id, fd.get("effects", []), rng)
		if nat.focus_current == "" and not nat.is_player:
			_ai_pick_focus(world, nat.id, rng)
		if not nat.is_player and world.day % 5 == nat.id % 5:
			nat.planned_wars = planned_wars(world, nat.id)
	# события, автоматически срабатывающие по дате
	for id in world.event_defs:
		var ev: Dictionary = world.event_defs[id]
		if ev.get("auto", false) and not world.events_fired.has(id):
			var already := false
			for q in world.event_queue:
				if q[0] == id:
					already = true
			if not already:
				world.event_queue.append([id, -1])
	# очередь событий: срабатывают, когда выполнены условия
	var keep: Array = []
	for q in world.event_queue:
		var id: String = q[0]
		var ev: Dictionary = world.event_defs.get(id, {})
		if ev.is_empty() or world.events_fired.has(id):
			continue
		var target := tag_id(world, ev.get("target", ""))
		if check(world, target, ev.get("trigger", {})) != "":
			keep.append(q)
			continue
		world.events_fired[id] = true
		if target < 0 or not world.nations[target].alive:
			# адресата нет — исторический исход по первому варианту не нужен
			continue
		if world.nations[target].is_player:
			world.pending_events.append(id)
		else:
			choose_option(world, id, _ai_option(world, ev, rng), rng)
	world.event_queue = keep


## С кем у страны запланирована война: текущий фокус и ближайший следующий
## (требования выполнены, дата ещё не наступила). ИИ готовится к ним заранее.
static func planned_wars(world: World, n: int) -> Dictionary:
	var nat: World.Nation = world.nations[n]
	var res := {}
	var look: Array = []
	if nat.focus_current != "":
		look.append(focus_def(world, n, nat.focus_current))
	for fd in tree_of(world, n):
		if nat.focus_done.has(fd["id"]) or fd["id"] == nat.focus_current:
			continue
		var ok := true
		for r in fd.get("requires", []):
			if not nat.focus_done.has(r):
				ok = false
		if ok:
			look.append(fd)
			break
	for fd in look:
		for e in fd.get("effects", []):
			if e.get("t", "") == "war":
				var t := tag_id(world, e["target"])
				if t >= 0 and world.nations[t].alive:
					res[t] = true
	return res


static func _ai_pick_focus(world: World, n: int, rng: RandomNumberGenerator) -> void:
	var avail: Array = []
	for fd in tree_of(world, n):
		if focus_block(world, n, fd) == "":
			avail.append(fd["id"])
	if avail.is_empty():
		return
	var id: String = avail[0] if world.historical else avail[rng.randi() % avail.size()]
	start_focus(world, n, id)


static func _ai_option(world: World, ev: Dictionary, rng: RandomNumberGenerator) -> int:
	var opts: Array = ev.get("options", [])
	if opts.is_empty():
		return -1
	if world.historical:
		var best := 0
		for i in opts.size():
			if float(opts[i].get("ai", 0)) > float(opts[best].get("ai", 0)):
				best = i
		return best
	var total := 0.0
	for o in opts:
		total += maxf(1.0, float(o.get("ai", 0)))
	var r := rng.randf() * total
	for i in opts.size():
		r -= maxf(1.0, float(opts[i].get("ai", 0)))
		if r <= 0.0:
			return i
	return 0


## Выбор варианта события (ИИ или игрок).
static func choose_option(world: World, id: String, option: int, rng: RandomNumberGenerator) -> void:
	var ev: Dictionary = world.event_defs.get(id, {})
	var opts: Array = ev.get("options", [])
	if option < 0 or option >= opts.size():
		return
	var target := tag_id(world, ev.get("target", ""))
	var o: Dictionary = opts[option]
	world.log_event("%s — %s: %s" % [ev.get("title", id), world.nations[target].name, o.get("name", "")])
	apply(world, target, o.get("effects", []), rng)


# --- Эффекты ---------------------------------------------------------------------

static func apply(world: World, n: int, effects: Array, rng: RandomNumberGenerator) -> void:
	for e in effects:
		var who := n
		if e.has("who"):
			who = tag_id(world, e["who"])
		if who < 0 or (not world.nations[who].alive and e["t"] != "release" and e["t"] != "civil_war"):
			continue
		var target := tag_id(world, e.get("target", "")) if e.has("target") else -1
		var nat: World.Nation = world.nations[who]
		match e["t"]:
			"tension":
				Diplomacy.add_tension(world, float(e["v"]))
			"factories":
				for k in int(e.get("civ", 0)):
					place_factory(world, who, "civ")
				for k in int(e.get("mil", 0)):
					place_factory(world, who, "mil")
			"bonus":
				nat.bonus[e["key"]] = float(nat.bonus.get(e["key"], 0.0)) + float(e["v"])
				nat.stats_dirty = true
			"tech":
				Tech.complete(nat, e["id"])
			"divisions":
				var keys := {"inf": Military.T_INF, "mnt": Military.T_MNT, "cav": Military.T_CAV,
					"art": Military.T_ART, "mot": Military.T_MOT, "arm": Military.T_ARM}
				if world.p_controller[nat.capital] == who:
					for k in int(e.get("n", 1)):
						world.spawn_division(who, nat.capital, keys.get(e.get("tpl", "inf"), 0))
			"manpower":
				nat.manpower += float(e["v"])
			"event":
				world.event_queue.append([e["id"], who])
			"flag":
				world.flags[e["id"]] = true
			"war":
				if target >= 0 and world.nations[target].alive and not world.is_at_war(who, target):
					nat.pacts.erase(target)
					world.nations[target].pacts.erase(who)
					nat.wargoals[target] = true
					if Diplomacy.same_side(world, who, target):
						continue
					Diplomacy.declare_war(world, who, target, not e.get("limited", false))
			"wargoal":
				if target >= 0:
					nat.wargoals[target] = true
			"guarantee":
				if target >= 0 and world.nations[target].alive:
					Diplomacy.guarantee(world, who, target)
			"pact":
				if target >= 0:
					Diplomacy.sign_pact(world, who, target)
			"break_pact":
				if target >= 0 and nat.pacts.has(target):
					Diplomacy.break_pact(world, who, target)
			"faction":
				if nat.faction < 0:
					var found := -1
					for f in world.factions:
						if f.alive and f.name == e["name"]:
							found = f.id
					if found >= 0:
						Diplomacy.join_faction(world, who, found)
					else:
						Diplomacy.create_faction(world, who, e["name"])
			"join_faction_of":
				if target >= 0 and world.nations[target].alive:
					if world.nations[target].faction < 0:
						Diplomacy.create_faction(world, target)
					var f: int = world.nations[target].faction
					if nat.faction != f:
						if nat.faction >= 0:
							Diplomacy.leave_faction(world, who)
						Diplomacy.join_faction(world, who, f)
			"annex":
				if target >= 0 and world.nations[target].alive:
					annex(world, who, target)
			"transfer":
				var to := tag_id(world, e["to"]) if e.has("to") else who
				transfer(world, area(world, e["area"]), to)
			"release":
				release(world, e["tag"], area(world, e["area"]), tag_id(world, e.get("puppet_of", "")))
			"civil_war":
				var spec: Dictionary = world.areas.get(e["area"], {})
				var old := tag_id(world, spec.get("owner", ""))
				var nt := release(world, e["tag"], area(world, e["area"]), -1, true)
				if nt >= 0 and old >= 0:
					world.set_war(nt, old)
					world.nations[nt].war_activity_day = world.day
					world.nations[old].war_activity_day = world.day
					world.log_event("Гражданская война: %s против страны %s" % [world.nations[nt].name, world.nations[old].name])
			"peace":
				if target >= 0 and world.is_at_war(who, target):
					make_white_peace(world, who, target)
			"vichy":
				pass   # обрабатывается при капитуляции (capitulation_hook)
			"log":
				world.log_event(e["text"])
	world.palette_dirty = true


## Провинции исторической области (по владельцу на текущий момент).
static func area(world: World, name: String) -> Array:
	var spec: Dictionary = world.areas.get(name, {})
	var owner := tag_id(world, spec.get("owner", ""))
	var res: Array = []
	if owner < 0:
		return res
	var adm: Array = spec.get("adm0", [])
	var boxes: Array = spec.get("boxes", [])
	var excl: Array = spec.get("exclude", [])
	var border: Array = []
	for t in spec.get("border_with", []):
		border.append(tag_id(world, t))
	for p in world.prov_count:
		if world.p_owner[p] != owner or world.p_land[p] == 0:
			continue
		var ll := world.p_lonlat[p]
		var inside := adm.is_empty() and boxes.is_empty()
		if adm.has(world.p_adm0[p]):
			inside = true
		for b in boxes:
			if ll.x >= b[0] and ll.y >= b[1] and ll.x <= b[2] and ll.y <= b[3]:
				inside = true
		if adm.size() > 0 and boxes.is_empty() and not adm.has(world.p_adm0[p]):
			inside = false
		for b in excl:
			if ll.x >= b[0] and ll.y >= b[1] and ll.x <= b[2] and ll.y <= b[3]:
				inside = false
		if inside and not border.is_empty():
			var touches := false
			for q in world.p_adj[p]:
				if border.has(world.p_owner[q]):
					touches = true
			inside = touches
		if inside:
			res.append(p)
	return res


## Мир между двумя странами (и их марионетками): оккупированное возвращается.
static func make_white_peace(world: World, a: int, b: int) -> void:
	var side_a := [a] + Diplomacy.puppets_of(world, a)
	var side_b := [b] + Diplomacy.puppets_of(world, b)
	for x in side_a:
		for y in side_b:
			if world.is_at_war(x, y):
				world.nations[x].at_war.erase(y)
				world.nations[y].at_war.erase(x)
				world.war[x * world.nation_count + y] = 0
				world.war[y * world.nation_count + x] = 0
	for p in world.prov_count:
		var o := world.p_owner[p]
		var c := world.p_controller[p]
		if o >= 0 and c != o and not world.is_at_war(o, c):
			world.p_controller[p] = o
	world.log_event("Мир между странами %s и %s" % [world.nations[a].name, world.nations[b].name])
	world.palette_dirty = true


static func place_factory(world: World, nid: int, mode: String) -> void:
	var best := -1
	var best_score := INF
	for p in world.prov_count:
		if world.p_owner[p] != nid or world.p_controller[p] != nid:
			continue
		var total := world.p_civ[p] + world.p_mil[p]
		if total >= Simulation.factory_slots(world, p):
			continue
		var score := float(total) - (2.0 if world.p_terrain[p] == World.T_URBAN else 0.0) + float(p % 7) * 0.01
		if score < best_score:
			best_score = score
			best = p
	if best < 0:
		return
	if mode == "civ":
		world.p_civ[best] += 1
	else:
		world.p_mil[best] += 1


## Передача провинций: войска прежнего владельца отходят к своей столице.
static func transfer(world: World, provs: Array, to: int) -> void:
	if provs.is_empty() or to < 0:
		return
	var old: int = world.p_owner[provs[0]]
	for p in provs:
		world.p_owner[p] = to
		world.p_controller[p] = to
	for d in world.divisions:
		if d.alive and provs.has(d.prov) and d.owner != to:
			var cap: int = world.nations[d.owner].capital
			if world.nations[d.owner].alive and cap >= 0 and world.p_controller[cap] == d.owner:
				_move(world, d, cap)
			else:
				d.alive = false
	if old >= 0 and old != to:
		world.log_event("%s передаёт %d пров. стране %s" % [world.nations[old].name, provs.size(), world.nations[to].name])
	_fix_capital(world, old)
	world.rebuild_prov_divs()
	world.palette_dirty = true


static func _move(world: World, d: World.Division, p: int) -> void:
	d.prov = p
	d.path = PackedInt32Array()
	d.progress = 0.0


## Мирное присоединение: земли, армия и заводы переходят целиком.
static func annex(world: World, who: int, target: int) -> void:
	var nt: World.Nation = world.nations[target]
	for p in world.prov_count:
		if world.p_owner[p] == target:
			world.p_owner[p] = who
			if world.p_controller[p] == target:
				world.p_controller[p] = who
		elif world.p_controller[p] == target:
			world.p_controller[p] = world.p_owner[p]
	for d in world.divisions:
		if d.alive and d.owner == target:
			d.owner = who
			d.group = -1
			Military.refresh_division(world, d)
	world.nations[who].manpower += nt.manpower
	for k in Military.EQ_COUNT:
		world.nations[who].stock[k] += nt.stock[k]
	world.end_wars_of(target)
	if nt.faction >= 0:
		Diplomacy.leave_faction(world, target)
	for p in Diplomacy.puppets_of(world, target):
		world.nations[p].overlord = -1
	nt.alive = false
	nt.training.clear()
	nt.justify_target = -1
	for o in world.nations:
		o.guarantees.erase(target)
		o.pacts.erase(target)
		o.wargoals.erase(target)
		if o.justify_target == target:
			o.justify_target = -1
	world.log_event("%s присоединяет страну %s" % [world.nations[who].name, nt.name])
	world.rebuild_prov_divs()
	world.palette_dirty = true


## Появление «спящего» государства на указанных провинциях. Войска прежнего
## владельца в этих провинциях переходят к новому (гражданская война, распад).
static func release(world: World, tag: String, provs: Array, overlord: int, take_army: bool = false) -> int:
	var n := tag_id(world, tag)
	if n < 0 or provs.is_empty():
		return -1
	var nat: World.Nation = world.nations[n]
	var old: int = world.p_owner[provs[0]]
	nat.alive = true
	nat.dormant = false
	# столица — ближайшая к исторической
	var best: int = provs[0]
	var best_d := INF
	for p in provs:
		var dd := world.p_lonlat[p].distance_squared_to(nat.capital_lonlat)
		if dd < best_d:
			best_d = dd
			best = p
	nat.capital = best
	for p in provs:
		world.p_owner[p] = n
		world.p_controller[p] = n
	var pop := 0
	for p in provs:
		pop += world.p_manpower[p]
	nat.manpower = pop * 0.5
	for d in world.divisions:
		if d.alive and provs.has(d.prov) and d.owner == old:
			if take_army:
				d.owner = n
				d.group = -1
				Military.refresh_division(world, d)
			else:
				var cap: int = world.nations[old].capital
				if cap >= 0 and not provs.has(cap):
					_move(world, d, cap)
				else:
					d.alive = false
	nat.overlord = overlord
	var income := world.compute_all_income()
	nat.civ = income[n][0]
	nat.mil = income[n][1]
	nat.stock = PackedFloat32Array([300.0 + nat.mil * 50.0, 40.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	Military.assign_free_factories(nat, Military.default_split(nat))
	if overlord >= 0:
		Diplomacy._inherit_wars(world, n, overlord)
	world.log_event("Появляется новое государство: %s" % nat.full_name)
	_fix_capital(world, old)
	world.rebuild_prov_divs()
	world.palette_dirty = true
	return n


static func _fix_capital(world: World, n: int) -> void:
	if n < 0 or not world.nations[n].alive:
		return
	var nat: World.Nation = world.nations[n]
	if world.p_owner[nat.capital] == n:
		return
	var best := -1
	for p in world.prov_count:
		if world.p_owner[p] == n and (best < 0 or world.p_vp[p] > world.p_vp[best]):
			best = p
	if best >= 0:
		nat.capital = best
	else:
		nat.alive = false


## Особые условия капитуляции (Компьенское перемирие, конец гражданской войны).
## true — капитуляция обработана здесь.
static func capitulation_hook(world: World, loser: int, winner: int, rng: RandomNumberGenerator) -> bool:
	for rule in world.capitulation_rules:
		if tag_id(world, rule["loser"]) != loser or tag_id(world, rule["winner"]) != winner:
			continue
		if rule.has("mode"):
			Diplomacy.make_peace(world, loser, winner, rule["mode"])
			return true
		for e in rule.get("effects", []):
			if e["t"] == "vichy":
				_vichy(world, loser, winner, e["tag"])
		if rule.has("log"):
			world.log_event(rule["log"])
		return true
	return false


static func _vichy(world: World, loser: int, winner: int, tag: String) -> void:
	# оккупированное остаётся оккупантам, неоккупированное — новому режиму
	var free: Array = []
	for p in world.prov_count:
		if world.p_owner[p] != loser:
			continue
		var c := world.p_controller[p]
		if c != loser and world.is_at_war(loser, c):
			world.p_owner[p] = c
		else:
			free.append(p)
	for d in world.divisions:
		if d.owner == loser:
			d.alive = false
	world.end_wars_of(loser)
	if world.nations[loser].faction >= 0:
		Diplomacy.leave_faction(world, loser)
	world.nations[loser].alive = false
	if not free.is_empty():
		for p in free:
			world.p_controller[p] = loser
		var v := release(world, tag, free, Diplomacy.root(world, winner))
		if v >= 0:
			world.nations[v].at_war.clear()
			for o in world.nations:
				o.at_war.erase(v)
			world.build_caches()
	world.rebuild_prov_divs()
	world.palette_dirty = true


## Человекочитаемое описание эффектов (для дерева фокусов и событий).
static func effects_text(world: World, effects: Array) -> String:
	var parts: Array = []
	var bonus_names := {"industry": "выпуск снаряжения", "research": "наука", "construction": "стройка",
		"attack": "атака", "defense": "оборона", "org": "организация", "speed": "скорость",
		"manpower": "призыв", "reinforce": "пополнение"}
	for e in effects:
		var tname := ""
		if e.has("target"):
			var t := tag_id(world, e["target"])
			tname = world.nations[t].name if t >= 0 else e["target"]
		var who := ""
		if e.has("who"):
			var w := tag_id(world, e["who"])
			who = (world.nations[w].name if w >= 0 else e["who"]) + ": "
		match e["t"]:
			"tension":
				parts.append("напряжённость %+d%%" % e["v"])
			"factories":
				if int(e.get("civ", 0)) > 0:
					parts.append("+%d гражд. фабр." % e["civ"])
				if int(e.get("mil", 0)) > 0:
					parts.append("+%d воен. зав." % e["mil"])
			"bonus":
				parts.append("%s%s %+d%%" % [who, bonus_names.get(e["key"], e["key"]), float(e["v"]) * 100.0])
			"tech":
				parts.append("технология «%s»" % Tech.get_tech(e["id"]).get("name", e["id"]))
			"divisions":
				parts.append("%s+%d дивизий" % [who, e.get("n", 1)])
			"manpower":
				parts.append("+%dк призывников" % e["v"])
			"event":
				parts.append("событие «%s»" % world.event_defs.get(e["id"], {}).get("title", e["id"]))
			"war":
				parts.append("%sвойна: %s" % [who, tname])
			"wargoal":
				parts.append("%sпретензии к стране %s" % [who, tname])
			"guarantee":
				parts.append("гарантия: %s" % tname)
			"pact":
				parts.append("пакт с %s" % tname)
			"break_pact":
				parts.append("разрыв пакта с %s" % tname)
			"faction":
				parts.append("фракция «%s»" % e["name"])
			"join_faction_of":
				parts.append("союз с %s" % tname)
			"annex":
				parts.append("%sприсоединение: %s" % [who, tname])
			"transfer":
				var to := tag_id(world, e.get("to", ""))
				parts.append("передача земель → %s" % (world.nations[to].name if to >= 0 else "нам"))
			"release":
				parts.append("новое государство")
			"civil_war":
				parts.append("гражданская война")
			"peace":
				parts.append("мир с %s" % tname)
	return "Эффекты: " + ", ".join(parts) if not parts.is_empty() else ""
