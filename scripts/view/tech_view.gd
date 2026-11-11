class_name TechView
extends PanelContainer
## Дерево технологий на весь экран: вкладки категорий, линии по годам
## (1936–1944 слева направо), слоты исследований сверху. Касание технологии —
## подробности и кнопка «Исследовать» (в выбранный слот).

const NODE := Vector2(138, 52)
const GAP := Vector2(10, 8)
const LABEL_W := 118.0
const HEAD_H := 26.0
const YEAR0 := 1936
const YEAR1 := 1944

var game
var world: World
var nid := -1
var cat := "ind"
var slot := 0
var selected := ""
var tree: Control
var scroll: ScrollContainer
var head: Label
var detail: Label
var start_btn: Button
var _cat_btns := {}
var _slot_btns: Array = []
var _slot_row: HBoxContainer
var _buttons := {}
var _styles := {}
var _key := ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	offset_left = 176
	offset_top = 70
	offset_right = -8
	offset_bottom = -8
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var title := Label.new()
	title.text = "НАУКА"
	UiStyle.title(title, 24)
	title.add_theme_color_override("font_color", UiStyle.INK)
	top.add_child(title)
	head = Label.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", UiStyle.INK_SOFT)
	top.add_child(head)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.custom_minimum_size = Vector2(48, 40)
	close.add_theme_font_size_override("font_size", 22)
	close.pressed.connect(func(): hide())
	top.add_child(close)
	# слоты исследований
	_slot_row = HBoxContainer.new()
	_slot_row.add_theme_constant_override("separation", 8)
	v.add_child(_slot_row)
	# категории
	var cats := HBoxContainer.new()
	cats.add_theme_constant_override("separation", 4)
	v.add_child(cats)
	for c in Tech.CATS:
		var id: String = c["id"]
		var b := Button.new()
		b.text = c["short"]
		b.icon = UiStyle.icon(c["icon"], 40)
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 13)
		b.clip_text = true
		b.pressed.connect(func(): set_cat(id))
		cats.add_child(b)
		_cat_btns[id] = b
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	tree = Control.new()
	tree.draw.connect(_draw_tree)
	scroll.add_child(tree)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	v.add_child(bottom)
	detail = Label.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_font_size_override("font_size", 13)
	detail.custom_minimum_size = Vector2(0, 66)
	bottom.add_child(detail)
	start_btn = Button.new()
	start_btn.text = "Исследовать"
	start_btn.custom_minimum_size = Vector2(170, 56)
	start_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	start_btn.pressed.connect(func(): game.act(_start), CONNECT_DEFERRED)
	bottom.add_child(start_btn)
	# стили узлов: [фон, рамка]
	var defs := {
		"done": [Color(0.66, 0.72, 0.55), Color(0.25, 0.36, 0.20)],
		"work": [Color(0.91, 0.78, 0.46), Color(0.52, 0.36, 0.12)],
		"open": [UiStyle.CREAM, UiStyle.INK_SOFT],
		"ahead": [Color(0.93, 0.86, 0.76), UiStyle.RED_INK],
		"lock": [Color(0.78, 0.74, 0.65, 0.55), Color(0.45, 0.40, 0.33, 0.6)],
	}
	for k in defs:
		_styles[k] = UiStyle._box(defs[k][0], defs[k][1], 1, 4, 4)
		var sel: StyleBoxFlat = UiStyle._box(defs[k][0], UiStyle.RED_INK, 3, 4, 4)
		_styles[k + "_sel"] = sel


func open(g, w: World, n: int, c := "") -> void:
	game = g
	world = w
	nid = n
	if c != "":
		cat = c
	selected = ""
	var nat: World.Nation = world.nations[nid]
	Tech.fit_slots(nat)
	var fs := Tech.free_slot(nat)
	slot = fs if fs >= 0 else clampi(slot, 0, nat.research.size() - 1)
	_key = ""
	_rebuild()
	show()


func set_cat(c: String) -> void:
	cat = c
	selected = ""
	_rebuild()
	scroll.scroll_horizontal = 0


func _pos(t: Dictionary) -> Vector2:
	var col := clampi(int(t["year"]) - YEAR0, 0, YEAR1 - YEAR0)
	return Vector2(LABEL_W + col * (NODE.x + GAP.x), HEAD_H + int(t["row"]) * (NODE.y + GAP.y))


func _rebuild() -> void:
	for c in tree.get_children():
		tree.remove_child(c)
		c.queue_free()
	_buttons.clear()
	var rows := 1
	for c in Tech.CATS:
		if c["id"] == cat:
			rows = c["rows"].size()
	for t in Tech.of_cat(cat):
		var b := Button.new()
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 11)
		b.add_theme_constant_override("line_spacing", -2)
		b.position = _pos(t)
		b.size = NODE
		b.clip_text = true
		var id: String = t["id"]
		b.pressed.connect(func(): _select(id))
		tree.add_child(b)
		_buttons[id] = b
	tree.custom_minimum_size = Vector2(LABEL_W + (YEAR1 - YEAR0 + 1) * (NODE.x + GAP.x), HEAD_H + rows * (NODE.y + GAP.y))
	refresh()


func _state(nat: World.Nation, t: Dictionary) -> String:
	if nat.techs.has(t["id"]):
		return "done"
	if nat.research.has(t["id"]):
		return "work"
	if not Tech.can_research(nat, t):
		return "lock"
	return "ahead" if float(t["year"]) > Tech.year_now(world) + 0.02 else "open"


## Обновить слоты, цвета и подписи (каждый игровой день, пока окно открыто).
func refresh() -> void:
	if world == null or nid < 0:
		return
	var nat: World.Nation = world.nations[nid]
	Tech.fit_slots(nat)
	slot = clampi(slot, 0, nat.research.size() - 1)
	head.text = "скорость науки %+d%% · изучено %d из %d" % [roundi(nat.b("research") * 100.0), _done_count(nat), Tech.all().size()]
	# слоты
	if _slot_btns.size() != nat.research.size():
		for b in _slot_btns:
			b.queue_free()
		_slot_btns.clear()
		for i in nat.research.size():
			var b := Button.new()
			b.custom_minimum_size = Vector2(0, 44)
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			b.add_theme_font_size_override("font_size", 12)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.clip_text = true
			var si := i
			b.pressed.connect(func(): _pick_slot(si))
			_slot_row.add_child(b)
			_slot_btns.append(b)
	for i in nat.research.size():
		var id: String = nat.research[i]
		var b: Button = _slot_btns[i]
		var mark := "▶ " if i == slot else "  "
		if id == "":
			b.text = "%sСлот %d: свободен\n  выберите технологию" % [mark, i + 1]
		else:
			var t := Tech.get_tech(id)
			var pct := 100.0 * float(nat.research_progress.get(id, 0.0)) / float(t["days"])
			b.text = "%sСлот %d: %s\n  %d%% · осталось %d дн." % [mark, i + 1, t["name"], pct, Tech.days_left(world, nat, id)]
		b.add_theme_color_override("font_color", UiStyle.RED_INK if i == slot else UiStyle.INK)
	for c in _cat_btns:
		_cat_btns[c].disabled = c == cat
	for t in Tech.of_cat(cat):
		var b: Button = _buttons.get(t["id"])
		if b == null:
			continue
		var st := _state(nat, t)
		var sub := ""
		match st:
			"done":
				sub = "изучено"
			"work":
				sub = "%d%% · %d дн." % [100.0 * float(nat.research_progress.get(t["id"], 0.0)) / float(t["days"]), Tech.days_left(world, nat, t["id"])]
			_:
				sub = "%d г. · %d дн." % [t["year"], Tech.days_left(world, nat, t["id"])]
		b.text = "%s\n%s" % [t["name"], sub]
		var sb: StyleBox = _styles[st + ("_sel" if t["id"] == selected else "")]
		for state in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(state, sb)
		var fc := UiStyle.INK if st != "lock" else Color(UiStyle.INK_SOFT, 0.75)
		for cn in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(cn, fc)
	_update_detail()
	tree.queue_redraw()


func _done_count(nat: World.Nation) -> int:
	var c := 0
	for t in Tech.all():
		if nat.techs.has(t["id"]):
			c += 1
	return c


func _draw_tree() -> void:
	if world == null or nid < 0:
		return
	var nat: World.Nation = world.nations[nid]
	var font := UiStyle.mono_bold()
	var yr_now := Tech.year_now(world)
	# шапка лет и полоса текущей даты
	for y in range(YEAR0, YEAR1 + 1):
		var x := LABEL_W + (y - YEAR0) * (NODE.x + GAP.x)
		tree.draw_string(font, Vector2(x, 17), str(y), HORIZONTAL_ALIGNMENT_CENTER, NODE.x, 14,
			UiStyle.INK if y <= int(yr_now) else Color(UiStyle.INK_SOFT, 0.7))
		tree.draw_line(Vector2(x - GAP.x * 0.5, HEAD_H - 4), Vector2(x - GAP.x * 0.5, tree.size.y), Color(UiStyle.INK_SOFT, 0.18), 1.0)
	var nx := LABEL_W + clampf(yr_now - YEAR0, 0.0, YEAR1 - YEAR0 + 1.0) * (NODE.x + GAP.x) - GAP.x * 0.5
	tree.draw_line(Vector2(nx, 2), Vector2(nx, tree.size.y), Color(UiStyle.RED_INK, 0.55), 2.0)
	# названия линий
	for c in Tech.CATS:
		if c["id"] != cat:
			continue
		var rows: Array = c["rows"]
		for r in rows.size():
			var y0 := HEAD_H + r * (NODE.y + GAP.y)
			tree.draw_multiline_string(UiStyle.mono_font(), Vector2(2, y0 + 20), rows[r], HORIZONTAL_ALIGNMENT_LEFT,
				LABEL_W - 10, 12, 3, UiStyle.INK_SOFT)
			tree.draw_line(Vector2(0, y0 - GAP.y * 0.5), Vector2(tree.size.x, y0 - GAP.y * 0.5), Color(UiStyle.INK_SOFT, 0.18), 1.0)
	# связи «требует»
	for t in Tech.of_cat(cat):
		var rd := Tech.get_tech(t["req"])
		if rd.is_empty() or rd["cat"] != cat:
			continue
		var a := _pos(rd) + Vector2(NODE.x, NODE.y * 0.5)
		var b := _pos(t) + Vector2(0, NODE.y * 0.5)
		var col := Color(0.25, 0.36, 0.20) if nat.techs.has(rd["id"]) else Color(UiStyle.INK_SOFT, 0.6)
		if is_equal_approx(a.y, b.y):
			tree.draw_line(a, b, col, 2.0)
		else:
			var mx := b.x - GAP.x * 0.5
			tree.draw_polyline(PackedVector2Array([a, Vector2(mx, a.y), Vector2(mx, b.y), b]), col, 2.0)


func _select(id: String) -> void:
	selected = id
	refresh()


func _pick_slot(i: int) -> void:
	slot = i
	var nat: World.Nation = world.nations[nid]
	# касание занятого слота показывает его технологию
	if i < nat.research.size() and nat.research[i] != "":
		var t := Tech.get_tech(nat.research[i])
		if not t.is_empty():
			selected = t["id"]
			if t["cat"] != cat:
				cat = t["cat"]
				_rebuild()
				return
	refresh()


func _update_detail() -> void:
	var nat: World.Nation = world.nations[nid]
	if selected == "":
		detail.text = "Коснитесь технологии, чтобы увидеть подробности. Исследование идёт в каждом слоте; технология раньше своего года изучается дольше (+%d%% срока за год опережения)." % roundi(Tech.AHEAD_PENALTY * 100.0)
		start_btn.disabled = true
		start_btn.text = "Исследовать"
		return
	var t := Tech.get_tech(selected)
	var st := _state(nat, t)
	var txt := "%s (%d г.) — %s\n%s" % [t["name"], t["year"], t["desc"], Tech.effect_text(t)]
	match st:
		"done":
			txt += "\n⟶ изучено"
		"lock":
			txt += "\n⟶ требуется «%s»" % Tech.tech_name(t["req"])
		_:
			var m := Tech.ahead_mult(world, t)
			txt += "\nСрок: %d дн." % Tech.days_left(world, nat, selected)
			if m > 1.01:
				txt += " (опережение времени: сейчас ×%.1f)" % m
			elif float(nat.research_progress.get(selected, 0.0)) > 0.0 and st != "work":
				txt += " (часть работы уже сделана)"
	detail.text = txt
	var busy: bool = slot < nat.research.size() and nat.research[slot] != ""
	start_btn.text = "Заменить в слоте %d" % (slot + 1) if busy else "Исследовать"
	start_btn.disabled = st == "done" or st == "lock" or st == "work"


func _start() -> void:
	var nat: World.Nation = world.nations[nid]
	if Tech.start(nat, slot, selected):
		game.hud.toast("Исследование: «%s»" % Tech.tech_name(selected))
		game.hud.refresh_top()   # снять значок на корешке сразу, не дожидаясь дня
		var fs := Tech.free_slot(nat)
		if fs >= 0:
			slot = fs
	refresh()
