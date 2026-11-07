class_name Hud
extends CanvasLayer
## Интерфейс, рассчитанный на пальцы: крупные кнопки, нижняя панель
## информации, всплывающие окна армии / науки / стройки / дипломатии.

var game  # main.gd
var gen_info := ""

var root: Control
var top_bar: PanelContainer
var swatch: ColorRect
var nation_label: Label
var date_label: Label
var res_label: Label
var speed_buttons: Array = []
var side: VBoxContainer
var info_panel: PanelContainer
var info_label: Label
var info_actions: HBoxContainer
var popup: PanelContainer
var popup_title: Label
var popup_body: VBoxContainer
var popup_tab := ""
var log_box: VBoxContainer
var perf_label: Label
var overlay: PanelContainer
var overlay_box: VBoxContainer
var toast_label: Label
var _toast_t := 0.0
var _dynamic: Dictionary = {}   # ссылки на элементы окна, которые обновляются каждый тик
var _info_prov := -1


func _ready() -> void:
	layer = 2
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()
	add_child(root)
	_build_top_bar()
	_build_side()
	_build_info()
	_build_popup()
	_build_log()
	_build_overlay()
	toast_label = Label.new()
	toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	toast_label.position = Vector2(-300, -190)
	toast_label.size = Vector2(600, 40)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_color_override("font_outline_color", Color.BLACK)
	toast_label.add_theme_constant_override("outline_size", 6)
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_label)


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 20
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.11, 0.12, 0.13, 0.92)
	panel.border_color = Color(0.55, 0.47, 0.32)
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(8)
	panel.set_content_margin_all(10)
	t.set_stylebox("panel", "PanelContainer", panel)
	var btn := StyleBoxFlat.new()
	btn.bg_color = Color(0.24, 0.23, 0.2)
	btn.border_color = Color(0.62, 0.53, 0.36)
	btn.set_border_width_all(2)
	btn.set_corner_radius_all(6)
	btn.set_content_margin_all(8)
	var hover := btn.duplicate()
	hover.bg_color = Color(0.33, 0.31, 0.26)
	var pressed := btn.duplicate()
	pressed.bg_color = Color(0.5, 0.42, 0.25)
	var disabled := btn.duplicate()
	disabled.bg_color = Color(0.17, 0.17, 0.17)
	disabled.border_color = Color(0.3, 0.3, 0.3)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.93, 0.89, 0.8))
	t.set_color("font_disabled_color", "Button", Color(0.5, 0.5, 0.5))
	t.set_color("font_color", "Label", Color(0.93, 0.9, 0.82))
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.05, 0.05, 0.05)
	bar_bg.set_corner_radius_all(4)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.75, 0.6, 0.3)
	bar_fill.set_corner_radius_all(4)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)
	return t


func _button(text: String, cb: Callable, min_size := Vector2(0, 56)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.pressed.connect(cb)
	return b


# --- Построение --------------------------------------------------------------

func _build_top_bar() -> void:
	top_bar = PanelContainer.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_left = 8
	top_bar.offset_right = -8
	top_bar.offset_top = 6
	root.add_child(top_bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	top_bar.add_child(h)
	swatch = ColorRect.new()
	swatch.custom_minimum_size = Vector2(34, 34)
	h.add_child(swatch)
	nation_label = Label.new()
	nation_label.add_theme_font_size_override("font_size", 22)
	h.add_child(nation_label)
	res_label = Label.new()
	res_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_label.clip_text = true
	res_label.add_theme_font_size_override("font_size", 18)
	h.add_child(res_label)
	date_label = Label.new()
	date_label.custom_minimum_size = Vector2(190, 0)
	date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(date_label)
	var labels := ["II", "1", "2", "3", "4", "5"]
	for i in labels.size():
		var b := _button(labels[i], func(): game.set_speed(i); refresh_top(), Vector2(48, 48))
		b.toggle_mode = true
		speed_buttons.append(b)
		h.add_child(b)


func _build_side() -> void:
	side = VBoxContainer.new()
	side.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	side.position = Vector2(10, -220)
	side.add_theme_constant_override("separation", 8)
	root.add_child(side)
	side.add_child(_button("Армия", func(): open_tab("army"), Vector2(150, 60)))
	side.add_child(_button("Наука", func(): open_tab("research"), Vector2(150, 60)))
	side.add_child(_button("Стройка", func(): open_tab("build"), Vector2(150, 60)))
	side.add_child(_button("Дипломатия", func(): open_tab("diplomacy"), Vector2(150, 60)))
	side.add_child(_button("Все войска", func(): game.select_all(), Vector2(150, 60)))
	side.add_child(_button("Режим карты", _cycle_map_mode, Vector2(150, 60)))


func _build_info() -> void:
	info_panel = PanelContainer.new()
	info_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	info_panel.offset_left = 180
	info_panel.offset_right = -180
	info_panel.offset_bottom = -8
	info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(info_panel)
	var v := VBoxContainer.new()
	info_panel.add_child(v)
	info_label = Label.new()
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.add_theme_font_size_override("font_size", 18)
	v.add_child(info_label)
	info_actions = HBoxContainer.new()
	info_actions.add_theme_constant_override("separation", 8)
	v.add_child(info_actions)
	info_panel.hide()


func _build_popup() -> void:
	popup = PanelContainer.new()
	popup.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	popup.offset_left = -470
	popup.offset_right = -8
	popup.offset_top = 70
	popup.offset_bottom = -8
	root.add_child(popup)
	var v := VBoxContainer.new()
	popup.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	popup_title = Label.new()
	popup_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup_title.add_theme_font_size_override("font_size", 24)
	head.add_child(popup_title)
	head.add_child(_button("✕", close_popup, Vector2(56, 52)))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	popup_body = VBoxContainer.new()
	popup_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup_body.add_theme_constant_override("separation", 8)
	scroll.add_child(popup_body)
	popup.hide()


func _build_log() -> void:
	log_box = VBoxContainer.new()
	log_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	log_box.position = Vector2(-520, 72)
	log_box.custom_minimum_size = Vector2(510, 0)
	log_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(log_box)
	perf_label = Label.new()
	perf_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	perf_label.offset_top = -26
	perf_label.offset_right = -10
	perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	perf_label.add_theme_font_size_override("font_size", 14)
	perf_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.7))
	perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(perf_label)


func _build_overlay() -> void:
	overlay = PanelContainer.new()
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.custom_minimum_size = Vector2(560, 0)
	overlay.grow_horizontal = Control.GROW_DIRECTION_BOTH
	overlay.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(overlay)
	overlay_box = VBoxContainer.new()
	overlay_box.add_theme_constant_override("separation", 10)
	overlay.add_child(overlay_box)


func _clear(c: Node) -> void:
	for ch in c.get_children():
		c.remove_child(ch)
		ch.queue_free()


func _label(text: String, size := 20, color := Color(0.93, 0.9, 0.82)) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


# --- Экраны ------------------------------------------------------------------

func show_loading() -> void:
	top_bar.hide()
	side.hide()
	info_panel.hide()
	popup.hide()
	_clear(overlay_box)
	overlay_box.add_child(_label("Генерация мира…", 28))
	overlay_box.add_child(_label("Рельеф и провинции считаются параллельно на %d ядрах" % Parallel.thread_count(), 18))
	overlay.show()


func show_select(nid: int) -> void:
	top_bar.hide()
	side.hide()
	info_panel.hide()
	popup.hide()
	_clear(overlay_box)
	var w: World = game.world
	overlay.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	overlay.offset_top = -10
	overlay.offset_bottom = -10
	overlay.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if nid < 0:
		overlay_box.add_child(_label("Выберите страну", 28))
		overlay_box.add_child(_label("Коснитесь страны на карте или выберите державу ниже. Карту двигайте пальцем, масштаб — двумя пальцами.", 18))
	else:
		var n: World.Nation = w.nations[nid]
		var provs := 0
		var civ := 0
		var mil := 0
		for p in w.prov_count:
			if w.p_owner[p] == nid:
				provs += 1
				civ += w.p_civ[p]
				mil += w.p_mil[p]
		var t := _label(n.name, 30, n.color.lightened(0.3))
		overlay_box.add_child(t)
		overlay_box.add_child(_label("Столица: %s · Провинций: %d · Дивизий: %d · Фабрик: %d гражд. / %d воен." % [w.p_name[n.capital], provs, w.divisions_of(nid).size(), civ, mil], 18))
		overlay_box.add_child(_button("Начать игру: %s" % n.name, func(): game.start_as(nid), Vector2(0, 64)))
	if game.procedural:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_button("Новая карта", func(): game.new_world(randi() % 100000), Vector2(200, 56)))
		var size_btn := _button("Большая карта" if not game.large_map else "Обычная карта", func():
			game.large_map = not game.large_map
			game.new_world(randi() % 100000), Vector2(220, 56))
		row.add_child(size_btn)
		overlay_box.add_child(row)
	else:
		# быстрый выбор великих держав
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		for tag in ["GER", "SOV", "ENG", "FRA", "ITA", "POL", "SPR", "TUR"]:
			var i: int = game.nation_by_tag(tag)
			if i < 0:
				continue
			var b := _button(w.nations[i].name, func(): game.pick(i), Vector2(150, 48))
			b.add_theme_font_size_override("font_size", 17)
			if i == nid:
				b.disabled = true
			grid.add_child(b)
		overlay_box.add_child(grid)
	overlay_box.add_child(_label(gen_info, 14, Color(0.7, 0.7, 0.7)))
	overlay.show()


func show_play() -> void:
	overlay.hide()
	top_bar.show()
	side.show()
	_clear(log_box)
	refresh_top()
	on_tick()


func show_game_over(result: String) -> void:
	popup.hide()
	_clear(overlay_box)
	overlay.set_anchors_preset(Control.PRESET_CENTER)
	overlay.grow_vertical = Control.GROW_DIRECTION_BOTH
	if result == "victory":
		overlay_box.add_child(_label("Победа!", 36, Color(0.95, 0.85, 0.4)))
		overlay_box.add_child(_label("Все соперники капитулировали. %s" % game.world.date_string(), 20))
	else:
		overlay_box.add_child(_label("Капитуляция", 36, Color(0.9, 0.4, 0.35)))
		overlay_box.add_child(_label("Ваша страна пала. %s" % game.world.date_string(), 20))
	overlay_box.add_child(_button("Новая игра", func(): game.new_world(randi() % 100000), Vector2(0, 64)))

	overlay.show()


# --- Обновление --------------------------------------------------------------

func refresh_top() -> void:
	var w: World = game.world
	if w == null or game.player() < 0:
		return
	var n: World.Nation = w.nations[game.player()]
	swatch.color = n.color
	nation_label.text = n.name
	date_label.text = w.date_string()
	res_label.text = "Снаряж. %d (+%.0f)  ·  Люди %dк  ·  Фабр. %d/%d  ·  Див. %d" % [
		n.equipment, n.daily_equipment, n.manpower, n.civ, n.mil, n.division_count]
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = game.speed == i
	var phases := ""
	for k in game.sim.phase_usec:
		phases += " %s %.1f" % [k, game.sim.phase_usec[k] / 1000.0]
	perf_label.text = "Ядер %d · %.1f дн/с · тик %.2f мс ·%s · %d FPS" % [Parallel.thread_count(), game.days_per_sec, game.sim.last_tick_usec / 1000.0, phases, Engine.get_frames_per_second()]
	if _toast_t > 0.0:
		_toast_t -= get_process_delta_time()
		toast_label.modulate.a = clampf(_toast_t, 0.0, 1.0)


func on_tick() -> void:
	var w: World = game.world
	while not w.events.is_empty():
		var e: String = w.events.pop_front()
		var l := _label(e, 16)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 5)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		log_box.add_child(l)
		while log_box.get_child_count() > 5:
			var old := log_box.get_child(0)
			log_box.remove_child(old)
			old.queue_free()
	if popup.visible:
		_update_popup_dynamic()
	if info_panel.visible:
		if not game.selected_divs.is_empty():
			_update_selection_text()
		elif _info_prov >= 0:
			info_label.text = _province_text(_info_prov)


func toast(text: String) -> void:
	toast_label.text = text
	_toast_t = 2.5
	toast_label.modulate.a = 1.0


# --- Нижняя панель -----------------------------------------------------------

func hide_info() -> void:
	info_panel.hide()
	_info_prov = -1


func _province_text(p: int) -> String:
	var w: World = game.world
	if w.p_land[p] == 0:
		return "Море %s" % w.p_name[p]
	var own: World.Nation = w.nations[w.p_owner[p]]
	var ctrl: World.Nation = w.nations[w.p_controller[p]]
	var s := "%s  ·  %s  ·  %s" % [w.p_name[p], World.TERRAIN_NAMES[w.p_terrain[p]], own.name]
	if ctrl != own:
		s += " (оккупирована: %s)" % ctrl.name
	s += "\nФабрики: %d гражд. / %d воен. · Население: %dк · Очки победы: %d" % [w.p_civ[p], w.p_mil[p], w.p_manpower[p], w.p_vp[p]]
	var counts := {}
	for d in w.prov_divs[p]:
		if d.alive:
			counts[d.owner] = int(counts.get(d.owner, 0)) + 1
	for k in counts:
		s += "\nДивизии %s: %d" % [w.nations[k].name, counts[k]]
	return s


func show_province(p: int) -> void:
	var w: World = game.world
	_info_prov = p
	info_label.text = _province_text(p)
	_clear(info_actions)
	if w.p_land[p] == 1:
		var c := w.p_controller[p]
		var me: int = game.player()
		if c != me and w.nations[c].alive and not w.is_at_war(me, c):
			info_actions.add_child(_button("Объявить войну: %s" % w.nations[c].name, func():
				game.declare_war_on(c)
				show_province(p)))
		info_actions.add_child(_button("Закрыть", func(): game.clear_selection()))
	info_panel.show()


func show_selection() -> void:
	_info_prov = -1
	_update_selection_text()
	_clear(info_actions)
	info_actions.add_child(_button("Стоп", func(): game.stop_selected(); toast("Войска остановлены")))
	info_actions.add_child(_button("Снять выделение", func(): game.clear_selection()))
	info_panel.show()


func _update_selection_text() -> void:
	var sel: Array = game.selected_divs
	if sel.is_empty():
		info_label.text = "Нет выделенных дивизий"
		return
	var w: World = game.world
	var s := 0.0
	var o := 0.0
	var moving := 0
	var fighting := 0
	for d in sel:
		s += d.strength
		o += d.org / maxf(1.0, w.division_max_org(d.owner))
		if not d.path.is_empty():
			moving += 1
		if d.in_battle:
			fighting += 1
	info_label.text = "Выбрано дивизий: %d · сила %d%% · организация %d%% · в пути %d · в бою %d\nКоснитесь провинции, чтобы отправить войска. Вражеская провинция — атака." % [
		sel.size(), s / sel.size(), o / sel.size() * 100.0, moving, fighting]


# --- Всплывающие окна --------------------------------------------------------

func open_tab(tab: String) -> void:
	popup_tab = tab
	_rebuild_popup()
	popup.show()
	log_box.hide()


func close_popup() -> bool:
	if popup.visible:
		popup.hide()
		log_box.show()
		return true
	return false


func _cycle_map_mode() -> void:
	var m: int = (game.map_view.map_mode + 1) % 3
	game.set_map_mode(m)
	toast(["Политическая карта", "Местность", "Промышленность"][m])


func _rebuild_popup() -> void:
	_clear(popup_body)
	_dynamic.clear()
	var w: World = game.world
	var me: int = game.player()
	var n: World.Nation = w.nations[me]
	match popup_tab:
		"army":
			popup_title.text = "Армия"
			_dynamic["army"] = _label("", 18)
			popup_body.add_child(_dynamic["army"])
			popup_body.add_child(_label("Дивизия: %d снаряжения и %dк человек, подготовка %d дн." % [
				Simulation.DIV_EQUIP_COST, Simulation.DIV_MANPOWER_COST, Simulation.DIV_TRAIN_DAYS], 16, Color(0.75, 0.75, 0.7)))
			var b1 := _button("Сформировать дивизию", func(): _train(1))
			var b5 := _button("Сформировать 5 дивизий", func(): _train(5))
			_dynamic["b1"] = b1
			_dynamic["b5"] = b5
			popup_body.add_child(b1)
			popup_body.add_child(b5)
			popup_body.add_child(_label("Новые дивизии появляются в столице. Потрёпанные части пополняются на своей территории за счёт снаряжения.", 16, Color(0.75, 0.75, 0.7)))
		"research":
			popup_title.text = "Наука"
			_dynamic["res_id"] = n.current_research
			_dynamic["res"] = _label("", 18)
			popup_body.add_child(_dynamic["res"])
			var bar := ProgressBar.new()
			bar.custom_minimum_size = Vector2(0, 22)
			bar.show_percentage = false
			_dynamic["bar"] = bar
			popup_body.add_child(bar)
			for t in Tech.available(n):
				var id: String = t["id"]
				var b := _button("%s\n%s · %d очков" % [t["name"], t["desc"], t["cost"]], func():
					if n.current_research != id:
						n.current_research = id
						n.research_points = 0.0
					_rebuild_popup())
				b.alignment = HORIZONTAL_ALIGNMENT_LEFT
				if n.current_research == id:
					b.disabled = true
				popup_body.add_child(b)
			if not n.techs.is_empty():
				var done: Array = []
				for k in n.techs:
					done.append(Tech.get_tech(k)["name"])
				popup_body.add_child(_label("Изучено: " + ", ".join(done), 16, Color(0.7, 0.8, 0.7)))
		"build":
			popup_title.text = "Стройка"
			_dynamic["build"] = _label("", 18)
			popup_body.add_child(_dynamic["build"])
			var bar := ProgressBar.new()
			bar.custom_minimum_size = Vector2(0, 22)
			bar.show_percentage = false
			_dynamic["bar"] = bar
			popup_body.add_child(bar)
			var civ := _button("Строить гражданские фабрики", func(): n.build_mode = "civ"; _rebuild_popup())
			var mil := _button("Строить военные заводы", func(): n.build_mode = "mil"; _rebuild_popup())
			civ.disabled = n.build_mode == "civ"
			mil.disabled = n.build_mode == "mil"
			popup_body.add_child(civ)
			popup_body.add_child(mil)
			popup_body.add_child(_label("Гражданские фабрики ускоряют стройку и науку. Военные заводы выпускают снаряжение для дивизий. Оккупированные провинции дают половину.", 16, Color(0.75, 0.75, 0.7)))
		"diplomacy":
			popup_title.text = "Дипломатия"
			var neighbours := w.neighbours_of_nation(me)
			for o in w.nations:
				if o.id == me or not o.alive:
					continue
				var row := HBoxContainer.new()
				var sw := ColorRect.new()
				sw.color = o.color
				sw.custom_minimum_size = Vector2(22, 22)
				sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				row.add_child(sw)
				var status := "ВОЙНА" if w.is_at_war(me, o.id) else ("сосед" if neighbours.has(o.id) else "мир")
				var l := _label("%s · %s · дивизий %d · провинций %d" % [o.name, status, o.division_count, o.province_count], 17,
					Color(1, 0.5, 0.45) if status == "ВОЙНА" else Color(0.9, 0.88, 0.8))
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				row.add_child(l)
				if not w.is_at_war(me, o.id):
					var oid: int = o.id
					row.add_child(_button("Война", func(): game.declare_war_on(oid); _rebuild_popup(), Vector2(100, 48)))
				popup_body.add_child(row)
	_update_popup_dynamic()


func _train(count: int) -> void:
	var made: int = game.train(count)
	toast("В подготовке: +%d" % made if made > 0 else "Не хватает снаряжения или людей")
	_update_popup_dynamic()


func _update_popup_dynamic() -> void:
	var w: World = game.world
	var n: World.Nation = w.nations[game.player()]
	match popup_tab:
		"army":
			var next := ""
			if not n.training.is_empty():
				next = " (ближайшая через %d дн.)" % n.training.min()
			_dynamic["army"].text = "Дивизий: %d · в подготовке: %d%s\nАтака %.1f · Защита %.1f · Организация %.0f · Скорость x%.2f" % [
				n.division_count, n.training.size(), next, w.division_attack(n.id), w.division_defense(n.id),
				w.division_max_org(n.id), 1.0 + n.b("speed")]
			var can := n.equipment >= Simulation.DIV_EQUIP_COST and n.manpower >= Simulation.DIV_MANPOWER_COST
			_dynamic["b1"].disabled = not can
			_dynamic["b5"].disabled = not can
		"research":
			if n.current_research != _dynamic.get("res_id", ""):
				_rebuild_popup()  # технология изучена — обновить список
				return
			if n.current_research == "":
				_dynamic["res"].text = "Ничего не исследуется — выберите технологию. (+%.1f/день)" % n.daily_research
				_dynamic["bar"].value = 0
			else:
				var t := Tech.get_tech(n.current_research)
				_dynamic["res"].text = "Сейчас: %s — %d / %d (+%.1f/день)" % [t["name"], n.research_points, t["cost"], n.daily_research]
				_dynamic["bar"].max_value = t["cost"]
				_dynamic["bar"].value = n.research_points
		"build":
			var rate := n.civ * 0.12 * (1.0 + n.b("construction"))
			_dynamic["build"].text = "Фабрики: %d гражданских, %d военных\nСледующая: %s, %d%% (+%.1f/день)" % [
				n.civ, n.mil, "гражданская" if n.build_mode == "civ" else "военная",
				n.build_progress / Simulation.FACTORY_COST * 100.0, rate]
			_dynamic["bar"].max_value = Simulation.FACTORY_COST
			_dynamic["bar"].value = n.build_progress
