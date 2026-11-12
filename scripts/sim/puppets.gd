class_name Puppets
extends RefCounted
## Марионетки (решение пользователя, ноябрь 2026): отдают сюзерену часть
## гражданских фабрик, военных заводов и добычи ресурсов (людской резерв не в
## счёт). В первый год — 50 %, дальше — 30 % при средней свободе (50).
## Свобода 0..100: ниже — марионетка интегрированнее и отдаёт до 90 %, выше —
## отдаёт меньше, при 100 — ничего. Свобода растёт от вклада марионетки в
## войну, её помощи (ленд-лиза) другим и её фокусов; падает от стройки
## сюзерена на её земле, помощи сюзерена ей и фокусов сюзерена.

const START_FREEDOM := 50.0
const FIRST_YEAR := 0.5        # доля в первый год
const BASE := 0.3              # потом, при свободе 50
const MAX_SHARE := 0.9         # при свободе 0
const F_SCORE := 0.05          # свободы за очко вклада марионетки
const F_AID_GIVE := 2.0        # марионетка помогает другим
const F_AID_GET := -3.0        # сюзерен помогает марионетке
const F_FOCUS := 1.5           # фокус марионетки
const F_OVER_FOCUS := -0.5     # фокус сюзерена (каждой его марионетке)
const F_BUILD := -4.0          # сюзерен строит фабрику на её земле
const AI_BUILD_ABOVE := 65.0   # ИИ-сюзерен строит у марионетки со свободой выше


## Существующая страна становится марионеткой: отсчёт первого года, средняя
## свобода; вместо своего дерева фокусов — дерево марионетки (текущий фокус
## своего дерева прерывается).
static func make(world: World, n: int, overlord: int) -> void:
	var nat: World.Nation = world.nations[n]
	nat.overlord = overlord
	nat.puppet_since = world.day
	nat.freedom = START_FREEDOM
	nat.puppet_tree = true
	nat.focus_current = ""
	nat.focus_days = 0
	nat.focus_wait_until = 0
	world.focus_epoch += 1


static func is_puppet(world: World, n: int) -> bool:
	var nat: World.Nation = world.nations[n]
	return nat.alive and nat.overlord >= 0 and world.nations[nat.overlord].alive


## Доля отчислений марионетки сюзерену (0..0,9).
static func share(world: World, n: int) -> float:
	var nat: World.Nation = world.nations[n]
	var base := FIRST_YEAR if nat.puppet_since >= 0 and world.day - nat.puppet_since < 365 else BASE
	var f := clampf(nat.freedom, 0.0, 100.0)
	if f <= 50.0:
		return base + (MAX_SHARE - base) * (50.0 - f) / 50.0
	return base * (100.0 - f) / 50.0


static func add_freedom(world: World, n: int, v: float) -> void:
	if n >= 0 and is_puppet(world, n):
		var nat: World.Nation = world.nations[n]
		nat.freedom = clampf(nat.freedom + v, 0.0, 100.0)


## Вклад в войну (Peace.add_score): у марионетки растёт свобода.
static func on_score(world: World, n: int, v: float) -> void:
	add_freedom(world, n, v * F_SCORE)


static func on_aid(world: World, from: int, to: int) -> void:
	if is_puppet(world, from):
		add_freedom(world, from, F_AID_GIVE)
	if is_puppet(world, to) and world.nations[to].overlord == from:
		add_freedom(world, to, F_AID_GET)


static func on_focus(world: World, n: int) -> void:
	if is_puppet(world, n):
		add_freedom(world, n, F_FOCUS)
	for p in Diplomacy.puppets_of(world, n):
		add_freedom(world, p, F_OVER_FOCUS)


## Куда сюзерен строит следующую фабрику: марионетка или −1 (у себя).
static func build_target(world: World, nat: World.Nation) -> int:
	var t := nat.build_puppet
	if t >= 0 and (not is_puppet(world, t) or world.nations[t].overlord != nat.id):
		nat.build_puppet = -1
		return -1
	if t < 0 and not nat.is_player:
		# ИИ строит у слишком свободной марионетки
		for p in Diplomacy.puppets_of(world, nat.id):
			if world.nations[p].alive and world.nations[p].freedom > AI_BUILD_ABOVE:
				return p
	return t


## Готовая фабрика сюзерена — на землю марионетки (свобода падает).
static func build_in(world: World, nat: World.Nation, t: int) -> bool:
	var before := 0
	for p in world.prov_count:
		if world.p_owner[p] == t:
			before += world.p_civ[p] + world.p_mil[p]
	History.place_factory(world, t, nat.build_mode)
	var after := 0
	for p in world.prov_count:
		if world.p_owner[p] == t:
			after += world.p_civ[p] + world.p_mil[p]
	if after == before:
		return false
	add_freedom(world, t, F_BUILD)
	if nat.is_player:
		world.log_event("Фабрика построена у марионетки: %s (свобода %d%%)" % [world.nations[t].name, roundi(world.nations[t].freedom)])
	if not nat.is_player:
		nat.build_puppet = -1
	return true


## Отчисления фабрик и заводов (results — World.compute_all_income).
static func adjust_income(world: World, results: Array) -> void:
	for nat in world.nations:
		if not is_puppet(world, nat.id):
			continue
		var s := share(world, nat.id)
		var r: Array = results[nat.id]
		var o: Array = results[nat.overlord]
		var gc := roundi(float(r[0]) * s)
		var gm := roundi(float(r[1]) * s)
		r[0] = int(r[0]) - gc
		r[1] = int(r[1]) - gm
		o[0] = int(o[0]) + gc
		o[1] = int(o[1]) + gm


## Отчисления добычи ресурсов (Economy._refresh_prod, до синтетики).
static func adjust_resources(world: World) -> void:
	for nat in world.nations:
		if not is_puppet(world, nat.id):
			continue
		var s := share(world, nat.id)
		var o: World.Nation = world.nations[nat.overlord]
		for r in nat.res_prod.size():
			var v: float = nat.res_prod[r] * s
			nat.res_prod[r] -= v
			o.res_prod[r] += v
