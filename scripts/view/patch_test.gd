class_name PatchTest
extends Node
## Проверка сверки окон (UiPatch): все окна и их страницы по кругу через годы
## партии; после каждой пересборки дерево на экране сравнивается со свежей
## сборкой (Hud.patch_check). Плюс цена: первое открытие и повторное.
## Запуск: godot --headless --path . -- --patchtest [--nation=GER]

const DATES := ["1936-01-01", "1936-03-01", "1937-01-01", "1938-06-01", "1939-09-10", "1940-06-01", "1941-07-01"]

var game
var _idle := [0, 0]
var _reb := {}   # страница → [пересборка, её кадр, раз]
var _cost := {}   # страница → [первое, повторные сумма, повторов]


func run(g) -> void:
	game = g
	var h = g.hud
	h.patch_check = false   # проверяем сами: после открытия, без лишней сборки в замере
	var me: int = g.nation_by_tag(g._arg("nation")) if g._arg("nation") != "" else g.nation_by_tag("GER")
	g.world_lock()
	g.start_as(me)
	g.world_unlock()
	await get_tree().process_frame
	for date in DATES:
		g.world_lock()
		var w: World = g.world
		while w.day < w.day_of(date):
			if not w.pending_peace.is_empty():
				g.sim.resolve_peace("annex")
			w.pending_events.clear()
			w.info_events.clear()
			g.sim.tick()
		w.events.clear()
		g.world_unlock()
		for rep in 2:
			for page in _pages(w, me):
				g.world_lock()
				var t0 := Time.get_ticks_usec()
				_open(h, w, me, page)
				var us := Time.get_ticks_usec() - t0
				h.verify_popup()
				h._rebuild_popup()   # то же состояние ещё раз
				h.verify_popup()
				g.world_unlock()
				var key := String(page[0]) + (":" + str(page[1]) if page.size() > 1 else "")
				var tf := Time.get_ticks_usec()
				await get_tree().process_frame   # первый кадр окна: раскладка текста
				var fr := Time.get_ticks_usec() - tf
				g.world_lock()
				var tr0 := Time.get_ticks_usec()
				h._rebuild_popup()   # пересборка открытого окна (как после нажатия)
				var tr := Time.get_ticks_usec() - tr0
				g.world_unlock()
				tf = Time.get_ticks_usec()
				await get_tree().process_frame
				_reb[key] = [int(_reb.get(key, [0, 0, 0])[0]) + tr, int(_reb.get(key, [0, 0, 0])[1]) + Time.get_ticks_usec() - tf, int(_reb.get(key, [0, 0, 0])[2]) + 1]
				if not _cost.has(key):
					_cost[key] = [us, 0, 0, fr, 0]
				else:
					_cost[key][1] += us
					_cost[key][2] += 1
					_cost[key][4] += fr
				_close(h)
				await get_tree().process_frame
				var ti := Time.get_ticks_usec()
				await get_tree().process_frame   # кадр без окна — точка отсчёта
				_idle[0] += Time.get_ticks_usec() - ti
				_idle[1] += 1
		print("PATCHTEST %s: проверок %d, расхождений %d" % [date, h.patch_checks, h.patch_fails])
	print("Окна, мс: открытие первое / повторное (среднее) · первый кадр окна: первое / повторное")
	var keys := _cost.keys()
	keys.sort()
	for k in keys:
		var c: Array = _cost[k]
		var r: Array = _reb.get(k, [0, 0, 1])
		print("  %-26s %7.1f / %7.1f · %7.1f / %7.1f · пересборка %5.1f, кадр %5.1f" % [k, c[0] / 1000.0, (c[1] / maxf(1.0, c[2])) / 1000.0,
			c[3] / 1000.0, (c[4] / maxf(1.0, c[2])) / 1000.0, r[0] / 1000.0 / r[2], r[1] / 1000.0 / r[2]])
	print("  кадр без окна: %.1f" % (_idle[0] / maxf(1.0, _idle[1]) / 1000.0))
	print("PATCHTEST итог: проверок %d, расхождений %d" % [h.patch_checks, h.patch_fails])
	g._shutdown()
	get_tree().quit(1 if h.patch_fails > 0 else 0)


func _pages(w: World, me: int) -> Array:
	var out: Array = [["army"], ["army", "tpl"], ["army", "tank"], ["army", "retrain"], ["army", "join"],
		["navy"], ["navy", "plane"], ["navy", "ship"],
		["diplomacy", "world"], ["diplomacy", "politics"], ["diplomacy", "advisors"],
		["production", "factories"], ["production", "trade"], ["production", "lands"],
		["build"], ["nations"], ["settings"], ["save"], ["load"], ["menu"]]
	for tag in ["GER", "SOV", "ENG", "POL", "ITA"]:
		out.append(["nation", tag])
	return out


func _open(h, w: World, me: int, page: Array) -> void:
	var tab: String = page[0]
	var sub: String = page[1] if page.size() > 1 else ""
	match tab:
		"diplomacy":
			h._dip_page = sub
		"production":
			h._prod_page = sub
		"nation":
			h._card_nation = game.nation_by_tag(sub)
	h.open_tab(tab)
	match sub:
		"tpl":
			h._open_tpl_editor(w, -1, false)
		"tank":
			h._open_tank_editor(w, -1)
		"retrain", "join":
			var mine: Array = []
			for d in w.divisions:
				if d.alive and d.owner == me:
					mine.append(d)
					if mine.size() >= 6:
						break
			if sub == "retrain":
				h._open_retrain(mine)
			else:
				h._open_join(mine)
		"plane":
			h._open_plane_editor(w, -1)
		"ship":
			h._open_ship_editor(w, -1)


func _close(h) -> void:
	h._tk_open = false
	h._tpl_edit = -2
	h._pl_open = false
	h._sh_open = false
	h._retrain_divs = []
	h._join_divs = []
	h.close_popup()
