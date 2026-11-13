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
##
## Законы (как в жанре, значения свои; решение пользователя, ноябрь 2026):
## экономика (доля фабрик на товары народного потребления, стройка военных
## заводов) и призыв (приток людей и потолок армии). Строже закон — выше
## требование к поддержке войны. Советники: политические (ПВ) и военные
## (командный ресурс, КР) — по ADVISOR_SLOTS мест; военные сами опыта не дают,
## только ускоряют его прибавку.
## Стабильность: товары народного потребления, поддержка войны, призыв,
## выпуск заводов, стройка, принятие на чужих землях, ПВ. Поддержка войны:
## атака и оборона (до +20 %), стройка военных заводов, планирование, КР,
## прибавка опыта армии, флота, авиации и командиров, подавление сопротивления
## на чужих землях (до +20 %).

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

const CP_DAY := 0.5             # командный ресурс в день при поддержке войны 50 %
const CP_CAP := 200.0
const CP_START := 20.0
const CG_MAX := 0.6             # товары народного потребления — не больше этой доли фабрик
const AI_LAW_DAYS := 30         # ИИ пересматривает законы и советников раз в месяц

const BASE_STAB := {"democracy": 0.65, "fascism": 0.7, "communism": 0.65}
const BASE_WS := {"democracy": 0.35, "fascism": 0.65, "communism": 0.6}


static func base_stability(nat: World.Nation) -> float:
	return float(BASE_STAB.get(nat.ideology, 0.55))


static func base_war_support(nat: World.Nation) -> float:
	return float(BASE_WS.get(nat.ideology, 0.45))


static func init_nation(nat: World.Nation) -> void:
	if nat.econ_law < 0 or nat.conscr_law < 0:
		if nat.econ_law < 0:
			nat.econ_law = int(START_ECON.get(nat.tag, 0))
		if nat.conscr_law < 0:
			nat.conscr_law = int(START_CONSCR.get(nat.tag, 2))
		recalc_laws(nat)
	if nat.command_power < 0.0:
		nat.command_power = CP_START
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
			nat.pol_power = minf(PP_CAP, nat.pol_power + pp_rate(nat))
			nat.command_power = minf(CP_CAP, nat.command_power + cp_rate(nat))
		_refresh_mods(world, nat)
		if not nat.is_player and (world.day + nat.id) % AI_LAW_DAYS == 0 and not nat.capitulated:
			ai_laws(world, nat)
			ai_advisors(world, nat)
			Leaders.ai_traits(world, nat)


## ПВ в день: быстрее при высокой стабильности.
static func pp_rate(nat: World.Nation) -> float:
	return PP_DAY * (0.5 + nat.stability) * maxf(0.0, 1.0 + nat.b("pol_power"))


## Командный ресурс в день: быстрее при высокой поддержке войны.
static func cp_rate(nat: World.Nation) -> float:
	return CP_DAY * (0.5 + nat.war_support) * maxf(0.0, 1.0 + nat.b("command_power"))


## Бонусы от шкал (World.Nation.b): с шагом 1 %, чтобы не дёргать пересчёты.
## Стабильность (s) и поддержка войны (w) — от 0 до 1, середина 0,5 — без влияния.
static func scale_mods(s: float, w: float) -> Dictionary:
	var lo := 0.5 - s      # > 0 — стабильность ниже середины
	var wb := (w - 0.5) * 0.4 if w > 0.5 else -(0.5 - w) * 0.2   # +20 % … −10 %
	var wl := (w - 0.5) * 0.4                                      # ±20 %
	var m := {
		# стабильность
		"industry": -lo * 0.4 if lo > 0.0 else -lo * 0.1,          # −20 % … +5 %
		"construction": -lo * 0.4 if lo > 0.0 else -lo * 0.2,      # −20 % … +10 %
		"cons_goods": lo * 0.2 if lo > 0.0 else lo * 0.1,          # +10 % … −5 % фабрик
		"manpower": -lo * 0.3,                                     # ±15 %
		"war_support": -lo * 0.2,                                  # ±10 % к цели поддержки войны
		"occ_comply": -lo * 0.4,                                   # ±20 %
		# поддержка войны
		"attack": wb, "defense": wb, "occ_suppress": wb,
		"mil_build": wl, "plan_speed": wl,
		"xp_land": wl, "xp_navy": wl, "xp_air": wl, "xp_lead": wl, "xp_div": wl,
		# обе низкие — ближе капитуляция
		"surrender": maxf(0.0, 0.4 - s) * 0.25 + maxf(0.0, 0.4 - w) * 0.25,
	}
	for k in m:
		m[k] = snappedf(float(m[k]), 0.01)
	return m


static func _refresh_mods(world: World, nat: World.Nation) -> void:
	var m := scale_mods(nat.stability, nat.war_support)
	if m != nat.pol_bonus:
		# характеристики дивизий пересчитываются, только если сдвинулись атака и оборона
		if float(m["attack"]) != float(nat.pol_bonus.get("attack", 0.0)) or float(m["defense"]) != float(nat.pol_bonus.get("defense", 0.0)):
			nat.stats_dirty = true
		nat.pol_bonus = m


## Товары народного потребления: доля всех фабрик (гражданских и военных),
## занятая нуждами населения, — по закону об экономике, стабильности и советникам.
static func consumer_share(nat: World.Nation) -> float:
	return clampf(nat.b("cons_goods"), 0.0, CG_MAX)


## Сколько гражданских фабрик уходит на товары народного потребления.
static func consumer_factories(nat: World.Nation) -> float:
	return minf(float(nat.civ), consumer_share(nat) * float(nat.civ + nat.mil))


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


# --- Законы: экономика и призыв -------------------------------------------------
# Требования: ws — поддержка войны; war_ws — на войне хватает этой; war — только на войне.

const COST_LAW := 50.0

const ECON_LAWS := [
	{"name": "Гражданская экономика", "ws": 0.0, "bonus": {"cons_goods": 0.30, "mil_build": -0.20},
		"desc": "товары народного потребления 30 % фабрик, стройка военных заводов −20 %"},
	{"name": "Ранняя мобилизация", "ws": 0.15, "bonus": {"cons_goods": 0.25, "mil_build": -0.10},
		"desc": "товары народного потребления 25 %, стройка военных заводов −10 %"},
	{"name": "Частичная мобилизация", "ws": 0.3, "bonus": {"cons_goods": 0.20},
		"desc": "товары народного потребления 20 %"},
	{"name": "Военная экономика", "ws": 0.5, "war_ws": 0.3, "bonus": {"cons_goods": 0.15, "mil_build": 0.10},
		"desc": "товары народного потребления 15 %, стройка военных заводов +10 %"},
	{"name": "Тотальная мобилизация", "ws": 0.7, "war": true, "bonus": {"cons_goods": 0.10, "mil_build": 0.20, "stability": -0.05},
		"desc": "товары народного потребления 10 %, стройка военных заводов +20 %, стабильность −5 %"},
]

## Приток людей — к «Всеобщей воинской обязанности» (так жили почти все
## континентальные страны в 1936 г.); conscription — потолок армии ИИ.
const CONSCR_LAWS := [
	{"name": "Добровольческая армия", "ws": 0.0, "bonus": {"manpower": -0.55, "conscription": -0.4},
		"desc": "приток людей −55 %, только добровольцы"},
	{"name": "Ограниченный призыв", "ws": 0.0, "bonus": {"manpower": -0.25, "conscription": -0.2},
		"desc": "приток людей −25 %"},
	{"name": "Всеобщая воинская обязанность", "ws": 0.25, "bonus": {},
		"desc": "обычный приток людей"},
	{"name": "Призыв всех годных", "ws": 0.5, "war_ws": 0.3, "bonus": {"manpower": 0.3, "conscription": 0.3, "industry": -0.03},
		"desc": "приток людей +30 %, выпуск заводов −3 %"},
	{"name": "Служат все", "ws": 0.7, "war": true, "bonus": {"manpower": 0.7, "conscription": 0.6, "industry": -0.08, "stability": -0.05},
		"desc": "приток людей +70 %, выпуск заводов −8 %, стабильность −5 %"},
]

## Законы 1936 г. (свои оценки): Германия — Четырёхлетний план, СССР —
## пятилетки, Япония — подготовка к войне в Китае, Италия — Абиссиния.
const START_ECON := {"GER": 2, "SOV": 2, "JAP": 2, "ITA": 1, "MAN": 1, "SPR": 1, "NSP": 1}
## Призыв: англоязычный мир без призыва до войны (Британия — до 1939 г., США — до 1940 г.).
const START_CONSCR := {"ENG": 0, "USA": 0, "CAN": 0, "AST": 0, "NZL": 0, "SAF": 0, "RAJ": 0, "IRE": 0,
	"MEX": 1, "BRA": 1, "ARG": 1, "SIA": 1, "PER": 1, "AFG": 1}


static func laws_of(kind: String) -> Array:
	return ECON_LAWS if kind == "econ" else CONSCR_LAWS


static func law_index(nat: World.Nation, kind: String) -> int:
	return nat.econ_law if kind == "econ" else nat.conscr_law


## Пересчитать бонусы законов и советников (World.Nation.adv_bonus).
static func recalc_laws(nat: World.Nation) -> void:
	var m := {}
	var parts: Array = [ECON_LAWS[clampi(nat.econ_law, 0, ECON_LAWS.size() - 1)]["bonus"],
		CONSCR_LAWS[clampi(nat.conscr_law, 0, CONSCR_LAWS.size() - 1)]["bonus"]]
	var ids := nat.advisors.keys()
	ids.sort()
	for id in ids:
		var a := advisor(str(id))
		if not a.is_empty():
			parts.append(a["bonus"])
	for bon in parts:
		for k in bon:
			m[k] = float(m.get(k, 0.0)) + float(bon[k])
	var old: Dictionary = nat.adv_bonus
	nat.adv_bonus = m
	for k in m:
		if not Tech.ECON_KEYS.has(k) and float(old.get(k, 0.0)) != float(m[k]):
			nat.stats_dirty = true
	for k in old:
		if not m.has(k) and not Tech.ECON_KEYS.has(k):
			nat.stats_dirty = true


## Можно ли принять закон i: пусто — можно, иначе причина.
static func law_block(world: World, nat: World.Nation, kind: String, i: int) -> String:
	var laws := laws_of(kind)
	if i < 0 or i >= laws.size() or i == law_index(nat, kind):
		return "уже принят" if i == law_index(nat, kind) else "нет такого закона"
	var lw: Dictionary = laws[i]
	var war := not nat.at_war.is_empty()
	if bool(lw.get("war", false)) and not war:
		return "только во время войны"
	var need: float = float(lw["ws"])
	if war and lw.has("war_ws"):
		need = float(lw["war_ws"])
	if nat.war_support + 1e-6 < need:
		return "нужна поддержка войны %d %%" % roundi(need * 100.0)
	return can_pay(world, nat, COST_LAW)


static func set_law(world: World, nat: World.Nation, kind: String, i: int) -> String:
	var why := law_block(world, nat, kind, i)
	if why != "":
		return why
	spend(world, nat, COST_LAW)
	if kind == "econ":
		nat.econ_law = i
	else:
		nat.conscr_law = i
	recalc_laws(nat)
	if nat.is_player:
		world.log_event("Принят закон: %s" % laws_of(kind)[i]["name"])
	return ""


## ИИ: законы под обстановку. На войне — военная экономика и призыв всех
## годных, при потере земель — тотальная мобилизация и «Служат все»; перед
## запланированной войной — на ступень мягче; в мире — стартовые законы.
static func ai_laws(world: World, nat: World.Nation) -> void:
	var war := not nat.at_war.is_empty()
	var plan := not nat.planned_wars.is_empty()
	var losing := war and nat.vp_ratio < 0.85
	var te := int(START_ECON.get(nat.tag, 0))
	var tc := int(START_CONSCR.get(nat.tag, 2))
	if war:
		te = maxi(te, 4 if losing else 3)
		tc = maxi(tc, 4 if losing else 3)
	elif plan:
		te = maxi(te, 3)
		tc = maxi(tc, 2)
	elif world.tension >= 60.0:
		te = maxi(te, 1)
		tc = maxi(tc, 2 if tc >= 1 else 1)
	for kind in ["econ", "conscr"]:
		var want: int = te if kind == "econ" else tc
		var cur := law_index(nat, kind)
		if want < cur and not war and not plan:
			set_law(world, nat, kind, want)
			continue
		# строже — до ближайшего доступного закона
		for i in range(want, cur, -1):
			if law_block(world, nat, kind, i) == "":
				set_law(world, nat, kind, i)
				break


# --- Советники -------------------------------------------------------------------
# Политические нанимаются за ПВ, военные — за КР; военные сами опыта не дают,
# только ускоряют его прибавку (решение пользователя).

const ADVISOR_SLOTS := 3
const COST_POL_ADV := 100.0     # ПВ
const COST_MIL_ADV := 50.0      # КР

const POL_ADVISORS := {
	"industrialist": {"name": "Промышленник", "desc": "стройка +10 %", "bonus": {"construction": 0.10}},
	"armaments": {"name": "Министр вооружений", "desc": "выпуск заводов +5 %", "bonus": {"industry": 0.05}},
	"builder": {"name": "Куратор оборонных строек", "desc": "стройка военных заводов +15 %", "bonus": {"mil_build": 0.15}},
	"planner": {"name": "Экономист-плановик", "desc": "товары народного потребления −5 % фабрик", "bonus": {"cons_goods": -0.05}},
	"propagandist": {"name": "Глава пропаганды", "desc": "поддержка войны +5 %", "bonus": {"war_support": 0.05}},
	"lawkeeper": {"name": "Хранитель порядка", "desc": "стабильность +5 %", "bonus": {"stability": 0.05}},
	"organizer": {"name": "Партийный организатор", "desc": "политическая власть +15 %", "bonus": {"pol_power": 0.15}},
	"governor": {"name": "Администратор занятых земель", "desc": "принятие на чужих землях +15 %", "bonus": {"occ_comply": 0.15}},
}

const MIL_ADVISORS := {
	"army_chief": {"name": "Начальник штаба армии", "desc": "прибавка опыта армии +20 %", "bonus": {"xp_land": 0.20}},
	"navy_chief": {"name": "Начальник морского штаба", "desc": "прибавка опыта флота +20 %", "bonus": {"xp_navy": 0.20}},
	"air_chief": {"name": "Начальник штаба авиации", "desc": "прибавка опыта авиации +20 %", "bonus": {"xp_air": 0.20}},
	"drill": {"name": "Инспектор боевой подготовки", "desc": "прибавка опыта дивизий +25 %", "bonus": {"xp_div": 0.25}},
	"mentor": {"name": "Наставник командного состава", "desc": "прибавка опыта генералов и маршалов +25 %", "bonus": {"xp_lead": 0.25}},
	"staff": {"name": "Штабной планировщик", "desc": "скорость планирования +15 %", "bonus": {"plan_speed": 0.15}},
	"infantry": {"name": "Инспектор пехоты", "desc": "атака и оборона пехоты +5 %", "bonus": {"inf_attack": 0.05, "inf_defense": 0.05}},
	"armor": {"name": "Инспектор бронетанковых войск", "desc": "атака и оборона танков +5 %", "bonus": {"tank_attack": 0.05, "tank_defense": 0.05}},
	"artillery": {"name": "Инспектор артиллерии", "desc": "атака артиллерии +5 %, оборона +3 %", "bonus": {"art_attack": 0.05, "art_defense": 0.03}},
	"rear": {"name": "Начальник тыла", "desc": "пополнение +10 %", "bonus": {"reinforce": 0.10}},
}


static func advisor(id: String) -> Dictionary:
	if POL_ADVISORS.has(id):
		return POL_ADVISORS[id]
	return MIL_ADVISORS.get(id, {})


static func is_military(id: String) -> bool:
	return MIL_ADVISORS.has(id)


static func advisors_of(nat: World.Nation, military: bool) -> Array:
	var r: Array = []
	for id in nat.advisors:
		if is_military(str(id)) == military:
			r.append(str(id))
	r.sort()
	return r


## Потратить командный ресурс: пусто — списано, иначе причина. Исторический ИИ не платит.
static func spend_cp(world: World, nat: World.Nation, cost: float) -> String:
	var why := can_pay_cp(world, nat, cost)
	if why == "" and not (world.historical and not nat.is_player):
		nat.command_power -= cost
	return why


static func can_pay_cp(world: World, nat: World.Nation, cost: float) -> String:
	if world.historical and not nat.is_player:
		return ""
	if nat.command_power < cost:
		return "нужно %d КР (есть %d)" % [int(cost), int(nat.command_power)]
	return ""


static func hire_block(world: World, nat: World.Nation, id: String) -> String:
	if advisor(id).is_empty():
		return "нет такого советника"
	if nat.advisors.has(id):
		return "уже нанят"
	var mil := is_military(id)
	if advisors_of(nat, mil).size() >= ADVISOR_SLOTS:
		return "все %d места заняты" % ADVISOR_SLOTS
	if mil:
		return "" if nat.command_power >= COST_MIL_ADV else "нужно %d КР (есть %d)" % [int(COST_MIL_ADV), int(nat.command_power)]
	return "" if nat.pol_power >= COST_POL_ADV else "нужно %d ПВ (есть %d)" % [int(COST_POL_ADV), int(nat.pol_power)]


## Нанять советника. Платят все, и ИИ тоже (иначе исторический ИИ нанял бы всех сразу).
static func hire(world: World, nat: World.Nation, id: String) -> String:
	var why := hire_block(world, nat, id)
	if why != "":
		return why
	if is_military(id):
		nat.command_power -= COST_MIL_ADV
	else:
		nat.pol_power -= COST_POL_ADV
	nat.advisors[id] = world.day
	recalc_laws(nat)
	if nat.is_player:
		world.log_event("Нанят советник: %s" % advisor(id)["name"])
	return ""


## Отпустить советника (место освобождается, затраты не возвращаются).
static func dismiss(world: World, nat: World.Nation, id: String) -> void:
	if nat.advisors.erase(id):
		recalc_laws(nat)


## ИИ: свободное место — советник под обстановку, если хватает ПВ / КР с запасом.
static func ai_advisors(world: World, nat: World.Nation) -> void:
	var war := not nat.at_war.is_empty() or not nat.planned_wars.is_empty()
	var pol: Array = ["armaments", "builder", "propagandist", "industrialist", "organizer", "lawkeeper"] if war else \
		["industrialist", "organizer", "lawkeeper", "armaments", "planner", "propagandist"]
	if nat.stability < 0.45:
		pol.push_front("lawkeeper")
	if nat.war_support < 0.4 and war:
		pol.push_front("propagandist")
	var mil: Array = ["army_chief", "drill", "staff", "mentor", "infantry", "rear", "artillery"]
	if nat.major:
		mil.insert(2, "navy_chief")
		mil.insert(3, "air_chief")
	if nat.pol_power >= COST_POL_ADV + 60.0:
		for id in pol:
			if hire(world, nat, id) == "":
				break
	if nat.command_power >= COST_MIL_ADV + 30.0:
		for id in mil:
			if hire(world, nat, id) == "":
				break
