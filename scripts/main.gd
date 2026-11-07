extends Node
## Корень игры: создаёт мир, гоняет время, связывает карту, фишки и интерфейс.

const SPEEDS := [0.0, 1.0, 3.0, 8.0, 20.0]   # игровых дней в секунду
const MAX_TICKS_PER_FRAME := 4

var world: World
var sim: Simulation
var map_view: MapView
var unit_layer: UnitLayer
var hud: Hud

var state := "loading"           # loading / select / play / over
var speed := 0
var _accum := 0.0
var selected_prov := -1
var selected_divs: Array = []
var pick_nation := -1
var large_map := false


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
	if days >= 0 and _arg("pick") == "":
		start_as(0)
		set_speed(0)
		for i in days:
			sim.tick()
		hud.on_tick()
		if _arg("zoom") != "":
			map_view.camera.zoom = Vector2.ONE * float(_arg("zoom"))
			map_view.center_on(world.nations[0].capital)
		if _arg("tab") != "":
			hud.open_tab(_arg("tab"))
		if "--select" in OS.get_cmdline_user_args():
			_on_province_tapped(world.nations[0].capital)
	else:
		_on_province_tapped(world.nations[0].capital)
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
	var cell := 14 if large_map else 22
	var nations := 22 if large_map else 12
	var t := Time.get_ticks_msec()
	MapGen.generate(world, seed_value, 800, 500, cell, nations)
	var gen_ms := Time.get_ticks_msec() - t
	sim = Simulation.new(world)
	map_view.setup(world)
	unit_layer.map = map_view
	unit_layer.world = world
	unit_layer.player = -1
	selected_divs.clear()
	unit_layer.selected = selected_divs
	selected_prov = -1
	pick_nation = -1
	state = "select"
	hud.gen_info = "Карта #%d: %d провинций, сгенерирована за %d мс на %d ядрах" % [seed_value, world.prov_count, gen_ms, Parallel.thread_count()]
	hud.show_select(-1)


func start_as(nid: int) -> void:
	for n in world.nations:
		n.is_player = n.id == nid
	world.nations[nid].current_research = ""
	unit_layer.player = nid
	map_view.set_highlight_nation(-1)
	map_view.set_selected(-1)
	map_view.center_on(world.nations[nid].capital)
	state = "play"
	speed = 1
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
	if speed > 0:
		_accum += dt * SPEEDS[speed]
		var n := 0
		while _accum >= 1.0 and n < MAX_TICKS_PER_FRAME:
			_accum -= 1.0
			sim.tick()
			n += 1
		if n == MAX_TICKS_PER_FRAME:
			_accum = minf(_accum, 1.0)
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
			pick_nation = world.p_owner[p]
			map_view.set_highlight_nation(pick_nation)
			hud.show_select(pick_nation)
		return
	if state != "play":
		return
	var me := player()
	# есть выделенные войска -> приказ на движение
	if not selected_divs.is_empty() and p != selected_prov:
		var ok := 0
		for d in selected_divs:
			if sim.order_move(d, p):
				ok += 1
		if ok > 0:
			hud.toast("Приказ отдан: %d дивизий → %s" % [ok, world.p_name[p]])
			selected_prov = p
			map_view.set_selected(p)
			hud.show_selection()
			return
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
	selected_divs.clear()
	selected_prov = -1
	map_view.set_selected(-1)
	hud.hide_info()


func select_all() -> void:
	selected_divs.clear()
	for d in world.divisions_of(player()):
		if not d.in_battle:
			selected_divs.append(d)
	selected_prov = -1
	map_view.set_selected(-1)
	hud.show_selection()


func stop_selected() -> void:
	for d in selected_divs:
		d.path = PackedInt32Array()
		d.progress = 0.0


# --- Действия игрока ---------------------------------------------------------

func set_speed(s: int) -> void:
	speed = clampi(s, 0, SPEEDS.size() - 1)


func train(count: int) -> int:
	var made := 0
	for i in count:
		if sim.train_division(player()):
			made += 1
	return made


func declare_war_on(target: int) -> void:
	world.declare_war(player(), target)
	hud.on_tick()


func set_map_mode(m: int) -> void:
	map_view.set_map_mode(m)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if hud != null and hud.close_popup():
			return
		if not selected_divs.is_empty():
			clear_selection()
