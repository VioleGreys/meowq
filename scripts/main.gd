extends Node
## Корень игры: создаёт мир, гоняет время, связывает карту, фишки и интерфейс.

# Скорости как в стратегиях жанра: 1 — неспешно, 5 — «сколько потянет
# процессор». Игровых дней в секунду; INF — максимум.
const SPEEDS := [0.0, 0.5, 1.0, 2.0, 4.0, INF]
# Бюджет симуляции на кадр: если телефон не успевает, игра идёт медленнее,
# а картинка остаётся плавной (интерфейс и карта не подтормаживают).
const SIM_BUDGET_USEC := 8000

var world: World
var sim: Simulation
var map_view: MapView
var unit_layer: UnitLayer
var hud: Hud

var state := "loading"           # loading / select / play / over
var speed := 0
var _accum := 0.0
var days_per_sec := 0.0          # фактическая скорость, для индикатора
var selected_prov := -1
var selected_divs: Array = []
var selected_group := -1         # выбранная армия: касание карты задаёт ей цель
var selected_fleet := -1         # выбранный флот: касание моря — куда идти
var selected_wing := -1          # выбранное авиакрыло: касание карты — район задачи
var pick_nation := -1
var large_map := false
var procedural := false          # старая процедурная карта (для тестов): -- --procedural


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.09, 0.18, 0.29))
	map_view = MapView.new()
	add_child(map_view)
	var units_canvas := CanvasLayer.new()
	units_canvas.layer = 1
	add_child(units_canvas)
	unit_layer = UnitLayer.new()
	units_canvas.add_child(unit_layer)
	hud = Hud.new()
	hud.game = self
	add_child(hud)
	map_view.province_tapped.connect(_on_province_tapped)
	procedural = "--procedural" in OS.get_cmdline_user_args()
	await new_world(randi() % 100000 if _arg("seed") == "" else int(_arg("seed")))
	if _arg("screenshot") != "":
		_auto_screenshot(_arg("screenshot"))


func _arg(name: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.split("=", true, 1)[1]
	return ""


## Отладка/CI: godot -- --screenshot=out.png [--days=N] [--zoom=Z] [--select]
func _auto_screenshot(path: String) -> void:
	var days := int(_arg("days")) if _arg("days") != "" else 0
	var me := 0
	if _arg("nation") != "" and nation_by_tag(_arg("nation")) >= 0:
		me = nation_by_tag(_arg("nation"))
	if _arg("pick") == "":
		start_as(me)
		set_speed(0)
		var war_on := nation_by_tag(_arg("war")) if _arg("war") != "" else -1
		if "--group" in OS.get_cmdline_user_args():
			select_all()
			create_group_from_selection()
			if war_on >= 0:
				world.groups[selected_group].enemy = war_on
		var war_day := int(_arg("warday")) if _arg("warday") != "" else 0
		for i in days:
			if i == war_day and war_on >= 0:
				world.nations[me].pacts.erase(war_on)
				world.nations[war_on].pacts.erase(me)
				world.nations[me].wargoals[war_on] = true
				Diplomacy.declare_war(world, me, war_on)
				if selected_group >= 0:
					var g: World.ArmyGroup = world.groups[selected_group]
					g.mode = "attack"
					g.objective = world.nations[war_on].capital
			sim.tick()
		if selected_group >= 0:
			select_group(selected_group)
		hud.on_tick()
		if _arg("zoom") != "":
			map_view.camera.zoom = Vector2.ONE * float(_arg("zoom"))
			map_view.center_on(world.nations[me].capital)
		if _arg("center") != "" and nation_by_tag(_arg("center")) >= 0:
			map_view.center_on(world.nations[nation_by_tag(_arg("center"))].capital)
		if _arg("sel") == "fleet":
			for f in world.fleets:
				if f.alive and f.owner == me:
					select_fleet(f.id)
					break
		if _arg("sel") == "wing":
			for wg in world.wings:
				if wg.alive and wg.owner == me:
					select_wing(wg.id)
					break
		if _arg("card") != "":
			hud._card_nation = nation_by_tag(_arg("card"))
		if _arg("mapmode") != "":
			set_map_mode(int(_arg("mapmode")))
		if _arg("event") != "":
			world.pending_events.append(_arg("event"))
		if "--focus" in OS.get_cmdline_user_args():
			hud.focus_view.open(self, world, me)
		if _arg("peace") != "":
			world.pending_peace.append([nation_by_tag(_arg("peace")), me])
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))
		if "--select" in OS.get_cmdline_user_args():
			_on_province_tapped(world.nations[me].capital)
	else:
		pick(me)
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))
	for i in 10:
		await get_tree().process_frame
	hud.refresh_top()
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


func new_world(seed_value: int) -> void:
	state = "loading"
	speed = 0
	hud.show_loading()
	await get_tree().process_frame
	await get_tree().process_frame
	world = World.new()
	var t := Time.get_ticks_msec()
	if procedural:
		MapGen.generate(world, seed_value, 800, 500, 14 if large_map else 22, 22 if large_map else 12)
	else:
		MapLoader.load_world(world)
	var load_ms := Time.get_ticks_msec() - t
	sim = Simulation.new(world)
	map_view.setup(world)
	unit_layer.map = map_view
	unit_layer.world = world
	unit_layer.player = -1
	unit_layer._labels_day = -1
	selected_divs.clear()
	unit_layer.selected = selected_divs
	selected_prov = -1
	pick_nation = -1
	state = "select"
	if procedural:
		hud.gen_info = "Карта #%d: %d провинций, сгенерирована за %d мс на %d ядрах" % [seed_value, world.prov_count, load_ms, Parallel.thread_count()]
	else:
		hud.gen_info = "Европа, 1 января 1936 г.: %d провинций суши, %d морских зон · загрузка %d мс" % [world.land_count, world.prov_count - world.land_count, load_ms]
	hud.show_select(-1)


func nation_by_tag(tag: String) -> int:
	var i := world.nation_tags.find(tag)
	return i


func pick(nid: int) -> void:
	pick_nation = nid
	map_view.set_highlight_nation(nid)
	hud.show_select(nid)


func start_as(nid: int) -> void:
	for n in world.nations:
		n.is_player = n.id == nid
	world.nations[nid].current_research = ""
	unit_layer.player = nid
	map_view.set_highlight_nation(-1)
	map_view.set_selected(-1)
	map_view.camera.zoom = Vector2.ONE * 0.9
	map_view.center_on(world.nations[nid].capital)
	state = "play"
	speed = 0   # как в жанре: игра начинается на паузе
	world.log_event("Вы правите страной %s. Удачи!" % world.nations[nid].name)
	hud.show_play()


func player() -> int:
	return unit_layer.player


func _process(dt: float) -> void:
	if state != "play":
		return
	if world.game_over != "":
		state = "over"
		hud.show_game_over(world.game_over)
		return
	if not world.pending_events.is_empty():
		if hud.popup_tab != "event" or not hud.popup.visible:
			speed = 0
			hud.open_tab("event")
		hud.refresh_top()
		return
	if not world.pending_peace.is_empty():
		if hud.popup_tab != "peace" or not hud.popup.visible:
			speed = 0
			hud.open_tab("peace")
		hud.refresh_top()
		return
	if speed > 0:
		var unlimited: bool = SPEEDS[speed] == INF
		if not unlimited:
			_accum += dt * SPEEDS[speed]
		var n := 0
		var start := Time.get_ticks_usec()
		while (unlimited or _accum >= 1.0) and Time.get_ticks_usec() - start < SIM_BUDGET_USEC:
			if not unlimited:
				_accum -= 1.0
			sim.tick()
			n += 1
			if world.game_over != "":
				break
		# не копим долг: отставшая симуляция просто идёт медленнее
		_accum = minf(_accum, 1.0)
		days_per_sec = lerpf(days_per_sec, n / maxf(dt, 0.001), 0.05)
		if n > 0:
			_prune_selection()
			hud.on_tick()
	hud.refresh_top()


func _prune_selection() -> void:
	var alive: Array = []
	for d in selected_divs:
		if d.alive:
			alive.append(d)
	if alive.size() != selected_divs.size():
		selected_divs.clear()
		selected_divs.append_array(alive)


# --- Ввод с карты ------------------------------------------------------------

func _on_province_tapped(p: int) -> void:
	if state == "select":
		if world.p_land[p] == 1:
			pick(world.p_owner[p])
		return
	if state != "play":
		return
	var me := player()
	# выбран флот -> идёт в морскую зону (касание берега — в соседнюю зону)
	if selected_fleet >= 0:
		var f: World.Fleet = world.fleets[selected_fleet]
		var zone := p
		if world.p_land[p] == 1:
			zone = -1
			for q in world.p_adj[p]:
				if world.p_land[q] == 0:
					zone = q
					break
		if zone >= 0:
			var path := Forces.sea_path(world, f.zone, zone)
			if zone == f.zone or not path.is_empty():
				f.path = path
				if f.mission == "port":
					f.mission = "patrol"
				hud.toast("%s идёт: %s (%d дн.)" % [f.name, world.p_name[zone], path.size()])
			else:
				hud.toast("Туда флоту не дойти")
		hud.show_fleet(f)
		return
	# выбрано авиакрыло -> район задачи
	if selected_wing >= 0:
		var w: World.AirWing = world.wings[selected_wing]
		var r: int = world.p_region[p]
		if Forces.wing_in_range(world, w, r):
			w.region = r
			hud.toast("%s: район %s" % [w.name, world.region_name[r]])
		else:
			hud.toast("Слишком далеко от наших аэродромов")
		hud.show_wing(w)
		return
	# выбрана армия -> касание задаёт направление наступления
	if selected_group >= 0:
		var g: World.ArmyGroup = world.groups[selected_group]
		if world.p_land[p] == 1:
			g.objective = p
			if world.p_controller[p] != me:
				g.mode = "attack"
				if g.enemy < 0 and world.p_controller[p] >= 0 and world.is_at_war(me, world.p_controller[p]):
					g.enemy = world.p_controller[p]
			hud.toast("%s: цель — %s" % [g.name, world.p_name[p]])
			map_view.set_selected(p)
			hud.show_group(g)
		return
	# есть выделенные войска -> приказ на движение
	if not selected_divs.is_empty() and p != selected_prov:
		var ok := 0
		for d in selected_divs:
			if sim.order_move(d, p):
				ok += 1
				d.group = -1   # ручной приказ выводит дивизию из армии
		if ok > 0:
			hud.toast("Приказ отдан: %d дивизий → %s" % [ok, world.p_name[p]])
			selected_prov = p
			map_view.set_selected(p)
			hud.show_selection()
			return
		# по суше не пройти — переправа в свой/союзный порт или высадка с моря
		var ctl := world.p_controller[p]
		if world.p_land[p] == 1 and Forces.is_port(world, p) and ctl >= 0 and (ctl == me or world.ally[me * world.nation_count + ctl] == 1):
			var twhy := Forces.sea_transfer(world, selected_divs, p)
			if twhy == "":
				hud.toast("Переправа → %s: %d дн." % [world.p_name[p], selected_divs[0].transit_days])
				clear_selection()
			else:
				hud.toast("Переправа невозможна: " + twhy)
			return
		if world.p_land[p] == 1 and world.p_coastal[p] == 1:
			var why := Forces.plan_invasion(world, selected_divs, p)
			if why == "":
				var plan: World.InvasionPlan = world.invasions[world.invasions.size() - 1]
				hud.toast("Готовим высадку → %s: %d дн. Войска ждут в порту" % [world.p_name[p], plan.total])
				clear_selection()
				return
			hud.toast("Высадка невозможна: " + why)
		else:
			hud.toast("Туда не пройти: нужна война с владельцем")
	# повторное касание той же провинции снимает выделение
	if p == selected_prov and not selected_divs.is_empty():
		clear_selection()
		hud.show_province(p)
		return
	selected_prov = p
	map_view.set_selected(p)
	selected_divs.clear()
	for d in world.prov_divs[p]:
		if d.alive and d.owner == me:
			selected_divs.append(d)
	if selected_divs.is_empty():
		hud.show_province(p)
	else:
		hud.show_selection()


func clear_selection() -> void:
	selected_group = -1
	selected_fleet = -1
	selected_wing = -1
	selected_divs.clear()
	selected_prov = -1
	map_view.set_selected(-1)
	hud.hide_info()


func select_all() -> void:
	selected_group = -1
	selected_divs.clear()
	for d in world.divisions_of(player()):
		if not d.in_battle:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(-1)
	hud.show_selection()


# --- Армии -----------------------------------------------------------------

func create_group_from_selection() -> void:
	if selected_divs.is_empty():
		return
	var g := sim.create_group(player(), selected_divs)
	# по умолчанию — против ближайшего противника, иначе держать границу
	for e in world.nations[player()].at_war:
		g.enemy = e
		break
	select_group(g.id)
	hud.toast("Создана %s: %d дивизий" % [g.name, selected_divs.size()])


func select_fleet(id: int) -> void:
	clear_selection()
	selected_fleet = id
	hud.show_fleet(world.fleets[id])


func select_wing(id: int) -> void:
	clear_selection()
	selected_wing = id
	hud.show_wing(world.wings[id])


func select_group(id: int) -> void:
	var g: World.ArmyGroup = world.groups[id]
	selected_group = id
	selected_divs.clear()
	for d in world.divisions:
		if d.alive and d.group == id:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(g.objective)
	hud.show_group(g)


func group_divisions(id: int) -> Array:
	var res: Array = []
	for d in world.divisions:
		if d.alive and d.group == id:
			res.append(d)
	return res


## Противники для выбора фронта армии: страны в войне с нами и соседи.
func enemy_options() -> Array:
	var me := player()
	var opts: Array = [-1]
	for e in world.nations[me].at_war:
		opts.append(e)
	for nb in world.neighbours_of_nation(me):
		if not opts.has(nb) and not Diplomacy.same_side(world, me, nb):
			opts.append(nb)
	return opts


func stop_selected() -> void:
	for d in selected_divs:
		d.path = PackedInt32Array()
		d.progress = 0.0


# --- Действия игрока ---------------------------------------------------------

func set_speed(s: int) -> void:
	speed = clampi(s, 0, SPEEDS.size() - 1)


func train(count: int, tpl: int = Military.T_INF) -> int:
	var made := 0
	for i in count:
		if sim.train_division(player(), tpl):
			made += 1
	return made


func declare_war_on(target: int) -> void:
	Diplomacy.declare_war(world, player(), target)
	hud.on_tick()


func resolve_event(option: int) -> void:
	sim.resolve_event(option)
	hud.close_popup()
	hud.on_tick()
	if not world.pending_events.is_empty():
		hud.open_tab("event")


func resolve_peace(mode: String) -> void:
	sim.resolve_peace(mode)
	hud.close_popup()
	hud.on_tick()


## Что-то поменялось по действию игрока (дипломатия) — обновить карту и журнал.
func hud_changed() -> void:
	hud.on_tick()


func set_map_mode(m: int) -> void:
	map_view.set_map_mode(m)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if hud != null and hud.close_popup():
			return
		if not selected_divs.is_empty():
			clear_selection()
