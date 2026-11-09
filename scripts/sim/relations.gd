class_name Relations
## Репутация, отметки помощи, торговое влияние и шансы исходов событий.
##
## Репутация — у каждой пары стран: как страна A относится к B (0–100),
## World.rep[A * N + B]. Репутация альянса — среднее мнение членов фракции
## с весом по силе. Шанс — основа плюс поправки по условиям мира, 5–95 %.
## Всё считается в главном потоке симуляции (History.daily) — детерминированно.

const REP_MIN := 0.0
const REP_MAX := 100.0
const DRIFT_EVERY := 30      # раз в 30 дней репутация на 1 сдвигается к «естественной» (обида −30 помнится ~2,5 года)
const IMPROVE_SLOTS := 2     # одновременно улучшать отношения можно с двумя странами
const IMPROVE_PER_DAY := 0.15  # +4,5 в месяц (минус возврат к естественной ~1)
const IMPROVE_CAP := 85.0

# сродство строёв: как строй строки видит строй столбца (добавка к 50)
const IDEO := ["democracy", "authoritarian", "fascism", "communism"]
const IDEO_AFF := [
	[15, 0, -15, -15],
	[0, 5, 5, -15],
	[-15, 5, 15, -25],
	[-15, -15, -25, 15],
]


# --- Репутация ------------------------------------------------------------------

static func init(world: World) -> void:
	var n := world.nations.size()
	world.rep_n = n
	world.rep = PackedFloat32Array()
	world.rep.resize(n * n)
	for a in n:
		for b in n:
			world.rep[a * n + b] = natural(world, a, b) if a != b else REP_MAX


static func _ideo(s: String) -> int:
	for i in IDEO.size():
		if IDEO[i] == s:
			return i
	return 1


## «Естественное» отношение A к B: строй, союзы, гарантии, пакты, войны.
## К нему репутация медленно возвращается после событий.
static func natural(world: World, a: int, b: int) -> float:
	var na: World.Nation = world.nations[a]
	var nb: World.Nation = world.nations[b]
	var v := 50.0 + float(IDEO_AFF[_ideo(na.ideology)][_ideo(nb.ideology)])
	if na.faction >= 0 and na.faction == nb.faction:
		v += 20.0
	if na.overlord == b or nb.overlord == a:
		v += 20.0
	if nb.guarantees.has(a):
		v += 10.0
	if na.pacts.has(b):
		v += 5.0
	if world.is_at_war(a, b):
		v -= 40.0
	return clampf(v, REP_MIN, REP_MAX)


## Как A относится к B.
static func rep(world: World, a: int, b: int) -> float:
	if a < 0 or b < 0 or a >= world.rep_n or b >= world.rep_n:
		return 50.0
	return world.rep[a * world.rep_n + b]


static func add_rep(world: World, a: int, b: int, v: float) -> void:
	if a < 0 or b < 0 or a == b or a >= world.rep_n or b >= world.rep_n:
		return
	var i := a * world.rep_n + b
	world.rep[i] = clampf(world.rep[i] + v, REP_MIN, REP_MAX)


## Все живые страны (кроме самой B) меняют мнение о B.
static func add_rep_all(world: World, b: int, v: float) -> void:
	for a in world.nations.size():
		if world.nations[a].alive:
			add_rep(world, a, b, v)


## Средняя оценка B всеми живыми странами.
static func rep_avg(world: World, b: int) -> float:
	var s := 0.0
	var c := 0
	for a in world.nations.size():
		if a != b and world.nations[a].alive:
			s += rep(world, a, b)
			c += 1
	return s / c if c > 0 else 50.0


## Как фракция A относится к B: мнение членов с весом по силе.
## У страны без фракции — её собственное мнение.
static func faction_rep(world: World, a: int, b: int) -> float:
	var f: int = world.nations[Diplomacy.root(world, a)].faction
	if f < 0:
		return rep(world, a, b)
	var s := 0.0
	var w := 0.0
	for m in Diplomacy.faction_members(world, f):
		if m == b:
			continue
		var p := maxf(1.0, Diplomacy._power(world, m))
		s += rep(world, m, b) * p
		w += p
	return s / w if w > 0.0 else 50.0


## Улучшение отношений (дипломаты, визиты): мнение страны t о n растёт каждый день.
static func can_improve(world: World, n: int, t: int) -> String:
	if n == t or not world.nations[t].alive:
		return "невозможно"
	if world.is_at_war(n, t):
		return "мы воюем"
	if world.nations[n].improving.has(t):
		return ""
	if world.nations[n].improving.size() >= IMPROVE_SLOTS:
		return "уже улучшаем отношения с %d странами" % IMPROVE_SLOTS
	if rep(world, t, n) >= IMPROVE_CAP:
		return "отношения и так лучшие"
	return ""


## Раз в DRIFT_EVERY дней — на 1 к естественному отношению; каждый день —
## улучшение отношений.
static func daily(world: World) -> void:
	if world.rep_n != world.nations.size():
		init(world)
		return
	update_threat(world)
	for nat in world.nations:
		if nat.improving.is_empty() or not nat.alive:
			continue
		for t in nat.improving.keys():
			if not world.nations[t].alive or world.is_at_war(nat.id, t):
				nat.improving.erase(t)
			elif rep(world, t, nat.id) < IMPROVE_CAP:
				add_rep(world, t, nat.id, IMPROVE_PER_DAY)
	if world.day % DRIFT_EVERY != 0:
		return
	for nat in world.nations:
		nat.aggression *= 0.95
	var n := world.rep_n
	for a in n:
		if not world.nations[a].alive:
			continue
		for b in n:
			if a == b or not world.nations[b].alive:
				continue
			var i := a * n + b
			var nat := natural(world, a, b)
			var cur := world.rep[i]
			if cur < nat - 0.5:
				world.rep[i] = minf(nat, cur + 1.0)
			elif cur > nat + 0.5:
				world.rep[i] = maxf(nat, cur - 1.0)


# --- Угроза нацизма и коммунизма ----------------------------------------------------

const THREATS := {"fascism": "угроза нацизма", "communism": "угроза коммунизма"}
const THREAT_PART := 20.0     # каждая из пяти составляющих — до 20 очков (всего до 100 %)
const THREAT_FULL := 0.30     # доля мира, при которой армия/экономика/наука дают полные 20
const THREAT_ALLY_FULL := 0.35  # доля мира у фракций этого строя (2+ страны) — полные 20 за союз
const THREAT_AGGR_FULL := 60.0


## Сила страны для угрозы: армия (дивизии, флот, авиация), экономика, наука.
static func _strength(world: World) -> Array:
	var n := world.nations.size()
	var mil := PackedFloat32Array()
	mil.resize(n)
	for nat in world.nations:
		if nat.alive:
			mil[nat.id] = float(nat.division_count)
	for f in world.fleets:
		if f.alive and f.owner >= 0 and f.owner < n:
			mil[f.owner] += Forces.fleet_power(f) / 20.0
	for wg in world.wings:
		if wg.alive and wg.owner >= 0 and wg.owner < n:
			mil[wg.owner] += wg.planes / 200.0
	return [mil]


## Угроза строя (fascism / communism), %: очки армии, экономики, науки, союза и
## агрессивности всех стран этого строя (и их фракций — союз).
static func update_threat(world: World) -> void:
	var mil: PackedFloat32Array = _strength(world)[0]
	var tot_m := 0.0
	var tot_e := 0.0
	var tot_s := 0.0
	for nat in world.nations:
		if nat.alive:
			tot_m += mil[nat.id]
			tot_e += float(nat.civ + nat.mil)
			tot_s += float(nat.techs.size())
	for ideo in THREATS:
		var m := 0.0
		var e := 0.0
		var s := 0.0
		var ag := 0.0
		var bloc := {}
		var factions := {}
		for nat in world.nations:
			if nat.alive and nat.ideology == ideo:
				bloc[nat.id] = true
				m += mil[nat.id]
				e += float(nat.civ + nat.mil)
				s += float(nat.techs.size())
				ag += nat.aggression
				if nat.faction >= 0:
					factions[nat.faction] = true
		# союз: вся сила фракций, где состоят страны этого строя (если в фракции 2+ страны)
		var fsize := {}
		for nat in world.nations:
			if nat.alive and factions.has(nat.faction):
				fsize[nat.faction] = int(fsize.get(nat.faction, 0)) + 1
		var al := 0.0
		for nat in world.nations:
			if nat.alive and factions.has(nat.faction) and int(fsize[nat.faction]) > 1:
				al += mil[nat.id] + float(nat.civ + nat.mil) * 0.5
		var parts := {
			"армия": THREAT_PART * minf(1.0, (m / maxf(tot_m, 1.0)) / THREAT_FULL),
			"экономика": THREAT_PART * minf(1.0, (e / maxf(tot_e, 1.0)) / THREAT_FULL),
			"наука": THREAT_PART * minf(1.0, (s / maxf(tot_s, 1.0)) / THREAT_FULL),
			"союз": THREAT_PART * minf(1.0, (al / maxf(tot_m + tot_e * 0.5, 1.0)) / THREAT_ALLY_FULL),
			"агрессия": THREAT_PART * minf(1.0, ag / THREAT_AGGR_FULL),
		}
		var pct := 0.0
		for k in parts:
			pct += parts[k]
		world.threat[ideo] = {"pct": pct, "parts": parts}


static func threat_pct(world: World, ideo: String) -> float:
	return float(world.threat.get(ideo, {}).get("pct", 0.0))


## «Угроза нацизма 34 % (армия 8, экономика 7, …)».
static func threat_text(world: World, ideo: String) -> String:
	var t: Dictionary = world.threat.get(ideo, {})
	if t.is_empty():
		return ""
	var ps: Array = []
	for k in t["parts"]:
		ps.append("%s %d" % [k, roundi(t["parts"][k])])
	var title := String(THREATS[ideo])
	return "%s: %d %% (%s)" % [title[0].to_upper() + title.substr(1), roundi(t["pct"]), ", ".join(ps)]


static func add_aggression(world: World, n: int, v: float) -> void:
	if n >= 0 and n < world.nations.size():
		world.nations[n].aggression += v


# --- Мировые поводы ---------------------------------------------------------------

## Объявление войны: жертва, её гарантии и союзники резко хуже думают о нападающем.
static func on_war(world: World, a: int, b: int) -> void:
	add_aggression(world, a, 15.0)
	if world.rep_n == 0:
		return
	add_rep(world, b, a, -40.0)
	for x in world.nations.size():
		var nx: World.Nation = world.nations[x]
		if not nx.alive or x == a or x == b:
			continue
		if nx.guarantees.has(b) or (nx.faction >= 0 and nx.faction == world.nations[b].faction):
			add_rep(world, x, a, -15.0)
		else:
			add_rep(world, x, a, -3.0)


static func on_annex(world: World, who: int, _target: int) -> void:
	add_aggression(world, who, 10.0)
	if world.rep_n > 0:
		add_rep_all(world, who, -10.0)


static func on_guarantee(world: World, a: int, b: int) -> void:
	add_rep(world, b, a, 10.0)


static func on_pact(world: World, a: int, b: int) -> void:
	add_rep(world, a, b, 5.0)
	add_rep(world, b, a, 5.0)


static func on_break_pact(world: World, a: int, b: int) -> void:
	add_rep(world, b, a, -25.0)
	add_rep_all(world, a, -5.0)


# --- Помощь и торговля ------------------------------------------------------------

## Помощь: отметка, репутация и часть снаряжения пехоты (5 % склада).
static func give_aid(world: World, from: int, to: int) -> void:
	world.aid[from * 100000 + to] = world.day
	add_rep(world, to, from, 15.0)
	var nf: World.Nation = world.nations[from]
	var nt: World.Nation = world.nations[to]
	var part := nf.stock[Military.EQ_INF] * 0.05
	nf.stock[Military.EQ_INF] -= part
	nt.stock[Military.EQ_INF] += part


static func aided(world: World, from: int, to: int) -> bool:
	return world.aid.has(from * 100000 + to)


## Доля внешней торговли B, приходящаяся на A (0–100 %). Вес каждой страны:
##  экспорт (пока — гражданская промышленность; ресурсов в игре ещё нет) ×
##  флот (кто возит товары: ×1…×2 по силе флота) ×
##  репутация у B (как B относится к стране: ×0.5…×1.5) ×
##  близость (столица ближе к B — больше; через 150 пикс. карты, ~750 км, вес вдвое меньше).
## Конкуренция: доля — вес A, делённый на сумму весов всех экспортёров для B,
## поэтому сильный и близкий соперник отнимает долю.
## Война с B — ноль. Сверху — договорённости (эффект trade).
static func trade_influence(world: World, a: int, b: int) -> float:
	if a == b or not world.nations[a].alive or not world.nations[b].alive:
		return 0.0
	var cb: int = world.nations[b].capital
	if cb < 0:
		return 0.0
	var fleet := PackedFloat32Array()
	fleet.resize(world.nations.size())
	for f in world.fleets:
		if f.alive and f.owner >= 0 and f.owner < fleet.size():
			fleet[f.owner] += Forces.fleet_power(f)
	var pb := world.p_center[cb]
	var total := 0.0
	var mine := 0.0
	for x in world.nations.size():
		var nx: World.Nation = world.nations[x]
		if x == b or not nx.alive or nx.capital < 0 or world.is_at_war(x, b):
			continue
		var d := pb.distance_to(world.p_center[nx.capital]) / 150.0
		var export := float(nx.civ) + 1.0
		var fl := 1.0 + fleet[x] / (fleet[x] + 100.0)
		var rp := 0.5 + rep(world, b, x) / 100.0
		var w := export * fl * rp / (1.0 + d * d)
		total += w
		if x == a:
			mine = w
	var v := 100.0 * mine / total if total > 0.0 else 0.0
	return clampf(v + float(world.trade_bonus.get(a * 100000 + b, 0.0)), 0.0, 100.0)


# --- Условия и шансы --------------------------------------------------------------

## Страна по тегу; "$target" — адресат события, "$from" — кто его вызвал.
static func _who(world: World, tag, ctx: Dictionary) -> int:
	var s := String(tag)
	if s == "$target":
		return int(ctx.get("target", -1))
	if s == "$from":
		return int(ctx.get("from", -1))
	return History.tag_id(world, s)


static func _name(world: World, n: int) -> String:
	return world.nations[n].name if n >= 0 else "?"


## Проверка условия поправки. Возвращает [выполнено, текст условия].
static func cond(world: World, c: Dictionary, ctx: Dictionary) -> Array:
	if c.has("not"):
		var r := cond(world, c["not"], ctx)
		return [not bool(r[0]), "не: " + String(r[1])]
	if c.has("all"):
		var ok := true
		var parts: Array = []
		for sub in c["all"]:
			var r := cond(world, sub, ctx)
			ok = ok and bool(r[0])
			parts.append(r[1])
		return [ok, " и ".join(parts)]
	if c.has("any"):
		var ok := false
		var parts: Array = []
		for sub in c["any"]:
			var r := cond(world, sub, ctx)
			ok = ok or bool(r[0])
			parts.append(r[1])
		return [ok, " или ".join(parts)]
	if c.has("rep"):
		# {"rep": {"by": A, "of": B, "below"|"above": v}} — как A относится к B
		var s: Dictionary = c["rep"]
		var a := _who(world, s.get("by", "$target"), ctx)
		var b := _who(world, s.get("of", "$from"), ctx)
		var v := rep(world, a, b)
		return _cmp(v, s, "репутация %s у %s" % [_gen(world, b), _name(world, a)])
	if c.has("faction_rep"):
		var s: Dictionary = c["faction_rep"]
		var a := _who(world, s.get("by", "$target"), ctx)
		var b := _who(world, s.get("of", "$from"), ctx)
		var fn := Diplomacy.faction_name(world, a)
		var who_t := ("фракции «%s»" % fn) if fn != "" else _name(world, a)
		return _cmp(faction_rep(world, a, b), s, "репутация %s у %s" % [_gen(world, b), who_t])
	if c.has("trade"):
		var s: Dictionary = c["trade"]
		var a := _who(world, s.get("of", "$from"), ctx)
		var b := _who(world, s.get("in", "$target"), ctx)
		return _cmp(trade_influence(world, a, b), s, "торговое влияние %s у %s, %%" % [_gen(world, a), _name(world, b)])
	if c.has("threat"):
		# {"threat": {"of": "fascism"|"communism", "above"|"below": v}}
		var st: Dictionary = c["threat"]
		var ideo := String(st.get("of", "fascism"))
		return _cmp(threat_pct(world, ideo), st, String(THREATS.get(ideo, "угроза")) + ", %")
	if c.has("trade_top"):
		# {"trade_top": {"of": A, "in": B}} — A главный торговый партнёр B
		var s2: Dictionary = c["trade_top"]
		var a2 := _who(world, s2.get("of", "$from"), ctx)
		var b2 := _who(world, s2.get("in", "$target"), ctx)
		var mine := trade_influence(world, a2, b2)
		var top := true
		for x in world.nations.size():
			if x != a2 and x != b2 and world.nations[x].alive and trade_influence(world, x, b2) > mine:
				top = false
				break
		return [top, "%s — главный торговый партнёр страны «%s»" % [_name(world, a2), _name(world, b2)]]
	if c.has("tension"):
		return _cmp(world.tension, c["tension"], "напряжённость, %")
	if c.has("guarantee"):
		var a := _who(world, c["guarantee"][0], ctx)
		var b := _who(world, c["guarantee"][1], ctx)
		var ok: bool = a >= 0 and b >= 0 and world.nations[a].alive and world.nations[a].guarantees.has(b)
		return [ok, "%s гарантирует %s" % [_name(world, a), _acc(world, b)]]
	if c.has("guaranteed"):
		# кто-нибудь (кроме перечисленных в except) гарантирует страну
		var b := _who(world, c["guaranteed"], ctx)
		var ex: Array = []
		for t in c.get("except", []):
			ex.append(_who(world, t, ctx))
		var ok := false
		for x in world.nations.size():
			var nx: World.Nation = world.nations[x]
			if nx.alive and nx.guarantees.has(b) and not ex.has(x):
				ok = true
		return [ok, "%s под чьей-то гарантией" % _name(world, b)]
	if c.has("faction"):
		var a := _who(world, c["faction"][0], ctx)
		var b := _who(world, c["faction"][1], ctx)
		var fa: int = world.nations[a].faction if a >= 0 else -1
		var ok: bool = fa >= 0 and b >= 0 and fa == world.nations[b].faction
		return [ok, "%s и %s в одной фракции" % [_name(world, a), _name(world, b)]]
	if c.has("in_faction"):
		var a := _who(world, c["in_faction"], ctx)
		return [a >= 0 and world.nations[a].faction >= 0, "%s в союзе" % _name(world, a)]
	if c.has("pact"):
		var a := _who(world, c["pact"][0], ctx)
		var b := _who(world, c["pact"][1], ctx)
		return [a >= 0 and b >= 0 and world.nations[a].pacts.has(b), "пакт %s — %s" % [_name(world, a), _name(world, b)]]
	if c.has("war"):
		var a := _who(world, c["war"][0], ctx)
		var b := _who(world, c["war"][1], ctx)
		return [a >= 0 and b >= 0 and world.is_at_war(a, b), "война %s — %s" % [_name(world, a), _name(world, b)]]
	if c.has("at_war"):
		var a := _who(world, c["at_war"], ctx)
		return [a >= 0 and not world.nations[a].at_war.is_empty(), "%s воюет" % _name(world, a)]
	if c.has("aid"):
		var a := _who(world, c["aid"][0], ctx)
		var b := _who(world, c["aid"][1], ctx)
		return [a >= 0 and b >= 0 and aided(world, a, b), "%s помогал(а) стране %s" % [_name(world, a), _name(world, b)]]
	if c.has("army"):
		# {"army": {"a": A, "b": B, "ratio": 2}} — дивизий у A не меньше, чем ratio × у B
		var s: Dictionary = c["army"]
		var a := _who(world, s.get("a", "$target"), ctx)
		var b := _who(world, s.get("b", "$from"), ctx)
		var r := float(s.get("ratio", 1.0))
		var da := float(world.nations[a].division_count) if a >= 0 else 0.0
		var db := float(world.nations[b].division_count) if b >= 0 else 0.0
		var t := "армия %s больше армии %s" % [_gen(world, a), _gen(world, b)]
		if r != 1.0:
			t = "армия %s больше армии %s в %s раза" % [_gen(world, a), _gen(world, b), _num(r)]
		return [da >= db * r and da > 0.0, t]
	if c.has("ideology"):
		var s: Dictionary = c["ideology"]
		var a := _who(world, s.get("who", "$target"), ctx)
		var list: Array = s["is"] if s["is"] is Array else [s["is"]]
		var names: Array = []
		for x in list:
			names.append(world.ideology_names.get(x, x))
		return [a >= 0 and list.has(world.nations[a].ideology), "у %s строй: %s" % [_gen(world, a), ", ".join(names)]]
	if c.has("alive"):
		var a := _who(world, c["alive"], ctx)
		return [a >= 0 and world.nations[a].alive, "%s существует" % _name(world, a)]
	if c.has("flag"):
		return [world.flags.has(c["flag"]), "было событие «%s»" % c["flag"]]
	if c.has("owns_capital"):
		# {"owns_capital": [A, B]} — A держит столицу страны B
		var a := _who(world, c["owns_capital"][0], ctx)
		var b := _who(world, c["owns_capital"][1], ctx)
		var cap: int = world.nations[b].capital if b >= 0 else -1
		return [cap >= 0 and world.p_controller[cap] == a, "%s держит столицу страны %s" % [_name(world, a), _name(world, b)]]
	return [false, "?"]


static func _cmp(v: float, s: Dictionary, what: String) -> Array:
	if s.has("below"):
		return [v < float(s["below"]), "%s ниже %d (сейчас %d)" % [what, int(s["below"]), roundi(v)]]
	if s.has("above"):
		return [v > float(s["above"]), "%s выше %d (сейчас %d)" % [what, int(s["above"]), roundi(v)]]
	return [false, what]


static func _num(r: float) -> String:
	return str(int(r)) if r == floorf(r) else str(r)


## Подпись страны в автоматическом тексте условия (без склонения: «страны X»).
## В данных у поправок обычно свой текст («text») с правильными падежами.
static func _gen(world: World, n: int) -> String:
	return "страны «%s»" % _name(world, n)


static func _acc(world: World, n: int) -> String:
	return "«%s»" % _name(world, n)


## Шанс по описанию {"base": 60, "mods": [{"if": {...}, "v": 20, "text": "..."}]}.
## Основа плюс поправки; сверху не ограничен: 100 % и больше — исход
## гарантирован, излишек (например 150 %) — запас против помех (чужие
## гарантии, союзы, мнение). Снизу — 0 %.
## Возвращает {"pct", "lines": ["основа 60 %", "+20 % — …"], "missing": [что
## ещё можно добавить или убрать], "sure": pct >= 100}.
static func chance(world: World, spec: Dictionary, ctx: Dictionary) -> Dictionary:
	var pct := float(spec.get("base", 50))
	var lines: Array = ["основа %d %%" % int(pct)]
	var missing: Array = []
	# чужая гарантия снижает шанс один раз: из сработавших «гарантийных»
	# минусов берётся только самый сильный
	var guar_v := 0.0
	for m in spec.get("mods", []):
		var gv := float(m.get("v", 0))
		if gv < 0.0 and _is_guarantee(m.get("if", {})) and bool(cond(world, m.get("if", {}), ctx)[0]):
			guar_v = minf(guar_v, gv)
	var guar_used := false
	for m in spec.get("mods", []):
		var r := cond(world, m.get("if", {}), ctx)
		var v := float(m.get("v", 0))
		var txt: String = m.get("text", r[1])
		if bool(r[0]) and v < 0.0 and _is_guarantee(m.get("if", {})):
			if guar_used or v != guar_v:
				lines.append("(гарантия уже учтена) — %s" % txt)
				missing.append("убрать: " + txt)
				continue
			guar_used = true
		if bool(r[0]):
			pct += v
			lines.append("%s%d %% — %s" % ["+" if v >= 0.0 else "−", absi(int(v)), txt])
			if v < 0.0:
				missing.append("убрать: " + txt)
		elif v > 0.0:
			missing.append(txt)
	var res := maxf(pct, 0.0)
	var sure: bool = res >= 100.0
	if res > 100.0:
		lines.append("запас %d %% сверх гарантии" % int(res - 100.0))
	return {"pct": int(roundf(res)), "lines": lines, "missing": missing, "sure": sure}


## Условие про чужие гарантии (сами или внутри any/all).
static func _is_guarantee(c: Dictionary) -> bool:
	if c.has("guarantee") or c.has("guaranteed"):
		return true
	for k in ["any", "all"]:
		for sub in c.get(k, []):
			if _is_guarantee(sub):
				return true
	return false


## Все поправки с отметкой, выполнены ли они (для карточки фокуса).
static func chance_all(world: World, spec: Dictionary, ctx: Dictionary) -> Array:
	var res: Array = []
	for m in spec.get("mods", []):
		var r := cond(world, m.get("if", {}), ctx)
		res.append([bool(r[0]), int(m.get("v", 0)), m.get("text", r[1])])
	return res
