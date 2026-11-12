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
	# индекс id -> фокус по деревьям (строится один раз)
	var tag: String = world.nation_tags[n]
	if not world.focus_trees.has(tag):
		tag = "_generic"
	var idx: Dictionary = world.focus_index.get(tag, {})
	if idx.is_empty():
		for fd in world.focus_trees.get(tag, []):
			idx[fd["id"]] = fd
		world.focus_index[tag] = idx
	return idx.get(id, {})


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
	if cond.has("dead"):
		var td := tag_id(world, cond["dead"])
		if td >= 0 and world.nations[td].alive:
			return "пока существует страна %s" % world.nations[td].name
	if cond.has("flag") and not world.flags.has(cond["flag"]):
		return "нужно событие «%s»" % cond["flag"]
	if cond.has("not_flag") and world.flags.has(cond["not_flag"]):
		return "уже произошло"
	if cond.has("tension") and world.tension < float(cond["tension"]):
		return "нужна напряжённость %d%%" % cond["tension"]
	if cond.has("at_war"):
		var nat_w: World.Nation = world.nations[n]
		if bool(cond["at_war"]) != (not nat_w.at_war.is_empty()):
			return "нужна война" if bool(cond["at_war"]) else "только в мирное время"
	if cond.has("ideology") and world.nations[n].ideology != String(cond["ideology"]):
		return "нужен строй: %s" % world.ideology_names.get(cond["ideology"], cond["ideology"])
	if cond.has("at_war_pair"):
		var a := tag_id(world, cond["at_war_pair"][0])
		var b := tag_id(world, cond["at_war_pair"][1])
		if a < 0 or b < 0 or not world.is_at_war(a, b):
			return "нужна война: %s — %s" % [cond["at_war_pair"][0], cond["at_war_pair"][1]]
	return ""


## То же, что check(...) == "", без строк причин (те же условия по порядку).
static func check_ok(world: World, n: int, cond: Dictionary, ahead: int = 0) -> bool:
	if cond.is_empty():
		return true
	if cond.has("date") and world.day + ahead < world.day_of(cond["date"]):
		return false
	if cond.has("alive"):
		var t := tag_id(world, cond["alive"])
		if t < 0 or not world.nations[t].alive:
			return false
	if cond.has("dead"):
		var td := tag_id(world, cond["dead"])
		if td >= 0 and world.nations[td].alive:
			return false
	if cond.has("flag") and not world.flags.has(cond["flag"]):
		return false
	if cond.has("not_flag") and world.flags.has(cond["not_flag"]):
		return false
	if cond.has("tension") and world.tension < float(cond["tension"]):
		return false
	if cond.has("at_war"):
		var nat_w: World.Nation = world.nations[n]
		if bool(cond["at_war"]) != (not nat_w.at_war.is_empty()):
			return false
	if cond.has("ideology") and world.nations[n].ideology != String(cond["ideology"]):
		return false
	if cond.has("at_war_pair"):
		var a := tag_id(world, cond["at_war_pair"][0])
		var b := tag_id(world, cond["at_war_pair"][1])
		if a < 0 or b < 0 or not world.is_at_war(a, b):
			return false
	return true


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
	# развилка: выбран другой путь
	for x in fd.get("exclusive", []):
		if nat.focus_done.has(x) or nat.focus_current == x:
			return "выбран другой путь: «%s»" % focus_def(world, n, x).get("name", x)
	# любой из (requires_any)
	var any_req: Array = fd.get("requires_any", [])
	if not any_req.is_empty():
		var ok := false
		for r in any_req:
			if nat.focus_done.has(r):
				ok = true
		if not ok:
			return "сначала один из: %s" % ", ".join(any_req.map(func(r): return "«%s»" % focus_def(world, n, r).get("name", r)))
	return check(world, n, fd.get("available", {}), int(fd.get("days", 70)))


## То же, что focus_block(...) == "", но без строк причин (для ИИ): условия
## проверяются в том же порядке.
static func focus_open(world: World, n: int, fd: Dictionary) -> bool:
	var nat: World.Nation = world.nations[n]
	var id: String = fd["id"]
	if nat.focus_done.has(id) or nat.focus_current == id:
		return false
	for r in fd.get("requires", []):
		if not nat.focus_done.has(r):
			return false
	for x in fd.get("exclusive", []):
		if nat.focus_done.has(x) or nat.focus_current == x:
			return false
	var any_req: Array = fd.get("requires_any", [])
	if not any_req.is_empty():
		var ok := false
		for r in any_req:
			if nat.focus_done.has(r):
				ok = true
				break
		if not ok:
			return false
	return check_ok(world, n, fd.get("available", {}), int(fd.get("days", 70)))


static func start_focus(world: World, n: int, id: String) -> bool:
	var nat: World.Nation = world.nations[n]
	var fd := focus_def(world, n, id)
	if fd.is_empty() or nat.focus_current != "" or not focus_open(world, n, fd):
		return false
	nat.focus_current = id
	nat.focus_days = int(fd.get("days", 70))
	return true


# --- Ежедневный ход --------------------------------------------------------------

static func daily(world: World, rng: RandomNumberGenerator) -> void:
	if world.focus_trees.is_empty() and world.event_defs.is_empty():
		return
	# отложенные эффекты, срок которых наступил
	if not world.scheduled.is_empty():
		var keep_s: Array = []
		var due: Array = []
		for sc in world.scheduled:
			if world.day >= int(sc[0]):
				due.append(sc)
			else:
				keep_s.append(sc)
		world.scheduled = keep_s
		for sc in due:
			apply(world, int(sc[1]), sc[2], rng)
	# добровольцы (черты с ключом volunteers — дивизий в месяц), пока страна воюет
	if world.month_of(world.day) != world.month_of(world.day - 1):
		for nat in world.nations:
			var vol: float = nat.b("volunteers")
			if vol > 0.0 and nat.alive and not nat.capitulated and not nat.at_war.is_empty() and nat.capital >= 0 \
					and world.p_controller[nat.capital] == nat.id:
				nat.volunteer_acc += vol
				while nat.volunteer_acc >= 1.0:
					nat.volunteer_acc -= 1.0
					world.spawn_division(nat.id, nat.capital, Military.T_INF)
	# фокусы (у сдавшейся страны правительства нет — фокусы стоят)
	for nat in world.nations:
		if not nat.alive or nat.capitulated:
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
				# условия шансов событий фокуса — на день его завершения
				for fe in fd.get("effects", []):
					if fe.get("t", "") == "event":
						world.event_snap[String(fe["id"])] = snapshot(world, String(fe["id"]), nat.id)
				apply(world, nat.id, fd.get("effects", []), rng)
				nat.prep_day = -1   # сверить план подготовки
		var _pt := Time.get_ticks_usec()
		if nat.focus_current == "" and not nat.is_player:
			_ai_pick_focus(world, nat.id, rng)
		Prof.add("ист:выбор фокуса", _pt)
		_pt = Time.get_ticks_usec()
		if not nat.is_player and world.day % 5 == nat.id % 5:
			# зависят только от фокусов (текущий, выполненные) и живы ли цели:
			# пересчёт — при смене фокусов, иначе раз в 30 дней
			var key := "%s|%d" % [nat.focus_current, nat.focus_done.size()]
			if key != nat.pw_key or world.day - nat.pw_day >= 30:
				nat.pw_key = key
				nat.pw_day = world.day
				nat.planned_wars = planned_wars(world, nat.id)
		Prof.add("ист:планы войн", _pt)
		_pt = Time.get_ticks_usec()
		# план подготовки к событиям: в начале партии и после каждого фокуса
		if not nat.is_player and nat.prep_day < 0:
			_ai_prepare(world, nat.id)
		Prof.add("ист:подготовка", _pt)
	# события, автоматически срабатывающие по дате
	for id in world.event_defs:
		var ev: Dictionary = world.event_defs[id]
		if ev.get("auto", false) and not world.events_fired.has(id):
			var already := false
			for q in world.event_queue:
				if q[0] == id:
					already = true
			if not already:
				world.event_queue.append([id, -1, 0])
	# очередь событий: срабатывают, когда выполнены условия
	var keep: Array = []
	for q in world.event_queue:
		var id: String = q[0]
		var ev: Dictionary = world.event_defs.get(id, {})
		if ev.is_empty() or world.events_fired.has(id):
			continue
		# событие от фокуса или другого события наступает не раньше следующего дня
		if q.size() > 2 and world.day < int(q[2]):
			keep.append(q)
			continue
		var target := tag_id(world, ev.get("target", ""))
		if check(world, target, ev.get("trigger", {})) != "":
			keep.append(q)
			continue
		world.events_fired[id] = true
		world.event_from[id] = int(q[1])
		if target < 0 or not world.nations[target].alive:
			# адресата нет — исторический исход по первому варианту не нужен
			continue
		if world.nations[target].is_player and event_has_choice(ev):
			world.pending_events.append(id)
			world.pending_since[id] = world.day
		elif world.nations[target].is_player:
			# гарантированное или с одним вариантом — применяется сразу, игроку лист
			var k := _ai_option(world, ev, rng)
			choose_option(world, id, k, rng)
			world.info_events.append(id)
			world.info_option[id] = k
		else:
			choose_option(world, id, _ai_answer(world, id, ev, rng), rng)
	world.event_queue = keep
	_answer_overdue(world, rng)


## Есть ли у события выбор: несколько вариантов и исход не гарантирован
## (поле "guaranteed" — событие фокуса с гарантированным исходом).
static func event_has_choice(ev: Dictionary) -> bool:
	return ev.get("options", []).size() > 1 and not ev.get("guaranteed", false)


## День, после которого событие игрока выбирается само (через
## EVENT_ANSWER_DAYS дней); гарантированные и с одним вариантом применяются
## сразу при наступлении и сюда не попадают.
static func event_deadline(world: World, id: String) -> int:
	var since: int = int(world.pending_since.get(id, world.day))
	var ev: Dictionary = world.event_defs.get(id, {})
	return since + (World.EVENT_ANSWER_DAYS if event_has_choice(ev) else 0)


## Игрок не ответил в срок: исторический вариант в историческом режиме,
## иначе случайный.
static func _answer_overdue(world: World, rng: RandomNumberGenerator) -> void:
	if world.pending_events.is_empty():
		return
	var left: Array = []
	for id in world.pending_events:
		var sid: String = id
		if world.day <= event_deadline(world, sid):
			left.append(sid)
			continue
		var ev: Dictionary = world.event_defs.get(sid, {})
		var opts: Array = ev.get("options", [])
		var k := 0
		if not event_has_choice(ev):
			k = _ai_option(world, ev, rng)   # гарантированный исход — исторический вариант
		elif world.historical:
			k = _ai_option(world, ev, rng)
		else:
			k = rng.randi_range(0, opts.size() - 1)
		world.pending_since.erase(sid)
		if event_has_choice(ev):
			world.log_event("Ответ не дан в срок — выбрано само")
		choose_option(world, sid, k, rng)
	world.pending_events = left


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
		var effs: Array = fd.get("effects", []).duplicate()
		for e in fd.get("effects", []):
			if e.get("t", "") == "later":
				effs.append_array(e.get("effects", []))
		for e in effs:
			if e.get("t", "") == "war":
				var t := tag_id(world, e["target"])
				if t >= 0 and world.nations[t].alive:
					res[t] = true
	return res


static func _ai_pick_focus(world: World, n: int, rng: RandomNumberGenerator) -> void:
	var nat: World.Nation = world.nations[n]
	# фокусы проверяются, когда закончен предыдущий; если взять было нечего —
	# снова в день, когда по дате откроется ближайший, или когда мир изменился
	if world.day < nat.focus_wait_until and nat.focus_wait_epoch == world.focus_epoch:
		return
	var _pf := Time.get_ticks_usec()
	var avail: Array = []
	for fd in tree_of(world, n):
		if focus_open(world, n, fd):
			avail.append(fd["id"])
	Prof.add("фок:доступные", _pf)
	_pf = Time.get_ticks_usec()
	if avail.is_empty():
		_ai_wait(world, n)
		Prof.add("фок:ожидание", _pf)
		return
	# ИИ идёт строго по исторической ветке в любом режиме: развилки — первый путь
	# в списке, сроки — исторические. Варианты для ИИ добавим позже.
	_ai_pick_historical(world, n, avail)
	Prof.add("фок:исторический", _pf)


## Исторический ИИ: фокусы по сроку. Для каждого датированного фокуса считается
## последний день, когда нужно начать всю цепочку его невыполненных требований,
## чтобы закончить к дате. Сначала — шаги цепочки самого срочного, остальное —
## по порядку списка, если успевает до срока; иначе ждать.
static func _ai_pick_historical(world: World, n: int, avail: Array) -> void:
	var nat: World.Nation = world.nations[n]
	var memo := {}
	var targets: Array = []   # [день срока, цепочка]
	for fd in tree_of(world, n):
		var cond: Dictionary = fd.get("available", {})
		if not cond.has("date") or nat.focus_done.has(fd["id"]) or _excluded(world, n, fd) \
				or not _is_key(fd) or _is_alternative(world, n, fd):
			continue
		var chain := {}
		_chain_days(world, n, fd, memo, chain)
		var alt := false
		for cid in chain:
			if _is_alternative(world, n, focus_def(world, n, cid)):
				alt = true   # фокус небывшего пути — не срок для истории
		if not alt:
			targets.append([world.day_of(cond["date"]), chain])
	targets.sort_custom(func(x, y): return x[0] < y[0])
	# запас: к каждому сроку нужно успеть все цепочки сроков до него включительно
	var min_slack := 1 << 30
	var union := {}
	var before: Array = []   # запас сроков, которые раньше данного
	for tg in targets:
		before.append(min_slack)
		union.merge(tg[1])
		var work := 0
		for cid in union:
			work += nat.focus_days if nat.focus_current == cid else int(focus_def(world, n, cid).get("days", 70))
		min_slack = mini(min_slack, int(tg[0]) - world.day - work)
	# альтернативы исторического пути (развилка, вторая в списке) не берём
	avail = avail.filter(func(id): return not _is_alternative(world, n, focus_def(world, n, id)))
	# 1) шаг цепочки к ближайшему сроку (сроки по порядку, фокусы — по списку)
	for ti in targets.size():
		var tg: Array = targets[ti]
		for id in avail:
			# шаг к дальнему сроку — если не срывает более ранние
			if tg[1].has(id) and int(focus_def(world, n, id).get("days", 70)) <= int(before[ti]):
				start_focus(world, n, id)
				return
	# 2) другой фокус — если хватает запаса до всех сроков
	for id in avail:
		if int(focus_def(world, n, id).get("days", 70)) <= min_slack:
			start_focus(world, n, id)
			return
	# 3) иначе ждём (цепочки сроков ещё недоступны по дате)
	_ai_wait(world, n)


## Ждать до дня, когда откроется ближайший по дате фокус; условия войн и
## событий будят раньше через World.focus_epoch; на всякий случай — не дольше месяца.
static func _ai_wait(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	nat.focus_wait_epoch = world.focus_epoch
	var wake := world.day + 30
	for fd in tree_of(world, n):
		var cnd: Dictionary = fd.get("available", {})
		if cnd.has("date") and not nat.focus_done.has(fd["id"]):
			var open_day := world.day_of(cnd["date"]) - int(fd.get("days", 70))
			if open_day > world.day:
				wake = mini(wake, open_day)
	nat.focus_wait_until = wake


## Срок важен для истории: событие, война, договор, присоединение. Даты у
## остальных фокусов значат только «не раньше».
static func _is_key(fd: Dictionary) -> bool:
	for e in fd.get("effects", []):
		if e.get("t", "") in ["event", "war", "annex", "transfer", "release", "faction", "join_faction_of",
				"pact", "break_pact", "guarantee", "peace", "civil_war", "later", "leader", "ideology", "rep", "concede"]:
			return true
	return false


## Небывший путь: в развилке с фокусом, который стоит в списке раньше.
static func _is_alternative(world: World, n: int, fd: Dictionary) -> bool:
	var ex: Array = fd.get("exclusive", [])
	if ex.is_empty():
		return false
	for other in tree_of(world, n):
		if other["id"] == fd["id"]:
			return false
		if ex.has(other["id"]):
			return true
	return false


static func _excluded(world: World, n: int, fd: Dictionary) -> bool:
	var nat: World.Nation = world.nations[n]
	for x in fd.get("exclusive", []):
		if nat.focus_done.has(x) or nat.focus_current == x:
			return true
	return false


## Дней до конца цепочки: сам фокус + самая длинная цепочка невыполненных
## требований (из requires_any — самая короткая). chain — все её фокусы.
static func _chain_days(world: World, n: int, fd: Dictionary, memo: Dictionary, chain: Dictionary) -> int:
	var nat: World.Nation = world.nations[n]
	var id: String = fd["id"]
	if nat.focus_done.has(id):
		return 0
	chain[id] = true
	if memo.has(id):
		for k in memo[id][1]:
			chain[k] = true
		return memo[id][0]
	var left := int(fd.get("days", 70))
	if nat.focus_current == id:
		left = nat.focus_days
	var longest := 0
	var sub := {}
	for r in fd.get("requires", []):
		var c := {}
		var dd := _chain_days(world, n, focus_def(world, n, r), memo, c)
		if dd > longest:
			longest = dd
		sub.merge(c)
	var any_req: Array = fd.get("requires_any", [])
	if not any_req.is_empty():
		var best := 1 << 30
		var best_c := {}
		for r in any_req:
			var rd := focus_def(world, n, r)
			if _excluded(world, n, rd) or (world.historical and _is_alternative(world, n, rd)):
				continue
			var c := {}
			var dd := _chain_days(world, n, rd, memo, c)
			if dd < best:
				best = dd
				best_c = c
		if best < (1 << 30):
			longest = maxi(longest, best)
			sub.merge(best_c)
	chain.merge(sub)
	memo[id] = [left + longest, chain.duplicate()]
	return left + longest


static func _ai_option(world: World, ev: Dictionary, rng: RandomNumberGenerator) -> int:
	var opts: Array = ev.get("options", [])
	if opts.is_empty():
		return -1
	# ИИ всегда выбирает исторический вариант (наибольший вес «ai»);
	# варианты с весами для ИИ вернём, когда появятся альтернативные ветки
	var best := 0
	for i in opts.size():
		if float(opts[i].get("ai", 0)) > float(opts[best].get("ai", 0)):
			best = i
	return best


## Контекст события для условий: адресат и кто его вызвал.
static func event_ctx(world: World, id: String, from: int = -2) -> Dictionary:
	var ev: Dictionary = world.event_defs.get(id, {})
	var f: int = int(world.event_from.get(id, -1)) if from == -2 else from
	return {"id": id, "target": tag_id(world, ev.get("target", "")), "from": f}


## Шанс исторического ответа страны ИИ («шанс согласия») и бросков в вариантах.
## Ключи: "accept", "roll:<имя>".
static func snapshot(world: World, id: String, from: int) -> Dictionary:
	var ev: Dictionary = world.event_defs.get(id, {})
	var ctx := event_ctx(world, id, from)
	var res := {}
	if ev.has("chance"):
		res["accept"] = int(Relations.chance(world, ev["chance"], ctx)["pct"])
	for o in ev.get("options", []):
		for e in o.get("effects", []):
			if e.get("t", "") == "roll":
				res["roll:" + String(e.get("name", ""))] = int(Relations.chance(world, e.get("chance", {}), ctx)["pct"])
	return res


## Прогноз для карточки фокуса: события фокуса, кто отвечает и шансы по
## сегодняшнему состоянию мира (считается, только когда карточку открыли).
static func forecast_text(world: World, n: int, fd: Dictionary) -> String:
	var out: Array = []
	for fe in fd.get("effects", []):
		if fe.get("t", "") != "event":
			continue
		var id := String(fe["id"])
		var ev: Dictionary = world.event_defs.get(id, {})
		if ev.is_empty():
			continue
		var ctx := event_ctx(world, id, n)
		var t: int = ctx["target"]
		var tname: String = world.nations[t].name if t >= 0 else "?"
		var line := "Событие «%s» → %s" % [ev.get("title", id), tname]
		var opts: Array = ev.get("options", [])
		var hist := _ai_option(world, ev, null)
		if t >= 0 and world.nations[t].is_player:
			line += ": решает игрок"
		elif not event_has_choice(ev):
			line += ": исход гарантирован"
		elif ev.has("chance"):
			var c := Relations.chance(world, ev["chance"], ctx)
			line += ": «%s» — шанс %d %% (%s)" % [opts[hist].get("name", ""), c["pct"], "; ".join(c["lines"])]
			if not c["sure"] and not c["missing"].is_empty():
				line += "\n  до гарантии не хватает %d %%: %s" % [100 - int(c["pct"]), "; ".join(c["missing"])]
		else:
			line += ": «%s» — гарантировано" % opts[hist].get("name", "")
		out.append(line)
		for o in opts:
			for e in o.get("effects", []):
				if e.get("t", "") == "roll":
					var c2 := Relations.chance(world, e.get("chance", {}), ctx)
					out.append("  если «%s»: %s — шанс %d %% (%s)" % [o.get("name", ""), e.get("name", "бросок"), c2["pct"], "; ".join(c2["lines"])])
					if not c2["sure"] and not c2["missing"].is_empty():
						out.append("    до гарантии не хватает %d %%: %s" % [100 - int(c2["pct"]), "; ".join(c2["missing"])])
	return "\n".join(out)


# --- Подготовка ИИ к событиям своих фокусов --------------------------------------

## События всех ещё не пройденных фокусов исторического пути.
static func upcoming_events(world: World, n: int) -> Array:
	var nat: World.Nation = world.nations[n]
	var res: Array = []
	for fd in tree_of(world, n):
		var fid: String = fd["id"]
		if nat.focus_done.has(fid) or _is_alternative(world, n, fd) or _excluded(world, n, fd):
			continue
		for e in fd.get("effects", []):
			if e.get("t", "") == "event" and world.event_defs.has(e["id"]) and not world.events_fired.has(e["id"]):
				res.append(String(e["id"]))
	return res


## План подготовки ИИ: с начала партии — условия шансов всех событий своего
## исторического пути («шаблоны»): армия нужного размера, свои гарантии, пакты,
## улучшение отношений, помощь. Составляется в начале и сверяется после каждого
## фокуса (не каждый день). Чего ИИ сделать не может (чужие союзы, чужие
## гарантии) — может сбить игрок.
static func _ai_prepare(world: World, n: int) -> void:
	var nat: World.Nation = world.nations[n]
	nat.prep_day = world.day
	nat.prep_divs = 0
	var want_improve := {}
	for id in upcoming_events(world, n):
		var ev: Dictionary = world.event_defs[id]
		var ctx := event_ctx(world, id, n)
		var specs: Array = []
		if ev.has("chance"):
			specs.append(ev["chance"])
		var opts: Array = ev.get("options", [])
		var hist := _ai_option(world, ev, null)
		if hist >= 0:
			for e in opts[hist].get("effects", []):
				if e.get("t", "") == "roll":
					specs.append(e.get("chance", {}))
		for spec in specs:
			for m in spec.get("mods", []):
				var v := float(m.get("v", 0))
				if v == 0.0:
					continue
				_prep_cond(world, n, m.get("if", {}), v > 0.0, ctx, want_improve)
	# улучшение отношений: ИИ ведёт только нужные сейчас
	for t in nat.improving.keys():
		if not want_improve.has(t):
			nat.improving.erase(t)
	for t in want_improve:
		if Relations.can_improve(world, n, t) == "":
			nat.improving[t] = true


## Сделать условие истинным (want) или ложным — то, что в силах страны n.
static func _prep_cond(world: World, n: int, c: Dictionary, want: bool, ctx: Dictionary, improve: Dictionary) -> void:
	if bool(Relations.cond(world, c, ctx)[0]) == want:
		return
	var nat: World.Nation = world.nations[n]
	if c.has("not"):
		_prep_cond(world, n, c["not"], not want, ctx, improve)
	elif c.has("all") or c.has("any"):
		for sub in c.get("all", c.get("any", [])):
			_prep_cond(world, n, sub, want, ctx, improve)
	elif c.has("army"):
		var s: Dictionary = c["army"]
		var a := Relations._who(world, s.get("a", "$target"), ctx)
		var b := Relations._who(world, s.get("b", "$from"), ctx)
		var r := float(s.get("ratio", 1.0))
		if a == n and want and b >= 0:
			nat.prep_divs = maxi(nat.prep_divs, int(ceilf(world.nations[b].division_count * r)) + 1)
		elif b == n and not want and a >= 0 and r > 0.0:
			nat.prep_divs = maxi(nat.prep_divs, int(floorf(world.nations[a].division_count / r)) + 1)
	elif c.has("guarantee"):
		var a := Relations._who(world, c["guarantee"][0], ctx)
		var b := Relations._who(world, c["guarantee"][1], ctx)
		if a == n and b >= 0 and world.nations[b].alive:
			if want and not Diplomacy.same_side(world, n, b) and not world.is_at_war(n, b):
				Diplomacy.guarantee(world, n, b)
			elif not want and nat.guarantees.has(b):
				nat.guarantees.erase(b)
	elif c.has("pact"):
		var a := Relations._who(world, c["pact"][0], ctx)
		var b := Relations._who(world, c["pact"][1], ctx)
		var other := b if a == n else (a if b == n else -1)
		if other >= 0 and want and not world.is_at_war(n, other):
			var o: World.Nation = world.nations[other]
			if o.is_player:
				return
			var ans: Array = Diplomacy.ai_accepts(world, n, other, "pact")
			if ans[0]:
				Diplomacy.sign_pact(world, n, other)
			else:
				improve[other] = true
	elif c.has("rep") or c.has("faction_rep"):
		var s: Dictionary = c.get("rep", c.get("faction_rep", {}))
		var by := Relations._who(world, s.get("by", "$target"), ctx)
		var of := Relations._who(world, s.get("of", "$from"), ctx)
		# нам нужно лучшее мнение о нас — улучшаем отношения
		if of == n and by >= 0 and ((want and s.has("above")) or (not want and s.has("below"))):
			improve[by] = true
	elif c.has("trade") or c.has("trade_top"):
		var s: Dictionary = c.get("trade", c.get("trade_top", {}))
		var a := Relations._who(world, s.get("of", "$from"), ctx)
		var b := Relations._who(world, s.get("in", "$target"), ctx)
		if a == n and b >= 0 and want:
			improve[b] = true   # репутация входит в торговое влияние
	elif c.has("aid"):
		var a := Relations._who(world, c["aid"][0], ctx)
		var b := Relations._who(world, c["aid"][1], ctx)
		if a == n and want and b >= 0 and world.nations[b].alive and not world.nations[b].at_war.is_empty() \
				and not world.is_at_war(n, b):
			Relations.give_aid(world, n, b)


## Ответ страны ИИ: исторический вариант; если у события есть шанс —
## исторический только при удачном броске, иначе лучший из остальных.
static func _ai_answer(world: World, id: String, ev: Dictionary, rng: RandomNumberGenerator) -> int:
	var hist := _ai_option(world, ev, rng)
	if not ev.has("chance") or hist < 0:
		return hist
	var snap: Dictionary = world.event_snap.get(id, {})
	var c := Relations.chance(world, ev["chance"], event_ctx(world, id))
	var pct: int = int(snap["accept"]) if snap.has("accept") else int(c["pct"])
	var ok := rng.randf() * 100.0 < float(pct)
	world.chance_log.append([world.day, id, pct, ok, "; ".join(c["missing"]), c["lines"]])
	if ok:
		return hist
	var opts: Array = ev.get("options", [])
	var alt := -1
	for i in opts.size():
		if i != hist and (alt < 0 or float(opts[i].get("ai", 0)) > float(opts[alt].get("ai", 0))):
			alt = i
	world.log_event("«%s»: история пошла иначе (шанс был %d %%)" % [ev.get("title", id), pct])
	return alt if alt >= 0 else hist


## Выбор варианта события (ИИ или игрок).
static func choose_option(world: World, id: String, option: int, rng: RandomNumberGenerator) -> void:
	var ev: Dictionary = world.event_defs.get(id, {})
	var opts: Array = ev.get("options", [])
	if option < 0 or option >= opts.size():
		return
	var target := tag_id(world, ev.get("target", ""))
	var o: Dictionary = opts[option]
	world.log_event("%s — %s: %s" % [ev.get("title", id), world.nations[target].name, o.get("name", "")])
	world.ev_ctx = event_ctx(world, id)
	if ev.has("chance"):
		# требование к другой стране — ультиматум: агрессивность того, кто требует
		Relations.add_aggression(world, int(world.ev_ctx.get("from", -1)), 5.0)
	apply(world, target, o.get("effects", []), rng)
	world.ev_ctx = {}
	world.event_snap.erase(id)


# --- Эффекты ---------------------------------------------------------------------

static func apply(world: World, n: int, effects: Array, rng: RandomNumberGenerator) -> void:
	for e in effects:
		# то, от чего зависят условия фокусов (войны, мир, страны, флаги, строй) —
		# будит ждущих ИИ; бонусы и заводы условий не меняют
		if e.get("t", "") in ["war", "peace", "annex", "release", "civil_war", "flag", "ideology", "transfer"]:
			world.focus_epoch += 1
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
			"later":
				# «через N дней»: эффекты выполнятся позже (для событий, разделённых
				# неделей, — короче самого короткого фокуса)
				world.scheduled.append([world.day + int(e.get("days", 1)), who, e.get("effects", [])])
			"ships":
				# корабли основного проекта роли (линкоры bb, крейсеры cr, эсминцы dd,
				# подлодки ss, авианосцы cv) — в соединения страны (Forces.place_ship)
				var role: int = ShipDesigns.ROLE_OF_KEY.get(e.get("kind", "dd"), 0)
				ShipDesigns.ai_update(world, nat)
				var did: int = nat.ship_role[role]
				if did >= 0:
					for k in int(e.get("n", 1)):
						Forces.place_ship(world, who, did)
			"ideology":
				nat.ideology = String(e["v"])
				world.palette_dirty = true
			"leader":
				nat.leader = String(e["name"])
				if e.has("title"):
					nat.leader_title = String(e["title"])
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
				# "at": столица другой страны (союзника), например Квантунская армия в Маньчжурии
				var at := nat.capital
				if e.has("at"):
					var an := tag_id(world, e["at"])
					if an >= 0 and world.nations[an].alive and world.nations[an].capital >= 0:
						at = world.nations[an].capital
				if at >= 0 and (world.p_controller[at] == who or Diplomacy.same_side(world, world.p_controller[at], who)):
					for k in int(e.get("n", 1)):
						world.spawn_division(who, at, keys.get(e.get("tpl", "inf"), 0))
			"manpower":
				nat.manpower += float(e["v"])
			"event":
				world.event_queue.append([e["id"], who, world.day + 1])
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
			"rep":
				# {"t": "rep", "by": кто меняет мнение (по умолчанию who; "all" — все), "of": о ком, "v": ±}
				var of := Relations._who(world, e.get("of", "$from"), world.ev_ctx) if e.has("of") else target
				if of < 0:
					continue
				if String(e.get("by", "")) == "all":
					Relations.add_rep_all(world, of, float(e["v"]))
				else:
					var by := Relations._who(world, e["by"], world.ev_ctx) if e.has("by") else who
					Relations.add_rep(world, by, of, float(e["v"]))
			"aid":
				if target >= 0:
					Relations.give_aid(world, who, target)
			"no_attack":
				# ИИ страны держит фронт против target, но не наступает (до no_attack_end)
				if target >= 0:
					nat.no_attack[target] = true
			"no_attack_end":
				nat.no_attack.erase(target)
			"spirit_add":
				nat.spirits[String(e["id"])] = float(e.get("v", 1.0))
				world.recalc_spirits(nat)
			"spirit_remove":
				nat.spirits.erase(String(e["id"]))
				world.recalc_spirits(nat)
			"spirit_scale":
				# ослабить (или усилить) черту: множитель её силы
				if nat.spirits.has(String(e["id"])):
					nat.spirits[String(e["id"])] = float(nat.spirits[String(e["id"])]) * float(e.get("v", 0.5))
					world.recalc_spirits(nat)
			"org_hit":
				# внезапный удар: дивизии страны теряют часть организации
				for d in world.divisions:
					if d.alive and d.owner == who:
						d.org *= 1.0 - float(e.get("v", 0.5))
			"supply":
				# поставка по договору (обязательство): продавец (who) отдаёт ресурс
				# покупателю (target) даже в ущерб себе; рвёт только война
				var ri := ["oil", "steel", "aluminium", "rubber", "tungsten", "chromium"].find(String(e.get("res", "oil")))
				if ri >= 0 and target >= 0:
					Economy.oblige(world, who, target, ri, float(e.get("v", 1)), int(e.get("days", 365)))
			"closed_trade":
				# марионетка торгует только с сюзереном (v: false — открыть)
				nat.trade_closed = bool(e.get("v", true))
			"embargo":
				# эмбарго: who не продаёт target, поставки рвутся
				if target >= 0:
					Economy.embargo(world, who, target)
			"synthetic":
				# заводы синтетического горючего/каучука: ед. ресурса в день
				var ri := ["oil", "steel", "aluminium", "rubber", "tungsten", "chromium"].find(String(e.get("res", "oil")))
				if ri >= 0:
					nat.res_synth[ri] += float(e.get("v", 0))
					world.res_ctrl = PackedInt32Array()   # пересчитать добычу
			"concede":
				# уступка: влияние своей силы на шкале падает
				Relations.add_diplo(world, who, -float(e.get("v", 10)))
			"drop_guarantee":
				if target >= 0 and nat.guarantees.has(target):
					nat.guarantees.erase(target)
					Relations.add_diplo(world, who, -5.0)
					world.log_event("%s снимает гарантию независимости страны %s" % [nat.name, world.nations[target].name])
			"trade":
				if target >= 0:
					var k := who * 100000 + target
					world.trade_bonus[k] = float(world.trade_bonus.get(k, 0.0)) + float(e["v"])
			"roll":
				# бросок: {"name", "chance": {base, mods}, "ok": [...], "fail": [...]}
				var pct := roll_pct(world, e, who)
				var ok := rng.randf() * 100.0 < float(pct)
				world.log_event("%s: %s (шанс %d %%)" % [e.get("name", "Бросок"), "да" if ok else "нет", pct])
				apply(world, who, e.get("ok" if ok else "fail", []), rng)
	world.palette_dirty = true


## Шанс броска: снимок на день завершения фокуса, если есть, иначе по миру сейчас.
static func roll_pct(world: World, e: Dictionary, who: int, ctx_in: Dictionary = {}) -> int:
	var key := "roll:" + String(e.get("name", ""))
	var base_ctx: Dictionary = ctx_in if not ctx_in.is_empty() else world.ev_ctx
	var eid: String = base_ctx.get("id", "")
	if eid != "" and world.event_snap.has(eid) and world.event_snap[eid].has(key):
		return int(world.event_snap[eid][key])
	var ctx := base_ctx.duplicate()
	if not ctx.has("target"):
		ctx["target"] = who
	return int(Relations.chance(world, e.get("chance", {}), ctx)["pct"])


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
	Relations.on_annex(world, who, target)
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
		if tag_id(world, rule["loser"]) != loser:
			continue
		if rule.has("winner") and tag_id(world, rule["winner"]) != winner:
			continue
		if rule.get("mode", "") == "partition":
			_partition(world, loser, winner)
			if rule.has("log"):
				world.log_event(rule["log"])
			return true
		if rule.has("mode"):
			Diplomacy.make_peace(world, loser, winner, rule["mode"])
			return true
		for e in rule.get("effects", []):
			if e["t"] == "vichy":
				_vichy(world, loser, winner, e["tag"])
			else:
				apply(world, loser, [e], rng)   # например, мир с передачей области
		if rule.has("fire"):
			world.events_fired[rule["fire"]] = true   # событие уже исполнено правилом
		if rule.has("log"):
			world.log_event(rule["log"])
		return true
	return false


## Раздел по линии фронта: провинции, занятые другими противниками, отходят
## им, остальное — главному победителю (раздел Польши 1939 г.).
static func _partition(world: World, loser: int, winner: int) -> void:
	for p in world.prov_count:
		if world.p_owner[p] != loser:
			continue
		var c := world.p_controller[p]
		if c >= 0 and c != loser and c != winner and world.is_at_war(c, loser) \
				and not Diplomacy.same_side(world, c, winner):
			world.p_owner[p] = Diplomacy.root(world, c)
	annex(world, winner, loser)


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
	var bonus_names := Tech.BONUS_NAMES.duplicate()
	bonus_names.merge({"research": "наука", "attack": "атака", "defense": "оборона", "speed": "скорость"}, true)
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
			"later":
				var inner := effects_text(world, e.get("effects", [])).trim_prefix("Эффекты: ")
				parts.append("через %d дн.: %s" % [int(e.get("days", 1)), inner])
			"ships":
				parts.append("+%d: %s" % [int(e.get("n", 1)), ShipDesigns.ROLE_PLURAL[ShipDesigns.ROLE_OF_KEY.get(e.get("kind", "dd"), 0)]])
			"ideology":
				parts.append("строй: %s" % world.ideology_names.get(e["v"], e["v"]))
			"leader":
				parts.append("новый глава: %s" % e["name"])
			"rep":
				var of := tag_id(world, e.get("of", "")) if e.has("of") else tag_id(world, e.get("target", ""))
				var by := String(e.get("by", ""))
				var by_t: String = "у всех" if by == "all" else ("у " + world.nations[tag_id(world, by)].name if tag_id(world, by) >= 0 else "")
				parts.append("репутация %s %s %+d" % [world.nations[of].name if of >= 0 else "?", by_t, int(e["v"])])
			"aid":
				parts.append("помощь: %s" % tname)
			"drop_guarantee":
				parts.append("%sснятие гарантии: %s" % [who, tname])
			"concede":
				parts.append("%sуступка (влияние −%d)" % [who, int(e.get("v", 10))])
			"supply":
				var rn2 := {"oil": "нефть", "steel": "сталь", "aluminium": "алюминий", "rubber": "каучук", "tungsten": "вольфрам", "chromium": "хром"}
				parts.append("%sпоставки по договору: %s %s в день → %s" % [who, rn2.get(String(e.get("res", "oil")), ""), str(snappedf(float(e.get("v", 1)), 0.1)).trim_suffix(".0"), tname])
			"closed_trade":
				parts.append("%s%s" % [who, "торговля только с сюзереном" if bool(e.get("v", true)) else "свободная торговля марионетки"])
			"embargo":
				parts.append("%sэмбарго: %s" % [who, tname])
			"synthetic":
				var rn := {"oil": "горючее", "rubber": "каучук", "steel": "сталь", "aluminium": "алюминий", "tungsten": "вольфрам", "chromium": "хром"}
				var sv := float(e.get("v", 0))
				var num := str(snappedf(absf(sv), 0.1)).trim_suffix(".0")
				var res_n: String = rn.get(String(e.get("res", "oil")), String(e.get("res", "")))
				if String(e.get("res", "oil")) in ["oil", "rubber"] and sv > 0.0:
					parts.append("%sсинтетическое %s +%s в день" % [who, res_n, num])
				else:
					parts.append("%s%s %s%s в день%s" % [who, res_n, "+" if sv > 0.0 else "−", num, " (запасы)" if sv > 0.0 else ""])
			"no_attack":
				parts.append("%sбез наступления на %s" % [who, tname])
			"no_attack_end":
				parts.append("%sнаступление на %s" % [who, tname])
			"spirit_add":
				parts.append("%sчерта «%s»" % [who, world.spirit_defs.get(e["id"], {}).get("name", e["id"])])
			"spirit_remove":
				parts.append("%sснять черту «%s»" % [who, world.spirit_defs.get(e["id"], {}).get("name", e["id"])])
			"spirit_scale":
				parts.append("%sчерта «%s» ×%s" % [who, world.spirit_defs.get(e["id"], {}).get("name", e["id"]), str(e.get("v", 0.5))])
			"org_hit":
				parts.append("%sорганизация дивизий −%d %%" % [who, roundi(100 * float(e.get("v", 0.5)))])
			"trade":
				parts.append("торговое влияние в %s %+d %%" % [tname, int(e["v"])])
			"roll":
				var pct := roll_pct(world, e, tag_id(world, e.get("who", "")))
				var ok_t := effects_text(world, e.get("ok", [])).trim_prefix("Эффекты: ")
				var fail_t := effects_text(world, e.get("fail", [])).trim_prefix("Эффекты: ")
				parts.append("%s — шанс %d %%: %s; иначе: %s" % [e.get("name", "бросок"), pct, ok_t if ok_t != "" else "—", fail_t if fail_t != "" else "—"])
	return "Эффекты: " + ", ".join(parts) if not parts.is_empty() else ""
