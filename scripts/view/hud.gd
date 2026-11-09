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
	# действия игрока меняют мир — выполняем под блокировкой (ждём конца дня)
	# отложенно (в конце кадра): действие часто пересобирает окно и удаляет саму
	# кнопку — посреди обработки нажатия это давало ошибки «!is_inside_tree()»
	b.pressed.connect(func():
		if game != null:
			game.world_lock()
		cb.call()
		if game != null:
			game.world_unlock(), CONNECT_DEFERRED)
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
	var rw := rf.get_string_size(res_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x + 34.0
	rw = minf(rw, x0 - dw - 24.0 - 16.0 - rx)
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
			focus_view.open(game, game.world, game.player())],
		["army", func(): open_tab("army")],
		["navy", func(): open_tab("navy")],
		["production", func(): open_tab("production")],
		["research", func(): open_tab("research")],
		["build", func(): open_tab("build")],
		["diplomacy", func(): open_tab("diplomacy")],
		["all", func(): game.select_all()],
		["mapmode", _cycle_map_mode],
		["settings", func(): open_tab("settings")],
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
	"nations": "Выбор страны", "nation": "Досье страны", "peace": "Мирный договор"}
const TAB_NUM := {"army": 2, "navy": 3, "production": 4, "research": 5, "build": 6, "diplomacy": 7,
	"nation": 7, "settings": 10, "nations": 1, "peace": 7}


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
	if w != null and nid >= 0 and nid < w.nations.size():
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
	nation_label.text = n.name.to_upper()
	date_label.text = w.date_string()
	res_label.text = "Винт. %d  Ору. %d  Танки %d  Груз. %d  Люди %dк  Див. %d" % [
		n.stock[0], n.stock[1], n.stock[2], n.stock[3], n.manpower, n.division_count]
	var key := nation_label.text + "|" + date_label.text + "|" + res_label.text
	if key != _tb_key:
		_tb_key = key
		_layout_top()
	for i in speed_buttons.size():
		speed_buttons[i].button_pressed = game.speed == i
	var phases := ""
	for k in game.sim.phase_usec:
		phases += " %s %.1f" % [k, game.sim.phase_usec[k] / 1000.0]
	if OS.has_feature("mobile"):
		phases = ""   # на телефоне без фаз — они закрывали бы карту
	var gpu: Vector2 = game.map_view.gpu_ms()
	if gpu.x <= 0.0:
		gpu.x = game.map_view.last_cost_ms   # OpenGL ES: оценка по времени кадра
	Report.sample(Engine.get_frames_per_second(), game.sim.last_tick_usec / 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, game.unit_layer.draw_usec / 1000.0,
		gpu.x, game.days_per_sec)
	phases += "\nкадр: логика %.1f · фишки %.1f · ГП карта %.1f (%d%%) · ГП экран %.1f мс · карта %d раз/с\nдень (макс. за с): панели %.1f · палитра %.1f · список %.1f · строка %.1f мс" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, game.unit_layer.draw_usec / 1000.0,
		gpu.x, int(game.map_view.res_scale * 100), gpu.y, _redraw_rate(), game.ui_prof[0] / 1000.0, game.ui_prof[1] / 1000.0,
		game.ui_prof[2] / 1000.0, game.ui_prof[3] / 1000.0]
	perf_label.text = "%s\n%d FPS · %s · ядер %d · %.1f дн/с · тик %.2f мс" % [phases.strip_edges(), Engine.get_frames_per_second(), "C++" if Native.available() else "GDScript", Parallel.thread_count(), game.days_per_sec, game.sim.last_tick_usec / 1000.0]
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
	var s := "%s\n%s · %s" % [w.p_name[p], World.TERRAIN_NAMES[w.p_terrain[p]], own.name]
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
	_info_text(_province_text(p))
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
	for d in divs:
		s += d.strength
		sup += d.supply
		if d.in_battle:
			fights += 1
	var n := maxi(1, divs.size())
	var order := "держит фронт" if g.mode == "hold" else "наступает"
	if g.mode == "attack" and g.objective >= 0:
		order += " · цель: %s" % w.p_name[g.objective]
	_info_text("%s · %d %s\n%s · сила %d%%\nСнабжение %d%% · в бою %d" % [
		g.name, divs.size(), _plural(divs.size(), "дивизия", "дивизии", "дивизий"), order[0].to_upper() + order.substr(1),
		s / n, sup / n * 100.0, fights])


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
	for d in sel:
		s += d.strength
		o += d.org / maxf(1.0, d.max_org)
		if not d.path.is_empty():
			moving += 1
		if d.in_battle:
			fighting += 1
	_info_text("Выбрано: %d %s\nСила %d%% · организация %d%% · в пути %d · в бою %d\nКоснитесь провинции, чтобы отправить войска. Вражеская провинция — атака." % [
		sel.size(), _plural(sel.size(), "дивизия", "дивизии", "дивизий"), s / sel.size(), o / sel.size() * 100.0, moving, fighting])


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
	var was_open := popup.visible
	var same_mode := was_open and ((popup_tab == "event") == (tab == "event"))
	popup_tab = tab
	var clipboard := tab == "event"
	_layout_popup(clipboard)
	_rebuild_popup()
	popup.show()
	if not clipboard:
		_fill_cover()
		popup_cover.show()
	_set_side_active(tab)
	if not same_mode:
		_animate_open(clipboard)
	log_box.hide()
	if tab == "nations":
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
		"settings":
			_build_settings()
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
	# угрозы нацизма и коммунизма: по 20 очков за армию, экономику, науку, союз и агрессию
	for ideo in Relations.THREATS:
		var tt := Relations.threat_text(w, ideo)
		if tt != "":
			popup_body.add_child(_small(tt))
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
		info += "\nМарионетка страны %s" % w.nations[o.overlord].name
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
	_info_text("%s\n%s · сила %d · готовность %d%%\n%s · %s%s\nКоснитесь моря (или берега), чтобы отправить флот. Готовность восстанавливается на базе." % [
		f.name, _ships_text(f), Forces.fleet_power(f), f.readiness * 100.0, w.p_name[f.zone], MISSION_NAMES.get(f.mission, f.mission),
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


func _build_settings() -> void:
	popup_title.text = "Настройки"
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
