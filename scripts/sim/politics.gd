class_name Politics
extends RefCounted
## Внутренняя политика (решение пользователя, ноябрь 2026): три шкалы страны.
##
## Политическая власть (ПВ) копится каждый день (быстрее при высокой
## стабильности) и тратится на действия: гарантии, обоснование претензий,
## смену законов, решения «Пропаганда» и «Укрепить порядок».
## Стабильность (0..100 %) и поддержка войны (0..100 %) тянутся к цели (база по
## строю + черты + обстановка) на DRIFT в день; события и фокусы сдвигают их
## разово, дальше они снова сползают к цели.
## Влияние: стабильность ниже 50 % режет промышленность (до −20 %), выше — до
## +5 %; поддержка войны меняет призыв ±15 %; обе ниже 40 % приближают
## капитуляцию. Без поддержки войны 50 % игрок не обосновывает претензии.
## Объявление войны: нападающему — «Инициатива нападающего» (60 дней) и удар по
## стабильности (демократиям — и по поддержке войны), жертве — «Защита родины»
## (120 дней), +15 % поддержки войны и +3 % стабильности. Вызов гаранта-игрока —
## событие с выбором (`guarantee_call`).

const DRIFT := 0.002            # шкалы сползают к цели на 0,2 % в день
const PP_DAY := 1.0             # ПВ в день при стабильности 50 %
const PP_CAP := 500.0
const COST_GUARANTEE := 25.0
const COST_JUSTIFY := 40.0
const COST_OCC_LAW := 15.0
const COST_TRADE_LAW := 30.0
const COST_DECISION := 50.0
const DECISION_STEP := 0.05     # решения: +5 % шкалы
const DECISION_CD := 60         # дней между решениями одного вида
const WS_JUSTIFY := 0.5         # поддержка войны для обоснования претензий
const DEFEND_WS := 0.25         # оборонительная война: цель поддержки войны выше

const BASE_STAB := {"democracy": 0.65, "fascism": 0.7, "communism": 0.65}
const BASE_WS := {"democracy": 0.35, "fascism": 0.65, "communism": 0.6}


static func base_stability(nat: World.Nation) -> float:
	return float(BASE_STAB.get(nat.ideology, 0.55))


static func base_war_support(nat: World.Nation) -> float:
	return float(BASE_WS.get(nat.ideology, 0.45))


static func init_nation(nat: World.Nation) -> void:
	if nat.stability < 0.0:
		nat.stability = clampf(base_stability(nat) + nat.b("stability"), 0.0, 1.0)
	if nat.war_support < 0.0:
		nat.war_support = clampf(base_war_support(nat) + nat.b("war_support"), 0.0, 1.0)


static func init(world: World) -> void:
	for nat in world.nations:
		init_nation(nat)
		_refresh_mods(world, nat)


static func target_stability(world: World, nat: World.Nation) -> float:
	var t := base_stability(nat) + nat.b("stability")
	t -= 0.3 * (1.0 - clampf(nat.vp_ratio, 0.0, 1.0))   # потерянные земли
	if nat.exile:
		t -= 0.1
	return clampf(t, 0.0, 1.0)


static func target_war_support(world: World, nat: World.Nation) -> float:
	var t := base_war_support(nat) + nat.b("war_support") + world.tension / 100.0 * 0.15
	if nat.defending and not nat.at_war.is_empty():
		t += DEFEND_WS
	return clampf(t, 0.0, 1.0)


## Раз в день (главный поток, перед экономикой).
static func daily(world: World) -> void:
	for nat in world.nations:
		if not nat.alive:
			continue
		init_nation(nat)
		if nat.at_war.is_empty():
			nat.defending = false
		# временные черты
		if not nat.spirit_until.is_empty():
			var gone := false
			for id in nat.spirit_until.keys():
				if world.day >= int(nat.spirit_until[id]):
					nat.spirit_until.erase(id)
					nat.spirits.erase(id)
					gone = true
			if gone:
				world.recalc_spirits(nat)
				nat.stats_dirty = true
		var ts := target_stability(world, nat)
		var tw := target_war_support(world, nat)
		nat.stability += clampf(ts - nat.stability, -DRIFT, DRIFT)
		nat.war_support += clampf(tw - nat.war_support, -DRIFT, DRIFT)
		if not nat.capitulated:
			nat.pol_power = minf(PP_CAP, nat.pol_power + PP_DAY * (0.5 + nat.stability) * maxf(0.0, 1.0 + nat.b("pol_power")))
		_refresh_mods(world, nat)


## Бонусы от шкал (World.Nation.b): с шагом 1 %, чтобы не дёргать пересчёты.
static func _refresh_mods(world: World, nat: World.Nation) -> void:
	var s := nat.stability
	var w := nat.war_support
	var ind := -(0.5 - s) * 0.4 if s < 0.5 else (s - 0.5) * 0.1
	var mp := (w - 0.5) * 0.3
	var sur := maxf(0.0, 0.4 - s) * 0.25 + maxf(0.0, 0.4 - w) * 0.25
	var m := {"industry": snappedf(ind, 0.01), "manpower": snappedf(mp, 0.01), "surrender": snappedf(sur, 0.01)}
	if m != nat.pol_bonus:
		nat.pol_bonus = m
		nat.stats_dirty = true


static func add_stability(nat: World.Nation, v: float) -> void:
	nat.stability = clampf(nat.stability + v, 0.0, 1.0)


static func add_war_support(nat: World.Nation, v: float) -> void:
	nat.war_support = clampf(nat.war_support + v, 0.0, 1.0)


## Потратить ПВ: пусто — списано, иначе причина. Исторический ИИ не платит.
static func spend(world: World, nat: World.Nation, cost: float) -> String:
	if world.historical and not nat.is_player:
		return ""
	if nat.pol_power < cost:
		return "нужно %d ПВ (есть %d)" % [int(cost), int(nat.pol_power)]
	nat.pol_power -= cost
	return ""


static func can_pay(world: World, nat: World.Nation, cost: float) -> String:
	if world.historical and not nat.is_player:
		return ""
	if nat.pol_power < cost:
		return "нужно %d ПВ (есть %d)" % [int(cost), int(nat.pol_power)]
	return ""


## Временная черта: id из spirits.json на days дней (повтор — продлевает).
static func add_timed_spirit(world: World, nat: World.Nation, id: String, days: int) -> void:
	nat.spirits[id] = 1.0
	nat.spirit_until[id] = world.day + days
	world.recalc_spirits(nat)
	nat.stats_dirty = true


# --- Решения игрока -------------------------------------------------------------

const DECISIONS := {
	"propaganda": {"name": "Военная пропаганда", "desc": "+5 % поддержки войны"},
	"order": {"name": "Укрепить порядок", "desc": "+5 % стабильности"},
}


static func decision_block(world: World, nat: World.Nation, id: String) -> String:
	var last := int(nat.pol_cd.get(id, -100000))
	if world.day - last < DECISION_CD:
		return "снова через %d дн." % (DECISION_CD - (world.day - last))
	return can_pay(world, nat, COST_DECISION)


static func take_decision(world: World, nat: World.Nation, id: String) -> String:
	var why := decision_block(world, nat, id)
	if why != "":
		return why
	spend(world, nat, COST_DECISION)
	nat.pol_cd[id] = world.day
	if id == "propaganda":
		add_war_support(nat, DECISION_STEP)
	else:
		add_stability(nat, DECISION_STEP)
	return ""


# --- Война ----------------------------------------------------------------------

## Объявление войны a → b: баффы и дебаффы сторон.
static func on_declare(world: World, a: int, b: int) -> void:
	var na: World.Nation = world.nations[a]
	var nb: World.Nation = world.nations[b]
	init_nation(na)
	init_nation(nb)
	add_timed_spirit(world, na, "war_initiative", 60)
	add_stability(na, -0.08 if na.ideology == "democracy" else -0.03)
	if na.ideology == "democracy":
		add_war_support(na, -0.05)
	add_timed_spirit(world, nb, "war_homeland", 120)
	add_war_support(nb, 0.15)
	add_stability(nb, 0.03)
	nb.defending = true


## На гарантированную игроком страну b напала a: событие с выбором игроку g.
static func guarantee_call(world: World, g: int, b: int, a: int) -> void:
	var tg: String = world.nation_tags[g]
	var tb: String = world.nation_tags[b]
	var ta: String = world.nation_tags[a]
	var id := "gcall_%d_%d_%d" % [g, b, world.day]
	var nb: World.Nation = world.nations[b]
	var na: World.Nation = world.nations[a]
	var troops := clampi(2 + world.nations[g].mil / 25, 2, 6)
	# ИИ-гарант решает расчётом (вес варианта): вступиться или отречься
	var join := true
	if not world.nations[g].is_player:
		var j := ai_judge(world, g, b, a)
		join = j["join"]
		world.log_event("%s взвешивает гарантию стране %s: %s" % [world.nations[g].name, nb.name, j["why"]])
	var others: Array = []
	for x in other_guarantors(world, b, a, g):
		others.append(world.nations[x].name)
	var text := "%s объявила войну стране %s, независимость которой мы гарантировали.\n\nПосол %s просит выполнить обещание. Если мы останемся в стороне, нашему слову больше никто не поверит — ни союзники, ни собственные граждане." % [na.name, nb.name, nb.name]
	if not others.is_empty():
		text += "\n\nНа стороне защиты по гарантиям (с цепочкой гарантов) также: %s." % ", ".join(others)
	var shame: bool = world.nations[g].guar_refusals >= 1
	var no_desc := "−10 % стабильности, −10 % поддержки войны, −50 ПВ, отношения с жертвой −30, гарантия снята, " + \
		("второй отказ: «Позор нации» на 3 года, все гарантии сняты, новые — не раньше чем через 3 года" if shame else "«Нарушенное слово» на 365 дней (второй отказ — «Позор нации»)")
	var ev := {
		"title": "Нападение на страну %s" % nb.name,
		"target": tg, "photo": ta,
		"text": text,
		"options": [
			{"name": "Вступиться", "ai": 100 if join else 0, "desc": "Война против нападающих; +5 %% стабильности, +10 %% поддержки войны, %d дивизий, «Верность слову» на 180 дней" % troops,
				"effects": [{"t": "defend", "target": tb}, {"t": "stability", "v": 0.05}, {"t": "war_support", "v": 0.10},
					{"t": "divisions", "tpl": "inf", "n": troops}, {"t": "spirit_timed", "id": "guar_kept", "days": 180}]},
			{"name": "Остаться в стороне", "ai": 0 if join else 100, "desc": no_desc,
				"effects": [{"t": "stability", "v": -0.10}, {"t": "war_support", "v": -0.10}, {"t": "pol_power", "v": -50},
					{"t": "rep", "by": tb, "of": tg, "v": -30}, {"t": "guar_refuse", "target": tb}]},
		],
	}
	world.dyn_events[id] = ev
	world.event_defs[id] = ev
	world.event_queue.append([id, a, world.day])


## Расчёт ИИ-гаранта (решение пользователя): вступается, если по оценке война
## кончится за 2 года и у нападающих нет большого перевеса ни в промышленности,
## ни в военной силе (не больше JUDGE_RATIO). Срок: JUDGE_K × (A + D) / |A − D|
## дней по общей силе сторон (равные силы — затяжная война).
const JUDGE_RATIO := 1.5
const JUDGE_K := 120.0
const JUDGE_DAYS := 730


static func ai_judge(world: World, g: int, b: int, a: int) -> Dictionary:
	var att := {}
	for x in world.nations[b].at_war:
		att[x] = true
	att[a] = true
	var dfn := {b: true, g: true}
	for x in world.nations[a].at_war:
		if not att.has(x):
			dfn[x] = true
	for p in Diplomacy.puppets_of(world, g):
		dfn[p] = true
	# другие гаранты жертвы — тоже на стороне защиты (решение пользователя)
	for x in other_guarantors(world, b, a, g):
		dfn[x] = true
		for p in Diplomacy.puppets_of(world, x):
			dfn[p] = true
	var am := 0.0
	var ai := 0.0
	var dm := 0.0
	var di := 0.0
	for x in att:
		am += Diplomacy.military_strength(world, x)
		ai += world.nations[x].civ + world.nations[x].mil
	for x in dfn:
		dm += Diplomacy.military_strength(world, x)
		di += world.nations[x].civ + world.nations[x].mil
	var sa := am + ai
	var sd := dm + di
	var days := JUDGE_K * (sa + sd) / maxf(absf(sa - sd), 0.01)
	var why := "война ~%d дн., промышленность %d против %d, военная сила %d против %d" % [
		mini(int(days), 9999), int(ai), int(di), int(am), int(dm)]
	var join := days <= JUDGE_DAYS and ai <= di * JUDGE_RATIO and am <= dm * JUDGE_RATIO
	return {"join": join, "why": ("вступается — " if join else "отрекается — ") + why}


## Цепочка гарантий (решение пользователя): кто ещё гарантирует b, кто
## гарантирует этих гарантов (и g), и так далее — живые, не на стороне
## нападающего a и не воюющие с жертвой. Без g, в порядке обхода.
static func other_guarantors(world: World, b: int, a: int, g: int) -> Array:
	var seen := {b: true, g: true}
	var queue: Array = [b, g]
	var r: Array = []
	var i := 0
	while i < queue.size():
		var x: int = queue[i]
		i += 1
		for nat in world.nations:
			if seen.has(nat.id) or not nat.alive or nat.id == a or not nat.guarantees.has(x):
				continue
			if Diplomacy.same_side(world, nat.id, a) or world.is_at_war(nat.id, b):
				continue
			seen[nat.id] = true
			queue.append(nat.id)
			r.append(nat.id)
	return r


## Отказ вступиться за гарантированную b: гарантия снята; первый отказ —
## «Нарушенное слово» на год, второй — «Позор нации» на 3 года, все гарантии
## сняты и новые запрещены на 3 года (решение пользователя).
const SHAME_DAYS := 1095


static func refuse_guarantee(world: World, n: int, b: int) -> void:
	var nat: World.Nation = world.nations[n]
	nat.guarantees.erase(b)
	nat.guar_hist.erase(b)
	nat.guar_refusals += 1
	if nat.guar_refusals < 2:
		add_timed_spirit(world, nat, "guar_broken", 365)
		return
	nat.guar_refusals = 0
	nat.spirits.erase("guar_broken")
	nat.spirit_until.erase("guar_broken")
	add_timed_spirit(world, nat, "national_shame", SHAME_DAYS)
	nat.guarantees.clear()
	nat.guar_hist.clear()
	nat.guar_ban_until = world.day + SHAME_DAYS
	world.log_event("%s: «Позор нации» — второй отказ защитить гарантированную страну; все гарантии сняты, новые — не раньше чем через 3 года" % nat.name)


## Вступить в войну на стороне b против всех, с кем она воюет.
static func defend(world: World, n: int, b: int) -> void:
	var nb: World.Nation = world.nations[b]
	if not nb.alive:
		return
	var side: Array = [n]
	side.append_array(Diplomacy.puppets_of(world, n))
	for x in nb.at_war.keys():
		for s in side:
			if s != x and not Diplomacy.same_side(world, s, x):
				world.set_war(s, x)
	world.nations[n].defending = true
	world.nations[n].war_activity_day = world.day
	world.focus_epoch += 1
	world.log_event("%s вступает в войну на стороне страны %s" % [world.nations[n].name, nb.name])
