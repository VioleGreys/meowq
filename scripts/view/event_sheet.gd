class_name EventSheet
extends Control
## Окно события «один в один» с утверждённым макетом: состаренный планшет с
## тенью, помятый лист под зажимом с наклоном 1,2° и своей тенью, шапка
## телеграммы, штамп «СЕКРЕТНО», фото в белой рамке на скрепке, текст в обтекании
## фото, карточки вариантов с квадратиком и звездой исторического выбора.
##
## Координаты и размеры — в пикселях экрана 1920×1080, как в макете
## (tools/build_ui.py: build_event); узел масштабируется 720/1080 под единицы
## интерфейса, поэтому на любом экране пропорции те же.

const DESIGN_H := 1080.0
const BOARD := Vector2(672, 990)       # планшет (ev_board.png — с полями 48 под тень)
const PAD := 48.0
const BOARD_TOP := 86.0                 # от верха экрана, как в макете
const BOARD_CX := 965.0 - 960.0         # центр планшета правее середины экрана на 5 пикс.
const SHEET := Vector2(602, 840)
const SHEET_CENTER := Vector2(340, 530)
const SHEET_ROT := 1.2                  # по часовой
const MARGIN_X := 48.0
const TEXT_W := 506.0                   # ширина текста на листе (602 − 96)
const BESIDE_X := 250.0                 # текст рядом с фото
const BESIDE_W := 302.0
const PHOTO_BOTTOM := 430.0             # ниже фото текст идёт на всю ширину
const LINE_H := 29.0

const INK := Color8(38, 30, 22)
const INK_SOFT := Color8(78, 64, 48)

var game
var world: World
var sheet: Control
var _content: Control
var _buttons: Array = []
var _event_id := ""
var _info := false   # событие уже применено: лист только для прочтения


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	size = BOARD
	var board := _tex_rect("ev_board.png", Vector2(-PAD, -PAD), BOARD + Vector2(PAD, PAD) * 2.0)
	board.mouse_filter = Control.MOUSE_FILTER_STOP   # клики по планшету не уходят на карту
	add_child(board)
	sheet = Control.new()
	sheet.size = SHEET
	sheet.pivot_offset = SHEET * 0.5
	sheet.position = SHEET_CENTER - SHEET * 0.5
	sheet.rotation_degrees = SHEET_ROT
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sheet)
	sheet.add_child(_tex_rect("ev_sheet_shadow.png", Vector2(-24 + 5, -24 + 7), SHEET + Vector2(48, 48)))
	sheet.add_child(_tex_rect("ev_sheet.png", Vector2.ZERO, SHEET))
	_content = Control.new()
	_content.size = SHEET
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.add_child(_content)
	add_child(_tex_rect("ev_clip.png", Vector2(-PAD, -PAD), BOARD + Vector2(PAD, PAD) * 2.0))
	get_viewport().size_changed.connect(_place)
	_place()


## Размер и место на экране: масштаб 720/1080, планшет по центру (как в макете).
func _place() -> void:
	var view := get_viewport_rect().size
	var k := 720.0 / DESIGN_H
	scale = Vector2(k, k)
	position = Vector2(view.x * 0.5 + (BOARD_CX - BOARD.x * 0.5) * k, BOARD_TOP * k)


func _tex_rect(name: String, pos: Vector2, sz: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = UiStyle.ui_tex(name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.position = pos
	r.size = sz
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Надпись в точке (x, y) — как ImageDraw.text в макете (верх = линия асцендера).
func _text(parent: Control, pos: Vector2, text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("line_spacing", 0)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## Повёрнутый элемент: в макете картинка поворачивалась вокруг центра с
## расширением холста и ставилась левым верхним углом в (x, y).
func _rotated(c: Control, top_left: Vector2, sz: Vector2, deg: float) -> void:
	var a := deg_to_rad(absf(deg))
	var ew := sz.x * cos(a) + sz.y * sin(a)
	var eh := sz.x * sin(a) + sz.y * cos(a)
	c.size = sz
	c.pivot_offset = sz * 0.5
	c.position = top_left + Vector2(ew, eh) * 0.5 - sz * 0.5
	c.rotation_degrees = deg


## Перенос строк по словам, как text_block макета (жадно по ширине).
func _wrap(words: Array, font: Font, size: int, width: float) -> Array:
	var lines: Array = []
	var line := ""
	for w in words:
		var t: String = (line + " " + w).strip_edges()
		if font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width and line != "":
			lines.append(line)
			line = w
		else:
			line = t
	if line != "":
		lines.append(line)
	return lines


func show_event(g, w: World, id: String, info := false) -> void:
	game = g
	world = w
	_event_id = id
	_info = info
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_buttons.clear()
	var ev: Dictionary = w.event_defs.get(id, {})
	var mono := UiStyle.mono_font()
	var mono_b := UiStyle.mono_bold()
	var serif := UiStyle.serif_font()
	var osw := UiStyle._font("res://assets/fonts/Oswald.ttf")
	# шапка, заголовок, черта
	var since: int = int(w.pending_since.get(id, w.day))
	_text(_content, Vector2(48, 70), "ТЕЛЕГРАММА · %s" % w.date_short(since), mono_b, 18, INK_SOFT)
	var title := String(ev.get("title", id)).to_upper()
	var ts := 38
	while ts > 24 and osw.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, ts).x > TEXT_W:
		ts -= 1
	_text(_content, Vector2(48, 100), title, osw, ts, INK)
	var rule := ColorRect.new()
	rule.color = INK_SOFT
	rule.position = Vector2(48, 151)
	rule.size = Vector2(TEXT_W, 2)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(rule)
	# фото: картинка события, иначе лидер страны из поля photo, иначе адресата
	var art := UiStyle.event_art(id)
	if art == null and ev.has("photo"):
		art = UiStyle.portrait(String(ev["photo"]))
	if art == null and ev.has("target"):
		art = UiStyle.portrait(String(ev["target"]))
	if art != null:
		var frame := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color8(247, 240, 225)
		frame.add_theme_stylebox_override("panel", sb)
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ph := TextureRect.new()
		ph.texture = art
		ph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ph.stretch_mode = TextureRect.STRETCH_SCALE
		ph.position = Vector2(8, 8)
		ph.size = Vector2(170, 226)
		ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(ph)
		_content.add_child(frame)
		_rotated(frame, Vector2(44, 172), Vector2(186, 242), 2.0)
		var clip := _tex_rect("ev_paperclip.png", Vector2.ZERO, Vector2(65, 96))
		_content.add_child(clip)
		_rotated(clip, Vector2(56, 146), Vector2(65, 96), -14.0)
	# текст: рядом с фото, затем (и после пустой строки) — ниже фото на всю ширину
	var y := 176.0
	var beside := art != null
	var paras: PackedStringArray = String(ev.get("text", "")).split("\n\n")
	for pi in paras.size():
		var words: Array = Array(paras[pi].strip_edges().split(" ", false))
		if pi > 0 and beside:
			beside = false
			y = maxf(y, PHOTO_BOTTOM)
		while not words.is_empty():
			var x := BESIDE_X if beside else MARGIN_X
			var width := BESIDE_W if beside else TEXT_W
			var line := _wrap(words, serif, 20, width)[0] as String
			_text(_content, Vector2(x, y), line, serif, 20, INK)
			words = words.slice(line.split(" ", false).size())
			y += LINE_H
			if beside and y + LINE_H > PHOTO_BOTTOM:
				beside = false
				y = maxf(y, PHOTO_BOTTOM)
	if art != null:
		y = maxf(y, PHOTO_BOTTOM)   # варианты — всегда ниже фото
	# пометка исторического выбора и варианты
	var opts: Array = ev.get("options", [])
	if info and not opts.is_empty():
		# показываем только применённый вариант; нажатие закрывает лист
		opts = [opts[clampi(int(w.info_option.get(id, 0)), 0, opts.size() - 1)]]
	var best := 0
	for i in opts.size():
		if float(opts[i].get("ai", 0)) > float(opts[best].get("ai", 0)):
			best = i
	if opts.size() > 1:
		_content.add_child(_tex_rect("ev_star18.png", Vector2(48, y + 8), Vector2(18, 22)))
		_text(_content, Vector2(72, y + 8), "— так поступили в истории", mono, 16, INK_SOFT)
	if not info and History.event_has_choice(ev):
		# срок ответа: без выбора вариант назначится сам
		var due := "ответ до %s" % w.date_short(History.event_deadline(w, id))
		var dw: float = mono_b.get_string_size(due, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		_text(_content, Vector2(554.0 - dw, y + 8), due, mono_b, 16, UiStyle.RED_INK)
	var extra := 0.0   # длинные описания эффектов в несколько строк сдвигают следующие варианты
	for i in opts.size():
		var o: Dictionary = opts[i]
		var by := y + 44.0 + 88.0 * i + extra
		var b := TextureButton.new()
		b.texture_normal = UiStyle.ui_tex("ev_card.png")
		b.texture_hover = UiStyle.ui_tex("ev_card_hover.png")
		b.texture_pressed = UiStyle.ui_tex("ev_card_pressed.png")
		b.position = Vector2(48, by)
		b.size = Vector2(514, 58)
		var k := i
		b.pressed.connect(func(): _choose(k), CONNECT_DEFERRED)
		_content.add_child(b)
		_buttons.append(b)
		_text(b, Vector2(46, 25 - 20 * 0.7), String(o.get("name", "?")), mono_b, 20, INK)
		if i == best and opts.size() > 1:
			b.add_child(_tex_rect("ev_star26.png", Vector2(506 - 38, 25 - 16), Vector2(25, 32)))
		var desc := String(o.get("desc", ""))
		if desc == "":
			desc = History.effects_text(w, o.get("effects", [])).trim_prefix("Эффекты:").strip_edges()
			if desc != "":
				desc = desc[0].to_upper() + desc.substr(1)
		elif not info:
			# шансы бросков варианта (снимок условий на день фокуса)
			for ef in o.get("effects", []):
				if ef.get("t", "") == "roll":
					desc += ". %s — шанс %d %%" % [ef.get("name", "Бросок"), History.roll_pct(w, ef, -1, History.event_ctx(w, id))]
		if desc != "":
			var dl := _wrap(Array(desc.split(" ", false)), mono, 15, TEXT_W - 44.0)
			for j in dl.size():
				_text(_content, Vector2(92, by + 56 + 20.0 * j), dl[j], mono, 15, INK_SOFT)
			extra += 20.0 * (dl.size() - 1)
	# штамп поверх листа
	var st := _tex_rect("ev_stamp_secret.png", Vector2.ZERO, Vector2(220, 74))
	_content.add_child(st)
	_rotated(st, Vector2(SHEET.x - 250, 30), Vector2(220, 74), 9.0)


func _choose(k: int) -> void:
	if game == null:
		return
	for b in _buttons:
		b.disabled = true
	game.world_lock()
	if _info:
		game.dismiss_info_event()
	else:
		game.resolve_event(k)
	game.world_unlock()


## Появление: планшет въезжает снизу.
func animate_in() -> void:
	_place()
	var y := position.y
	position.y = y + 120.0
	modulate.a = 0.0
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "position:y", y, 0.32)
	tw.parallel().tween_property(self, "modulate:a", 1.0, 0.2)
