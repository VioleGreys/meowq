class_name FocusView
extends PanelContainer
## Дерево фокусов на весь экран: прокрутка пальцем, касание фокуса — подробности
## и кнопка «Начать».

const NODE := Vector2(190, 70)
const GAP := Vector2(30, 46)

var game
var world: World
var nid := -1
var tree: Control
var scroll: ScrollContainer
var head: Label
var detail: Label
var start_btn: Button
var selected := ""
var _buttons := {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 176
	offset_top = 70
	offset_right = -8
	offset_bottom = -8
	var v := VBoxContainer.new()
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	head = Label.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_theme_font_size_override("font_size", 20)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(head)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(56, 52)
	close.pressed.connect(func(): hide())
	top.add_child(close)
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	tree = Control.new()
	tree.draw.connect(_draw_lines)
	scroll.add_child(tree)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	v.add_child(bottom)
	detail = Label.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_font_size_override("font_size", 16)
	detail.custom_minimum_size = Vector2(0, 70)
	bottom.add_child(detail)
	start_btn = Button.new()
	start_btn.text = "Начать"
	start_btn.custom_minimum_size = Vector2(150, 60)
	start_btn.pressed.connect(func(): game.act(_start), CONNECT_DEFERRED)
	bottom.add_child(start_btn)


func open(g, w: World, n: int) -> void:
	game = g
	world = w
	nid = n
	selected = ""
	_rebuild()
	show()


func _rebuild() -> void:
	for c in tree.get_children():
		c.queue_free()
	_buttons.clear()
	var defs := History.tree_of(world, nid)
	var max_x := 0
	var max_y := 0
	for fd in defs:
		max_x = maxi(max_x, int(fd["x"]))
		max_y = maxi(max_y, int(fd["y"]))
		var b := Button.new()
		b.text = fd["name"]
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 15)
		b.position = _pos(fd)
		b.size = NODE
		var id: String = fd["id"]
		b.pressed.connect(func(): game.act(func(): _select(id)), CONNECT_DEFERRED)
		tree.add_child(b)
		_buttons[id] = b
	tree.custom_minimum_size = Vector2((max_x + 1) * (NODE.x + GAP.x) + GAP.x, (max_y + 1) * (NODE.y + GAP.y) + GAP.y)
	refresh()


func _pos(fd: Dictionary) -> Vector2:
	return Vector2(GAP.x + int(fd["x"]) * (NODE.x + GAP.x), GAP.y * 0.5 + int(fd["y"]) * (NODE.y + GAP.y))


## Обновить цвета и подписи (каждый игровой день, пока окно открыто).
func refresh() -> void:
	if world == null or nid < 0:
		return
	var nat: World.Nation = world.nations[nid]
	if nat.focus_current != "":
		var fd := History.focus_def(world, nid, nat.focus_current)
		head.text = "Фокус: «%s» — осталось %d дн." % [fd.get("name", ""), nat.focus_days]
	else:
		head.text = "Фокус не выбран — выберите следующий шаг страны"
	for fd in History.tree_of(world, nid):
		var b: Button = _buttons.get(fd["id"])
		if b == null:
			continue
		var st := History.focus_block(world, nid, fd)
		var col := Color(0.24, 0.23, 0.2)
		if st == "выполнен":
			col = Color(0.2, 0.42, 0.22)
		elif st == "выполняется":
			col = Color(0.55, 0.45, 0.15)
		elif st == "":
			col = Color(0.32, 0.31, 0.27)
		else:
			col = Color(0.16, 0.16, 0.16)
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_corner_radius_all(10)
		sb.set_border_width_all(3 if fd["id"] == selected else 1)
		sb.border_color = Color(1, 0.9, 0.6) if fd["id"] == selected else Color(0.6, 0.53, 0.36)
		sb.set_content_margin_all(6)
		for state in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(state, sb)
		b.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85) if st != "" or true else Color.WHITE)
	_update_detail()
	tree.queue_redraw()


func _draw_lines() -> void:
	for fd in History.tree_of(world, nid):
		for r in fd.get("requires", []):
			var rd := History.focus_def(world, nid, r)
			if rd.is_empty():
				continue
			var a := _pos(rd) + Vector2(NODE.x * 0.5, NODE.y)
			var b := _pos(fd) + Vector2(NODE.x * 0.5, 0)
			var done: bool = world.nations[nid].focus_done.has(r)
			tree.draw_line(a, b, Color(0.75, 0.65, 0.4) if done else Color(0.45, 0.42, 0.36), 3.0)
		# развилка — красный пунктир между взаимоисключающими фокусами
		for x in fd.get("exclusive", []):
			var xd := History.focus_def(world, nid, x)
			if xd.is_empty() or String(x) < String(fd["id"]):
				continue
			var p1 := _pos(fd) + NODE * 0.5
			var p2 := _pos(xd) + NODE * 0.5
			tree.draw_dashed_line(p1, p2, Color(0.66, 0.13, 0.11), 3.0, 10.0)


var _forecast := ""   # прогноз шансов: считается при выборе фокуса, а не каждый день


func _select(id: String) -> void:
	selected = id
	game.world_lock()
	_forecast = History.forecast_text(world, nid, History.focus_def(world, nid, id))
	game.world_unlock()
	refresh()


func _update_detail() -> void:
	if selected == "":
		detail.text = "Коснитесь фокуса, чтобы увидеть подробности. Выполняется один фокус за раз."
		start_btn.disabled = true
		return
	var fd := History.focus_def(world, nid, selected)
	var st := History.focus_block(world, nid, fd)
	var txt := "%s (%d дн.) — %s\n%s" % [fd["name"], fd.get("days", 70), fd.get("desc", ""), History.effects_text(world, fd.get("effects", []))]
	if _forecast != "":
		txt += "\n" + _forecast
	if st != "":
		txt += "\n⟶ " + st
	detail.text = txt
	start_btn.disabled = st != "" or world.nations[nid].focus_current != ""


func _start() -> void:
	if History.start_focus(world, nid, selected):
		game.hud.toast("Начат фокус «%s»" % History.focus_def(world, nid, selected)["name"])
	refresh()
