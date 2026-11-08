class_name Hud
extends CanvasLayer
## Интерфейс, рассчитанный на пальцы: крупные кнопки, нижняя панель
## информации, всплывающие окна армии / науки / стройки / дипломатии.

var game  # main.gd
var gen_info := ""

var root: Control
var top_bar: PanelContainer
var swatch: Flag
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
var _card_nation := -1
var focus_view: FocusView


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
	focus_view = FocusView.new()
	root.add_child(focus_view)
	focus_view.hide()
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
	# действия игрока меняют мир — выполняем под блокировкой (ждём конца дня)
	b.pressed.connect(func():
		if game != null:
			game.world_lock()
		cb.call()
		if game != null:
			game.world_unlock())
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
	swatch = Flag.make({}, Vector2(48, 32))
	h.add_child(swatch)
	nation_label = Label.new()
	nation_label.add_theme_font_size_override("font_size", 22)
	h.add_child(nation_label)
	res_label = Label.new()
	res_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_label.clip_text = true
	res_label.add_theme_font_size_override("font_size", 16)
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
	side.position = Vector2(10, -272)
	side.add_theme_constant_override("separation", 4)
	root.add_child(side)
	var bs := Vector2(166, 52)
	side.add_child(_button("Фокусы", func():
		close_popup()
		focus_view.open(game, game.world, game.player()), bs))
	side.add_child(_button("Армия", func(): open_tab("army"), bs))
	side.add_child(_button("Флот и авиация", func(): open_tab("navy"), bs))
	side.add_child(_button("Производство", func(): open_tab("production"), bs))
	side.add_child(_button("Наука", func(): open_tab("research"), bs))
	side.add_child(_button("Стройка", func(): open_tab("build"), bs))
	side.add_child(_button("Дипломатия", func(): open_tab("diplomacy"), bs))
	side.add_child(_button("Все войска", func(): game.select_all(), bs))
	side.add_child(_button("Режим карты", _cycle_map_mode, bs))


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
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 12)
		head.add_child(Flag.make(n.flag, Vector2(66, 44)))
		var names := VBoxContainer.new()
		names.add_theme_constant_override("separation", 0)
		names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for l in [_label(n.name, 28, n.color.lightened(0.35)), _label(n.full_name, 15, Color(0.75, 0.73, 0.68))]:
			l.autowrap_mode = TextServer.AUTOWRAP_OFF
			names.add_child(l)
		head.add_child(names)
		overlay_box.add_child(head)
		overlay_box.add_child(_label("%s · %s: %s" % [w.ideology_names.get(n.ideology, n.ideology), n.leader_title, n.leader], 18))
		var pop := 0
		for p in w.prov_count:
			if w.p_owner[p] == nid:
				pop += w.p_population[p]
		overlay_box.add_child(_label("Столица: %s · Население: %.1f млн · Дивизий: %d · Фабрики: %d гражд. / %d воен." % [w.p_name[n.capital], pop / 1000.0, w.divisions_of(nid).size(), civ, mil], 17, Color(0.85, 0.83, 0.78)))
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
		var hist := _button("Исторический ИИ: %s" % ("вкл" if w.historical else "выкл"), func():
			w.historical = not w.historical
			show_select(nid), Vector2(0, 44))
		hist.add_theme_font_size_override("font_size", 16)
		overlay_box.add_child(hist)
		overlay_box.add_child(_small("Вкл — страны ИИ следуют истории (фокусы и события по датам). Выкл — альтернативная история."))
		# быстрый выбор великих держав
		var grid := GridContainer.new()
		grid.columns = 4
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		for tag in ["GER", "SOV", "ENG", "FRA", "ITA", "POL", "SPR"]:
			var i: int = game.nation_by_tag(tag)
			if i < 0:
				continue
			var b := _button(w.nations[i].name, func(): game.pick(i), Vector2(150, 48))
			b.add_theme_font_size_override("font_size", 17)
			if i == nid:
				b.disabled = true
			grid.add_child(b)
		var all_btn := _button("Все страны…", func(): open_tab("nations"), Vector2(150, 48))
		all_btn.add_theme_font_size_override("font_size", 17)
		grid.add_child(all_btn)
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
	if swatch.spec != n.flag:
		swatch.spec = n.flag
	nation_label.text = n.name
	date_label.text = w.date_string()
	res_label.text = "Винт. %d · Ору. %d · Танки %d · Груз. %d · Люди %dк · Див. %d" % [
		n.stock[0], n.stock[1], n.stock[2], n.stock[3], n.manpower, n.division_count]
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
	if focus_view.visible:
		focus_view.refresh()
	if info_panel.visible:
		if game.selected_fleet >= 0 and w.fleets[game.selected_fleet].alive:
			show_fleet(w.fleets[game.selected_fleet])
		elif game.selected_wing >= 0 and w.wings[game.selected_wing].alive:
			show_wing(w.wings[game.selected_wing])
		elif game.selected_group >= 0:
			var g: World.ArmyGroup = w.groups[game.selected_group]
			if g.alive:
				_update_group_text(g)
		elif not game.selected_divs.is_empty():
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
	var fn := Diplomacy.faction_name(w, own.id)
	if fn != "":
		s += " («%s»)" % fn
	if ctrl != own:
		s += " (оккупирована: %s)" % ctrl.name
	if w.p_colony[p] == 1:
		s += " · колония"
	s += "\nФабрики: %d гражд. / %d воен. · Население: %s · Резерв: %dк · Очки победы: %d" % [
		w.p_civ[p], w.p_mil[p], _fmt_pop(w.p_population[p]), w.p_manpower[p], w.p_vp[p]]
	var counts := {}
	for d in w.divs_in(p):
		if d.alive:
			counts[d.owner] = int(counts.get(d.owner, 0)) + 1
	for k in counts:
		s += "\nДивизии %s: %d" % [w.nations[k].name, counts[k]]
	return s


func _fmt_pop(k: int) -> String:
	return "%.1f млн" % (k / 1000.0) if k >= 1000 else "%d тыс." % k


func show_province(p: int) -> void:
	var w: World = game.world
	_info_prov = p
	info_label.text = _province_text(p)
	_clear(info_actions)
	if w.p_land[p] == 1:
		var c := w.p_controller[p]
		var me: int = game.player()
		if c != me and w.nations[c].alive:
			info_actions.add_child(_button("Страна: %s" % w.nations[c].name, func():
				_card_nation = c
				open_tab("nation")))
		info_actions.add_child(_button("Закрыть", func(): game.clear_selection()))
	info_panel.show()


func show_selection() -> void:
	_info_prov = -1
	_update_selection_text()
	_clear(info_actions)
	info_actions.add_child(_button("Создать армию", func(): game.create_group_from_selection()))
	info_actions.add_child(_button("Стоп", func(): game.stop_selected(); toast("Войска остановлены")))
	info_actions.add_child(_button("Снять выделение", func(): game.clear_selection()))
	info_panel.show()


## Панель выбранной армии: приказ, противник, цель.
func show_group(g: World.ArmyGroup) -> void:
	_info_prov = -1
	_update_group_text(g)
	_clear(info_actions)
	var hold := _button("Держать фронт", func():
		g.mode = "hold"
		g.objective = -1
		game.map_view.set_selected(-1)
		show_group(g))
	hold.disabled = g.mode == "hold"
	info_actions.add_child(hold)
	var atk := _button("Наступать", func():
		g.mode = "attack"
		show_group(g))
	atk.disabled = g.mode == "attack"
	info_actions.add_child(atk)
	var w: World = game.world
	var en: String = "все противники" if g.enemy < 0 else w.nations[g.enemy].name
	info_actions.add_child(_button("Фронт: %s ▸" % en, func():
		var opts: Array = game.enemy_options()
		var i := opts.find(g.enemy)
		g.enemy = opts[(i + 1) % opts.size()]
		show_group(g)))
	info_actions.add_child(_button("Распустить", func():
		game.sim.disband_group(g)
		game.clear_selection()))
	info_actions.add_child(_button("✕", func(): game.clear_selection(), Vector2(56, 56)))
	info_panel.show()


func _update_group_text(g: World.ArmyGroup) -> void:
	var w: World = game.world
	var divs: Array = game.group_divisions(g.id)
	var s := 0.0
	var sup := 0.0
	var fights := 0
	for d in divs:
		s += d.strength
		sup += d.supply
		if d.in_battle:
			fights += 1
	var n := maxi(1, divs.size())
	var order := "держит фронт" if g.mode == "hold" else "наступает"
	if g.mode == "attack" and g.objective >= 0:
		order += " на %s" % w.p_name[g.objective]
	info_label.text = "%s · %d дивизий · %s · сила %d%% · снабжение %d%% · в бою %d\nКоснитесь провинции — цель наступления. Дивизии распределяются по фронту сами." % [
		g.name, divs.size(), order, s / n, sup / n * 100.0, fights]


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
		o += d.org / maxf(1.0, d.max_org)
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
	if tab == "nations":
		overlay.hide()


func close_popup() -> bool:
	if popup.visible:
		popup.hide()
		log_box.show()
		if game.state == "select":
			overlay.show()
		return true
	return false


func _cycle_map_mode() -> void:
	var m: int = (game.map_view.map_mode + 1) % 5
	game.set_map_mode(m)
	toast(["Политическая карта", "Местность", "Промышленность", "Фракции", "Снабжение"][m])


func _rebuild_popup() -> void:
	_clear(popup_body)
	_dynamic.clear()
	var w: World = game.world
	if popup_tab == "nations":
		_build_nation_list(w)
		return
	var me: int = game.player()
	var n: World.Nation = w.nations[me]
	match popup_tab:
		"army":
			_build_army(w, me)
		"production":
			_build_production(w, me)
		"navy":
			_build_navy(w, me)
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
			_build_diplomacy(w, me)
		"nation":
			_build_nation_card(w, me, _card_nation)
		"peace":
			_build_peace(w)
		"event":
			_build_event(w)
	_update_popup_dynamic()


func _section(text: String) -> Label:
	var l := _label(text, 19, Color(0.95, 0.82, 0.55))
	return l


func _small(text: String) -> Label:
	return _label(text, 15, Color(0.72, 0.71, 0.66))


func _relation(w: World, me: int, o: int) -> String:
	if w.is_at_war(me, o):
		return "ВОЙНА"
	if w.nations[o].overlord == me:
		return "наша марионетка"
	if w.nations[me].overlord == o:
		return "наш сюзерен"
	if Diplomacy.same_side(w, me, o):
		return "союзник"
	var parts: Array = []
	if w.nations[me].pacts.has(o):
		parts.append("пакт")
	if w.nations[me].guarantees.has(o):
		parts.append("под нашей гарантией")
	if w.nations[o].guarantees.has(me):
		parts.append("гарантирует нас")
	if w.nations[me].wargoals.has(o):
		parts.append("претензии обоснованы")
	if w.nations[me].justify_target == o:
		parts.append("обоснование…")
	if w.nations[o].wargoals.has(me) or w.nations[o].justify_target == me:
		parts.append("угрожает нам")
	return ", ".join(parts) if not parts.is_empty() else "мир"


func _build_diplomacy(w: World, me: int) -> void:
	popup_title.text = "Дипломатия"
	var n: World.Nation = w.nations[me]
	_dynamic["tension"] = _label("", 18)
	popup_body.add_child(_dynamic["tension"])
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 18)
	bar.show_percentage = false
	bar.max_value = 100
	_dynamic["tbar"] = bar
	popup_body.add_child(bar)
	popup_body.add_child(_small("Напряжённость растёт от претензий, войн и аннексий. Демократиям нужна напряжённость 50% для претензий, авторитарным режимам — 25%."))
	_dynamic["justify"] = _label("", 17, Color(0.95, 0.8, 0.5))
	popup_body.add_child(_dynamic["justify"])
	# своя фракция
	var fname := Diplomacy.faction_name(w, me)
	if n.overlord >= 0:
		popup_body.add_child(_section("Мы — марионетка страны %s" % w.nations[n.overlord].name))
	elif fname != "":
		var members: Array = []
		for m in Diplomacy.faction_members(w, n.faction):
			members.append(w.nations[m].name)
		popup_body.add_child(_section("Фракция «%s»" % fname))
		popup_body.add_child(_small(", ".join(members)))
		popup_body.add_child(_button("Покинуть фракцию", func():
			Diplomacy.leave_faction(w, me)
			_rebuild_popup()))
	else:
		popup_body.add_child(_section("Мы вне фракций"))
		popup_body.add_child(_button("Создать фракцию", func():
			Diplomacy.create_faction(w, me)
			_rebuild_popup()))
	popup_body.add_child(_section("Страны"))
	popup_body.add_child(_small("Нажмите на страну, чтобы открыть её карточку и действия."))
	var order: Array = []
	for o in w.nations:
		if o.alive and o.id != me:
			order.append(o)
	var neighbours := w.neighbours_of_nation(me)
	order.sort_custom(func(a, b):
		var ka := (0 if w.is_at_war(me, a.id) else (1 if neighbours.has(a.id) else 2))
		var kb := (0 if w.is_at_war(me, b.id) else (1 if neighbours.has(b.id) else 2))
		return ka < kb if ka != kb else a.name < b.name)
	for o in order:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(Flag.make(o.flag, Vector2(36, 24)))
		var rel := _relation(w, me, o.id)
		var f := Diplomacy.faction_name(w, o.id)
		var oid: int = o.id
		var b := _button("%s%s · %s" % [o.name, (" («%s»)" % f) if f != "" else "", rel], func():
			_card_nation = oid
			popup_tab = "nation"
			_rebuild_popup(), Vector2(0, 46))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.add_theme_font_size_override("font_size", 16)
		if rel == "ВОЙНА":
			b.add_theme_color_override("font_color", Color(1, 0.5, 0.45))
		row.add_child(b)
		popup_body.add_child(row)


func _build_nation_card(w: World, me: int, oid: int) -> void:
	var o: World.Nation = w.nations[oid]
	var n: World.Nation = w.nations[me]
	popup_title.text = o.name
	popup_body.add_child(_button("← Ко всем странам", func():
		popup_tab = "diplomacy"
		_rebuild_popup(), Vector2(0, 44)))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(Flag.make(o.flag, Vector2(60, 40)))
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_child(_label(o.full_name, 17))
	names.add_child(_small("%s · %s: %s" % [w.ideology_names.get(o.ideology, ""), o.leader_title, o.leader]))
	head.add_child(names)
	popup_body.add_child(head)
	var f := Diplomacy.faction_name(w, oid)
	var info := "Фракция: %s · Дивизий: %d · Фабрики: %d/%d" % [f if f != "" else "нет", o.division_count, o.civ, o.mil]
	if o.overlord >= 0:
		info += "\nМарионетка страны %s" % w.nations[o.overlord].name
	if o.neutral:
		info += "\nТрадиционный нейтралитет"
	popup_body.add_child(_small(info))
	popup_body.add_child(_label("Отношения: " + _relation(w, me, oid), 17))
	popup_body.add_child(_section("Действия"))
	# претензии и война
	if w.nations[me].wargoals.has(oid):
		_action("Объявить войну", Diplomacy.can_declare(w, me, oid), func():
			game.declare_war_on(oid))
	else:
		var days := Diplomacy.justify_days(w, oid)
		_action("Обосновать претензии (%d дн.)" % days, Diplomacy.can_justify(w, me, oid), func():
			Diplomacy.start_justify(w, me, oid)
			toast("Обоснование претензий: %d дней" % days))
	# пакт
	if n.pacts.has(oid):
		_action("Расторгнуть пакт о ненападении", "", func():
			Diplomacy.break_pact(w, me, oid))
	else:
		var why := _proposal_block(w, me, oid)
		if why == "":
			var ans: Array = Diplomacy.ai_accepts(w, me, oid, "pact") if not o.is_player else [true, ""]
			why = "" if ans[0] else "откажут: " + ans[1]
		_action("Предложить пакт о ненападении", why, func():
			Diplomacy.sign_pact(w, me, oid))
	# гарантия
	if not n.guarantees.has(oid):
		var gwhy := ""
		if Diplomacy.same_side(w, me, oid) or w.is_at_war(me, oid):
			gwhy = "невозможно"
		elif n.overlord >= 0:
			gwhy = "марионетка не ведёт свою внешнюю политику"
		_action("Гарантировать независимость", gwhy, func():
			Diplomacy.guarantee(w, me, oid))
	# фракции
	var my_f: int = w.nations[Diplomacy.root(w, me)].faction
	if my_f >= 0 and w.factions[my_f].leader == me and o.faction < 0:
		var ans: Array = Diplomacy.ai_accepts(w, me, oid, "invite")
		var iwhy := _proposal_block(w, me, oid)
		if iwhy == "" and not ans[0]:
			iwhy = "откажут: " + ans[1]
		_action("Пригласить во фракцию", iwhy, func():
			Diplomacy.join_faction(w, oid, my_f))
	if n.faction < 0 and n.overlord < 0 and o.faction >= 0 and w.factions[o.faction].leader == oid:
		var ans2: Array = Diplomacy.ai_accepts(w, me, oid, "join")
		var jwhy := _proposal_block(w, me, oid)
		if jwhy == "" and not ans2[0]:
			jwhy = "откажут: " + ans2[1]
		_action("Попроситься во фракцию «%s»" % w.factions[o.faction].name, jwhy, func():
			Diplomacy.join_faction(w, me, o.faction))


func _proposal_block(w: World, me: int, oid: int) -> String:
	if w.is_at_war(me, oid):
		return "мы воюем"
	if w.nations[me].overlord >= 0:
		return "марионетка не ведёт свою внешнюю политику"
	if w.nations[oid].overlord >= 0:
		return "это марионетка страны %s" % w.nations[w.nations[oid].overlord].name
	return ""


## Кнопка действия; если нельзя — серая с причиной под ней.
func _action(text: String, why: String, cb: Callable) -> void:
	var b := _button(text, func():
		cb.call()
		game.hud_changed()
		_rebuild_popup(), Vector2(0, 50))
	b.disabled = why != ""
	popup_body.add_child(b)
	if why != "":
		popup_body.add_child(_small("   " + why))


func _build_peace(w: World) -> void:
	popup_title.text = "Мирный договор"
	if w.pending_peace.is_empty():
		close_popup()
		return
	var pp: Array = w.pending_peace[0]
	var loser: World.Nation = w.nations[pp[0]]
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(Flag.make(loser.flag, Vector2(60, 40)))
	var title := _label("%s капитулирует!" % loser.name, 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	popup_body.add_child(head)
	popup_body.add_child(_small("Выберите условия мира. Время стоит, пока вы не решите."))
	popup_body.add_child(_button("Аннексировать", func(): game.resolve_peace("annex"), Vector2(0, 56)))
	popup_body.add_child(_small("Оккупанты забирают занятые провинции, остальное — нам. Напряжённость +1,5%."))
	popup_body.add_child(_button("Сделать марионеткой", func(): game.resolve_peace("puppet"), Vector2(0, 56)))
	popup_body.add_child(_small("Страна сохраняет все земли, распускает армию и воюет на нашей стороне."))


func _build_event(w: World) -> void:
	if w.pending_events.is_empty():
		close_popup()
		return
	var id: String = w.pending_events[0]
	var ev: Dictionary = w.event_defs.get(id, {})
	popup_title.text = ev.get("title", id)
	popup_body.add_child(_label(w.date_string(), 15, Color(0.75, 0.7, 0.6)))
	popup_body.add_child(_label(ev.get("text", ""), 18))
	var opts: Array = ev.get("options", [])
	if opts.size() > 1:
		popup_body.add_child(_small("★ — так поступили в истории"))
	var best := 0
	for i in opts.size():
		if float(opts[i].get("ai", 0)) > float(opts[best].get("ai", 0)):
			best = i
	for i in opts.size():
		var o: Dictionary = opts[i]
		var k := i
		var b := _button(o.get("name", "?") + ("  ★" if i == best and opts.size() > 1 else ""), func():
			game.resolve_event(k), Vector2(0, 56))
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		popup_body.add_child(b)
		var et := History.effects_text(w, o.get("effects", []))
		if et != "":
			popup_body.add_child(_small("   " + et))


## Список всех стран для выбора (экран выбора, игрока ещё нет).
func _build_nation_list(w: World) -> void:
	popup_title.text = "Все страны"
	var order: Array = []
	for o in w.nations:
		if o.alive:
			order.append(o)
	order.sort_custom(func(a, b): return a.name < b.name)
	for o in order:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.add_child(Flag.make(o.flag, Vector2(42, 28)))
		var oid: int = o.id
		var b := _button("%s · %s" % [o.name, w.ideology_names.get(o.ideology, "")], func():
			close_popup()
			game.pick(oid), Vector2(0, 50))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		popup_body.add_child(row)


func _train(count: int, tpl: int) -> void:
	var made: int = game.train(count, tpl)
	toast("В подготовке: +%d" % made if made > 0 else Military.can_train(game.world.nations[game.player()], tpl))
	_rebuild_popup()


func _eq_text(eq: Array) -> String:
	var parts: Array = []
	for k in Military.EQ_COUNT:
		if eq[k] > 0:
			parts.append("%s %d" % [Military.EQ_SHORT[k], eq[k]])
	return ", ".join(parts)


func _build_army(w: World, me: int) -> void:
	popup_title.text = "Армия"
	var n: World.Nation = w.nations[me]
	_dynamic["army"] = _label("", 17)
	popup_body.add_child(_dynamic["army"])
	popup_body.add_child(_section("Армии"))
	var any := false
	for g in w.groups:
		if g.alive and g.owner == me:
			any = true
			var cnt: int = game.group_divisions(g.id).size()
			var gid: int = g.id
			var b := _button("%s · %d див. · %s" % [g.name, cnt, "держит фронт" if g.mode == "hold" else "наступает"], func():
				close_popup()
				game.select_group(gid), Vector2(0, 48))
			b.add_theme_color_override("font_color", g.color)
			popup_body.add_child(b)
	if not any:
		popup_body.add_child(_small("Выделите дивизии на карте (или «Все войска») и нажмите «Создать армию». Армия сама держит фронт против выбранной страны или наступает к цели."))
	popup_body.add_child(_section("Формирование дивизий"))
	for t in Military.tpl_count():
		var tp: Dictionary = Military.tpl(t)
		var why := Military.can_train(n, t)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var b1 := _button("%s" % tp["name"], func(): _train(1, t), Vector2(0, 48))
		b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b1.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b1.disabled = why != ""
		row.add_child(b1)
		var b5 := _button("×5", func(): _train(5, t), Vector2(60, 48))
		b5.disabled = why != ""
		row.add_child(b5)
		popup_body.add_child(row)
		popup_body.add_child(_small("   атака %d · оборона %d · скорость ×%.1f · %dк чел. · %s · %d дн.%s" % [
			tp["atk"], tp["def"], tp["spd"], tp["men"], _eq_text(tp["eq"]), tp["days"], ("\n   " + why) if why != "" else ""]))


func _ships_text(f: World.Fleet) -> String:
	var parts: Array = []
	for k in 4:
		if f.ships[k] > 0:
			parts.append("%s %d" % [Forces.SHIP_NAMES[k].substr(0, 4).to_lower(), f.ships[k]])
	return ", ".join(parts)


const MISSION_NAMES := {"patrol": "патруль", "raid": "рейды", "port": "в порту",
	"sup": "превосходство", "cas": "поддержка войск", "bomb": "бомбардировка", "naval": "удары по флоту"}


func _build_navy(w: World, me: int) -> void:
	popup_title.text = "Флот и авиация"
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Флоты"))
	var any := false
	for f in w.fleets:
		if f.alive and f.owner == me:
			any = true
			var fid: int = f.id
			var b := _button("%s · %s · %d%% · %s · %s" % [f.name, _ships_text(f), f.readiness * 100.0, w.p_name[f.zone], MISSION_NAMES.get(f.mission, f.mission)], func():
				close_popup()
				game.select_fleet(fid), Vector2(0, 46))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			b.add_theme_font_size_override("font_size", 15)
			popup_body.add_child(b)
	if not any:
		popup_body.add_child(_small("Флота нет."))
	popup_body.add_child(_section("Верфи"))
	var q: Array = []
	for t in n.ship_queue:
		q.append(Forces.SHIP_ONE[t])
	popup_body.add_child(_small("Очки судостроения: %d (+%.1f/день, заводы — во вкладке «Производство»). Очередь: %s" % [
		n.stock[Military.EQ_SHIP], n.daily_output[Military.EQ_SHIP], ", ".join(q) if not q.is_empty() else "пусто"]))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for t in 4:
		var tt := t
		var b := _button("+%s\n%d" % [Forces.SHIP_ONE[t], Forces.SHIP_COST[t]], func():
			n.ship_queue.append(tt)
			_rebuild_popup(), Vector2(0, 56))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 14)
		row.add_child(b)
	popup_body.add_child(row)
	popup_body.add_child(_section("Авиация"))
	for wg in w.wings:
		if wg.alive and wg.owner == me:
			var wid: int = wg.id
			var b := _button("%s · %d самол. · %s · %s" % [wg.name, wg.planes, w.region_name[wg.region], MISSION_NAMES.get(wg.mission, wg.mission)], func():
				close_popup()
				game.select_wing(wid), Vector2(0, 46))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			b.add_theme_font_size_override("font_size", 15)
			popup_body.add_child(b)
	popup_body.add_child(_small("В резерве: истребителей %d, бомбардировщиков %d — пополняют крылья до %d самолётов." % [
		n.stock[Military.EQ_FIG], n.stock[Military.EQ_BOMB], Forces.WING_MAX]))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	for kind in 2:
		var k := kind
		var b := _button("Новое крыло: %s" % ("истребители" if kind == 0 else "бомбардировщики"), func():
			var eq := Military.EQ_FIG if k == 0 else Military.EQ_BOMB
			if n.stock[eq] < 50.0:
				toast("Нужно хотя бы 50 самолётов в резерве")
				return
			var nw := Forces.create_wing(w, me, k, w.p_region[n.capital])
			nw.planes = minf(Forces.WING_MAX, n.stock[eq])
			n.stock[eq] -= nw.planes
			nw.mission = "sup" if k == 0 else "cas"
			_rebuild_popup(), Vector2(0, 48))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 14)
		row2.add_child(b)
	popup_body.add_child(row2)
	popup_body.add_child(_section("Морские высадки"))
	var plans := 0
	for plan in w.invasions:
		if plan.alive and plan.owner == me:
			plans += 1
			var pl: World.InvasionPlan = plan
			var r := HBoxContainer.new()
			var l := _label("%s → %s · %d див. · %s" % [w.p_name[plan.port], w.p_name[plan.target], plan.divs.size(), Forces.plan_status(w, plan)], 15)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.add_child(l)
			r.add_child(_button("Отменить", func():
				Forces.cancel_plan(w, pl)
				_rebuild_popup(), Vector2(110, 44)))
			popup_body.add_child(r)
	if plans == 0:
		popup_body.add_child(_small("Переправа: выделите дивизии в своём порту и коснитесь своего или союзного порта за морем — войска пойдут без подготовки. Высадка: выделите дивизии в порту и коснитесь вражеского побережья. Подготовка — 1–2 месяца, войска ждут в порту; высадка — когда подготовка готова и у цели господство на море. Плацдарм снабжает войска 60 дней — захватите порт: через него идут снабжение и подкрепления."))


func show_fleet(f: World.Fleet) -> void:
	var w: World = game.world
	_info_prov = -1
	info_label.text = "%s · %s · сила %d · готовность %d%% · %s · %s%s\nКоснитесь моря (или берега), чтобы отправить флот. Готовность восстанавливается на военно-морской базе; флот на базе в бою не участвует." % [
		f.name, _ships_text(f), Forces.fleet_power(f), f.readiness * 100.0, w.p_name[f.zone], MISSION_NAMES.get(f.mission, f.mission),
		(" · в пути %d дн." % f.path.size()) if not f.path.is_empty() else ""]
	_clear(info_actions)
	for m in ["patrol", "raid", "port"]:
		var mm: String = m
		var b := _button(MISSION_NAMES[m].capitalize(), func():
			f.mission = mm
			if mm == "port":
				f.path = Forces.sea_path(w, f.zone, f.home)
			show_fleet(f))
		b.disabled = f.mission == m
		info_actions.add_child(b)
	info_actions.add_child(_button("✕", func(): game.clear_selection(), Vector2(56, 56)))
	info_panel.show()


func show_wing(wg: World.AirWing) -> void:
	var w: World = game.world
	_info_prov = -1
	var sup: float = w.air_sup[wg.region * w.nation_count + wg.owner] if w.air_sup.size() > wg.region * w.nation_count + wg.owner else 0.5
	info_label.text = "%s · %d самолётов · район %s · превосходство %d%%\nКоснитесь карты, чтобы сменить район (дальность ограничена)." % [
		wg.name, wg.planes, w.region_name[wg.region], sup * 100.0]
	_clear(info_actions)
	var missions := ["sup"] if wg.kind == 0 else ["cas", "bomb", "naval"]
	for m in missions:
		var mm: String = m
		var b := _button(MISSION_NAMES[m].capitalize(), func():
			wg.mission = mm
			show_wing(wg))
		b.disabled = wg.mission == m
		info_actions.add_child(b)
	info_actions.add_child(_button("✕", func(): game.clear_selection(), Vector2(56, 56)))
	info_panel.show()


func _build_production(w: World, me: int) -> void:
	popup_title.text = "Производство"
	var n: World.Nation = w.nations[me]
	_dynamic["prod"] = _label("", 17)
	popup_body.add_child(_dynamic["prod"])
	popup_body.add_child(_small("Военные заводы выпускают снаряжение для новых дивизий и пополнения. Новая линия разгоняется с 30% до 100% эффективности."))
	var need := Military.shortage(w, me)
	for k in Military.EQ_COUNT:
		var f := 0
		var eff := 0.0
		for line in n.lines:
			if line[0] == k:
				f = line[1]
				eff = line[2]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := _label("%s\nзаводов %d · эфф. %d%% · +%.1f/день · склад %d · не хватает %d" % [
			Military.EQ_NAMES[k], f, eff * 100.0, n.daily_output[k], n.stock[k], need[k]], 16)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var kk := k
		row.add_child(_button("−", func():
			Military.change_line(n, kk, -1)
			_rebuild_popup(), Vector2(52, 48)))
		row.add_child(_button("+", func():
			if not Military.change_line(n, kk, 1):
				toast("Нет свободных заводов")
			_rebuild_popup(), Vector2(52, 48)))
		popup_body.add_child(row)


func _update_popup_dynamic() -> void:
	var w: World = game.world
	if game.player() < 0:
		return
	var n: World.Nation = w.nations[game.player()]
	match popup_tab:
		"diplomacy":
			_dynamic["tension"].text = "Мировая напряжённость: %d%%" % w.tension
			_dynamic["tbar"].value = w.tension
			if n.justify_target >= 0:
				_dynamic["justify"].text = "Обоснование претензий к стране %s: осталось %d дн." % [w.nations[n.justify_target].name, n.justify_days]
			elif not n.wargoals.is_empty():
				var names: Array = []
				for t in n.wargoals:
					names.append(w.nations[t].name)
				_dynamic["justify"].text = "Претензии обоснованы: " + ", ".join(names)
			else:
				_dynamic["justify"].text = ""
		"army":
			var next := ""
			if not n.training.is_empty():
				var m := 9999
				for e in n.training:
					m = mini(m, int(e[0]))
				next = " (ближайшая через %d дн.)" % m
			_dynamic["army"].text = "Дивизий: %d · в подготовке: %d%s · людей в резерве: %dк" % [
				n.division_count, n.training.size(), next, n.manpower]
		"production":
			var used := Military.assigned_factories(n)
			_dynamic["prod"].text = "Военных заводов: %d · на линиях: %d · свободно: %d" % [n.mil, used, n.mil - used]
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
			var rate := n.civ * Simulation.BUILD_RATE * (1.0 + n.b("construction"))
			_dynamic["build"].text = "Фабрики: %d гражданских, %d военных\nСледующая: %s, %d%% (+%.1f/день)" % [
				n.civ, n.mil, "гражданская" if n.build_mode == "civ" else "военная",
				n.build_progress / Simulation.FACTORY_COST * 100.0, rate]
			_dynamic["bar"].max_value = Simulation.FACTORY_COST
			_dynamic["bar"].value = n.build_progress
