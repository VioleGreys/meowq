class_name Peace
extends RefCounted
## Конец войны и мирные переговоры (решение пользователя, ноябрь 2026).
##
## Капитуляция посреди войны не делит страну сразу: армия распущена, страна
## выходит из боёв (флаг capitulated), а её земли остаются оккупированными до
## конца всего конфликта. Конфликт — связная группа стран, воюющих друг с другом
## (две стороны по раскраске графа войн). Когда на одной стороне сдались все
## главные страны (не марионетки), собираются переговоры: победители ходят по
## кругу в порядке вклада (war_score) и тратят очки на земли проигравших:
##   • аннексия участка (страна × воздушный район) — цена по заводам, фабрикам,
##     ресурсам и очкам победы, своё занятое дешевле;
##   • марионетка — страна-проигравший с оставшимися землями становится
##     марионеткой победителя;
##   • освобождение — страна с оставшимися землями становится независимой,
##     со строем освободителя, и вступает в его фракцию.
## Неразобранное остаётся прежнему владельцу. Исторические правила капитуляции
## (Виши, Московский мир, раздел Польши…) — отдельный мир, как и прежде.
##
## Вклад: занятые провинции врага (очки победы + 1), потери, нанесённые врагу в
## боях, помощь (ленд-лиз). Очки марионеток идут сюзерену.

const SCORE_KILL := 0.05     # за единицу численности, потерянную врагом в бою
const SCORE_AID := 0.02      # за единицу снаряжения, отправленного помощью
const BUDGET_K := 1.2        # очки всех победителей = стоимость всех земель × 1,2
const OCC_DISCOUNT := 0.75   # участок, который победитель сам держит, дешевле
const PUPPET_K := 0.5        # марионетка: доля стоимости оставшихся земель
const FREE_K := 0.3          # освобождение
const AI_MIN_RATIO := 0.5    # ИИ берёт, только если ценность/цена не ниже
const OTHER_ANNEX := 1.5     # участок, занятый другим победителем, — дороже при аннексии
const OTHER_REST := 3.0      # …и при марионетке или освобождении страны


static func add_score(world: World, n: int, v: float) -> void:
	if n >= 0 and v > 0.0:
		world.nations[n].war_score += v


## Цена провинции: заводы и фабрики, ресурсы, очки победы.
static func prov_cost(world: World, p: int, res: PackedFloat32Array) -> float:
	return 1.0 + 2.0 * world.p_civ[p] + 3.0 * world.p_mil[p] + 0.1 * res[p] + 0.2 * world.p_vp[p]


static func _res_by_prov(world: World) -> PackedFloat32Array:
	var res := PackedFloat32Array()
	res.resize(world.prov_count)
	var rc := Economy.RES_COUNT
	for i in world.res_prov.size():
		var s := 0.0
		for r in rc:
			s += world.res_val[i * rc + r]
		res[world.res_prov[i]] += s
	return res


# --- Капитуляция -------------------------------------------------------------

## Страна сдаётся: армия, флот и авиация распущены, всё своё занимает главный
## победитель, чужое, что она держала, возвращается владельцам. Земли ждут
## переговоров в конце войны.
static func capitulate(world: World, loser: int, winner: int) -> void:
	var nl: World.Nation = world.nations[loser]
	nl.capitulated = true
	nl.exile = false
	world.focus_epoch += 1
	for d in world.divisions:
		if d.alive and d.owner == loser:
			d.alive = false
	for f in world.fleets:
		if f.owner == loser:
			f.alive = false
	for wg in world.wings:
		if wg.owner == loser:
			wg.alive = false
	nl.training.clear()
	nl.justify_target = -1
	nl.focus_current = ""
	for p in world.prov_count:
		var c := world.p_controller[p]
		if world.p_owner[p] == loser and c == loser:
			world.p_controller[p] = winner
		elif c == loser:
			world.p_controller[p] = world.p_owner[p]
	Diplomacy.add_tension(world, 1.0)
	world.log_event("%s капитулирует: страна оккупирована до конца войны (%s)" % [nl.name, world.nations[winner].name])
	world.palette_dirty = true
	world.rebuild_prov_divs()


# --- Конец войны -------------------------------------------------------------

## Раз в день: не кончилась ли какая-то война (сдались все главные страны стороны).
static func check_end(world: World) -> void:
	if not world.conference.is_empty():
		return
	var nc := world.nation_count
	var color := PackedInt32Array()
	color.resize(nc)
	color.fill(-1)
	for s in nc:
		var ns: World.Nation = world.nations[s]
		if color[s] >= 0 or not ns.alive or ns.at_war.is_empty():
			continue
		# обход группы воюющих стран; цвет — сторона
		var sides: Array = [[], []]
		var queue := [s]
		color[s] = 0
		var qi := 0
		while qi < queue.size():
			var a: int = queue[qi]
			qi += 1
			sides[color[a]].append(a)
			var ks: Array = world.nations[a].at_war.keys()
			ks.sort()
			for b in ks:
				if color[b] < 0 and world.nations[b].alive:
					color[b] = 1 - color[a]
					queue.append(b)
		for k in 2:
			if _defeated(world, sides[k]) and not _defeated(world, sides[1 - k]):
				start(world, sides[1 - k], sides[k])
				return


static func _defeated(world: World, side: Array) -> bool:
	var main := 0
	for n in side:
		var nat: World.Nation = world.nations[n]
		if nat.overlord >= 0:
			continue
		main += 1
		if not nat.capitulated:
			return false
	if main > 0:
		return true
	for n in side:
		if not world.nations[n].capitulated:
			return false
	return not side.is_empty()


# --- Переговоры --------------------------------------------------------------

## Начать переговоры: победители (главные, не сдавшиеся) против проигравших.
static func start(world: World, side_w: Array, side_l: Array) -> void:
	var score := {}
	for n in side_w:
		var nat: World.Nation = world.nations[n]
		if nat.capitulated:
			continue
		var r := Diplomacy.root(world, n)
		if world.nations[r].capitulated or not side_w.has(r):
			r = n
		score[r] = float(score.get(r, 0.0)) + nat.war_score
	var winners: Array = score.keys()
	winners.sort_custom(func(a, b): return score[a] > score[b] if score[a] != score[b] else a < b)
	var losers: Array = side_l.duplicate()
	losers.sort()
	var res := _res_by_prov(world)
	# участки: владелец × воздушный район
	var idx := {}
	var u_owner := PackedInt32Array()
	var u_provs: Array = []
	var u_cost := PackedFloat32Array()
	var u_big := PackedInt32Array()
	for p in world.prov_count:
		var o := world.p_owner[p]
		if o < 0 or world.p_land[p] == 0 or not losers.has(o):
			continue
		var reg := world.p_region[p] if p < world.p_region.size() else -1
		var key := o * 100000 + (reg if reg >= 0 else 50000 + p % 50000)
		if not idx.has(key):
			idx[key] = u_owner.size()
			u_owner.append(o)
			u_provs.append(PackedInt32Array())
			u_cost.append(0.0)
			u_big.append(p)
		var u: int = idx[key]
		var pa: PackedInt32Array = u_provs[u]
		pa.append(p)
		u_provs[u] = pa
		u_cost[u] += prov_cost(world, p, res)
		if world.p_vp[p] > world.p_vp[u_big[u]]:
			u_big[u] = p
	var total := 0.0
	for c in u_cost:
		total += c
	var sum := 0.0
	for w in winners:
		sum += float(score[w])
	var budget := {}
	for w in winners:
		var share: float = float(score[w]) / sum if sum > 0.0 else 1.0 / float(winners.size())
		budget[w] = total * BUDGET_K * share
	var taken := PackedInt32Array()
	taken.resize(u_owner.size())
	taken.fill(-1)
	world.conference = {"winners": winners, "losers": losers, "score": score, "budget": budget,
		"u_owner": u_owner, "u_provs": u_provs, "u_cost": u_cost, "u_big": u_big, "u_taken": taken,
		"puppet": {}, "free": {}, "turn": 0, "passes": 0, "out": {}, "log": []}
	var wn: Array = []
	for w in winners:
		wn.append(world.nations[w].name)
	var ln: Array = []
	for l in losers:
		ln.append(world.nations[l].name)
	world.log_event("Мирная конференция: %s побеждают (%s)" % [", ".join(wn), ", ".join(ln)])
	run(world)


## Доли провинций участка: [у победителя w, у другого победителя].
static func _held(world: World, u: int, w: int) -> Vector2:
	var c: Dictionary = world.conference
	var provs: PackedInt32Array = c["u_provs"][u]
	var ws: Array = c["winners"]
	var mine := 0
	var other := 0
	for p in provs:
		var ctl := world.p_controller[p]
		if ctl == w:
			mine += 1
		elif ctl >= 0 and ws.has(Diplomacy.root(world, ctl)):
			other += 1
	return Vector2(mine, other) / float(provs.size())


## Цена участка для победителя w: своё занятое дешевле, чужое занятое дороже.
static func unit_price(world: World, u: int, w: int) -> float:
	var h := _held(world, u, w)
	return float(world.conference["u_cost"][u]) * (1.0 - (1.0 - OCC_DISCOUNT) * h.x + (OTHER_ANNEX - 1.0) * h.y)


## Цена марионетки или освобождения страны l для w (k — PUPPET_K / FREE_K).
static func _rest_price(world: World, l: int, w: int, k: float) -> float:
	var c: Dictionary = world.conference
	var taken: PackedInt32Array = c["u_taken"]
	var s := 0.0
	for u in taken.size():
		if taken[u] == -1 and int(c["u_owner"][u]) == l:
			s += float(c["u_cost"][u]) * (1.0 + (OTHER_REST - 1.0) * _held(world, u, w).y)
	return s * k


## Свободные участки страны-проигравшего и их стоимость.
static func rest_cost(world: World, l: int) -> float:
	var c: Dictionary = world.conference
	var s := 0.0
	var taken: PackedInt32Array = c["u_taken"]
	var owner: PackedInt32Array = c["u_owner"]
	for u in taken.size():
		if taken[u] == -1 and owner[u] == l:
			s += float(c["u_cost"][u])
	return s


## Цена действия: kind = "annex" (arg — участок), "puppet" / "free" (arg — страна).
static func price(world: World, w: int, kind: String, arg: int) -> float:
	match kind:
		"annex":
			return unit_price(world, arg, w)
		"puppet":
			return _rest_price(world, arg, w, PUPPET_K)
		"free":
			return _rest_price(world, arg, w, FREE_K)
	return INF


static func can_do(world: World, w: int, kind: String, arg: int) -> bool:
	var c: Dictionary = world.conference
	if c.is_empty():
		return false
	if kind == "annex":
		if c["u_taken"][arg] != -1:
			return false
	elif rest_cost(world, arg) <= 0.0:
		return false
	return price(world, w, kind, arg) <= float(c["budget"][w]) + 0.001


## Кто сейчас ходит (-1 — переговоры закончены).
static func current(world: World) -> int:
	var c: Dictionary = world.conference
	if c.is_empty():
		return -1
	var ws: Array = c["winners"]
	return ws[int(c["turn"]) % ws.size()]


## Ход игрока или ИИ. kind = "annex" / "puppet" / "free" / "pass" / "done".
static func act(world: World, w: int, kind: String, arg: int = -1) -> void:
	var c: Dictionary = world.conference
	if c.is_empty() or current(world) != w:
		return
	if kind == "done":
		c["out"][w] = true
	elif kind == "pass" or not can_do(world, w, kind, arg):
		c["passes"] = int(c["passes"]) + 1
	else:
		c["budget"][w] = float(c["budget"][w]) - price(world, w, kind, arg)
		c["passes"] = 0
		if kind == "annex":
			c["u_taken"][arg] = w
			c["log"].append("%s: %s" % [world.nations[w].name, world.p_name[c["u_big"][arg]]])
		else:
			var taken: PackedInt32Array = c["u_taken"]
			for u in taken.size():
				if taken[u] == -1 and int(c["u_owner"][u]) == arg:
					taken[u] = -2   # остаётся стране (марионетке или освобождённой)
			c["u_taken"] = taken
			c[kind][arg] = w
			c["log"].append("%s: %s — %s" % [world.nations[w].name, world.nations[arg].name,
					"марионетка" if kind == "puppet" else "освобождение"])
	c["turn"] = int(c["turn"]) + 1
	world.pending_peace.clear()
	run(world)


## Ходы ИИ до хода игрока или до конца переговоров.
static func run(world: World) -> void:
	var guard := 0
	while not world.conference.is_empty() and guard < 100000:
		guard += 1
		var c: Dictionary = world.conference
		var ws: Array = c["winners"]
		if ws.is_empty() or not _any_free(c) or int(c["passes"]) >= ws.size() or c["out"].size() >= ws.size():
			finish(world)
			return
		var w := current(world)
		if c["out"].has(w):
			c["turn"] = int(c["turn"]) + 1
			c["passes"] = int(c["passes"]) + 1
			continue
		if world.nations[w].is_player:
			# ждём выбора игрока (окно «Мирная конференция»; ход стоит)
			world.pending_peace = [[-1, w]]
			return
		var pick := ai_pick(world, w)
		if pick.is_empty():
			c["out"][w] = true
			c["turn"] = int(c["turn"]) + 1
			continue
		act(world, w, pick[0], pick[1])
		return


static func _any_free(c: Dictionary) -> bool:
	for t in c["u_taken"]:
		if t == -1:
			return true
	return false


## Выбор ИИ: лучшее отношение ценности к цене. Держит участок или граничит с ним —
## ценнее; демократии почти не аннексируют метрополии и охотно освобождают,
## остальные — аннексируют занятое и берут марионеток.
static func ai_pick(world: World, w: int) -> Array:
	var c: Dictionary = world.conference
	var budget: float = c["budget"][w]
	var nat: World.Nation = world.nations[w]
	var demo := nat.ideology == "democracy"
	var best: Array = []
	var best_r := AI_MIN_RATIO
	var taken: PackedInt32Array = c["u_taken"]
	for u in taken.size():
		if taken[u] != -1:
			continue
		var pr := unit_price(world, u, w)
		if pr > budget:
			continue
		var provs: PackedInt32Array = c["u_provs"][u]
		var mine := 0
		var adj := false
		var colony := false
		for p in provs:
			if world.p_controller[p] == w:
				mine += 1
			if world.p_colony.size() == world.prov_count and world.p_colony[p] == 1:
				colony = true
			if not adj:
				for q in world.p_adj[p]:
					if world.p_owner[q] == w:
						adj = true
						break
		var share := float(mine) / float(provs.size())
		var v := float(c["u_cost"][u]) * (share * 1.5 + (0.5 if adj else 0.0) + 0.2)
		if demo and not colony:
			v *= 0.4
		var r := v / maxf(0.01, pr)
		if r > best_r:
			best_r = r
			best = ["annex", u]
	for l in c["losers"]:
		var rest := rest_cost(world, l)
		if rest <= 0.0:
			continue
		var held := 0.0
		var all := 0.0
		for u in taken.size():
			if taken[u] == -1 and int(c["u_owner"][u]) == l:
				for p in c["u_provs"][u]:
					all += 1.0
					var ctl := world.p_controller[p]
					if ctl == w or (ctl >= 0 and Diplomacy.same_side(world, ctl, w)):
						held += 1.0
		var share := held / maxf(1.0, all)
		if share < 0.3:
			continue
		var free_v := rest * share * (1.5 if demo or nat.ideology == "communism" else 0.5)
		var pup_v := rest * share * (0.6 if demo else 1.2)
		var fp := _rest_price(world, l, w, FREE_K)
		var pp := _rest_price(world, l, w, PUPPET_K)
		if fp <= budget and free_v / fp > best_r:
			best_r = free_v / fp
			best = ["free", l]
		if pp <= budget and pup_v / pp > best_r:
			best_r = pup_v / pp
			best = ["puppet", l]
	return best


## Итоги: земли переходят, войны кончаются, сдавшиеся победители возвращаются.
static func finish(world: World) -> void:
	var c: Dictionary = world.conference
	world.conference = {}
	world.pending_peace.clear()
	world.focus_epoch += 1
	var losers: Array = c["losers"]
	var winners: Array = c["winners"]
	var taken: PackedInt32Array = c["u_taken"]
	var got := {}
	for u in taken.size():
		var w := taken[u]
		if w < 0:
			continue
		var from := int(c["u_owner"][u])
		var provs: PackedInt32Array = c["u_provs"][u]
		for p in provs:
			world.p_owner[p] = w
			world.p_controller[p] = w
		Occupation.on_annex(world, provs, w, from)
		got[w] = int(got.get(w, 0)) + 1
	for w in winners:
		if got.has(w):
			world.log_event("Мир: %s присоединяет %d уч. земель проигравших" % [world.nations[w].name, got[w]])
	# войны проигравших кончаются
	for l in losers:
		world.end_wars_of(l)
	# сдавшиеся в этой войне снова свободны (Польша, Нидерланды у победителей)
	for nat in world.nations:
		if nat.alive and nat.capitulated and nat.at_war.is_empty():
			nat.capitulated = false
			nat.exile = false
	for p in world.prov_count:
		var o := world.p_owner[p]
		var ctl := world.p_controller[p]
		if o >= 0 and ctl != o and not world.is_at_war(o, ctl):
			world.p_controller[p] = o
	for l in losers:
		var nl: World.Nation = world.nations[l]
		nl.capitulated = false
		nl.exile = false
		nl.wargoals.clear()
		var has := false
		for p in world.prov_count:
			if world.p_owner[p] == l:
				has = true
				break
		if not has:
			_dissolve(world, l)
			continue
		if nl.faction >= 0:
			Diplomacy.leave_faction(world, l)
		if c["puppet"].has(l):
			var w: int = c["puppet"][l]
			nl.overlord = Diplomacy.root(world, w)
			nl.puppet_since = world.day
			nl.freedom = Puppets.START_FREEDOM
			world.log_event("Мир: %s становится марионеткой страны %s" % [nl.name, world.nations[nl.overlord].name])
		elif c["free"].has(l):
			var w: int = c["free"][l]
			nl.overlord = -1
			nl.ideology = world.nations[w].ideology
			world.log_event("Мир: %s освобождена, новый строй — %s" % [nl.name, world.ideology_names.get(nl.ideology, nl.ideology)])
			var f: int = world.nations[w].faction
			if f >= 0:
				Diplomacy.join_faction(world, l, f)
		else:
			nl.overlord = -1
		_fix_capital(world, l)
	# дивизии на чужой земле после мира — домой
	for d in world.divisions:
		if not d.alive:
			continue
		var ctl := world.p_controller[d.prov]
		if ctl == d.owner or (ctl >= 0 and (Diplomacy.same_side(world, ctl, d.owner) or world.is_at_war(ctl, d.owner))):
			continue
		var cap: int = world.nations[d.owner].capital
		if cap >= 0 and world.p_controller[cap] == d.owner:
			d.prov = cap
			d.path = PackedInt32Array()
			d.progress = 0.0
		else:
			d.alive = false
	for n in winners + losers:
		world.nations[n].war_score = 0.0
	world.col_done.clear()
	world.palette_dirty = true
	world.rebuild_prov_divs()


static func _fix_capital(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	if nat.capital >= 0 and world.p_owner[nat.capital] == n:
		return
	var best := -1
	for p in world.prov_count:
		if world.p_owner[p] == n and (best < 0 or world.p_vp[p] > world.p_vp[best]):
			best = p
	nat.capital = best


## Страна без земли исчезает.
static func _dissolve(world: World, l: int) -> void:
	var nl: World.Nation = world.nations[l]
	if nl.faction >= 0:
		Diplomacy.leave_faction(world, l)
	for p in Diplomacy.puppets_of(world, l):
		world.nations[p].overlord = -1
	nl.alive = false
	nl.training.clear()
	for d in world.divisions:
		if d.owner == l:
			d.alive = false
	for f in world.fleets:
		if f.owner == l:
			f.alive = false
	for wg in world.wings:
		if wg.owner == l:
			wg.alive = false
	for o in world.nations:
		o.guarantees.erase(l)
		o.pacts.erase(l)
		o.wargoals.erase(l)
		if o.justify_target == l:
			o.justify_target = -1
	world.log_event("Мир: %s перестаёт существовать" % nl.name)


## Отладка и скриншоты (--peace=TAG): страна сдаётся стране w, сразу переговоры.
static func debug_start(world: World, loser: int, w: int) -> void:
	if not world.nations[loser].capitulated:
		capitulate(world, loser, w)
	start(world, [w], [loser])
