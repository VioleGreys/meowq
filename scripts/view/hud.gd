class_name Hud
extends CanvasLayer
## Интерфейс, рассчитанный на пальцы: крупные кнопки, нижняя панель
## информации, всплывающие окна армии / науки / стройки / дипломатии.

var game  # main.gd
var gen_info := ""

var root: Control
var top_bar: Control
var swatch: Flag
var nation_label: Label
var date_label: Label
var res_label: Label
var speed_buttons: Array = []
var side: Control
var info_panel: Control
var info_actions: HFlowContainer
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
var tech_view: TechView
var event_sheet: EventSheet


# Звук нажатия: все кнопки интерфейса (и созданные позже) щёлкают сами —
# подключаемся к каждой новой кнопке в дереве.
var _click: AudioStreamPlayer
var _toggle_snd: AudioStreamPlayer


func _setup_sounds() -> void:
	_click = AudioStreamPlayer.new()
	_click.stream = load("res://assets/sounds/click.wav")
	_click.volume_db = -8.0
	add_child(_click)
	_toggle_snd = AudioStreamPlayer.new()
	_toggle_snd.stream = load("res://assets/sounds/toggle.wav")
	_toggle_snd.volume_db = -8.0
	add_child(_toggle_snd)
	get_tree().node_added.connect(_hook_button)


func _hook_button(n: Node) -> void:
	if n is BaseButton and not n.has_meta("snd"):
		n.set_meta("snd", true)
		n.pressed.connect(_play_click.bind(n))


func _play_click(b: BaseButton) -> void:
	if not Settings.ui_sound():
		return
	var p := _toggle_snd if b is CheckButton else _click
	if p != null and p.stream != null:
		p.play()


func _ready() -> void:
	_setup_sounds()
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
	event_sheet = EventSheet.new()
	root.add_child(event_sheet)
	event_sheet.hide()
	focus_view = FocusView.new()
	root.add_child(focus_view)
	focus_view.hide()
	tech_view = TechView.new()
	root.add_child(tech_view)
	tech_view.hide()
	toast_label = Label.new()
	# уведомления — справа под верхней полосой, не поверх окон и планшета
	toast_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	toast_label.position = Vector2(-620, 60)
	toast_label.size = Vector2(600, 40)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toast_label.add_theme_color_override("font_color", UiStyle.CREAM)
	toast_label.add_theme_color_override("font_outline_color", Color.BLACK)
	toast_label.add_theme_constant_override("outline_size", 6)
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_label)


func _make_theme() -> Theme:
	return UiStyle.make_theme()


func _button(text: String, cb: Callable, min_size := Vector2(0, 56)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	# действия игрока меняют мир — через очередь game.act (на границе дня)
	# отложенно (в конце кадра): действие часто пересобирает окно и удаляет саму
	# кнопку — посреди обработки нажатия это давало ошибки «!is_inside_tree()»
	b.pressed.connect(func():
		if game != null:
			game.act(cb)   # конвейер ввода: не ждём конца игрового дня
		else:
			cb.call(), CONNECT_DEFERRED)
	return b


# --- Построение --------------------------------------------------------------

## Верхняя полоса «один в один» с макетом: координаты — в пикселях экрана
## 1920×1080, узел масштабируется 720/1080 (UI_K). Кожа со строчкой, флаг на
## бумажной бирке, ресурсы на бумажной ленте, дата на карточке, бирки скорости.
const UI_K := 720.0 / 1080.0
const TB_H := 78.0
const CREAM_M := Color8(238, 228, 205)
const INK_M := Color8(38, 30, 22)
var _tb_bg: TextureRect
var _tb_res: Control
var _tb_date: Control
var _tb_tags: Array = []
var _tb_key := ""


func _build_top_bar() -> void:
	top_bar = Control.new()
	top_bar.scale = Vector2(UI_K, UI_K)
	top_bar.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top_bar)
	_tb_bg = TextureRect.new()
	_tb_bg.texture = UiStyle.ui_tex("tb_leather.jpg")
	_tb_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tb_bg.stretch_mode = TextureRect.STRETCH_TILE
	_tb_bg.mouse_filter = Control.MOUSE_FILTER_STOP   # клики по полосе не уходят на карту
	top_bar.add_child(_tb_bg)
	var flag_tag := _tb_paper(Vector2(14, 12), Vector2(102, 54), 4, Vector2(3, 4), 4.0, 120)
	swatch = Flag.make({}, Vector2(87, 39))
	swatch.position = Vector2(8, 8)
	swatch.size = Vector2(87, 39)
	flag_tag.add_child(swatch)
	nation_label = _tb_label(UiStyle._font("res://assets/fonts/Oswald.ttf"), 44, CREAM_M)
	nation_label.position = Vector2(132, 4)
	top_bar.add_child(nation_label)
	_tb_res = _tb_paper(Vector2.ZERO, Vector2(100, 36), 2, Vector2(2, 3), 3.0, 110)
	res_label = _tb_label(UiStyle.mono_font(), 19, INK_M)
	res_label.position = Vector2(17, 6)
	res_label.clip_text = true
	_tb_res.add_child(res_label)
	_tb_date = _tb_paper(Vector2.ZERO, Vector2(100, 48), 3, Vector2(3, 4), 4.0, 120)
	date_label = _tb_label(UiStyle.mono_bold(), 22, INK_M)
	date_label.position = Vector2(20, 10)
	_tb_date.add_child(date_label)
	var labels := ["II", "1", "2", "3", "4", "5"]
	for i in labels.size():
		var b := TextureButton.new()
		b.texture_normal = UiStyle.ui_tex("tb_tag.png")
		b.texture_pressed = UiStyle.ui_tex("tb_tag_on.png")
		b.texture_hover = UiStyle.ui_tex("tb_tag.png")
		b.toggle_mode = true
		b.size = Vector2(60, 56)
		var sp := i
		b.pressed.connect(func():
			game.set_speed(sp)
			refresh_top(), CONNECT_DEFERRED)
		var l := _tb_label(UiStyle._font("res://assets/fonts/Oswald.ttf"), 28, INK_M)
		l.text = labels[i]
		var tw: float = l.get_theme_font("font").get_string_size(labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		l.position = Vector2(26 - tw * 0.5, 4)
		b.add_child(l)
		top_bar.add_child(b)
		speed_buttons.append(b)
		_tb_tags.append(b)
	get_viewport().size_changed.connect(_layout_top)
	_layout_top()


## Бумажная карточка с тенью (как shadow + paper в макете).
func _tb_paper(pos: Vector2, sz: Vector2, radius: int, off: Vector2, blur: float, alpha: int) -> Control:
	var c := Control.new()
	c.position = pos
	c.size = sz
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(214, 200, 168)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color8(0, 0, 0, alpha)
	sb.shadow_size = int(blur * 1.6)
	sb.shadow_offset = off
	sb.anti_aliasing = true
	sh.add_theme_stylebox_override("panel", sb)
	sh.set_anchors_preset(Control.PRESET_FULL_RECT)
	sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(sh)
	var paper := TextureRect.new()
	var at := AtlasTexture.new()
	at.atlas = UiStyle.ui_tex("tb_paper.jpg")
	at.region = Rect2(Vector2.ZERO, sz)
	paper.texture = at
	paper.set_meta("atlas", at)
	paper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	paper.stretch_mode = TextureRect.STRETCH_SCALE
	paper.set_anchors_preset(Control.PRESET_FULL_RECT)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(paper)
	c.set_meta("paper", paper)
	top_bar.add_child(c)
	return c


func _tb_resize(c: Control, pos: Vector2, sz: Vector2) -> void:
	c.position = pos
	c.size = sz
	var at: AtlasTexture = (c.get_meta("paper") as TextureRect).get_meta("atlas")
	at.region = Rect2(Vector2.ZERO, sz)


func _tb_label(font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Раскладка полосы по ширине экрана (как top_bar макета).
func _layout_top() -> void:
	if top_bar == null:
		return
	var W := root.get_viewport_rect().size.x / UI_K
	_tb_bg.size = Vector2(W, TB_H)
	var osw: Font = nation_label.get_theme_font("font")
	var name_w := osw.get_string_size(nation_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x
	var x0 := W - 20.0 - 6.0 * 62.0
	for i in _tb_tags.size():
		(_tb_tags[i] as Control).position = Vector2(x0 + i * 62.0, 14)
	var df: Font = date_label.get_theme_font("font")
	var dw := df.get_string_size(date_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 40.0
	_tb_resize(_tb_date, Vector2(x0 - dw - 24.0, 14), Vector2(dw, 48))
	var rx := 132.0 + name_w + 30.0
	var rf: Font = res_label.get_theme_font("font")
	var avail := x0 - dw - 24.0 - 16.0 - rx
	# длинная строка (запасы + политика): шрифт сжимается, а не обрезается
	var fs := 19
	while fs > 13 and rf.get_string_size(res_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 34.0 > avail:
		fs -= 1
	res_label.add_theme_font_size_override("font_size", fs)
	res_label.position = Vector2(17, 6 + (19 - fs) * 0.5)
	var rw := rf.get_string_size(res_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 34.0
	rw = minf(rw, avail)
	_tb_res.visible = rw > 80.0
	_tb_resize(_tb_res, Vector2(rx, 20), Vector2(maxf(rw, 1.0), 36))
	res_label.size = Vector2(maxf(rw - 34.0, 1.0), 26)


# Стопка папок слева «один в один» с макетом: корешки 470×84 (в пикселях экрана
# 1920×1080, узел масштабирован UI_K), шаг 92, наклон по часовой ~6°, видна
# правая часть с наклейкой. Наведение — папка чуть выезжает, открытая —
# выдвинута и выпрямлена (как stack() макета с out = 1).
const SPINE := Vector2(470, 84)
const SPINE_Y0 := 96.0
const SPINE_STEP := 92.0
var spines: Array = []                  # [TextureButton, id, номер, тень, выдвиг 0..1]
var _badges := {}                        # id корешка -> [Control, Label]: значок «нужно решение»
var _side_active := ""


func _build_side() -> void:
	side = Control.new()
	side.scale = Vector2(UI_K, UI_K)
	side.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(side)
	var items := [
		["focus", func():
			close_popup()
			tech_view.hide()
			focus_view.open(game, game.world, game.player())],
		["army", func(): open_tab("army")],
		["navy", func(): open_tab("navy")],
		["production", func(): open_tab("production")],
		["research", func(): open_tab("research")],
		["build", func(): open_tab("build")],
		["diplomacy", func(): open_tab("diplomacy")],
		["all", func(): game.select_all()],
		["mapmode", _cycle_map_mode],
		["menu", func(): open_tab("menu")],
	]
	for i in items.size():
		var id: String = items[i][0]
		var cb: Callable = items[i][1]
		var shd := TextureRect.new()
		shd.texture = UiStyle.ui_tex("spine_shadow.png")
		shd.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shd.stretch_mode = TextureRect.STRETCH_SCALE
		shd.size = SPINE + Vector2(48, 48)
		shd.pivot_offset = shd.size * 0.5
		shd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		side.add_child(shd)
		var tb := TextureButton.new()
		tb.texture_normal = UiStyle.ui_tex("spine_%s.png" % id)
		tb.ignore_texture_size = true
		tb.stretch_mode = TextureButton.STRETCH_SCALE
		tb.size = SPINE
		tb.pivot_offset = SPINE * 0.5
		tb.pressed.connect(func(): cb.call(), CONNECT_DEFERRED)
		side.add_child(tb)
		if id == "research" or id == "focus":
			_badges[id] = _make_badge(tb)
		var entry := [tb, id, i, shd, 0.0]
		spines.append(entry)
		tb.mouse_entered.connect(func(): _spine_slide(entry, 0.25))
		tb.mouse_exited.connect(func(): _spine_slide(entry, 0.0))
		_spine_place(entry, 0.0)


## Положение корешка при выдвиге o (0..1) — формулы stack() макета: угол
## −6 + 5·o + (i mod 3 − 1)·1,1 (в PIL против часовой), левый верхний угол
## повёрнутого холста x = −470 + 250 + 40 + 120·o + (i mod 2)·8.
func _spine_place(entry: Array, o: float) -> void:
	entry[4] = o
	var tb: TextureButton = entry[0]
	var shd: TextureRect = entry[3]
	var i: int = entry[2]
	var ang := -6.0 + 5.0 * o + float(i % 3 - 1) * 1.1
	var a := deg_to_rad(absf(ang))
	var ew := SPINE.x * cos(a) + SPINE.y * sin(a)
	var eh := SPINE.x * sin(a) + SPINE.y * cos(a)
	var tl := Vector2(-SPINE.x + 250.0 + 40.0 + 120.0 * o + float(i % 2) * 8.0, SPINE_Y0 + i * SPINE_STEP)
	var center := tl + Vector2(ew, eh) * 0.5
	tb.position = center - SPINE * 0.5
	tb.rotation_degrees = -ang
	shd.position = center - shd.size * 0.5 + Vector2(6, 8)
	shd.rotation_degrees = -ang
	shd.modulate.a = (0.5 + 0.2 * o) / 0.5


## Значок на корешке: красный кружок с числом (свободные слоты науки, фокус не
## выбран). Дочерний узел кнопки — поворачивается и выезжает вместе с папкой.
func _make_badge(tb: TextureButton) -> Array:
	var dot := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiStyle.RED_INK
	sb.border_color = UiStyle.CREAM
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(22)
	sb.anti_aliasing = true
	dot.add_theme_stylebox_override("panel", sb)
	dot.size = Vector2(44, 44)
	dot.position = Vector2(SPINE.x - 40, -14)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", UiStyle.title_font(700))
	l.add_theme_font_size_override("font_size", 28)
	l.add_theme_color_override("font_color", UiStyle.CREAM)
	dot.add_child(l)
	tb.add_child(dot)
	dot.hide()
	return [dot, l]


func _show_badges(alerts: Dictionary) -> void:
	for id in _badges:
		var n: int = int(alerts.get(id, 0))
		var b: Array = _badges[id]
		b[0].visible = n > 0
		b[1].text = str(n) if id == "research" else "!"


## Папка выезжает/возвращается (плавно, с замедлением).
func _spine_slide(entry: Array, hover: float) -> void:
	var target := 1.0 if entry[1] == _side_active else hover
	var tb: TextureButton = entry[0]
	if entry[1] == _side_active:
		# открытая папка — поверх соседних, как в макете
		side.move_child(entry[3], side.get_child_count() - 1)
		side.move_child(tb, side.get_child_count() - 1)
	var tw := tb.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(v: float): _spine_place(entry, v), float(entry[4]), target, 0.22)


func _set_side_active(id: String) -> void:
	_side_active = id
	for sp in spines:
		_spine_slide(sp, 0.0)


# Нижняя карточка «один в один» с макетом (index_card): бумага, красная черта
# под заголовком, синяя линовка через 30 пикс.; заголовок — машинопись 24,
# строки — 18 на линейках, кнопки — бумажные карточки с квадратиком (текущий
# приказ — с галочкой). Пиксели экрана 1920×1080, узел масштабирован UI_K.
var info_title: Label
var info_bg: NinePatchRect
var info_body: Control
var _info_rows := PackedStringArray()


func _build_info() -> void:
	info_panel = Control.new()
	info_panel.scale = Vector2(UI_K, UI_K)
	info_panel.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	info_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(info_panel)
	var sh := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color8(214, 200, 168)
	sb.set_corner_radius_all(4)
	sb.shadow_color = Color8(0, 0, 0, 140)
	sb.shadow_size = 13
	sb.shadow_offset = Vector2(5, 6)
	sb.anti_aliasing = true
	sh.add_theme_stylebox_override("panel", sb)
	sh.set_anchors_preset(Control.PRESET_FULL_RECT)
	sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(sh)
	info_bg = NinePatchRect.new()
	info_bg.texture = UiStyle.ui_tex("ic_card.png")
	info_bg.patch_margin_left = 10
	info_bg.patch_margin_right = 10
	info_bg.patch_margin_top = 82
	info_bg.patch_margin_bottom = 28
	info_bg.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT
	info_bg.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE
	info_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	info_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(info_bg)
	info_title = _tb_label(UiStyle.mono_bold(), 24, INK_M)
	info_title.position = Vector2(18, 10)
	info_panel.add_child(info_title)
	info_body = Control.new()
	info_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(info_body)
	info_actions = HFlowContainer.new()
	info_actions.add_theme_constant_override("h_separation", 12)
	info_actions.add_theme_constant_override("v_separation", 12)
	info_actions.theme = _info_theme()
	info_panel.add_child(info_actions)
	info_panel.hide()
	get_viewport().size_changed.connect(_layout_info)


## Кнопки карточки: бумага с квадратиком, машинопись 20; недоступная (= текущий
## выбор) — с красной галочкой.
func _info_theme() -> Theme:
	var t := Theme.new()
	var normal := UiStyle.sbox("ic_button.png", 8, 8)
	normal.texture_margin_left = 40
	normal.content_margin_left = 46
	normal.content_margin_right = 18
	var ticked := UiStyle.sbox("ic_button_pressed.png", 8, 8)
	ticked.texture_margin_left = 40
	ticked.content_margin_left = 46
	ticked.content_margin_right = 18
	var hover := normal.duplicate()
	hover.modulate_color = Color(1.04, 1.03, 1.0)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", ticked)
	t.set_stylebox("hover_pressed", "Button", ticked)
	t.set_stylebox("disabled", "Button", ticked)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_font("font", "Button", UiStyle.mono_bold())
	t.set_font_size("font_size", "Button", 20)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_disabled_color"]:
		t.set_color(c, "Button", INK_M)
	return t


## Текст карточки: первая строка — заголовок, остальные — на линейках.
func _info_text(s: String) -> void:
	var lines := s.split("\n")
	info_title.text = lines[0].to_upper()
	_info_rows = lines.slice(1)
	_layout_info.call_deferred()


func _layout_info() -> void:
	if info_panel == null:
		return
	var view := root.get_viewport_rect().size / UI_K
	var mono := UiStyle.mono_font()
	var bold := UiStyle.mono_bold()
	# ширина: как в макете 540, шире — если не влезают заголовок или кнопки
	var need := bold.get_string_size(info_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x + 36.0
	var widths: Array = []
	for b in info_actions.get_children():
		var bt := b as Button
		bt.custom_minimum_size = Vector2(48, 48)
		widths.append(bold.get_string_size(bt.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20).x + 64.0)
	var btn_w := 0.0
	for bw in widths:
		btn_w += float(bw) + 12.0
	# не шире 720 и не заходит под планшет события — лишние кнопки во второй ряд
	var cap := minf(720.0, view.x - 380.0)
	if event_sheet != null and event_sheet.visible:
		cap = minf(cap, view.x * 0.5 - 341.0 - 40.0)
	var W := clampf(maxf(maxf(540.0, need), btn_w + 24.0), 540.0, maxf(540.0, cap))
	# строки (с переносом по словам), по линейкам через 30
	for c in info_body.get_children():
		info_body.remove_child(c)
		c.queue_free()
	var rows: Array = []
	for line in _info_rows:
		var words: Array = Array(String(line).split(" ", false))
		var cur := ""
		for wd in words:
			var t: String = (cur + " " + wd).strip_edges()
			if mono.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x > W - 36.0 and cur != "":
				rows.append(cur)
				cur = wd
			else:
				cur = t
		if cur != "":
			rows.append(cur)
	for i in rows.size():
		var l := _tb_label(mono, 18, Color8(78, 64, 48))
		l.text = rows[i]
		l.position = Vector2(18, 58 + 30 * i)
		info_body.add_child(l)
	var btop := 166.0 + 30.0 * maxi(0, rows.size() - 3)
	info_actions.position = Vector2(18, btop)
	info_actions.size = Vector2(W - 36.0, 48)
	var rows_b := 1
	var x := 0.0
	for bw in widths:
		if x > 0.0 and x + float(bw) > W - 36.0:
			rows_b += 1
			x = 0.0
		x += float(bw) + 12.0
	var flow_h := 48.0 * rows_b + 12.0 * (rows_b - 1)
	var H := btop + flow_h + 16.0 if info_actions.get_child_count() > 0 else 230.0 + 30.0 * maxi(0, rows.size() - 3)
	info_panel.size = Vector2(W, H)
	info_panel.position = (view - Vector2(W + 20.0, H + 30.0)) * UI_K


static func _plural(n: int, one: String, few: String, many: String) -> String:
	var m10 := n % 10
	var m100 := n % 100
	if m10 == 1 and m100 != 11:
		return one
	if m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14):
		return few
	return many


# Окно — раскрытая папка-«дело»: левая створка (наклейка дела, фото) и правая
# с листом, на котором содержимое. События — лист на планшете под зажимом.
var popup_board: NinePatchRect
var popup_close: Button
var popup_rule: ColorRect
var cover_card: PanelContainer
var cover_rows: VBoxContainer
var popup_sheet: TextureRect
var popup_sheet_box: MarginContainer
var popup_content: MarginContainer
var popup_clip: NinePatchRect
var popup_cover: TextureRect
var cover_title: Label
var cover_sub: Label
var cover_photo: TextureRect
var cover_photo_holder: Control
var cover_box: MarginContainer
var cover_stamp: TextureRect

const TAB_NAMES := {"army": "Армия", "navy": "Флот и авиация", "production": "Производство",
	"research": "Наука", "build": "Стройка", "diplomacy": "Дипломатия", "settings": "Настройки",
	"nations": "Выбор страны", "nation": "Досье страны", "peace": "Мирный договор",
	"menu": "Меню", "save": "Сохранение", "load": "Загрузка"}
const TAB_NUM := {"army": 2, "navy": 3, "production": 4, "research": 5, "build": 6, "diplomacy": 7,
	"nation": 7, "settings": 10, "nations": 1, "peace": 7, "menu": 10, "save": 10, "load": 10}
# страницы папки «Меню» (корешок один — подсвечивается он)
const MENU_TABS := {"menu": true, "save": true, "load": true, "settings": true}


func _nine(tex: String, m: int) -> NinePatchRect:
	var n := NinePatchRect.new()
	n.texture = UiStyle.ui_tex(tex)
	n.patch_margin_left = m
	n.patch_margin_right = m
	n.patch_margin_top = m
	n.patch_margin_bottom = m
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return n


func _build_popup() -> void:
	popup = PanelContainer.new()
	popup.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	root.add_child(popup)
	popup_board = _nine("dossier_right.png", 40)
	popup.add_child(popup_board)
	popup_sheet_box = MarginContainer.new()
	popup_sheet_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup.add_child(popup_sheet_box)
	popup_sheet = TextureRect.new()
	popup_sheet.texture = UiStyle.ui_tex("sheet.png")
	popup_sheet.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	popup_sheet.stretch_mode = TextureRect.STRETCH_SCALE
	popup_sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	popup_sheet_box.add_child(popup_sheet)
	popup_content = MarginContainer.new()
	popup.add_child(popup_content)
	var v := VBoxContainer.new()
	popup_content.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	popup_title = Label.new()
	popup_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiStyle.title(popup_title, 26)
	popup_title.add_theme_color_override("font_color", UiStyle.INK)
	head.add_child(popup_title)
	popup_close = _button("✕", close_popup, Vector2(40, 40))
	popup_close.flat = true
	popup_close.add_theme_font_size_override("font_size", 26)
	head.add_child(popup_close)
	popup_rule = ColorRect.new()
	popup_rule.color = Color(UiStyle.INK_SOFT, 0.6)
	popup_rule.custom_minimum_size = Vector2(0, 2)
	v.add_child(popup_rule)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	popup_body = VBoxContainer.new()
	popup_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	popup_body.add_theme_constant_override("separation", 6)
	scroll.add_child(popup_body)
	popup_clip = _nine("clipboard_clip.png", 1)
	popup.add_child(popup_clip)
	# разворот папки-«дела» целиком (как в макете): левая створка с наклейкой,
	# фото и анкетой, правая — под листом окна; лежит позади окна
	popup_cover = TextureRect.new()
	popup_cover.texture = UiStyle.ui_tex("dossier_spread.png")
	popup_cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	popup_cover.stretch_mode = TextureRect.STRETCH_SCALE
	root.add_child(popup_cover)
	root.move_child(popup_cover, popup.get_index())
	cover_box = MarginContainer.new()
	cover_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	popup_cover.add_child(cover_box)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	cover_box.add_child(cv)
	var lab := PanelContainer.new()
	lab.add_theme_stylebox_override("panel", UiStyle.sbox("dossier_label.png", 20, 12))
	lab.rotation_degrees = 1.0
	cv.add_child(lab)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 0)
	lab.add_child(lv)
	lv.add_child(_label("НАРОДНЫЙ КОМИССАРИАТ ИНОСТРАННЫХ ДЕЛ", 10, UiStyle.INK_SOFT, true))
	cover_title = _label("ДЕЛО № 07", 30, UiStyle.INK, true)
	cover_title.add_theme_font_override("font", UiStyle.title_font(600))
	lv.add_child(cover_title)
	cover_sub = _label("", 12, UiStyle.INK, true)
	lv.add_child(cover_sub)
	lv.add_child(_label("Начато 1936 г.   Хранить вечно", 11, UiStyle.RED_INK, true))
	# фото на скрепке и мятая анкета рядом
	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 10)
	cv.add_child(mid)
	cover_photo_holder = _clipped_photo(null, Vector2(118, 158))
	cover_photo = cover_photo_holder.get_child(0).get_child(0)
	mid.add_child(cover_photo_holder)
	cover_card = PanelContainer.new()
	cover_card.add_theme_stylebox_override("panel", UiStyle.sbox("sheet_crumpled.png", 30, 14))
	cover_card.rotation_degrees = 1.8
	cover_card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cover_card.size_flags_vertical = Control.SIZE_SHRINK_END
	mid.add_child(cover_card)
	cover_rows = VBoxContainer.new()
	cover_rows.add_theme_constant_override("separation", 4)
	cover_card.add_child(cover_rows)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cv.add_child(spacer)
	cover_stamp = TextureRect.new()
	cover_stamp.texture = UiStyle.ui_tex("stamp_top_secret.png")
	cover_stamp.custom_minimum_size = Vector2(190, 60)
	cover_stamp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover_stamp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover_stamp.rotation_degrees = -6.0
	cover_stamp.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	cv.add_child(cover_stamp)
	_layout_popup(false)
	popup.hide()
	popup_cover.hide()


## Раскладка окна: папка-«дело» справа (створка слева от неё) или планшет по
## центру (события).
func _layout_popup(clipboard: bool) -> void:
	var view := root.get_viewport_rect().size if root.is_inside_tree() else Vector2(1280, 720)
	if clipboard:
		popup.set_anchors_preset(Control.PRESET_CENTER_TOP)
		popup.anchor_bottom = 1.0
		var h := view.y - 84.0
		var w := minf(h * 665.0 / 980.0 * 1.05, view.x - 40.0)
		popup.offset_left = -w * 0.5
		popup.offset_right = w * 0.5
		popup.offset_top = 76
		popup.offset_bottom = -6
		popup_board.texture = UiStyle.ui_tex("clipboard.png")
		_set_margins(popup_sheet_box, 34, 34, int(h * 0.10), 26)
		_set_margins(popup_content, 50, 50, int(h * 0.10) + 52, 40)
		popup_sheet.texture = UiStyle.ui_tex("sheet_crumpled.png")
		popup_sheet.rotation_degrees = -1.0
		popup_clip.texture = UiStyle.ui_tex("clipboard_clip.png")
		popup_clip.show()
		popup_cover.hide()
	else:
		# разворот справа: ширина ~62% экрана, правая половина — окно с листом
		var sw := clampf(view.x * 0.62, 760.0, 1180.0)
		var top := 80.0
		popup_cover.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		popup_cover.offset_right = -10
		popup_cover.offset_left = -10 - sw
		popup_cover.offset_top = top
		popup_cover.offset_bottom = -8
		_set_margins(cover_box, 40, int(sw * 0.5) + 24, 28, 22)
		popup.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		popup.offset_left = -10 - sw * 0.5 + 8.0
		popup.offset_right = -10
		popup.offset_top = top
		popup.offset_bottom = -8
		popup_board.texture = null
		_set_margins(popup_sheet_box, 18, 30, 22, 22)
		_set_margins(popup_content, 42, 52, 40, 38)
		popup_sheet.texture = UiStyle.ui_tex("sheet.png")
		popup_sheet.rotation_degrees = -1.0
		popup_clip.hide()
	popup_sheet.pivot_offset = popup_sheet.size * 0.5


func _set_margins(m: MarginContainer, l: int, r: int, t: int, b: int) -> void:
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_bottom", b)


## Створка дела: номер, раздел, фото лидера (своей страны или страны из досье).
func _fill_cover() -> void:
	var w: World = game.world
	var num: int = TAB_NUM.get(popup_tab, 0)
	cover_title.text = "ДЕЛО № %02d" % num
	var sub: String = TAB_NAMES.get(popup_tab, "")
	var nid: int = game.player() if w != null else -1
	if popup_tab == "nation" and _card_nation >= 0:
		nid = _card_nation
	# без страны (окна из главного меню) — только номер дела и штамп
	var known: bool = w != null and nid >= 0 and nid < w.nations.size()
	cover_photo_holder.visible = known
	cover_card.visible = known
	if known:
		var n: World.Nation = w.nations[nid]
		sub = "%s · %s" % [sub, n.name]
		var pt := UiStyle.portrait(n.tag)
		cover_photo.texture = pt if pt != null else UiStyle.ui_tex("nophoto.png")
		cover_stamp.texture = UiStyle.ui_tex("stamp_threat.png") if popup_tab == "nation" and \
			w.nations[game.player()].at_war.has(nid) else UiStyle.ui_tex("stamp_top_secret.png")
		# анкета страны
		_clear(cover_rows)
		var rows := [["Глава", n.leader], ["Строй", w.ideology_names.get(n.ideology, n.ideology)],
			["Фракция", Diplomacy.faction_name(w, nid) if Diplomacy.faction_name(w, nid) != "" else "нет"],
			["Армия", "%d див." % n.division_count], ["Заводы", "%d / %d" % [n.civ, n.mil]]]
		for r in rows:
			var line := HBoxContainer.new()
			var k := _label(String(r[0]) + ":", 12, UiStyle.INK_SOFT, true)
			k.custom_minimum_size = Vector2(70, 0)
			k.autowrap_mode = TextServer.AUTOWRAP_OFF
			line.add_child(k)
			var vl := _label(String(r[1]), 12, UiStyle.INK, true)
			vl.add_theme_font_override("font", UiStyle.mono_bold())
			vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line.add_child(vl)
			cover_rows.add_child(line)
	cover_sub.text = sub


## Анимация открытия: створка раскрывается от сгиба, лист проявляется; планшет
## событий въезжает снизу.
func _animate_open(clipboard: bool) -> void:
	await get_tree().process_frame
	popup_sheet.pivot_offset = popup_sheet.size * 0.5
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if clipboard:
		var y := popup.position.y
		popup.position.y = y + 120.0
		popup.modulate.a = 0.0
		tw.tween_property(popup, "position:y", y, 0.32)
		tw.parallel().tween_property(popup, "modulate:a", 1.0, 0.2)
	else:
		popup.modulate.a = 0.0
		popup_cover.pivot_offset = Vector2(popup_cover.size.x * 0.5, popup_cover.size.y * 0.5)
		popup_cover.scale = Vector2(0.05, 1.0)
		tw.tween_property(popup, "modulate:a", 1.0, 0.18)
		tw.parallel().tween_property(popup_cover, "scale:x", 1.0, 0.32)


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
	perf_label.offset_left = 10
	perf_label.offset_right = -10
	perf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# на узком экране фазы переносятся вверх, главное (FPS, тик) — всегда в нижней строке
	perf_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	perf_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	perf_label.add_theme_font_size_override("font_size", 14)
	perf_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85, 0.7))
	perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	perf_label.visible = Settings.show_perf()
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


## Подпись. Окна — бумага, поэтому светлые цвета прежней тёмной темы
## переводятся в чернила (UiStyle.ink); raw — как есть (подписи поверх карты).
func _label(text: String, size := 20, color := Color(0.93, 0.9, 0.82), raw := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# в окнах-листах текст мельче (как в макете): 0.75 от прежних размеров
	l.add_theme_font_size_override("font_size", size if raw else maxi(10, int(round(size * 0.75))))
	l.add_theme_color_override("font_color", color if raw else UiStyle.ink(color))
	return l


# --- Экраны ------------------------------------------------------------------

func show_loading(text := "Загрузка мира…") -> void:
	top_bar.hide()
	side.hide()
	info_panel.hide()
	popup.hide()
	popup_cover.hide()
	log_box.hide()
	_clear(overlay_box)
	_overlay_center()
	overlay_box.add_child(_label(text, 28))
	overlay_box.add_child(_label("Карта, государства и армии 1936 года", 18))
	overlay.show()


func _overlay_center() -> void:
	overlay.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	overlay.grow_horizontal = Control.GROW_DIRECTION_BOTH
	overlay.grow_vertical = Control.GROW_DIRECTION_BOTH
	overlay.reset_size()


## Главное меню: лист поверх карты мира.
func show_menu() -> void:
	top_bar.hide()
	side.hide()
	info_panel.hide()
	popup.hide()
	popup_cover.hide()
	log_box.hide()
	_set_side_active("")
	_clear(overlay_box)
	_overlay_center()
	var head := _label("MEOWQ: ФРОНТЫ", 58, UiStyle.INK, true)
	head.add_theme_font_override("font", UiStyle.title_font(600, 2))
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.autowrap_mode = TextServer.AUTOWRAP_OFF
	overlay_box.add_child(head)
	var sub := _label("Глобальная стратегия · 1936–1945", 20, UiStyle.INK_SOFT, true)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_box.add_child(sub)
	var rule := ColorRect.new()
	rule.color = Color8(168, 32, 28)
	rule.custom_minimum_size = Vector2(0, 3)
	overlay_box.add_child(rule)
	var saves := SaveGame.list()
	if not saves.is_empty():
		var last: Dictionary = saves[0]
		var nm: String = last["name"]
		var cont := _button("Продолжить\n%s · %s" % [last.get("nation", "?"), last.get("date", "")],
			func(): game.load_game(nm), Vector2(0, 76))
		overlay_box.add_child(cont)
	overlay_box.add_child(_button("Новая игра", func(): game.new_game(), Vector2(0, 60)))
	var ld := _button("Загрузить игру", func(): open_tab("load"), Vector2(0, 60))
	ld.disabled = saves.is_empty()
	overlay_box.add_child(ld)
	overlay_box.add_child(_button("Настройки", func(): open_tab("settings"), Vector2(0, 60)))
	overlay_box.add_child(_button("Выход", func():
		game.get_tree().root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
		game.get_tree().quit(), Vector2(0, 60)))
	overlay_box.add_child(_label(gen_info, 14, Color(0.7, 0.7, 0.7)))
	overlay.show()


func show_select(nid: int) -> void:
	top_bar.hide()
	side.hide()
	info_panel.hide()
	popup.hide()
	popup_cover.hide()
	_clear(overlay_box)
	var w: World = game.world
	overlay.reset_size()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	overlay.offset_top -= 10
	overlay.offset_bottom -= 10
	overlay.grow_horizontal = Control.GROW_DIRECTION_BOTH
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
		var pt := UiStyle.portrait(n.tag)
		if pt != null:
			head.add_child(UiStyle.framed(pt, Vector2(72, 96)))
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
	var back := _button("‹ Главное меню", func(): game.to_menu(), Vector2(0, 44))
	back.add_theme_font_size_override("font_size", 16)
	overlay_box.add_child(back)
	overlay_box.add_child(_label(gen_info, 14, Color(0.7, 0.7, 0.7)))
	overlay.show()


func show_play() -> void:
	overlay.hide()
	popup.hide()
	popup_cover.hide()
	_set_side_active("")
	top_bar.show()
	side.show()
	log_box.show()
	_clear(log_box)
	refresh_top()
	on_tick()


func show_game_over(result: String) -> void:
	popup.hide()
	_clear(overlay_box)
	_overlay_center()
	if result == "victory":
		overlay_box.add_child(_label("Победа!", 36, Color(0.95, 0.85, 0.4)))
		overlay_box.add_child(_label("Все соперники капитулировали. %s" % game.world.date_string(), 20))
	else:
		overlay_box.add_child(_label("Капитуляция", 36, Color(0.9, 0.4, 0.35)))
		overlay_box.add_child(_label("Ваша страна пала. %s" % game.world.date_string(), 20))
	overlay_box.add_child(_button("Новая игра", func(): game.new_game(), Vector2(0, 64)))
	overlay_box.add_child(_button("Главное меню", func(): game.to_menu(), Vector2(0, 56)))
	overlay.show()


# --- Обновление --------------------------------------------------------------

## Снимок цифр верхней строки (читает мир — под замком или в потоке симуляции
## сразу после дня; конвейер экрана, main._publish).
static func top_snapshot(w: World, me: int, sim: Simulation) -> Dictionary:
	if w == null or me < 0:
		return {}
	var n: World.Nation = w.nations[me]
	# значки на корешках: свободные слоты науки, фокус не выбран (а выбрать есть что)
	var free := 0
	for id in n.research:
		if id == "":
			free += 1
	if n.research.size() < n.research_slots:
		free += n.research_slots - n.research.size()
	var focus_idle := 0
	if n.focus_current == "":
		for fd in History.tree_of(w, me):
			if History.focus_block(w, me, fd) == "":
				focus_idle = 1
				break
	return {"alerts": {"research": free, "focus": focus_idle}, "flag": n.flag, "name": n.name.to_upper(), "date": w.date_string(),
		"res": "Винт. %d  Ору. %d  Танки %d  Груз. %d  ПТО %d  Люди %dк  Див. %d  ПВ %d  Стаб. %d%%  Война %d%%" % [
			n.stock[0], n.stock[1], n.stock[2], n.stock[3], n.stock[4], n.manpower, n.division_count,
			int(n.pol_power), roundi(n.stability * 100.0), roundi(n.war_support * 100.0)],
		"phases": sim.phase_usec.duplicate() if sim != null else {}, "tick": sim.last_tick_usec if sim != null else 0}


var top_data := {}   # последний снимок верхней строки (main._publish или refresh_top)


func refresh_top() -> void:
	# мир доступен (под замком) — свежий снимок; иначе — опубликованный
	if game.world != null and game.player() >= 0:
		top_data = top_snapshot(game.world, game.player(), game.sim)
	show_top()


## Верхняя строка по снимку top_data — без обращения к миру (каждый кадр).
func show_top() -> void:
	var d := top_data
	if d.is_empty():
		return
	if swatch.spec != d["flag"]:
		swatch.spec = d["flag"]
	nation_label.text = d["name"]
	_show_badges(d.get("alerts", {}))
	date_label.text = d["date"]
	res_label.text = d["res"]
	var key := nation_label.text + "|" + date_label.text + "|" + res_label.text
	if key != _tb_key:
		_tb_key = key
		_layout_top()
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = game.speed == i
	var phases := ""
	var ph: Dictionary = d["phases"]
	for k in ph:
		phases += " %s %.1f" % [k, ph[k] / 1000.0]
	if OS.has_feature("mobile"):
		phases = ""   # на телефоне без фаз — они закрывали бы карту
	var gpu: Vector2 = game.map_view.gpu_ms()
	if gpu.x <= 0.0:
		gpu.x = game.map_view.last_cost_ms   # OpenGL ES: оценка по времени кадра
	Report.sample(Engine.get_frames_per_second(), int(d["tick"]) / 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, game.unit_layer.draw_usec / 1000.0,
		gpu.x, game.days_per_sec)
	phases += "\nкадр: логика %.1f · фишки %.1f · ГП карта %.1f (%d%%) · ГП экран %.1f мс · карта %d раз/с\nдень (макс. за с): панели %.1f · палитра %.1f · список %.1f · строка %.1f мс" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, game.unit_layer.draw_usec / 1000.0,
		gpu.x, int(game.map_view.res_scale * 100), gpu.y, _redraw_rate(), game.ui_prof[0] / 1000.0, game.ui_prof[1] / 1000.0,
		game.ui_prof[2] / 1000.0, game.ui_prof[3] / 1000.0]
	perf_label.text = "%s\n%d FPS · %s · ядер %d · %.1f дн/с · тик %.2f мс" % [phases.strip_edges(), Engine.get_frames_per_second(), "C++" if Native.available() else "GDScript", Parallel.thread_count(), game.days_per_sec, int(d["tick"]) / 1000.0]
	if _toast_t > 0.0:
		_toast_t -= get_process_delta_time()
		toast_label.modulate.a = clampf(_toast_t, 0.0, 1.0)


var _rd_last := 0
var _rd_time := 0
var _rd_rate := 0


## Сколько раз в секунду перерисовывается карта (для нижней строки).
func _redraw_rate() -> int:
	var now := Time.get_ticks_msec()
	if now - _rd_time >= 1000:
		_rd_rate = int((game.map_view.redraws - _rd_last) * 1000.0 / maxf(1.0, now - _rd_time))
		_rd_last = game.map_view.redraws
		_rd_time = now
	return _rd_rate


func on_tick() -> void:
	var w: World = game.world
	while not w.events.is_empty():
		var e: String = w.events.pop_front()
		var l := _label(e, 16, UiStyle.CREAM, true)
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
	if tech_view.visible:
		tech_view.refresh()
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
			_info_text(_province_text(_info_prov))


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
	var s := "%s\n%s (ширина фронта %d) · %s" % [w.p_name[p], World.TERRAIN_NAMES[w.p_terrain[p]], World.FRONT_WIDTH[w.p_terrain[p]], own.name]
	var fn := Diplomacy.faction_name(w, own.id)
	if fn != "":
		s += " («%s»)" % fn
	if ctrl != own:
		s += " (оккупирована: %s)" % ctrl.name
	if w.p_colony[p] == 1:
		s += " · колония"
	if p < w.p_hot.size() and (w.p_hot[p] > 0.0 or w.p_cold[p] > 0.0):
		var cl: Array = []
		if w.p_hot[p] > 0.0:
			cl.append("жара %d%%" % roundi(w.p_hot[p] * 100.0))
		if w.p_cold[p] > 0.0:
			cl.append("холод %d%%" % roundi(w.p_cold[p] * 100.0))
		s += "\nСуровый климат: %s — непривычные войска медленнее, слабее и теряют людей" % ", ".join(cl)
	s += "\nФабрики: %d гражд. / %d воен. · Население: %s · Резерв: %dк · Очки победы: %d" % [
		w.p_civ[p], w.p_mil[p], _fmt_pop(w.p_population[p]), w.p_manpower[p], w.p_vp[p]]
	var cl := Claims.claimants(w, p)
	if not cl.is_empty():
		var cn: Array = []
		for x in cl:
			cn.append(w.nations[x].name)
		s += "\nНациональная территория: " + ", ".join(cn)
	var ok := Occupation.key_of(w, p) if p < w.p_resist.size() else -1
	if ok >= 0 and w.p_resist[p] >= 0.0:
		s += "\nЗемли страны %s под властью: %s · сопротивление %d%% · принятие %d%% · отдача %d%%" % [
			w.nations[ok % 4096].name, w.nations[ok / 4096].name, roundi(w.p_resist[p]), roundi(w.p_comply[p]), roundi(w.p_yield[p] * 100.0)]
	var ri := w.res_prov.find(p)
	if ri >= 0:
		var rs: Array = []
		for r in Economy.RES_COUNT:
			var v: float = w.res_val[ri * Economy.RES_COUNT + r]
			if v >= 0.05:
				rs.append("%s %.1f" % [Economy.RES_NAMES[r].to_lower(), v])
		s += "\nРесурсы: " + ", ".join(rs)
	var counts := {}
	var widths := {}
	for d in w.divs_in(p):
		if d.alive:
			counts[d.owner] = int(counts.get(d.owner, 0)) + 1
			widths[d.owner] = float(widths.get(d.owner, 0.0)) + Military.template_width(w.templates[d.tpl])
	for k in counts:
		s += "\nДивизии %s: %d (ширина %d)" % [w.nations[k].name, counts[k], widths[k]]
	var me: int = game.player()
	if me >= 0:
		var sd := Supply.side(w, me)
		var nk := Supply.node_of(w, sd, p)
		if nk >= 0:
			var lvl := w.p_node_lvl[p] if p < w.p_node_lvl.size() else 0
			if not Supply.node_ok(w, sd, p):
				s += "\nУзел снабжения (захвачен): не работает, пока не присоединён к сети"
			elif w.node_prov[nk] == p:
				s += "\nУзел снабжения: ур. %d · подача %.1f · взято %d из %d" % [lvl, w.node_f[nk], roundi(w.node_used[nk]), roundi(w.node_f[nk] * Supply.BUDGET_K)]
			else:
				s += "\nУзел снабжения: ур. %d (район кормит более сильный источник)" % lvl
	return s


func _fmt_pop(k: int) -> String:
	return "%.1f млн" % (k / 1000.0) if k >= 1000 else "%d тыс." % k


func show_province(p: int) -> void:
	var w: World = game.world
	_info_prov = p
	_info_text(_province_text(p))
	_clear(info_actions)
	if w.p_land[p] == 1:
		var c := w.p_controller[p]
		var me: int = game.player()
		if c == me:
			var sd := Supply.side(w, me)
			if Supply.node_of(w, sd, p) >= 0:
				var n: World.Nation = w.nations[me]
				if not Supply.node_ok(w, sd, p):
					if not Supply.has_job(n, p, Supply.JOB_JOIN):
						info_actions.add_child(_button("Присоединить узел", func():
							Supply.order(w, n, p, Supply.JOB_JOIN)
							show_province(p)))
				elif w.p_node_lvl[p] < Supply.NODE_MAX and not Supply.has_job(n, p, Supply.JOB_UP):
					info_actions.add_child(_button("Улучшить узел", func():
						Supply.order(w, n, p, Supply.JOB_UP)
						show_province(p)))
		var ok := Occupation.key_of(w, p) if p < w.p_resist.size() else -1
		if ok >= 0 and ok / 4096 == me:
			info_actions.add_child(_button("Управление землёй", func():
				_prod_page = "lands"
				_occ_key = ok
				open_tab("production")))
		if c != me and w.nations[c].alive:
			info_actions.add_child(_button("Страна: %s" % w.nations[c].name, func():
				_card_nation = c
				open_tab("nation")))
		info_actions.add_child(_button("Закрыть", func(): game.clear_selection()))
	info_panel.show()
	_layout_info.call_deferred()


func show_selection() -> void:
	_info_prov = -1
	_update_selection_text()
	_clear(info_actions)
	info_actions.add_child(_button("Создать армию", func(): game.create_group_from_selection()))
	info_actions.add_child(_button("Стоп", func(): game.stop_selected(); toast("Войска остановлены")))
	info_actions.add_child(_button("Снять выделение", func(): game.clear_selection()))
	info_panel.show()
	_layout_info.call_deferred()


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
		toast("Коснитесь провинции — цель наступления")
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
	_layout_info.call_deferred()


func _update_group_text(g: World.ArmyGroup) -> void:
	var w: World = game.world
	var divs: Array = game.group_divisions(g.id)
	var s := 0.0
	var sup := 0.0
	var fights := 0
	var pl := 0.0
	var bad := 0
	var exh := 0
	for d in divs:
		s += d.strength
		sup += d.supply
		pl += d.plan
		if d.in_battle:
			fights += 1
		if d.supply < World.SUP_EXH:
			exh += 1
		elif d.supply < World.SUP_BAD:
			bad += 1
		_clim_count(w, d.slot)
	var n := maxi(1, divs.size())
	var order := "держит фронт" if g.mode == "hold" else "наступает"
	if g.mode == "attack" and g.objective >= 0:
		order += " · цель: %s" % w.p_name[g.objective]
	_info_text("%s · %d %s\n%s · сила %d%%\nСнабжение %d%% · план %d%% (+%d%% к атаке) · в бою %d" % [
		g.name, divs.size(), _plural(divs.size(), "дивизия", "дивизии", "дивизий"), order[0].to_upper() + order.substr(1),
		s / n, sup / n * 100.0, pl / n * 100.0, pl / n * Simulation.PLAN_MAX * 100.0, fights] + _sup_flags(bad, exh) + _clim_flags())


var _clim_pen := 0      # дивизий выделения с климатическим штрафом (счётчик для _clim_flags)
var _clim_bon := 0


func _clim_count(w: World, slot: int) -> void:
	if slot < w.d_cmul.size():
		if w.d_cmul[slot] < 0.999:
			_clim_pen += 1
		elif w.d_cmul[slot] > 1.001:
			_clim_bon += 1


## Пометки климата (Climate): не привыкли — медленнее, слабее, теряют людей; коренные — бонус.
func _clim_flags() -> String:
	var parts: Array = []
	if _clim_pen > 0:
		parts.append("не привыкли к климату: %d (медленнее, слабее, теряют людей)" % _clim_pen)
	if _clim_bon > 0:
		parts.append("в родном климате: %d (до +15 %%)" % _clim_bon)
	_clim_pen = 0
	_clim_bon = 0
	return ("\n" + " · ".join(parts)) if not parts.is_empty() else ""


## Пометки снабжения: «плохое снабжение» (< 50 %, атака и оборона −25 %),
## «истощение» (< 25 %, −50 %, потери людей ×1,5).
func _sup_flags(bad: int, exh: int) -> String:
	var parts: Array = []
	if bad > 0:
		parts.append("плохое снабжение: %d (−25 %% атаки и обороны)" % bad)
	if exh > 0:
		parts.append("истощение: %d (−50 %%, потери людей ×1,5)" % exh)
	return ("\n" + " · ".join(parts)) if not parts.is_empty() else ""


func _update_selection_text() -> void:
	var sel: Array = game.selected_divs
	if sel.is_empty():
		_info_text("Нет выделенных дивизий")
		return
	var w: World = game.world
	var s := 0.0
	var o := 0.0
	var moving := 0
	var fighting := 0
	var pl := 0.0
	var bad := 0
	var exh := 0
	for d in sel:
		s += d.strength
		pl += d.plan
		o += d.org / maxf(1.0, d.max_org)
		if d.supply < World.SUP_EXH:
			exh += 1
		elif d.supply < World.SUP_BAD:
			bad += 1
		_clim_count(w, d.slot)
		if not d.path.is_empty():
			moving += 1
		if d.in_battle:
			fighting += 1
	_info_text("Выбрано: %d %s\nСила %d%% · организация %d%% · план %d%% · в пути %d · в бою %d%s\nПлан копится, пока войска стоят у фронта (до +%d%% к атаке), и тает в наступлении. Коснитесь провинции, чтобы отправить войска." % [
		sel.size(), _plural(sel.size(), "дивизия", "дивизии", "дивизий"), s / sel.size(), o / sel.size() * 100.0, pl / sel.size() * 100.0, moving, fighting,
		_sup_flags(bad, exh) + _clim_flags(), roundi(Simulation.PLAN_MAX * 100.0)])


# --- Всплывающие окна --------------------------------------------------------

func open_tab(tab: String) -> void:
	if tab == "event":
		var first := not event_sheet.visible
		popup_tab = "event"
		popup.hide()
		popup_cover.hide()
		_set_side_active("")
		var w: World = game.world
		var ef := w.event_front()
		if ef.is_empty():
			event_sheet.hide()
			return
		event_sheet.show_event(game, w, ef[0], ef[1])
		event_sheet.show()
		if first:
			event_sheet.animate_in()
		_layout_info.call_deferred()
		log_box.hide()
		return
	event_sheet.hide()
	tech_view.hide()
	if tab == "research":
		# наука — дерево на весь экран (TechView), без листа-папки
		close_popup()
		focus_view.hide()
		tech_view.open(game, game.world, game.player())
		_set_side_active("research")
		return
	var was_open := popup.visible
	var same_mode := was_open and ((popup_tab == "event") == (tab == "event"))
	if tab != popup_tab:
		_confirm = ""
	popup_tab = tab
	var clipboard := tab == "event"
	_layout_popup(clipboard)
	_rebuild_popup()
	popup.show()
	if not clipboard:
		_fill_cover()
		popup_cover.show()
	_set_side_active("menu" if MENU_TABS.has(tab) else tab)
	if not same_mode:
		_animate_open(clipboard)
	log_box.hide()
	if game.state != "play":
		overlay.hide()


## Открыто ли сейчас окно события (для main.gd).
func event_open() -> bool:
	return popup_tab == "event" and event_sheet.visible


func close_popup() -> bool:
	if event_sheet.visible:
		event_sheet.hide()
		popup_tab = ""
		_layout_info.call_deferred()
		log_box.show()
		return true
	if popup.visible:
		popup.hide()
		popup_cover.hide()
		_set_side_active("")
		if game.state == "play":
			log_box.show()
		elif game.state == "menu":
			show_menu()   # список сохранений мог измениться
		else:
			overlay.show()
		return true
	return false


func _cycle_map_mode() -> void:
	var m: int = (game.map_view.map_mode + 1) % 6
	game.set_map_mode(m)
	toast(["Политическая карта", "Местность", "Промышленность", "Фракции", "Снабжение", "Ресурсы"][m])


func _rebuild_popup() -> void:
	popup_title.add_theme_font_size_override("font_size", 26)
	popup_title.show()
	popup_close.show()
	popup_rule.show()
	_clear(popup_body)
	_dynamic.clear()
	if popup_tab != "event" and popup_cover != null and game != null and game.world != null:
		_fill_cover()
	var w: World = game.world
	if popup_tab == "nations":
		_build_nation_list(w)
		return
	# страницы меню не зависят от страны игрока (открываются и из главного меню)
	match popup_tab:
		"menu":
			_build_menu(w)
			return
		"save":
			_build_save(w)
			return
		"load":
			_build_load()
			return
		"settings":
			_build_settings()
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
			# событие — отдельное окно-планшет (EventSheet), не лист в папке
			var ef := w.event_front()
			if not ef.is_empty():
				event_sheet.show_event(game, w, ef[0], ef[1])
			return
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
	# общая шкала сил мира (4 силы делят 100 %) и очки каждой силы
	popup_body.add_child(_label(Relations.balance_text(w), 16))
	for ideo in Relations.THREATS:
		var tt := Relations.threat_text(w, ideo)
		if tt != "":
			popup_body.add_child(_small(tt))
	_dynamic["justify"] = _label("", 17, Color(0.95, 0.8, 0.5))
	popup_body.add_child(_dynamic["justify"])
	_build_politics(w, me)
	# своя фракция
	var fname := Diplomacy.faction_name(w, me)
	if n.exile:
		popup_body.add_child(_section("Правительство в изгнании: метрополия потеряна, воюем из колоний"))
	if n.overlord >= 0:
		popup_body.add_child(_section("Мы — марионетка страны %s" % w.nations[n.overlord].name))
		popup_body.add_child(_small("Свобода %d%%: отдаём %d%% заводов, фабрик и ресурсов. Свобода растёт от нашего вклада в войну, помощи другим и фокусов." % [
				roundi(n.freedom), roundi(Puppets.share(w, me) * 100.0)]))
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


## Внутренняя политика: политическая власть, стабильность, поддержка войны и решения.
func _build_politics(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Внутренняя политика"))
	popup_body.add_child(_label("Политическая власть: %d (+%.1f в день)" % [int(n.pol_power),
		Politics.PP_DAY * (0.5 + n.stability) * maxf(0.0, 1.0 + n.b("pol_power"))], 17))
	popup_body.add_child(_small("Тратится на гарантии (%d), претензии (%d), смену торгового курса (%d) и законов на чужих землях (%d), решения (%d)." % [
		int(Politics.COST_GUARANTEE), int(Politics.COST_JUSTIFY), int(Politics.COST_TRADE_LAW), int(Politics.COST_OCC_LAW), int(Politics.COST_DECISION)]))
	for row in [["Стабильность", n.stability, Politics.target_stability(w, n)], ["Поддержка войны", n.war_support, Politics.target_war_support(w, n)]]:
		popup_body.add_child(_label("%s: %d%% (стремится к %d%%)" % [row[0], roundi(float(row[1]) * 100.0), roundi(float(row[2]) * 100.0)], 17))
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(0, 14)
		bar.show_percentage = false
		bar.max_value = 100
		bar.value = float(row[1]) * 100.0
		popup_body.add_child(bar)
	var eff: Array = []
	for k in ["industry", "manpower", "surrender"]:
		var v: float = n.pol_bonus.get(k, 0.0)
		if absf(v) >= 0.005:
			eff.append("%s %+d%%" % [{"industry": "промышленность", "manpower": "призыв", "surrender": "порог капитуляции"}[k], roundi(v * 100.0)])
	popup_body.add_child(_small("Стабильность ниже 50 %% режет промышленность, поддержка войны меняет призыв; обе ниже 40 %% приближают капитуляцию. Сейчас: %s." % (", ".join(eff) if not eff.is_empty() else "без влияния")))
	for id in Politics.DECISIONS:
		var d: Dictionary = Politics.DECISIONS[id]
		var did: String = id
		_action("%s (%d ПВ)" % [d["name"], int(Politics.COST_DECISION)], Politics.decision_block(w, n, did), func():
			Politics.take_decision(w, n, did))
		popup_body.add_child(_small("   " + String(d["desc"]) + ", раз в %d дней" % Politics.DECISION_CD))


func _build_nation_card(w: World, me: int, oid: int) -> void:
	var o: World.Nation = w.nations[oid]
	var n: World.Nation = w.nations[me]
	popup_title.text = o.name
	popup_body.add_child(_button("← Ко всем странам", func():
		popup_tab = "diplomacy"
		_rebuild_popup(), Vector2(0, 44)))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var pt := UiStyle.portrait(o.tag)
	if pt != null:
		head.add_child(UiStyle.framed(pt, Vector2(66, 88)))
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
		info += "\nМарионетка страны %s · свобода %d%% · отдаёт %d%% заводов и ресурсов" % [
				w.nations[o.overlord].name, roundi(o.freedom), roundi(Puppets.share(w, oid) * 100.0)]
	if o.exile:
		info += "\nПравительство в изгнании: метрополия потеряна, воюет из колоний"
	if o.neutral:
		info += "\nТрадиционный нейтралитет"
	popup_body.add_child(_small(info))
	popup_body.add_child(_label("Отношения: " + _relation(w, me, oid), 17))
	if oid != me:
		# репутация (0–100) и торговое влияние (доля во внешней торговле)
		var rl: Array = ["Их мнение о нас: %d · наше о них: %d" % [roundi(Relations.rep(w, oid, me)), roundi(Relations.rep(w, me, oid))]]
		var of_name := Diplomacy.faction_name(w, oid)
		if of_name != "":
			rl.append("Мнение фракции «%s» о нас: %d" % [of_name, roundi(Relations.faction_rep(w, oid, me))])
		var mf_name := Diplomacy.faction_name(w, me)
		if mf_name != "" and mf_name != of_name:
			rl.append("Мнение нашей фракции «%s» о них: %d" % [mf_name, roundi(Relations.faction_rep(w, me, oid))])
		rl.append("Торговое влияние: наше у них %d %% · их у нас %d %%" % [roundi(Relations.trade_influence(w, me, oid)), roundi(Relations.trade_influence(w, oid, me))])
		var aid_t: Array = []
		if Relations.aided(w, me, oid):
			aid_t.append("мы им помогали")
		if Relations.aided(w, oid, me):
			aid_t.append("они нам помогали")
		if not aid_t.is_empty():
			rl.append("Помощь: " + ", ".join(aid_t))
		# что страна готовит: ближайшие события её фокусов и шанс сейчас —
		# игрок видит, на что можно повлиять (гарантии, союзы, отношения)
		if not o.is_player:
			var shown := 0
			for eid in History.upcoming_events(w, oid):
				var ev: Dictionary = w.event_defs[eid]
				if not ev.has("chance") or shown >= 2:
					continue
				var c := Relations.chance(w, ev["chance"], History.event_ctx(w, eid, oid))
				var tgt := History.tag_id(w, ev.get("target", ""))
				rl.append("Готовит: «%s» → %s — шанс %d %%" % [ev.get("title", eid), w.nations[tgt].name if tgt >= 0 else "?", c["pct"]])
				var neg: Array = []
				for line in c["lines"].slice(1):
					neg.append(line)
				if not neg.is_empty():
					rl.append("   " + "; ".join(neg))
				shown += 1
		popup_body.add_child(_small("\n".join(rl)))
	popup_body.add_child(_section("Действия"))
	if o.overlord == me:
		var mine: World.Nation = w.nations[me]
		var on := mine.build_puppet == oid
		popup_body.add_child(_button("Строить фабрики у марионетки: %s" % ("да" if on else "нет"), func():
			game.act(func(): mine.build_puppet = -1 if on else oid)
			_rebuild_popup.call_deferred(), Vector2(0, 50)))
		popup_body.add_child(_small("Наши готовые фабрики встают на её земле: каждая снижает её свободу на %d%%, и она отдаёт нам больше." % int(-Puppets.F_BUILD)))
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
	# улучшение отношений (их мнение о нас растёт каждый день)
	if n.improving.has(oid):
		_action("Прекратить улучшение отношений", "", func():
			n.improving.erase(oid))
	else:
		_action("Улучшать отношения (+4 в месяц)", Relations.can_improve(w, me, oid), func():
			n.improving[oid] = true)
	# торговля нашей марионетки: только с нами или свободная
	if o.overlord == me:
		_action("Открыть торговлю марионетки" if o.trade_closed else "Торговля марионетки — только с нами", "", func():
			o.trade_closed = not o.trade_closed)
	# гарантия
	if not n.guarantees.has(oid):
		var gwhy := Diplomacy.can_guarantee(w, me, oid)
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
	popup_title.text = "Мирная конференция"
	var c: Dictionary = w.conference
	if c.is_empty() or w.pending_peace.is_empty():
		close_popup()
		return
	var me := Peace.current(w)
	var budget: float = c["budget"][me]
	popup_body.add_child(_small("Война окончена. Победители по очереди, начиная с наибольшего вклада, делят земли проигравших. ★ — наша национальная территория: вдвое дешевле и сразу становится частью страны. Время стоит, пока вы не решите."))
	popup_body.add_child(_section("Победители"))
	for x in c["winners"]:
		var nx: World.Nation = w.nations[x]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(Flag.make(nx.flag, Vector2(36, 24)))
		var t := "%s — очков %d (вклад %d)%s" % [nx.name, int(c["budget"][x]), int(c["score"].get(x, 0.0)),
				"  ◀ ход" if x == me else ("  · закончила" if c["out"].has(x) else "")]
		var l := _label(t, 17, UiStyle.INK if x == me else UiStyle.INK_SOFT)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		popup_body.add_child(row)
	var lg: Array = c["log"]
	if not lg.is_empty():
		popup_body.add_child(_small("Решено: " + "; ".join(lg.slice(maxi(0, lg.size() - 6)))))
	popup_body.add_child(_button("Пропустить ход", func(): game.resolve_peace("pass"), Vector2(0, 48)))
	popup_body.add_child(_button("Закончить — остальное другим", func(): game.resolve_peace("done"), Vector2(0, 48)))
	var taken: PackedInt32Array = c["u_taken"]
	for l in c["losers"]:
		var nl: World.Nation = w.nations[l]
		var rest := Peace.rest_cost(w, l)
		if rest <= 0.0:
			continue
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 8)
		head.add_child(Flag.make(nl.flag, Vector2(48, 32)))
		var hl := _section("%s — свободных земель на %d очков" % [nl.name, int(rest)])
		hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(hl)
		popup_body.add_child(head)
		var ide: String = w.ideology_names.get(w.nations[me].ideology, w.nations[me].ideology)
		var fb := _button("Освободить (строй — %s) · %d" % [ide, int(Peace.price(w, me, "free", l))],
				func(): game.resolve_peace("free", l), Vector2(0, 48))
		fb.disabled = not Peace.can_do(w, me, "free", l)
		popup_body.add_child(fb)
		var pb := _button("Сделать марионеткой · %d" % int(Peace.price(w, me, "puppet", l)),
				func(): game.resolve_peace("puppet", l), Vector2(0, 48))
		pb.disabled = not Peace.can_do(w, me, "puppet", l)
		popup_body.add_child(pb)
		# участки: сначала занятые нами, потом дорогие
		var us: Array = []
		for u in taken.size():
			if taken[u] == -1 and int(c["u_owner"][u]) == l:
				us.append(u)
		var held := func(u: int) -> int:
			var n := 0
			for p in c["u_provs"][u]:
				if w.p_controller[p] == me:
					n += 1
			return n
		us.sort_custom(func(a, b):
			var ha: int = held.call(a)
			var hb: int = held.call(b)
			return ha > hb if ha != hb else float(c["u_cost"][a]) > float(c["u_cost"][b]))
		for u in us:
			var pr := Peace.unit_price(w, u, me)
			var big: int = c["u_big"][u]
			var mine: int = held.call(u)
			var provs: PackedInt32Array = c["u_provs"][u]
			var nat_land := Claims.share(w, me, provs) >= 0.5
			var b := _button("%d · %s%s, %d пров.%s" % [int(pr), "★ " if nat_land else "", w.p_name[big], provs.size(),
					" (занято нами)" if mine > 0 else ""], func(): game.resolve_peace("annex", u), Vector2(0, 44))
			b.disabled = pr > budget + 0.001
			b.clip_text = true
			popup_body.add_child(b)


func _build_event(w: World) -> void:
	if w.pending_events.is_empty():
		close_popup()
		return
	var id: String = w.pending_events[0]
	var ev: Dictionary = w.event_defs.get(id, {})
	# как в макете: шапка телеграммы и штамп сверху, под ними заголовок,
	# крестика нет — решение обязательно
	popup_title.text = ""
	popup_title.hide()
	popup_close.hide()
	popup_rule.hide()
	var faded := UiStyle.INK_SOFT
	var head := HBoxContainer.new()
	var tg := _label("ТЕЛЕГРАММА · %s" % w.date_short(), 12, faded, true)
	tg.add_theme_font_override("font", UiStyle.mono_bold())
	tg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tg.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(tg)
	var st := TextureRect.new()
	st.texture = UiStyle.ui_tex("stamp_secret.png")
	st.custom_minimum_size = Vector2(150, 50)
	st.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	st.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	st.rotation_degrees = -9.0
	head.add_child(st)
	head.add_theme_constant_override("separation", 0)
	popup_body.add_child(head)
	var title := _label(String(ev.get("title", id)).to_upper(), 25, UiStyle.INK, true)
	title.add_theme_font_override("font", UiStyle.title_font(500))
	popup_body.add_child(title)
	var rule := ColorRect.new()
	rule.color = Color(UiStyle.INK_SOFT, 0.7)
	rule.custom_minimum_size = Vector2(0, 2)
	popup_body.add_child(rule)
	# фото на скрепке рядом с текстом: картинка события или лидер страны,
	# к которой событие
	var art := UiStyle.event_art(id)
	if art == null:
		var tgt: int = game.nation_by_tag(String(ev.get("target", ""))) if ev.has("target") else -1
		if tgt >= 0:
			art = UiStyle.portrait(w.nations[tgt].tag)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	if art != null:
		row.add_child(_clipped_photo(art, Vector2(112, 150)))
	# текст как в макете: начало — рядом с фото, продолжение — ниже на всю ширину
	var full: String = ev.get("text", "")
	var parts := _split_text(full) if art != null else [full, ""]
	var text_l := _label(parts[0], 14, UiStyle.INK, true)
	text_l.add_theme_font_override("font", UiStyle.serif_font())
	text_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(text_l)
	popup_body.add_child(row)
	if parts[1] != "":
		var more := _label(parts[1], 14, UiStyle.INK, true)
		more.add_theme_font_override("font", UiStyle.serif_font())
		popup_body.add_child(more)
	var opts: Array = ev.get("options", [])
	if opts.size() > 1:
		var leg := HBoxContainer.new()
		var star := _label("★", 13, UiStyle.RED_INK, true)
		star.autowrap_mode = TextServer.AUTOWRAP_OFF
		star.add_theme_font_override("font", UiStyle.text_font())
		leg.add_child(star)
		var lt := _label("— так поступили в истории", 11, faded, true)
		lt.autowrap_mode = TextServer.AUTOWRAP_OFF
		lt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		leg.add_child(lt)
		popup_body.add_child(leg)
	var best := 0
	for i in opts.size():
		if float(opts[i].get("ai", 0)) > float(opts[best].get("ai", 0)):
			best = i
	for i in opts.size():
		var o: Dictionary = opts[i]
		var k := i
		# вариант — бумажная карточка с квадратиком слева и красной звездой справа
		var b := _button(o.get("name", "?"), func(): game.resolve_event(k), Vector2(0, 36))
		b.add_theme_font_size_override("font_size", 14)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.icon = UiStyle.ui_tex("checkbox.png")
		b.add_theme_constant_override("icon_max_width", 14)
		if i == best and opts.size() > 1:
			var bs := _label("★", 16, UiStyle.RED_INK, true)
			bs.autowrap_mode = TextServer.AUTOWRAP_OFF
			bs.add_theme_font_override("font", UiStyle.text_font())
			bs.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
			bs.position = Vector2(-26, -12)
			bs.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(bs)
		popup_body.add_child(b)
		var et := History.effects_text(w, o.get("effects", []))
		et = et.trim_prefix("Эффекты: ").trim_prefix("Эффекты:").strip_edges()
		if et != "":
			var el := _label(et[0].to_upper() + et.substr(1), 11, faded, true)
			var em := MarginContainer.new()
			em.add_theme_constant_override("margin_left", 30)
			em.add_child(el)
			popup_body.add_child(em)


## Текст события делится по предложению примерно пополам: начало — рядом с
## фото, остальное — ниже (как в макете).
func _split_text(t: String) -> Array:
	if t.length() < 140:
		return [t, ""]
	var target := int(t.length() * 0.55)
	var best := -1
	var i := t.find(". ")
	while i >= 0:
		if best < 0 or absi(i - target) < absi(best - target):
			best = i
		i = t.find(". ", i + 2)
	if best < 0:
		return [t, ""]
	return [t.substr(0, best + 1), t.substr(best + 2)]


## Фото в белой рамке с наклоном и скрепкой сверху.
func _clipped_photo(tex: Texture2D, size: Vector2) -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = size + Vector2(14, 26)
	var fr := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.97, 0.94, 0.87)
	sb.set_content_margin_all(6)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 4
	sb.shadow_offset = Vector2(2, 3)
	fr.add_theme_stylebox_override("panel", sb)
	var r := TextureRect.new()
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.texture = tex
	r.custom_minimum_size = size
	fr.add_child(r)
	fr.size = size + Vector2(12, 12)
	fr.position = Vector2(4, 18)
	fr.rotation_degrees = -2.0
	holder.add_child(fr)
	var clip_r := TextureRect.new()
	clip_r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	clip_r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	clip_r.texture = UiStyle.ui_tex("paperclip.png")
	clip_r.custom_minimum_size = Vector2(30, 44)
	clip_r.size = Vector2(30, 44)
	clip_r.position = Vector2(18, 0)
	clip_r.rotation_degrees = 12.0
	holder.add_child(clip_r)
	return holder


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
	toast("В подготовке: +%d" % made if made > 0 else Military.can_train(game.world, game.world.nations[game.player()], tpl))
	_rebuild_popup()


func _eq_text(eq: Array) -> String:
	var parts: Array = []
	for k in Military.EQ_COUNT:
		if eq[k] > 0:
			parts.append(("%s %d" if float(eq[k]) == floorf(float(eq[k])) else "%s %.1f") % [Military.EQ_SHORT[k], eq[k]])
	return ", ".join(parts)


# конструктор шаблонов: -2 — закрыт, -1 — новый шаблон, иначе правка своего
var _tpl_edit := -2
var _tpl_bat: Array = []
var _tpl_name := ""


func _tpl_stats_text(tp: Dictionary) -> String:
	var best := ""
	var bv := 0.0
	var worst := ""
	var wv := 9.0
	for k in [World.T_FOREST, World.T_HILLS, World.T_MOUNTAIN, World.T_URBAN, World.T_MARSH, World.T_DESERT]:
		var v: float = tp["terr"][k]
		if v > bv:
			bv = v
			best = TERRAIN_SHORT[k]
		if v < wv:
			wv = v
			worst = TERRAIN_SHORT[k]
	return "атака %.1f · оборона %.1f · орг. %d · скорость ×%.1f · бронированность %d%% · ширина %d · %.1fк чел. · %d дн.\n%s\nместность: лучше всего — %s (×%.2f), хуже — %s (×%.2f)" % [
		tp["atk"], tp["def"], tp["org"], tp["spd"], tp["hard"] * 100.0, Military.template_width(tp), tp["men"], tp["days"], _eq_text(tp["eq"]), best, bv, worst, wv]


const TERRAIN_SHORT := ["равнины", "лес", "холмы", "горы", "город", "море", "пустыня", "болота"]


func _open_tpl_editor(w: World, t: int, own: bool) -> void:
	var tp: Dictionary = w.templates[t] if t >= 0 else {}
	_tpl_bat = (tp["bat"] as Array).duplicate() if t >= 0 else [9, 0, 0, 0, 0, 0, 0]
	while _tpl_bat.size() < Military.BAT_COUNT:
		_tpl_bat.append(0)   # составы из старых сохранений — без ПТО
	_tpl_name = tp["name"] if own else ((tp["name"] + " (нов.)") if t >= 0 else "Новая дивизия")
	_tpl_edit = t if own else -1
	_rebuild_popup()


func _build_tpl_editor(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_title.text = "Шаблон дивизии"
	var name_edit := LineEdit.new()
	name_edit.text = _tpl_name
	name_edit.max_length = 32
	name_edit.custom_minimum_size = Vector2(0, 48)
	name_edit.text_changed.connect(func(tx: String): _tpl_name = tx)
	popup_body.add_child(name_edit)
	var total := 0
	for b in Military.BAT_COUNT:
		total += int(_tpl_bat[b])
	var tp := Military.make_template(_tpl_name, "", _tpl_bat, me)
	popup_body.add_child(_label(_tpl_stats_text(tp) if total > 0 else "Нет батальонов.", 15))
	if total > 0:
		var td := TankDesigns.of_nation(w, n)
		var ap := Military.armor_pierce(n, _tpl_bat, td)
		popup_body.add_child(_label("Броня %.0f · бронебойность %.0f%s" % [ap[0], ap[1],
			(" (танки — по проекту «%s»)" % td.get("name", "лёгкий танк")) if Military.bat_n(_tpl_bat, Military.B_TANK) > 0 else ""], 15))
	popup_body.add_child(_section("Батальоны: %d из %d" % [total, Military.MAX_BATTALIONS]))
	for b in Military.BAT_COUNT:
		var bt: Dictionary = Military.BATTALIONS[b]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var ic := TextureRect.new()
		ic.texture = UiStyle.icon(bt["icon"], 32)
		ic.custom_minimum_size = Vector2(32, 32)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.modulate = UiStyle.ink(Color(0.93, 0.9, 0.82))
		row.add_child(ic)
		var lock: String = bt["req"]
		var locked := lock != "" and not n.techs.has(lock)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_child(_label("%s × %d" % [bt["name"], int(_tpl_bat[b])], 16))
		col.add_child(_small(("нужна технология «%s»" % Tech.get_tech(lock).get("name", lock)) if locked else _bat_line(bt)))
		row.add_child(col)
		var bb := b
		var minus := _button("−", func():
			_tpl_bat[bb] = maxi(0, int(_tpl_bat[bb]) - 1)
			_rebuild_popup(), Vector2(44, 44))
		minus.disabled = int(_tpl_bat[b]) <= 0
		row.add_child(minus)
		var plus := _button("+", func():
			_tpl_bat[bb] = int(_tpl_bat[bb]) + 1
			_rebuild_popup(), Vector2(44, 44))
		plus.disabled = total >= Military.MAX_BATTALIONS
		row.add_child(plus)
		popup_body.add_child(row)
	popup_body.add_child(_small("Атака, оборона, люди и снаряжение складываются; организация, бронированность и местность — средние; скорость — по самому медленному батальону. Броня и бронебойность дивизии — 0,4 от лучшего батальона + 0,6 от среднего; кого противник не пробивает, тот получает вдвое меньше урона."))
	var miss := Military.tech_missing(tp, n)
	if miss != "":
		popup_body.add_child(_small("Пока нельзя готовить: нужна технология «%s»." % Tech.get_tech(miss).get("name", miss)))
	var used := 0
	if _tpl_edit >= 0:
		for d in w.divisions:
			if d.alive and d.tpl == _tpl_edit:
				used += 1
		if used > 0:
			popup_body.add_child(_small("Правка изменит %d дивизий: снаряжение и люди пересчитаются под новый состав, лишнее вернётся на склад, недостающее придёт пополнением." % used))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	var save := _button("Сохранить", func():
		var nm := _tpl_name.strip_edges()
		if nm == "":
			nm = "Дивизия"
		if Military.save_template(w, me, nm, _tpl_bat, _tpl_edit) < 0:
			toast("Нужен хотя бы один батальон")
			return
		toast("Шаблон «%s» сохранён" % nm)
		_tpl_edit = -2
		_rebuild_popup(), Vector2(0, 52))
	save.disabled = total <= 0
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(save)
	if _tpl_edit >= 0:
		var del := _button("Убрать из списка", func():
			Military.hide_template(w, me, _tpl_edit)
			_tpl_edit = -2
			_rebuild_popup(), Vector2(0, 52))
		del.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(del)
	var cancel := _button("Отмена", func():
		_tpl_edit = -2
		_rebuild_popup(), Vector2(0, 52))
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row2.add_child(cancel)
	popup_body.add_child(row2)


func _bat_line(bt: Dictionary) -> String:
	var ap := "бр. и пробит. — по проекту танка" if bt["icon"] == "arm" else "бр. %d · пробит. %d" % [bt["armor"], bt["pierce"]]
	return "ат. %.2f · об. %.2f · орг. %d · ×%.1f · шир. %d · %s" % [bt["atk"], bt["def"], bt["org"], bt["spd"], bt["width"], ap]


func _build_army(w: World, me: int) -> void:
	if _tk_open:
		_build_tank_editor(w, me)
		return
	if _tpl_edit != -2:
		_build_tpl_editor(w, me)
		return
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
	for t in Military.available_templates(w, n, true):
		var tp: Dictionary = Military.tpl(w, t)
		var why := Military.can_train(w, n, t)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var b1 := _button("%s" % tp["name"], func(): _train(1, t), Vector2(0, 48))
		b1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b1.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b1.clip_text = true   # длинное название не раздвигает лист
		b1.disabled = why != ""
		row.add_child(b1)
		var b5 := _button("×5", func(): _train(5, t), Vector2(60, 48))
		b5.disabled = why != ""
		row.add_child(b5)
		var own := int(tp["owner"]) == me
		var be := _button("Изм." if own else "Копия", func(): _open_tpl_editor(w, t, own), Vector2(84, 48))
		row.add_child(be)
		popup_body.add_child(row)
		popup_body.add_child(_small("   атака %.1f · оборона %.1f · скорость ×%.1f · %.1fк чел. · %s · %d дн.%s" % [
			tp["atk"], tp["def"], tp["spd"], tp["men"], _eq_text(tp["eq"]), tp["days"], ("\n   " + why) if why != "" else ""]))
	popup_body.add_child(_button("Новый шаблон дивизии", func(): _open_tpl_editor(w, -1, false), Vector2(0, 50)))
	_build_tank_designs(w, me)
	_build_supply(w, me)


# --- Конструктор танков (TankDesigns) -------------------------------------------
# во вкладке «Армия»: шасси + модули в слотах; проект в производстве — у всех
# танковых батальонов страны
var _tk_open := false
var _tk_hull := ""
var _tk_mods: Array = []
var _tk_name := ""


func _build_tank_designs(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Проекты танков"))
	var order: Array = []
	if n.tank_design >= 0 and n.tank_design < w.tank_designs.size():
		order.append(n.tank_design)
	for i in w.tank_designs.size():
		if int(w.tank_designs[i]["owner"]) == me and not order.has(i):
			order.append(i)
	if order.is_empty():
		popup_body.add_child(_small("Проектов нет: шасси открывает технология «Лёгкие танки»." if not n.techs.has("armor1") else "Проектов нет — соберите первый."))
	for i in order:
		var d: Dictionary = w.tank_designs[i]
		var did: int = i
		var cur: bool = n.tank_design == i
		var hr := TankDesigns.hull(d["hull"])
		popup_body.add_child(_label("%s%s" % [d["name"], " — выпускается" if cur else ""], 16))
		popup_body.add_child(_small("   %s: %s" % [hr[1] if not hr.is_empty() else d["hull"], TankDesigns.stats_text(d)]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		if not cur:
			var bp := _button("В производство", func():
				TankDesigns.set_production(w, n, did)
				toast("В производстве: %s" % d["name"])
				_rebuild_popup(), Vector2(0, 44))
			bp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(bp)
		var bc := _button("Копия и правка", func(): _open_tank_editor(w, did), Vector2(0, 44))
		bc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bc)
		popup_body.add_child(row)
	var bn := _button("Новый проект танка", func(): _open_tank_editor(w, -1), Vector2(0, 50))
	bn.disabled = TankDesigns.hulls_for(n).is_empty()
	popup_body.add_child(bn)
	popup_body.add_child(_small("Проект в производстве — у всех танковых батальонов страны: броня, бронебойность, атака и скорость. Цена проекта делит выпуск бронетехники."))


## Открыть редактор: на основе проекта did или новый (-1 — с лучшего доступного шасси).
func _open_tank_editor(w: World, did: int) -> void:
	if did >= 0:
		var d: Dictionary = w.tank_designs[did]
		_tk_hull = d["hull"]
		_tk_mods = (d["mods"] as Array).duplicate()
		_tk_name = String(d["name"]) + " (нов.)"
	else:
		var hs := TankDesigns.hulls_for(w.nations[maxi(0, w.player_nation())])
		_tk_hull = hs[hs.size() - 1] if not hs.is_empty() else TankDesigns.HULLS[0][0]
		_tk_mods = []
		_tk_name = "Новый танк"
	_tk_open = true
	_rebuild_popup()


func _tk_eff_text(eff: Dictionary) -> String:
	var parts: Array = []
	for key in eff:
		var v: float = eff[key]
		var nm: String = TankDesigns.STAT_NAMES[key]
		if key == "atk" or key == "speed" or key == "cost":
			parts.append("%s %s%.2f" % [nm, "+" if v > 0 else "−", absf(v)])
		elif key == "pierce":
			parts.append("%s %d" % [nm, roundi(v)])
		else:
			parts.append("%s %s%d" % [nm, "+" if v > 0 else "−", roundi(absf(v))])
	return ", ".join(parts)


func _build_tank_editor(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_title.text = "Проект танка"
	var h := TankDesigns.hull(_tk_hull)
	var name_edit := LineEdit.new()
	name_edit.text = _tk_name
	name_edit.max_length = 32
	name_edit.custom_minimum_size = Vector2(0, 48)
	name_edit.text_changed.connect(func(tx: String): _tk_name = tx)
	popup_body.add_child(name_edit)
	var s := TankDesigns.stats(_tk_hull, _tk_mods)
	var did: int = n.tank_design
	var has_b := did >= 0 and did < w.tank_designs.size()
	var b: Dictionary = w.tank_designs[did] if has_b else s
	var lines: Array = []
	if has_b:
		lines.append("Сравнение с выпускаемым «%s»" % b["name"])
	lines.append("броня %s · бронебойность %s" % [_pl_cmp(float(s["armor"]), float(b["armor"]), "%.0f", has_b),
		_pl_cmp(float(s["pierce"]), float(b["pierce"]), "%.0f", has_b)])
	lines.append("атака ×%s · скорость ×%s · цена ×%s" % [_pl_cmp(float(s["atk"]), float(b["atk"]), "%.2f", has_b),
		_pl_cmp(float(s["speed"]), float(b["speed"]), "%.2f", has_b), _pl_cmp(float(s["cost"]), float(b["cost"]), "%.2f", has_b)])
	popup_body.add_child(_label("\n".join(lines), 15))

	popup_body.add_child(_section("Шасси"))
	for hr in TankDesigns.HULLS:
		var hid: String = hr[0]
		var ok := TankDesigns.has_tech(n, hr[2])
		var txt := "%s%s\n%d сл. · броня %d · скорость ×%.2f · цена ×%.2f" % ["▶ " if hid == _tk_hull else "", hr[1], hr[3], hr[4], hr[5], hr[6]]
		if not ok:
			txt = "%s\nнужна «%s»" % [hr[1], Tech.get_tech(hr[2]).get("name", hr[2])]
		var bh := _button(txt, func():
			_tk_hull = hid
			var keep: Array = []
			for m in _tk_mods:
				if keep.size() < int(TankDesigns.hull(hid)[3]):
					keep.append(m)
			_tk_mods = keep
			_rebuild_popup(), Vector2(0, 54))
		bh.add_theme_font_size_override("font_size", 13)
		bh.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		bh.clip_text = true
		bh.disabled = not ok or hid == _tk_hull
		if hid == _tk_hull:
			bh.add_theme_color_override("font_disabled_color", UiStyle.ink(Color(0.95, 0.85, 0.5)))
		popup_body.add_child(bh)

	var slots: int = int(h[3]) if not h.is_empty() else 0
	popup_body.add_child(_section("Слоты: %d из %d" % [_tk_mods.size(), slots]))
	if _tk_mods.is_empty():
		popup_body.add_child(_small("Пусто — добавьте модули из списка ниже."))
	for i in _tk_mods.size():
		var ii := i
		var m := TankDesigns.module(String(_tk_mods[i]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := _label("%d. %s — %s" % [i + 1, m[1], _tk_eff_text(m[3])], 15)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(l)
		row.add_child(_button("✕", func():
			_tk_mods.remove_at(ii)
			_rebuild_popup(), Vector2(44, 44)))
		popup_body.add_child(row)

	popup_body.add_child(_section("Модули"))
	var guns := 0
	for m in _tk_mods:
		if TankDesigns.is_gun(String(m)):
			guns += 1
	for mr in TankDesigns.MODS:
		var mid: String = mr[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cnt := _tk_mods.count(mid)
		col.add_child(_label("%s%s" % [mr[1], (" × %d" % cnt) if cnt > 0 else ""], 16))
		var why := ""
		if not TankDesigns.has_tech(n, mr[2]):
			why = "нужна технология «%s»" % Tech.get_tech(mr[2]).get("name", mr[2])
		elif bool(mr[4]) and guns >= TankDesigns.MAX_GUNS and cnt == 0:
			why = "пушка в башне одна — сначала снимите другую"
		var sm := _small(why if why != "" else _tk_eff_text(mr[3]))
		sm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(sm)
		row.add_child(col)
		var plus := _button("+", func():
			_tk_mods.append(mid)
			_rebuild_popup(), Vector2(44, 44))
		plus.disabled = why != "" or _tk_mods.size() >= slots or cnt >= TankDesigns.MAX_SAME \
			or (bool(mr[4]) and guns >= TankDesigns.MAX_GUNS)
		row.add_child(plus)
		popup_body.add_child(row)
	popup_body.add_child(_small("Пушка одна, другие модули — не больше двух раз. Бронебойность — лучшая из пушки и пулемётов. Если бронебойности противника не хватает против брони дивизии, его урон по ней вдвое меньше."))

	var ok_save := not _tk_mods.is_empty() and TankDesigns.valid(n, _tk_hull, _tk_mods)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	for prod in [true, false]:
		var pr: bool = prod
		var bs := _button("В производство" if prod else "Сохранить", func():
			if not TankDesigns.valid(n, _tk_hull, _tk_mods) or _tk_mods.is_empty():
				toast("Проект собран неверно")
				return
			var nm := _tk_name.strip_edges()
			if nm == "":
				nm = "Танк"
			var before := w.tank_designs.size()
			var id := TankDesigns.add(w, me, nm, _tk_hull, _tk_mods)
			if id < before:
				nm = w.tank_designs[id]["name"]
				toast("Такой проект уже есть: «%s»" % nm)
			elif not pr:
				toast("Проект «%s» сохранён" % nm)
			if pr:
				TankDesigns.set_production(w, n, id)
				toast("В производстве: %s" % nm)
			_tk_open = false
			_rebuild_popup(), Vector2(0, 52))
		bs.disabled = not ok_save
		bs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(bs)
	popup_body.add_child(row2)
	popup_body.add_child(_button("Отмена", func():
		_tk_open = false
		_rebuild_popup(), Vector2(0, 48)))


const TRUCK_NAMES := ["конная", "половина на грузовиках", "грузовики"]


## Снабжение: узлы страны, их загрузка, стройка узлов, доставка грузовиками.
func _build_supply(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Снабжение"))
	var s := Supply.side(w, me)
	var nodes: Array = []   # [загрузка, провинция, взято, бюджет]
	var wait: Array = []
	for k in w.node_keys:
		var h := w.node_hub[k]
		if h >= 0 and w.p_controller[h] == me and not Supply.node_ok(w, s, h):
			wait.append(h)
		var p := w.node_prov[k]
		if p < 0 or w.p_controller[p] != me:
			continue
		var cap := w.node_f[k] * Supply.BUDGET_K
		nodes.append([w.node_used[k] / maxf(cap, 0.01), p, w.node_used[k], cap])
	nodes.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	var over := 0
	for e in nodes:
		if e[0] >= 0.95:
			over += 1
	popup_body.add_child(_label("Узлов %d, перегружено %d · ждут присоединения %d\nДоставка от узлов: %s%s" % [
		nodes.size(), over, wait.size(), TRUCK_NAMES[clampi(n.truck_mode, 0, 2)],
		(" · грузовиков %.1f в день (на складе %d%s)" % [n.truck_use, n.stock[Military.EQ_TRUCK], "" if n.truck_ok >= 0.999 else ", не хватает"]) if n.truck_mode > 0 else ""], 15))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for m in 3:
		var mm := m
		var b := _button(("● " if n.truck_mode == m else "") + ["Конная", "½ груз.", "Груз."][m], func():
			n.truck_mode = mm
			_rebuild_popup(), Vector2(0, 44))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	popup_body.add_child(row)
	popup_body.add_child(_small("Половина на грузовиках — радиус узлов +1, подача +20 %%; грузовики — +2 и +40 %%. Расход — %.2f грузовика в день на единицу подачи (при половине — вдвое меньше)." % Supply.TRUCK_USE))
	popup_body.add_child(_button("Присоединять узлы: %s" % ("да" if n.sup_auto else "нет"), func():
		n.sup_auto = not n.sup_auto
		_rebuild_popup(), Vector2(0, 44)))
	if not n.sup_jobs.is_empty():
		var lines: Array = []
		for j in n.sup_jobs:
			var p: int = j[0]
			lines.append("%s: %s — %d из %d" % ["Присоединить" if int(j[1]) == Supply.JOB_JOIN else "Улучшить до ур. %d" % (w.p_node_lvl[p] + 1),
				w.p_name[p], roundi(float(j[2])), roundi(Supply.job_cost(w, j))])
		popup_body.add_child(_small("Стройка узлов (до половины очков стройки):\n" + "\n".join(lines)))
	for h in wait.slice(0, 4):
		var hh: int = h
		if not Supply.has_job(n, hh, Supply.JOB_JOIN):
			popup_body.add_child(_button("Присоединить: %s" % w.p_name[hh], func():
				Supply.order(w, n, hh, Supply.JOB_JOIN)
				_rebuild_popup(), Vector2(0, 44)))
	for e in nodes.slice(0, 6):
		var p: int = e[1]
		var lvl := w.p_node_lvl[p] if p < w.p_node_lvl.size() else 0
		var b := _button("%s · ур.%d · %d/%d" % [w.p_name[p], lvl, roundi(e[2]), roundi(e[3])], func():
			Supply.order(w, n, p, Supply.JOB_UP)
			_rebuild_popup(), Vector2(0, 44))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.disabled = lvl >= Supply.NODE_MAX or Supply.has_job(n, p, Supply.JOB_UP)
		popup_body.add_child(b)
	popup_body.add_child(_small("Узел района (главный город) кормит провинции вокруг себя. Войска берут снабжение у ближайшего узла — основного; не хватило — у вспомогательных, ближайших к нему по дороге: чем ближе, тем больше они берут на себя (−25 %% за район между узлами). Чем длиннее фронт на узле, тем больше вспомогательных (до 4); узкий фронт упирается в предел. Нажмите на узел — улучшить: подача +%d %%, дорога района шире, каждые 2 уровня — радиус +1. Захваченный узел работает, только когда присоединён к своей сети." % roundi(Supply.NODE_UP * 100.0)))


const SHIP_SHORT := ["подл.", "крейс.", "авиан."]


func _ships_text(f: World.Fleet) -> String:
	var parts: Array = []
	for k in [Forces.SHIP_CR, Forces.SHIP_CV, Forces.SHIP_SS]:
		if f.ships[k] > 0:
			parts.append("%s %d" % [SHIP_SHORT[k], f.ships[k]])
	return ", ".join(parts)


const MISSION_NAMES := {"patrol": "патруль", "raid": "рейды", "port": "в порту",
	"sup": "превосходство", "cas": "поддержка войск", "bomb": "бомбардировка", "naval": "удары по флоту"}


func _build_navy(w: World, me: int) -> void:
	if _pl_open:
		_build_plane_editor(w, me)
		return
	if _sh_open:
		_build_ship_editor(w, me)
		return
	popup_title.text = "Флот и авиация"
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Флоты"))
	var any := false
	for f in w.fleets:
		if f.alive and f.owner == me:
			any = true
			var fid: int = f.id
			var b := _button("%s\n%s · %d%% · %s · %s" % [f.name, _ships_text(f), f.readiness * 100.0, w.p_name[f.zone], MISSION_NAMES.get(f.mission, f.mission)], func():
				close_popup()
				game.select_fleet(fid), Vector2(0, 56))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			b.clip_text = true
			b.add_theme_font_size_override("font_size", 14)
			popup_body.add_child(b)
	if not any:
		popup_body.add_child(_small("Флота нет."))
	popup_body.add_child(_section("Верфи"))
	var q: Array = []
	for did in n.ship_queue:
		if did >= 0 and did < w.ship_designs.size():
			q.append(w.ship_designs[did]["name"])
	popup_body.add_child(_small("Очки судостроения: %d (+%.1f/день, заводы — во вкладке «Производство»). В соединении до %d кораблей, в бою у стороны — до %d соединений.\nОчередь: %s" % [
		n.stock[Military.EQ_SHIP], n.daily_output[Military.EQ_SHIP], Forces.FLEET_MAX, Forces.NAVY_WIDTH, ", ".join(q) if not q.is_empty() else "пусто"]))
	if not n.ship_queue.is_empty():
		popup_body.add_child(_button("Очистить очередь", func():
			n.ship_queue.clear()
			_rebuild_popup(), Vector2(0, 44)))
	_build_convoys(w, me)
	_build_ship_designs(w, me)
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
		b.add_theme_font_size_override("font_size", 14)
		popup_body.add_child(b)
	_build_plane_designs(w, me)
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


# --- Конструктор самолётов (Designs) ------------------------------------------
# окно-редактор во вкладке «Флот и авиация»: корпус + модули в слотах
var _pl_open := false
var _pl_hull := ""
var _pl_mods: Array = []
var _pl_name := ""

const PL_KIND := ["истребитель", "бомбардировщик"]


## Проекты страны во вкладке: что в производстве, свои проекты, новый проект.
func _build_plane_designs(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Проекты самолётов"))
	# сначала выпускаемые (истребитель, бомбардировщик), затем остальные свои
	var order: Array = []
	for k in 2:
		if n.air_design[k] >= 0 and n.air_design[k] < w.plane_designs.size():
			order.append(n.air_design[k])
	for i in w.plane_designs.size():
		if int(w.plane_designs[i]["owner"]) == me and not order.has(i):
			order.append(i)
	for i in order:
		var d: Dictionary = w.plane_designs[i]
		var did: int = i
		var k: int = d["kind"]
		var cur: bool = n.air_design[k] == i
		var hr := Designs.hull(d["hull"])
		popup_body.add_child(_label("%s%s" % [d["name"], (" — выпускается (%s)" % ("истребители" if k == 0 else "бомбардировщики")) if cur else ""], 16))
		popup_body.add_child(_small("   %s, %s: %s" % [PL_KIND[k], hr[1] if not hr.is_empty() else d["hull"], Designs.stats_text(d)]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		if not cur:
			var bp := _button("В производство", func():
				Designs.set_production(w, n, did)
				toast("В производстве: %s" % d["name"])
				_rebuild_popup(), Vector2(0, 44))
			bp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(bp)
		var bc := _button("Копия и правка", func(): _open_plane_editor(w, did), Vector2(0, 44))
		bc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bc)
		popup_body.add_child(row)
	popup_body.add_child(_button("Новый проект самолёта", func(): _open_plane_editor(w, -1), Vector2(0, 50)))
	popup_body.add_child(_small("Новые крылья и крылья, пополненные больше чем наполовину, получают самолёты проекта в производстве. Цена проекта делит выпуск: дорогой самолёт выходит реже."))


## Открыть редактор: на основе проекта did или новый (-1 — с первого корпуса).
func _open_plane_editor(w: World, did: int) -> void:
	if did >= 0:
		var d: Dictionary = w.plane_designs[did]
		_pl_hull = d["hull"]
		_pl_mods = (d["mods"] as Array).duplicate()
		_pl_name = String(d["name"]) + " (нов.)"
	else:
		_pl_hull = Designs.HULLS[0][0]
		_pl_mods = []
		_pl_name = "Новый самолёт"
	_pl_open = true
	_rebuild_popup()


## Строка «значение (±разница с выпускаемым)».
func _pl_cmp(v: float, base: float, fmt: String, has_base: bool) -> String:
	var t := fmt % v
	if has_base and absf(v - base) > 1e-6:
		t += (" (+" if v > base else " (−") + (fmt % absf(v - base)) + ")"
	return t


func _pl_eff_text(eff: Dictionary) -> String:
	var parts: Array = []
	for key in eff:
		var v: float = eff[key]
		var nm: String = Designs.STAT_NAMES[key]
		if key == "coord":
			parts.append("%s %s%d%%" % [nm, "+" if v > 0 else "−", roundi(absf(v) * 100.0)])
		elif key == "agi" or key == "cost":
			parts.append("%s %s%.2f" % [nm, "+" if v > 0 else "−", absf(v)])
		else:
			parts.append("%s %s%d" % [nm, "+" if v > 0 else "−", roundi(absf(v))])
	return ", ".join(parts)


func _build_plane_editor(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_title.text = "Проект самолёта"
	var h := Designs.hull(_pl_hull)
	var name_edit := LineEdit.new()
	name_edit.text = _pl_name
	name_edit.max_length = 32
	name_edit.custom_minimum_size = Vector2(0, 48)
	name_edit.text_changed.connect(func(tx: String): _pl_name = tx)
	popup_body.add_child(name_edit)
	# характеристики и сравнение с выпускаемым проектом того же вида
	var s := Designs.stats(_pl_hull, _pl_mods)
	var k: int = s["kind"]
	var did: int = n.air_design[k]
	var has_b := did >= 0 and did < w.plane_designs.size()
	var b: Dictionary = w.plane_designs[did] if has_b else s
	var pw := float(s["atk"]) * float(s["agi"]) * Designs.MAN_MULT
	var pwb := float(b["atk"]) * float(b["agi"]) * Designs.MAN_MULT
	var dw := float(s["def"]) * float(s["agi"]) * Designs.MAN_MULT
	var dwb := float(b["def"]) * float(b["agi"]) * Designs.MAN_MULT
	var lines: Array = []
	lines.append("Вид: %s%s" % [PL_KIND[k], (" · сравнение с «%s»" % b["name"]) if has_b else ""])
	lines.append("атака %s · защита %s · манёвренность %s · координация %s" % [
		_pl_cmp(float(s["atk"]), float(b["atk"]), "%.0f", has_b), _pl_cmp(float(s["def"]), float(b["def"]), "%.0f", has_b),
		_pl_cmp(float(s["agi"]), float(b["agi"]), "%.2f", has_b), _pl_cmp(float(s["coord"]) * 100.0, float(b["coord"]) * 100.0, "%.0f%%", has_b)])
	lines.append("сила в бою: удар %s · стойкость %s (× манёвренность × %.1f)" % [
		_pl_cmp(pw, pwb, "%.1f", has_b), _pl_cmp(dw, dwb, "%.1f", has_b), Designs.MAN_MULT])
	var hits: Array = []
	for key in ["ground", "bomb", "naval"]:
		if float(s[key]) > 0.0 or float(b[key]) > 0.0:
			hits.append("%s %s" % [Designs.STAT_NAMES[key], _pl_cmp(float(s[key]), float(b[key]), "%.0f", has_b)])
	if not hits.is_empty():
		lines.append(" · ".join(hits))
	lines.append("цена %s (базовый: истребитель 1,0, бомбардировщик 2,0)" % _pl_cmp(float(s["cost"]), float(b["cost"]), "%.2f", has_b))
	popup_body.add_child(_label("\n".join(lines), 15))

	popup_body.add_child(_section("Корпус"))
	var grid := GridContainer.new()
	grid.columns = 1
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	for hr in Designs.HULLS:
		var hid: String = hr[0]
		var ok := Designs.has_tech(n, hr[2])
		var txt := "%s%s\n%d сл. · защ. %d · ман. %.2f · цена %.1f" % ["▶ " if hid == _pl_hull else "", hr[1], hr[3], hr[4], hr[5], hr[6]]
		if not ok:
			txt = "%s\nнужна «%s»" % [hr[1], Tech.get_tech(hr[2]).get("name", hr[2])]
		var bh := _button(txt, func():
			_pl_hull = hid
			# лишние модули и модули только для тяжёлых корпусов — снимаются
			var allowed := Designs.mods_for(n, hid)
			var keep: Array = []
			for m in _pl_mods:
				if allowed.has(m) and keep.size() < int(Designs.hull(hid)[3]):
					keep.append(m)
			_pl_mods = keep
			_rebuild_popup(), Vector2(0, 54))
		bh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bh.add_theme_font_size_override("font_size", 13)
		bh.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		bh.clip_text = true
		bh.disabled = not ok or hid == _pl_hull
		if hid == _pl_hull:
			bh.add_theme_color_override("font_disabled_color", UiStyle.ink(Color(0.95, 0.85, 0.5)))
		grid.add_child(bh)
	popup_body.add_child(grid)

	var slots: int = int(h[3]) if not h.is_empty() else 0
	popup_body.add_child(_section("Слоты: %d из %d" % [_pl_mods.size(), slots]))
	if _pl_mods.is_empty():
		popup_body.add_child(_small("Пусто — добавьте модули из списка ниже."))
	for i in _pl_mods.size():
		var ii := i
		var m := Designs.module(String(_pl_mods[i]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := _label("%d. %s — %s" % [i + 1, m[1], _pl_eff_text(m[3])], 15)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(_button("✕", func():
			_pl_mods.remove_at(ii)
			_rebuild_popup(), Vector2(44, 44)))
		popup_body.add_child(row)

	popup_body.add_child(_section("Модули"))
	var avail := Designs.mods_for(n, _pl_hull)
	for mr in Designs.MODS:
		var mid: String = mr[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cnt := _pl_mods.count(mid)
		col.add_child(_label("%s%s" % [mr[1], (" × %d" % cnt) if cnt > 0 else ""], 16))
		var why := ""
		if not Designs.has_tech(n, mr[2]):
			why = "нужна технология «%s»" % Tech.get_tech(mr[2]).get("name", mr[2])
		elif not avail.has(mid):
			why = "только для двух- и четырёхмоторных корпусов"
		col.add_child(_small(why if why != "" else _pl_eff_text(mr[3])))
		row.add_child(col)
		var plus := _button("+", func():
			_pl_mods.append(mid)
			_rebuild_popup(), Vector2(44, 44))
		plus.disabled = why != "" or _pl_mods.size() >= slots or cnt >= Designs.MAX_SAME
		row.add_child(plus)
		popup_body.add_child(row)
	popup_body.add_child(_small("Один модуль — не больше двух раз. Бомбы, бомбоотсек или торпеда делают самолёт бомбардировщиком. Манёвренность умножает атаку и защиту (×%.1f); координация — доля крыла, что бьёт согласованно." % Designs.MAN_MULT))

	var ok_save := not _pl_mods.is_empty() and Designs.valid(n, _pl_hull, _pl_mods)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	for prod in [true, false]:
		var pr: bool = prod
		var bs := _button("В производство" if prod else "Сохранить", func():
			if not Designs.valid(n, _pl_hull, _pl_mods) or _pl_mods.is_empty():
				toast("Проект собран неверно")
				return
			var nm := _pl_name.strip_edges()
			if nm == "":
				nm = "Самолёт"
			var before := w.plane_designs.size()
			var id := Designs.add(w, me, nm, _pl_hull, _pl_mods)
			if id < before:
				nm = w.plane_designs[id]["name"]
				toast("Такой проект уже есть: «%s»" % nm)
			elif not pr:
				toast("Проект «%s» сохранён" % nm)
			if pr:
				Designs.set_production(w, n, id)
				toast("В производстве: %s" % nm)
			_pl_open = false
			_rebuild_popup(), Vector2(0, 52))
		bs.disabled = not ok_save
		bs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(bs)
	popup_body.add_child(row2)
	popup_body.add_child(_button("Отмена", func():
		_pl_open = false
		_rebuild_popup(), Vector2(0, 48)))


# --- Конструктор кораблей (ShipDesigns) -----------------------------------------
# окно-редактор во вкладке «Флот и авиация»: категория, корпус, модули в слотах
var _sh_open := false
var _sh_kind := 1
var _sh_hull := ""
var _sh_mods: Array = []
var _sh_name := ""


## Проекты кораблей страны: основные (по ролям) сверху, затем свои; «Заложить» —
## в очередь верфей.
## Конвои: сколько есть и нужно, что доходит, опасные моря, постройка.
func _build_convoys(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Конвои"))
	var need := n.conv_trade_need + n.conv_sup_need
	var lines: Array = []
	lines.append("Конвоев %d, нужно %d: морской импорт %d, снабжение войск за морем %d" % [
		roundi(n.convoys), roundi(need), roundi(n.conv_trade_need), roundi(n.conv_sup_need)])
	lines.append("Доходит морского импорта %d%% · снабжение за морем обеспечено на %d%%" % [roundi(n.conv_trade * 100.0), roundi(n.conv_sup * 100.0)])
	lines.append("Потоплено: в этом месяце %d, в прошлом %d, всего %d" % [roundi(n.conv_sunk_month), roundi(n.conv_sunk_last), roundi(n.conv_sunk)])
	popup_body.add_child(_label("\n".join(lines), 15))
	if not n.conv_danger.is_empty():
		var zs: Array = n.conv_danger.keys()
		zs.sort_custom(func(a, b): return float(n.conv_danger[a]) > float(n.conv_danger[b]) or (float(n.conv_danger[a]) == float(n.conv_danger[b]) and int(a) < int(b)))
		var parts: Array = []
		for i in mini(6, zs.size()):
			var z: int = zs[i]
			var dz: float = n.conv_danger[z]
			parts.append("%s — %d%%%s" % [w.basin_name[z], roundi(dz * 100.0), " (блокада)" if dz >= Convoys.BLOCKADE_LOSS else ""])
		popup_body.add_child(_small("Перехват на путях: " + ", ".join(parts) + ". Охранение — соединения с ПЛО в этих морях."))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var ba := _button("Строить по нужде: %s" % ("да" if n.conv_auto else "нет"), func():
		n.conv_auto = not n.conv_auto
		_rebuild_popup(), Vector2(0, 44))
	ba.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ba)
	var bo := _button("+10 конвоев%s" % ((" (заказано %d)" % n.conv_order) if n.conv_order > 0 else ""), func():
		n.conv_order += 10
		_rebuild_popup(), Vector2(0, 44))
	bo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bo)
	popup_body.add_child(row)
	popup_body.add_child(_small("Конвой — %d очков судостроения, строится раньше кораблей. Сначала конвои идут на снабжение войск за морем, затем везут снаряжение на склады, остаток — на торговлю. Рейдеры и флот противника, господствующий на пути, топят конвои: теряется только то, что идёт через это море." % roundi(Convoys.COST)))
	_build_depots(w, me)
	_build_airlift(w, me)


## Склады за морем: главный пункт снабжения каждого участка — запас, доля
## запаса страны, что держать там (игрок меняет), подача, подвоз.
func _build_depots(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Склады за морем"))
	var ps: Array = []
	for p in w.dep_want:
		if w.p_controller[int(p)] == me:
			ps.append(int(p))
	ps.sort()
	if ps.is_empty():
		popup_body.add_child(_small("Пунктов снабжения за морем нет. Пункт снабжения — столица, крупный город или порт с улучшенным узлом; обычный порт — только база и ремонт кораблей."))
		return
	popup_body.add_child(_label("Подвоз снаряжения: конвоев занято %d из нужных %d" % [roundi(n.conv_eq_use), roundi(n.conv_eq_need)], 15))
	for p in ps:
		var pp: int = p
		var st: PackedFloat64Array = w.dep_stock.get(pp, PackedFloat64Array([0.0, 0.0, 0.0, 0.0]))
		var share: float = float(w.dep_share.get(pp, Depots.DEFAULT_SHARE))
		popup_body.add_child(_label("%s — запас %d (стрелковое %d, артиллерия %d, бронетехника %d, грузовики %d), подача %d%%" % [w.p_name[pp],
			roundi(Depots._value(st)), roundi(st[0]), roundi(st[1]), roundi(st[2]), roundi(st[3]), roundi(100.0 * w.p_dsup[pp]) if w.p_dsup.size() == w.prov_count else 100], 15))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		for dv in [-0.1, 0.1]:
			var d: float = dv
			var b := _button(("−10%" if d < 0.0 else "+10%"), func():
				var v := clampf(share + d, 0.0, 1.0)
				game.act(func(): w.dep_share[pp] = v)
				_rebuild_popup(), Vector2(0, 44))
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(b)
		var lb := _label("держать %d%% запаса страны" % roundi(share * 100.0), 15)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lb)
		popup_body.add_child(row)
	popup_body.add_child(_small("Дивизии пополняются из запаса, доступного по суше: в метрополии — со складов страны, за морем — со склада своего участка. Конвои довозят снаряжение до указанной доли (вместе — не больше %d%% запаса страны). Нет пути конвоев — участок живёт запасом склада; кончится — войска без снабжения." % roundi(Depots.SHARE_SUM_MAX * 100.0)))


func _build_airlift(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Транспортная авиация"))
	popup_body.add_child(_label("Самолётов %d: занято %d из нужных %d; потеряно %d" % [maxi(0, roundi(n.air_trans)), roundi(n.air_trans_use), roundi(n.air_trans_need), roundi(n.air_trans_lost)], 15))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var auto := n.air_auto
	var ba := _button("Пополнять по нужде: %s" % ("да" if auto else "нет"), func():
		game.act(func(): n.air_auto = not auto)
		_rebuild_popup(), Vector2(0, 44))
	ba.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ba)
	var bo := _button("+10 самолётов", func():
		game.act(func(): n.air_order += 10)
		toast("Заказано 10 транспортных самолётов")
		_rebuild_popup(), Vector2(0, 44))
	bo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(bo)
	popup_body.add_child(row)
	if n.air_order > 0:
		popup_body.add_child(_small("В заказе: %d (переделка из резерва бомбардировщиков, до %d в день)" % [n.air_order, roundi(Airlift.BUILD_MAX)]))
	popup_body.add_child(_small("Гражданские и транспортные самолёты возят снабжение по воздуху туда, куда нет пути по суше: в окружённые и отрезанные участки и за море — не дальше %d км от пункта снабжения метрополии. %d самолётов полностью снабжают одну дивизию; груз — из запаса страны. Под чужим господством в воздухе доставка падает вдвое, самолёты гибнут. Пополнение — переделка двухмоторных машин из резерва бомбардировщиков." % [roundi(Airlift.RANGE_KM), roundi(Airlift.PER_DIV)]))


func _build_ship_designs(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Проекты кораблей"))
	var order: Array = []
	for r in ShipDesigns.ROLES.size():
		var rd: int = n.ship_role[r]
		if rd >= 0 and rd < w.ship_designs.size() and not order.has(rd):
			order.append(rd)
	for i in w.ship_designs.size():
		if int(w.ship_designs[i]["owner"]) == me and not order.has(i):
			order.append(i)
	for i in order:
		var d: Dictionary = w.ship_designs[i]
		var did: int = i
		var hr := ShipDesigns.hull(d["hull"])
		var role := n.ship_role.find(did)
		popup_body.add_child(_label("%s%s" % [d["name"], (" — основной: %s" % ShipDesigns.ROLE_PLURAL[role]) if role >= 0 else ""], 16))
		popup_body.add_child(_small("   %s, %s: %s" % [ShipDesigns.KIND_ONE[int(d["kind"])], hr[1] if not hr.is_empty() else d["hull"], ShipDesigns.stats_text(d)]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var bq := _button("Заложить", func():
			n.ship_queue.append(did)
			toast("Заложен: %s" % d["name"])
			_rebuild_popup(), Vector2(0, 44))
		bq.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bq)
		var bc := _button("Копия и правка", func(): _open_ship_editor(w, did), Vector2(0, 44))
		bc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(bc)
		popup_body.add_child(row)
	popup_body.add_child(_button("Новый проект корабля", func(): _open_ship_editor(w, -1), Vector2(0, 50)))
	popup_body.add_child(_small("Три категории: подлодки (рейды на торговлю), крейсеры (все надводные боевые корабли — от эсминца до линкора) и авианосцы (удар авиагрупп). Готовый корабль уходит в соединение своей категории, где есть место."))


## Открыть редактор: копия проекта did или новый (-1 — крейсер на первом корпусе).
func _open_ship_editor(w: World, did: int) -> void:
	if did >= 0:
		var d: Dictionary = w.ship_designs[did]
		_sh_hull = d["hull"]
		_sh_kind = int(d["kind"])
		_sh_mods = (d["mods"] as Array).duplicate()
		_sh_name = String(d["name"]) + " (нов.)"
	else:
		_sh_kind = ShipDesigns.KIND_CR
		_sh_hull = "dd"
		_sh_mods = []
		_sh_name = "Новый корабль"
	_sh_open = true
	_rebuild_popup()


func _sh_eff_text(eff: Dictionary) -> String:
	var parts: Array = []
	for key in eff:
		var v: float = eff[key]
		var t := ("%d%%" % roundi(absf(v) * 100.0)) if key == "stealth" else ShipDesigns._num(absf(v))
		parts.append("%s %s%s" % [ShipDesigns.STAT_NAMES[key], "+" if v > 0 else "−", t])
	return ", ".join(parts)


## Корпуса и модули, что подходят новому корпусу, остаются; лишние — снимаются.
func _sh_set_hull(n: World.Nation, hid: String) -> void:
	_sh_hull = hid
	var allowed := ShipDesigns.mods_for(n, hid)
	var keep: Array = []
	for m in _sh_mods:
		if allowed.has(m) and keep.size() < int(ShipDesigns.hull(hid)[4]):
			keep.append(m)
	_sh_mods = keep


func _build_ship_editor(w: World, me: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_title.text = "Проект корабля"
	var h := ShipDesigns.hull(_sh_hull)
	var name_edit := LineEdit.new()
	name_edit.text = _sh_name
	name_edit.max_length = 32
	name_edit.custom_minimum_size = Vector2(0, 48)
	name_edit.text_changed.connect(func(tx: String): _sh_name = tx)
	popup_body.add_child(name_edit)
	# категория
	var krow := HBoxContainer.new()
	krow.add_theme_constant_override("separation", 6)
	for k in [ShipDesigns.KIND_SS, ShipDesigns.KIND_CR, ShipDesigns.KIND_CV]:
		var kk: int = k
		var bk := _button(ShipDesigns.KIND_NAMES[k], func():
			_sh_kind = kk
			for hr in ShipDesigns.HULLS:
				if int(hr[2]) == kk and ShipDesigns.has_tech(n, hr[3]):
					_sh_set_hull(n, hr[0])
					break
			_rebuild_popup(), Vector2(0, 46))
		bk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bk.add_theme_font_size_override("font_size", 11)
		bk.clip_text = true
		bk.disabled = _sh_kind == k
		if _sh_kind == k:
			bk.add_theme_color_override("font_disabled_color", UiStyle.ink(Color(0.95, 0.85, 0.5)))
		krow.add_child(bk)
	popup_body.add_child(krow)
	# характеристики и сравнение с основным проектом той же роли
	var s := ShipDesigns.stats(_sh_hull, _sh_mods)
	var role := ShipDesigns.role_of(s)
	var bd: int = n.ship_role[role]
	var has_b := bd >= 0 and bd < w.ship_designs.size()
	var b: Dictionary = w.ship_designs[bd] if has_b else s
	var lines: Array = []
	lines.append("%s%s" % [ShipDesigns.KIND_ONE[int(s["kind"])].capitalize(), (" · сравнение с «%s»" % b["name"]) if has_b else ""])
	var st: Array = []
	for key in ["atk", "air", "def", "asw", "aa", "raid"]:
		if float(s[key]) > 0.0 or float(b[key]) > 0.0:
			st.append("%s %s" % [ShipDesigns.STAT_NAMES[key], _pl_cmp(float(s[key]), float(b[key]), "%.1f", has_b)])
	lines.append(" · ".join(st))
	if float(s["stealth"]) > 0.0 or float(b["stealth"]) > 0.0:
		lines.append("скрытность %s" % _pl_cmp(float(s["stealth"]) * 100.0, float(b["stealth"]) * 100.0, "%.0f%%", has_b))
	lines.append("сила %s · цена %s очков судостроения" % [_pl_cmp(float(s["power"]), float(b["power"]), "%.1f", has_b),
		_pl_cmp(float(s["cost"]), float(b["cost"]), "%.0f", has_b)])
	popup_body.add_child(_label("\n".join(lines), 15))

	popup_body.add_child(_section("Корпус"))
	for hr in ShipDesigns.HULLS:
		if int(hr[2]) != _sh_kind:
			continue
		var hid: String = hr[0]
		var ok := ShipDesigns.has_tech(n, hr[3])
		var base: Dictionary = hr[7]
		var bt: Array = []
		for key in ["atk", "air", "def"]:
			if base.has(key):
				bt.append("%s %s" % [{"atk": "ог.", "air": "авиа", "def": "жив."}[key], ShipDesigns._num(float(base[key]))])
		var txt := "%s%s (%s)\n%d сл. · %s · %d" % ["▶ " if hid == _sh_hull else "", hr[1], ShipDesigns.SIZE_NAMES[int(hr[5])], hr[4], " · ".join(bt), roundi(float(hr[8]))]
		if not ok:
			txt = "%s\nнужна «%s»" % [hr[1], Tech.get_tech(hr[3]).get("name", hr[3])]
		var bh := _button(txt, func():
			_sh_set_hull(n, hid)
			_rebuild_popup(), Vector2(0, 54))
		bh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bh.add_theme_font_size_override("font_size", 13)
		bh.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		bh.clip_text = true
		bh.disabled = not ok or hid == _sh_hull
		if hid == _sh_hull:
			bh.add_theme_color_override("font_disabled_color", UiStyle.ink(Color(0.95, 0.85, 0.5)))
		popup_body.add_child(bh)

	var slots: int = int(h[4]) if not h.is_empty() else 0
	popup_body.add_child(_section("Слоты: %d из %d" % [_sh_mods.size(), slots]))
	if _sh_mods.is_empty():
		popup_body.add_child(_small("Пусто — добавьте модули из списка ниже."))
	for i in _sh_mods.size():
		var ii := i
		var m := ShipDesigns.module(String(_sh_mods[i]))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := _label("%d. %s — %s" % [i + 1, m[1], _sh_eff_text(m[4])], 15)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		row.add_child(_button("✕", func():
			_sh_mods.remove_at(ii)
			_rebuild_popup(), Vector2(44, 44)))
		popup_body.add_child(row)

	popup_body.add_child(_section("Модули"))
	for mr in ShipDesigns.MODS:
		if not (mr[2] as Array).has(_sh_kind):
			continue
		var mid: String = mr[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cnt := _sh_mods.count(mid)
		col.add_child(_label("%s%s" % [mr[1], (" × %d" % cnt) if cnt > 0 else ""], 16))
		var why := ""
		if not ShipDesigns.has_tech(n, mr[3]):
			why = "нужна технология «%s»" % Tech.get_tech(mr[3]).get("name", mr[3])
		elif not ShipDesigns.fits(mr, h):
			var lo: int = mr[6]
			var hi: int = mr[7]
			why = "только для корпусов: %s" % ", ".join(ShipDesigns.SIZE_NAMES.slice(lo, hi + 1))
		col.add_child(_small(why if why != "" else "%s · цена %d" % [_sh_eff_text(mr[4]), roundi(float(mr[5]))]))
		row.add_child(col)
		var plus := _button("+", func():
			_sh_mods.append(mid)
			_rebuild_popup(), Vector2(44, 44))
		plus.disabled = why != "" or _sh_mods.size() >= slots or cnt >= ShipDesigns.MAX_SAME
		row.add_child(plus)
		popup_body.add_child(row)
	popup_body.add_child(_small("Один модуль — не больше двух раз. Огонь бьёт по надводным кораблям, удар авиагрупп слабеет от ПВО цели, подлодки уязвимы только для ПЛО (скрытность снижает и его). Живучесть — сколько урона выдерживает корабль; сила — для господства на море."))

	var ok_save := not _sh_mods.is_empty() and ShipDesigns.valid(n, _sh_hull, _sh_mods)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	for q in [true, false]:
		var qq: bool = q
		var bs := _button("Заложить" if q else "Сохранить", func():
			if not ShipDesigns.valid(n, _sh_hull, _sh_mods) or _sh_mods.is_empty():
				toast("Проект собран неверно")
				return
			var nm := _sh_name.strip_edges()
			if nm == "":
				nm = "Корабль"
			var before := w.ship_designs.size()
			var id := ShipDesigns.add(w, me, nm, _sh_hull, _sh_mods)
			if id < before:
				nm = w.ship_designs[id]["name"]
				toast("Такой проект уже есть: «%s»" % nm)
			elif not qq:
				toast("Проект «%s» сохранён" % nm)
			if qq:
				n.ship_queue.append(id)
				toast("Заложен: %s" % nm)
			_sh_open = false
			_rebuild_popup(), Vector2(0, 52))
		bs.disabled = not ok_save
		bs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(bs)
	popup_body.add_child(row2)
	popup_body.add_child(_button("Отмена", func():
		_sh_open = false
		_rebuild_popup(), Vector2(0, 48)))


func show_fleet(f: World.Fleet) -> void:
	var w: World = game.world
	_info_prov = -1
	var comp: Array = []
	for i in f.designs.size():
		if comp.size() >= 3:
			comp.append("…")
			break
		comp.append("%s ×%d" % [w.ship_designs[f.designs[i]]["name"], f.counts[i]])
	_info_text("%s\n%s (%d из %d) · сила %d · готовность %d%%\n%s\n%s · %s%s\nКоснитесь моря (или берега), чтобы отправить соединение." % [
		f.name, _ships_text(f), Forces.fleet_size(f), Forces.FLEET_MAX, Forces.fleet_power(f), f.readiness * 100.0, ", ".join(comp),
		w.p_name[f.zone], MISSION_NAMES.get(f.mission, f.mission),
		(" · в пути %d дн." % f.path.size()) if not f.path.is_empty() else ""])
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
	var bs := _button("Разделить", func():
		var nf := Forces.split_fleet(w, f)
		if nf != null:
			Forces._refresh_cache(w)
			toast("Новое соединение: %s" % nf.name)
		show_fleet(f))
	bs.disabled = Forces.fleet_size(f) < 2
	info_actions.add_child(bs)
	var others := false
	for o in w.fleets:
		if o != f and o.alive and o.owner == f.owner and o.zone == f.zone:
			others = true
	var bm := _button("Слить", func():
		var moved := Forces.merge_here(w, f)
		toast("Перешло кораблей: %d" % moved if moved > 0 else "Места нет: в соединении до %d кораблей" % Forces.FLEET_MAX)
		show_fleet(f))
	bm.disabled = not others or Forces.fleet_size(f) >= Forces.FLEET_MAX
	info_actions.add_child(bm)
	info_actions.add_child(_button("✕", func(): game.clear_selection(), Vector2(56, 56)))
	info_panel.show()
	_layout_info.call_deferred()


func show_wing(wg: World.AirWing) -> void:
	var w: World = game.world
	_info_prov = -1
	var sup: float = w.air_sup[wg.region * w.nation_count + wg.owner] if w.air_sup.size() > wg.region * w.nation_count + wg.owner else 0.5
	_info_text("%s\n%d самолётов · район %s · превосходство %d%%\nКоснитесь карты, чтобы сменить район (дальность ограничена)." % [
		wg.name, wg.planes, w.region_name[wg.region], sup * 100.0])
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
	_layout_info.call_deferred()


# вкладка «Производство»: страница заводов или внешней экономики; ресурс,
# для которого открыт выбор продавца (−1 — нет)
var _prod_page := "factories"
var _buy_res := -1


func _prod_pages() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for pg in [["factories", "Заводы"], ["trade", "Торговля"], ["lands", "Чужие земли"]]:
		var id: String = pg[0]
		var b := _button(pg[1], func():
			_prod_page = id
			_buy_res = -1
			_rebuild_popup(), Vector2(0, 46))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = _prod_page == id
		row.add_child(b)
	popup_body.add_child(row)


var _occ_key := -1   # открытая территория (Occupation.tkey)


## Чужие земли под нашей властью: список территорий и одна территория —
## законы, гарнизон, интеграция (Occupation).
func _build_lands(w: World, me: int) -> void:
	popup_title.text = "Чужие земли"
	_prod_pages()
	var ks: Array = Occupation.territories(w, me)
	if _occ_key >= 0 and not ks.has(_occ_key):
		_occ_key = -1
	if _occ_key < 0:
		if ks.is_empty():
			popup_body.add_child(_small("Занятых в войне и присоединённых по миру земель нет."))
			return
		popup_body.add_child(_small("Занятые в войне и присоединённые на мирных переговорах земли. Отдача заводов, фабрик и ресурсов зависит от законов, принятия и сопротивления; гарнизон гасит сопротивление."))
		for k in ks:
			var st := Occupation.stats(w, k)
			var nm: String = w.nations[k % 4096].name
			var b := _button("%s · %d пров." % [nm, st[0]], func():
						_occ_key = k
						_rebuild_popup(), Vector2(0, 48))
			b.clip_text = true
			popup_body.add_child(b)
			popup_body.add_child(_small("Сопротивление %d%% · принятие %d%% · отдача %d%% · гарнизон %d из %d" % [
					roundi(st[1]), roundi(st[2]), roundi(st[3] * 100.0), int(w.occ_garrison.get(k, 0.0)), int(ceilf(float(w.occ_need.get(k, 0.0))))]))
		return
	var k := _occ_key
	var st := Occupation.stats(w, k)
	var from: World.Nation = w.nations[k % 4096]
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_button("← Ко всем землям", func():
		_occ_key = -1
		_rebuild_popup(), Vector2(0, 46)))
	var kind := "присоединены по миру" if int(st[4]) == int(st[0]) else ("заняты в войне" if int(st[4]) == 0 else "заняты и присоединены")
	popup_body.add_child(_section("Земли страны %s — %s" % [from.name, kind]))
	popup_body.add_child(_label("Провинций %d · сопротивление %d%% · принятие %d%% · отдача %d%%" % [st[0], roundi(st[1]), roundi(st[2]), roundi(st[3] * 100.0)], 17))
	# гарнизон
	var need: float = ceilf(float(w.occ_need.get(k, 0.0)))
	var g: float = w.occ_garrison.get(k, 0.0)
	popup_body.add_child(_section("Гарнизон: %d из %d нужных (%d%%)" % [int(g), int(need), roundi(100.0 * minf(1.0, g / maxf(0.1, need)))]))
	popup_body.add_child(_small("Единица — %dк человек и %d пехотного снаряжения. Без гарнизона сопротивление растёт, при сильном сопротивлении гарнизон несёт потери. Роспуск возвращает людей." % [int(Occupation.GARR_MP), int(Occupation.GARR_EQ)]))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for d in [-5, 5]:
		var dd: int = d
		var b := _button("%+d" % dd, func():
			game.act(func(): Occupation.set_garrison(w, k, g + dd))
			_rebuild_popup.call_deferred(), Vector2(0, 48))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	var fb := _button("По нужде", func():
		game.act(func(): Occupation.set_garrison(w, k, need))
		_rebuild_popup.call_deferred(), Vector2(0, 48))
	fb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(fb)
	popup_body.add_child(row)
	# законы
	popup_body.add_child(_section("Законы"))
	var cur := Occupation.law_of(w, k)
	for i in Occupation.LAWS.size():
		var li: int = i
		var law: Dictionary = Occupation.LAWS[i]
		var lb := _button(("● " if i == cur else "") + String(law["name"]), func():
			game.act(func():
				var why := Occupation.set_law(w, k, li)
				if why != "":
					toast.call_deferred(why))
			_rebuild_popup.call_deferred(), Vector2(0, 46))
		lb.disabled = i == cur
		popup_body.add_child(lb)
		popup_body.add_child(_small(String(law["desc"])))
	# интеграция
	if int(st[4]) > 0:
		popup_body.add_child(_section("Интеграция"))
		var on := w.occ_integrate.has(k)
		popup_body.add_child(_small("Присоединённые земли: −%d гражд. фабрик, принятие растёт быстрее; без интеграции принятие даёт не больше 70 %% прибавки к отдаче." % Occupation.integ_cost(w, k)))
		popup_body.add_child(_button("Интеграция: %s" % ("идёт — остановить" if on else "начать"), func():
			game.act(func():
				if w.occ_integrate.has(k):
					w.occ_integrate.erase(k)
				else:
					w.occ_integrate[k] = true)
			_rebuild_popup.call_deferred(), Vector2(0, 48)))
	popup_body.add_child(_small("Люди: %dк · пехотное снаряжение: %d" % [int(n.manpower), int(n.stock[Military.EQ_INF])]))


func _build_trade(w: World, me: int) -> void:
	popup_title.text = "Внешняя экономика"
	var n: World.Nation = w.nations[me]
	_prod_pages()
	if w.res_prov.is_empty():
		popup_body.add_child(_small("В этом мире нет природных ресурсов."))
		return
	if _buy_res >= 0:
		_build_sellers(w, me, _buy_res)
		return
	# курс
	var law: Dictionary = Economy.LAWS[n.trade_law]
	popup_body.add_child(_section("Курс: %s" % law["name"]))
	popup_body.add_child(_small("На экспорт идёт до %d%% добычи, но не больше излишка сверх своей нужды (кроме поставок по договорам). Покупатели ранжируются раз в месяц: экономическое влияние, близость, соседство и выход к морю, отношения и строй, союз, марионетки. Курс можно менять раз в %d дней." % [roundi(float(law["export"]) * 100.0), Economy.LAW_COOLDOWN]))
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 4)
	for i in Economy.LAWS.size():
		var li := i
		var lw: Dictionary = Economy.LAWS[i]
		var bon: Array = []
		for k in lw["bonus"]:
			bon.append("%s +%d%%" % [{"construction": "стройка", "research": "наука", "industry": "выпуск"}.get(k, k), roundi(float(lw["bonus"][k]) * 100.0)])
		var b := _button("%s · %d%%%s" % [lw["name"], roundi(float(lw["export"]) * 100.0), ("\n" + ", ".join(bon)) if not bon.is_empty() else ""], func():
			var why := Economy.set_law(w, n, li)
			if why != "":
				toast(why)
			_rebuild_popup(), Vector2(0, 62))
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(0, 54 if not bon.is_empty() else 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = i == n.trade_law
		grid.add_child(b)
	popup_body.add_child(grid)
	popup_body.add_child(_button("Автозакупки: %s" % ("да" if n.trade_auto else "нет"), func():
		n.trade_auto = not n.trade_auto
		_rebuild_popup(), Vector2(0, 48)))
	popup_body.add_child(_small("Гражданские заводы на оплату закупок: %.1f · приходит от продаж: %.1f (1 завод — %d ед. в день)" % [n.trade_civ, n.trade_civ_in, int(Economy.UNITS_PER_CIV)]))
	# ресурсы
	popup_body.add_child(_section("Ресурсы (ед. в день)"))
	for r in Economy.RES_COUNT:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var fill: float = n.res_fill[r]
		var lost := (" · не дошло морем −%.1f" % n.res_lost[r]) if n.res_lost[r] >= 0.05 else ""
		var l := _label("%s — обеспечено %d%%\nдобыча %.1f · нужно %.1f · куплено +%.1f%s · продано −%.1f" % [
			Economy.RES_NAMES[r], roundi(fill * 100.0), n.res_prod[r], n.res_need[r], n.res_in[r], lost, n.res_out[r]], 15)
		if fill < 0.999:
			l.add_theme_color_override("font_color", UiStyle.ink(Color(1.0, 0.45, 0.4)))
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var rr := r
		row.add_child(_button("Купить", func():
			_buy_res = rr
			_rebuild_popup(), Vector2(96, 48)))
		popup_body.add_child(row)
	# поставки
	var mine: Array = []
	var sold: Array = []
	for i in w.contracts.size():
		var c: Array = w.contracts[i]
		if c[0] == me:
			mine.append(i)
		elif c[1] == me:
			sold.append(i)
	popup_body.add_child(_section("Закупки"))
	if mine.is_empty():
		popup_body.add_child(_small("Нет."))
	for i in mine:
		var c: Array = w.contracts[i]
		var row := HBoxContainer.new()
		var next := ""
		if float(c[6]) >= 0.0:
			next = " · с %s: %.1f" % [w.date_short(int(c[4])), float(c[6])] if float(c[6]) > 0.0 else " · отказ с %s" % w.date_short(int(c[4]))
		if int(c[5]) > w.day:
			next = " · по договору до %s" % w.date_short(int(c[5]))
		var l := _label("%s: %s %.1f в день · оплачено до %s%s" % [w.nations[c[1]].name, Economy.RES_NAMES[c[2]].to_lower(), float(c[3]), w.date_short(int(c[4])), next], 15)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var ci: int = i
		var cb := _button("Отказаться", func():
			Economy.cancel(w, ci)
			toast("Поставка идёт до конца оплаченного месяца")
			_rebuild_popup(), Vector2(130, 44))
		cb.disabled = float(c[6]) == 0.0 or int(c[5]) > w.day
		row.add_child(cb)
		popup_body.add_child(row)
	popup_body.add_child(_section("Экспорт"))
	if sold.is_empty():
		popup_body.add_child(_small("Нет."))
	for i in sold:
		var c: Array = w.contracts[i]
		popup_body.add_child(_small("%s: %s %.1f в день до %s%s" % [w.nations[c[0]].name, Economy.RES_NAMES[c[2]].to_lower(), float(c[3]), w.date_short(int(c[4])),
			(" · по договору до %s" % w.date_short(int(c[5]))) if int(c[5]) > w.day else ""]))


## Выбор продавца ресурса r: кто может продать, сколько и как высоко мы у него
## в рейтинге (кто выше — тому он продаёт в первую очередь).
func _build_sellers(w: World, me: int, r: int) -> void:
	var n: World.Nation = w.nations[me]
	popup_body.add_child(_section("Купить: %s" % Economy.RES_NAMES[r].to_lower()))
	popup_body.add_child(_small("Нужно %.1f, есть %.1f. Поставка — на месяц; отказ вступает в силу с конца оплаченного месяца. Продавец сначала обслуживает тех, кто у него выше в рейтинге." % [n.res_need[r], Economy.available(n, r)]))
	popup_body.add_child(_button("← Назад", func():
		_buy_res = -1
		_rebuild_popup(), Vector2(0, 44)))
	var nc := w.nation_count
	var list: Array = []
	for s in nc:
		if s == me or not w.nations[s].alive:
			continue
		var free := Economy.exportable(w, w.nations[s], r, me)
		if free < 0.1:
			continue
		var sc: float = w.trade_score[s * nc + me] if w.trade_score.size() == nc * nc else 0.0
		list.append([sc, s, free])
	list.sort_custom(func(a, b): return a[0] > b[0] or (a[0] == b[0] and a[1] < b[1]))
	if list.is_empty():
		popup_body.add_child(_small("Сейчас никто не продаёт."))
	for it in list:
		var s: int = it[1]
		var free: float = it[2]
		var why := Economy.can_trade(w, me, s)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := _label("%s\nсвободно %.1f · рейтинг у продавца %.2f%s" % [w.nations[s].name, free, float(it[0]), (" · " + why) if why != "" else ""], 15)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		for amount in [1.0, 5.0]:
			var am: float = minf(amount, free)
			var b := _button("+%s" % ("%.1f" % am if am < amount else "%d" % int(amount)), func():
				if not Economy.buy(w, me, s, r, am, true):
					toast("Не получилось купить")
				_rebuild_popup(), Vector2(64, 44))
			b.disabled = why != ""
			row.add_child(b)
		popup_body.add_child(row)


func _build_production(w: World, me: int) -> void:
	if _prod_page == "trade":
		_build_trade(w, me)
		return
	if _prod_page == "lands":
		_build_lands(w, me)
		return
	popup_title.text = "Производство"
	var n: World.Nation = w.nations[me]
	_prod_pages()
	_dynamic["prod"] = _label("", 17)
	popup_body.add_child(_dynamic["prod"])
	popup_body.add_child(_small("Военный завод даёт %s очка в день × эффективность линии. Новая линия начинает с %d%% и растёт к потолку %d%% (технологии «Производства» поднимают его); завод, переведённый на другое снаряжение, сохраняет %d%% своей эффективности." % [
		("%.1f" % Military.FACTORY_PTS).replace(".", ","), roundi(Military.EFF_START * 100.0), roundi(Military.eff_cap(n) * 100.0), roundi(Military.EFF_KEEP * 100.0)]))
	var auto := _button("Автораспределение: %s" % ("да" if n.prod_auto else "нет"), func():
		n.prod_auto = not n.prod_auto
		if n.prod_auto:
			n.prod_split = []   # пересмотр — в ближайший день
		_rebuild_popup(), Vector2(0, 50))
	popup_body.add_child(auto)
	popup_body.add_child(_small("Автоматически — раз в месяц, как у ИИ: сначала пополнение и пехотное снаряжение новых дивизий, затем техника, затем запас; излишек — в авиацию и флот. Ручная правка линии выключает автоматику."))
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
		var rm := Economy.line_mult(n, k)
		var l := _label("%s\nзаводов %d · эфф. %d%% · +%s/день · склад %d · не хватает %d%s" % [
			Military.EQ_NAMES[k], f, eff * 100.0, ("%d" % roundi(n.daily_output[k])) if n.daily_output[k] >= 10.0 else ("%.1f" % n.daily_output[k]), n.stock[k], need[k],
			(" · ресурсы %d%%" % roundi(rm * 100.0)) if rm < 0.999 else ""], 16)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var kk := k
		row.add_child(_button("−", func():
			n.prod_auto = false
			Military.change_line(n, kk, -1)
			_rebuild_popup(), Vector2(52, 48)))
		row.add_child(_button("+", func():
			n.prod_auto = false
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
			if not _dynamic.has("army"):
				return   # открыт конструктор шаблонов
			var next := ""
			if not n.training.is_empty():
				var m := 9999
				for e in n.training:
					m = mini(m, int(e[0]))
				next = " (ближайшая через %d дн.)" % m
			_dynamic["army"].text = "Дивизий: %d · в подготовке: %d%s · людей в резерве: %dк" % [
				n.division_count, n.training.size(), next, n.manpower]
		"production":
			if not _dynamic.has("prod"):
				return   # страница внешней экономики
			var used := Military.assigned_factories(n)
			_dynamic["prod"].text = "Военных заводов: %d · на линиях: %d · свободно: %d" % [n.mil, used, n.mil - used]
		"build":
			var rate := n.civ * Simulation.BUILD_RATE * (1.0 + n.b("construction"))
			_dynamic["build"].text = "Фабрики: %d гражданских, %d военных\nСледующая: %s, %d%% (+%.1f/день)" % [
				n.civ, n.mil, "гражданская" if n.build_mode == "civ" else "военная",
				n.build_progress / Simulation.FACTORY_COST * 100.0, rate]
			_dynamic["bar"].max_value = Simulation.FACTORY_COST
			_dynamic["bar"].value = n.build_progress


# --- Меню партии: сохранение и загрузка ---------------------------------------

var _confirm := ""        # действие, ждущее второго нажатия (перезапись, удаление, загрузка)
var _save_title := ""


## Кнопка «‹ Меню» на страницах папки (в партии).
func _menu_back() -> void:
	if game.state != "play":
		return
	var b := _button("‹ Меню", func(): open_tab("menu"), Vector2(0, 40))
	b.add_theme_font_size_override("font_size", 15)
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	popup_body.add_child(b)


func _build_menu(w: World) -> void:
	popup_title.text = "Меню"
	var me: int = game.player()
	if me >= 0:
		popup_body.add_child(_label("%s · %s" % [w.nations[me].name, w.date_string()], 20))
	popup_body.add_child(_button("Сохранить игру", func(): open_tab("save")))
	popup_body.add_child(_button("Загрузить игру", func(): open_tab("load")))
	popup_body.add_child(_button("Настройки", func(): open_tab("settings")))
	popup_body.add_child(_button("Выйти в главное меню", func(): game.to_menu()))
	if game.autosave_on:
		popup_body.add_child(_small("При выходе партия записывается в автосохранение. Оно же обновляется каждые 5 минут игры и когда игру сворачивают."))
	else:
		popup_body.add_child(_small("Автосохранение выключено в настройках: перед выходом сохраните партию сами."))


static func _save_when(m: Dictionary) -> String:
	var t := int(m.get("time", 0)) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(t)
	return "%02d.%02d.%d %02d:%02d" % [d["day"], d["month"], d["year"], d["hour"], d["minute"]]


## Строка сохранения: название, страна и дата партии, когда записано.
func _save_row(m: Dictionary) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var fl: Variant = m.get("flag", {})
	if typeof(fl) == TYPE_DICTIONARY and not (fl as Dictionary).is_empty():
		var flag := Flag.make(fl, Vector2(36, 24))
		flag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(flag)
	var title := _label(str(m.get("title", m["name"])), 20)
	title.add_theme_font_override("font", UiStyle.mono_bold())
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	box.add_child(head)
	box.add_child(_small("%s · %s%s" % [m.get("nation", "?"), m.get("date", ""),
		"" if bool(m.get("historical", true)) else " · альтернативная история"]))
	box.add_child(_small("записано %s · %d КБ" % [_save_when(m), int(m.get("size", 0)) / 1024]))
	return box


func _build_save(w: World) -> void:
	popup_title.text = "Сохранить игру"
	_menu_back()
	var me: int = game.player()
	if game.state != "play" or me < 0:
		popup_body.add_child(_label("Сохранять можно только идущую партию.", 18))
		return
	if _save_title == "":
		_save_title = "%s, %s" % [w.nations[me].name, w.date_short()]
	popup_body.add_child(_label("Название", 20))
	var edit := LineEdit.new()
	edit.text = _save_title
	edit.max_length = 40
	edit.custom_minimum_size = Vector2(0, 48)
	edit.text_changed.connect(func(t: String): _save_title = t)
	popup_body.add_child(edit)
	popup_body.add_child(_button("Сохранить", func(): _do_save(_save_title)))
	var saves := SaveGame.list()
	var shown := false
	for m in saves:
		if bool(m.get("auto", false)):
			continue
		if not shown:
			popup_body.add_child(_section("Записать поверх"))
			shown = true
		popup_body.add_child(_save_row(m))
		var title: String = str(m.get("title", m["name"]))
		var key := "save:" + SaveGame.safe_name(title)
		var b := _button("Точно перезаписать?" if _confirm == key else "Перезаписать", func(): _do_save(title), Vector2(0, 44))
		b.add_theme_font_size_override("font_size", 16)
		popup_body.add_child(b)


func _do_save(title: String) -> void:
	var name := SaveGame.safe_name(title)
	if name == "" or name == SaveGame.AUTO:
		toast("Введите название сохранения")
		return
	var key := "save:" + name
	if FileAccess.file_exists(SaveGame.path_of(name)) and _confirm != key:
		_confirm = key
		toast("«%s» уже есть — нажмите ещё раз, чтобы перезаписать" % title)
		_rebuild_popup()
		return
	_confirm = ""
	var err: String = game.save_game(name, title.strip_edges())
	if err == "":
		toast("Игра сохранена: «%s»" % title.strip_edges())
		_save_title = ""
	else:
		toast("Не удалось сохранить: " + err)
	_rebuild_popup()


func _build_load() -> void:
	popup_title.text = "Загрузить игру"
	_menu_back()
	var saves := SaveGame.list()
	if saves.is_empty():
		popup_body.add_child(_label("Сохранений пока нет.", 18))
		return
	var playing: bool = game.state == "play"
	for m in saves:
		var nm: String = m["name"]
		popup_body.add_child(_save_row(m))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lkey := "load:" + nm
		var lb := _button("Загрузить? Несохранённое пропадёт" if _confirm == lkey else "Загрузить", func():
			if playing and _confirm != lkey:
				_confirm = lkey
				_rebuild_popup()
				return
			_confirm = ""
			game.load_game(nm), Vector2(0, 44))
		lb.add_theme_font_size_override("font_size", 16)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lb)
		var dkey := "del:" + nm
		var db := _button("Точно удалить?" if _confirm == dkey else "Удалить", func():
			if _confirm != dkey:
				_confirm = dkey
			else:
				_confirm = ""
				SaveGame.remove(nm)
				toast("Сохранение удалено")
			_rebuild_popup(), Vector2(0, 44))
		db.add_theme_font_size_override("font_size", 16)
		row.add_child(db)
		popup_body.add_child(row)


func _build_settings() -> void:
	popup_title.text = "Настройки"
	_menu_back()
	var au := CheckButton.new()
	au.text = "Автосохранение"
	au.button_pressed = Settings.autosave()
	au.toggled.connect(func(v: bool):
		Settings.set_autosave(v)
		game.autosave_on = v)
	popup_body.add_child(au)
	popup_body.add_child(_label("Каждые 5 минут игры, при выходе в меню и когда игру сворачивают — в одну запись «Автосохранение».", 15, Color(0.75, 0.75, 0.7)))
	popup_body.add_child(_label("Качество карты", 20))
	popup_body.add_child(_label("Высокое — самые плавные границы. Среднее — плавный берег и простые границы, легче для телефона. Низкое — без сглаживания, для слабых устройств. Число кадров — внизу экрана (FPS).", 15, Color(0.75, 0.75, 0.7)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var cur := Settings.map_quality()
	for q in 3:
		var qq := q
		var b := _button(Settings.QUALITY_NAMES[q], func():
			Settings.set_map_quality(qq)
			game.map_view.set_quality(qq)
			_rebuild_popup(), Vector2(0, 52))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.set_pressed_no_signal(q == cur)   # выбранное — «нажатая» латунная кнопка
		row.add_child(b)
	popup_body.add_child(row)
	popup_body.add_child(_label("Разрешение карты", 20))
	popup_body.add_child(_label("Ниже разрешение — быстрее сдвиг и масштаб на слабом телефоне; границы чуть мягче, надписи и фишки остаются чёткими. «Авто» подбирает разрешение по скорости видеокарты.", 15, Color(0.75, 0.75, 0.7)))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	var cur_r := Settings.map_res()
	for r in 4:
		var rr := r
		var b2 := _button(Settings.RES_NAMES[r], func():
			Settings.set_map_res(rr)
			game.map_view.set_res_scale(Settings.RES_SCALES[rr])
			_rebuild_popup(), Vector2(0, 52))
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.toggle_mode = true
		b2.set_pressed_no_signal(r == cur_r)
		row2.add_child(b2)
	popup_body.add_child(row2)
	popup_body.add_child(_label("Ограничение кадров", 20))
	popup_body.add_child(_label("На экранах 90–120 Гц лишние кадры только греют телефон и вызывают замедление от перегрева.", 15, Color(0.75, 0.75, 0.7)))
	var row3 := HBoxContainer.new()
	row3.add_theme_constant_override("separation", 8)
	var cur_f := Settings.fps_cap()
	for f in 3:
		var ff := f
		var b3 := _button(Settings.FPS_NAMES[f], func():
			Settings.set_fps_cap(ff)
			_rebuild_popup(), Vector2(0, 52))
		b3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b3.toggle_mode = true
		b3.set_pressed_no_signal(f == cur_f)
		row3.add_child(b3)
	popup_body.add_child(row3)
	var lite := CheckButton.new()
	lite.text = "Упрощать карту при сдвиге и масштабе"
	lite.button_pressed = Settings.motion_lite()
	lite.toggled.connect(func(v: bool):
		Settings.set_motion_lite(v)
		game.map_view.motion_lite = v)
	popup_body.add_child(lite)
	popup_body.add_child(_label("Пока карту двигают, она рисуется упрощённо и плавно переходит в выбранное качество после остановки.", 15, Color(0.75, 0.75, 0.7)))
	var snd := CheckButton.new()
	snd.text = "Звук нажатия кнопок"
	snd.button_pressed = Settings.ui_sound()
	snd.toggled.connect(func(v: bool): Settings.set_ui_sound(v))
	popup_body.add_child(snd)
	var pf := CheckButton.new()
	pf.text = "Строка замеров (FPS, тик) внизу экрана"
	pf.button_pressed = Settings.show_perf()
	pf.toggled.connect(func(v: bool):
		Settings.set_show_perf(v)
		perf_label.visible = v)
	popup_body.add_child(pf)
	popup_body.add_child(_label("Отчёт для разработки", 20))
	popup_body.add_child(_label("Телефон, видеокарта, настройки, замеры за последние 30 секунд и ошибки из журнала (после вылета — и причина). Вставьте его в чат одним сообщением.", 15, Color(0.75, 0.75, 0.7)))
	popup_body.add_child(_button("Скопировать отчёт", func():
		DisplayServer.clipboard_set(Report.build(game))
		toast("Отчёт скопирован в буфер обмена"), Vector2(0, 52)))
