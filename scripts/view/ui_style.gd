class_name UiStyle
extends RefCounted
## Оформление интерфейса: шрифты (Google Fonts, лицензия OFL — assets/fonts/)
## и тема «штабной документ 1930-х»: тёмные панели с латунной окантовкой,
## кнопки с плакатным шрифтом Oswald, окна событий — на «бумаге».

const BRASS := Color(0.74, 0.61, 0.36)
const BRASS_DIM := Color(0.50, 0.42, 0.27)
const INK := Color(0.16, 0.13, 0.10)
const INK_SOFT := Color(0.32, 0.26, 0.19)
const RED_INK := Color(0.60, 0.13, 0.10)
const CREAM := Color(0.94, 0.90, 0.80)
const PAPER := Color(0.89, 0.84, 0.72)

static var _fonts := {}


static func _font(path: String) -> Font:
	if not _fonts.has(path):
		var f: Font = load(path) if ResourceLoader.exists(path) else ThemeDB.fallback_font
		_fonts[path] = f
	return _fonts[path]


## Основной текст: PT Sans.
static func text_font() -> Font:
	return _font("res://assets/fonts/PTSans-Regular.ttf")


static func bold_font() -> Font:
	return _font("res://assets/fonts/PTSans-Bold.ttf")


## Тексты событий и фокусов: PT Serif.
static func serif_font() -> Font:
	return _font("res://assets/fonts/PTSerif-Regular.ttf")


## Заголовки и кнопки: Oswald (переменный шрифт), жирность weight.
static func title_font(weight: int = 500, spacing: int = 0) -> Font:
	var key := "oswald_%d_%d" % [weight, spacing]
	if not _fonts.has(key):
		var base := _font("res://assets/fonts/Oswald.ttf")
		var fv := FontVariation.new()
		fv.base_font = base
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		fv.spacing_glyph = spacing
		_fonts[key] = fv
	return _fonts[key]


static func _box(bg: Color, border: Color, width: int = 2, radius: int = 3, margin: int = 8) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(width)
	b.set_corner_radius_all(radius)
	b.set_content_margin_all(margin)
	b.anti_aliasing = true
	b.corner_detail = 10
	return b


static func make_theme() -> Theme:
	# «Досье и архив»: кнопки — бумажные карточки, окна — листы в папках,
	# текст — машинопись (IBM Plex Mono) тёмными чернилами (assets/ui, tools/build_ui.py)
	var t := Theme.new()
	t.default_font = mono_font()
	t.default_font_size = 19
	var sheet := sbox("sheet.png", 46, 26)
	t.set_stylebox("panel", "PanelContainer", sheet)
	t.set_stylebox("panel", "Panel", sheet)
	var card := sbox("card.png", 8, 10)
	card.content_margin_left = 16
	card.content_margin_right = 16
	var hover := card.duplicate()
	hover.modulate_color = Color(1.05, 1.03, 0.97)
	var pressed := sbox("card_pressed.png", 8, 10)
	pressed.content_margin_left = 16
	pressed.content_margin_right = 16
	var disabled := card.duplicate()
	disabled.modulate_color = Color(0.85, 0.82, 0.76, 0.65)
	for cls in ["Button", "CheckButton", "OptionButton"]:
		t.set_stylebox("normal", cls, card)
		t.set_stylebox("hover", cls, hover)
		t.set_stylebox("pressed", cls, pressed)
		t.set_stylebox("hover_pressed", cls, pressed)
		t.set_stylebox("disabled", cls, disabled)
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_font("font", cls, mono_bold())
		t.set_color("font_color", cls, INK)
		t.set_color("font_hover_color", cls, Color(0.05, 0.04, 0.03))
		t.set_color("font_pressed_color", cls, RED_INK)
		t.set_color("font_hover_pressed_color", cls, RED_INK)
		t.set_color("font_disabled_color", cls, Color(0.35, 0.30, 0.24, 0.7))
		t.set_color("icon_normal_color", cls, INK)
		t.set_color("icon_hover_color", cls, Color(0.05, 0.04, 0.03))
		t.set_color("icon_pressed_color", cls, RED_INK)
	t.set_constant("icon_max_width", "Button", 26)
	t.set_constant("h_separation", "Button", 8)
	t.set_color("font_color", "Label", INK)
	t.set_font("font", "Label", mono_font())
	var bar_bg := _box(Color(0.30, 0.24, 0.17, 0.35), Color(0.25, 0.19, 0.12, 0.8), 1, 2, 0)
	var bar_fill := _box(Color(0.52, 0.16, 0.12), Color(0.52, 0.16, 0.12), 0, 2, 0)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)
	t.set_color("font_color", "ProgressBar", INK)
	var grab := _box(Color(0.42, 0.32, 0.22, 0.7), Color(0, 0, 0, 0), 0, 3, 0)
	var scroll := _box(Color(0, 0, 0, 0.08), Color(0, 0, 0, 0), 0, 3, 0)
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, scroll)
		t.set_stylebox("grabber", sb, grab)
		t.set_stylebox("grabber_highlight", sb, _box(Color(0.42, 0.32, 0.22), Color(0, 0, 0, 0), 0, 3, 0))
		t.set_stylebox("grabber_pressed", sb, _box(Color(0.30, 0.22, 0.14), Color(0, 0, 0, 0), 0, 3, 0))
	return t


## Тема окон событий — та же бумага (раньше была отдельной).
static func paper_theme() -> Theme:
	return make_theme()


# --- текстуры интерфейса (assets/ui) -------------------------------------------

static var _ui := {}


static func ui_tex(name: String) -> Texture2D:
	if not _ui.has(name):
		var p := "res://assets/ui/" + name
		_ui[name] = load(p) if ResourceLoader.exists(p) else null
	return _ui[name]


## Растягиваемая по 9 частям текстура: margin — неизменные края, pad — отступ
## содержимого.
static func sbox(name: String, margin: int, pad: int) -> StyleBoxTexture:
	var b := StyleBoxTexture.new()
	b.texture = ui_tex(name)
	b.set_texture_margin_all(margin)
	b.set_content_margin_all(pad)
	return b


## Машинопись: IBM Plex Mono (OFL).
static func mono_font() -> Font:
	return _font("res://assets/fonts/IBMPlexMono-Regular.ttf")


static func mono_bold() -> Font:
	return _font("res://assets/fonts/IBMPlexMono-SemiBold.ttf")


## Цвет текста для бумаги: светлые цвета прежней тёмной темы → чернила.
static func ink(c: Color) -> Color:
	if c.get_luminance() < 0.5:
		return c
	if c.s < 0.25:
		return INK if c.v > 0.85 else INK_SOFT
	return Color.from_hsv(c.h, minf(1.0, c.s + 0.25), 0.42)


## Заголовок: Oswald, крупно, с разрядкой.
static func title(l: Label, size: int = 24) -> void:
	l.add_theme_font_override("font", title_font(600, 1))
	l.add_theme_font_size_override("font_size", size)


# --- Иконки (game-icons.net, CC BY 3.0; assets/icons/icons.json) -------------

static var _icon_svg := {}
static var _icon_tex := {}


## Белая иконка name размером px×px (перекрашивается через modulate/цвет рисования).
## null — если иконки нет.
## Иконка картинкой (RGBA, белая) — для сборки атласов; null, если нет.
static func icon_image(name: String, px: int = 64) -> Image:
	icon(name, px)   # загрузит набор SVG
	if not _icon_svg.has(name):
		return null
	var img := Image.new()
	if img.load_svg_from_string(_icon_svg[name], px / 512.0) != OK:
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


static func icon(name: String, px: int = 64) -> Texture2D:
	var key := "%s@%d" % [name, px]
	if _icon_tex.has(key):
		return _icon_tex[key]
	if _icon_svg.is_empty():
		var path := "res://assets/icons/icons.json"
		if FileAccess.file_exists(path):
			var d = JSON.parse_string(FileAccess.get_file_as_string(path))
			if typeof(d) == TYPE_DICTIONARY:
				_icon_svg = d.get("icons", {})
	var tex: Texture2D = null
	if _icon_svg.has(name):
		var img := Image.new()
		if img.load_svg_from_string(_icon_svg[name], px / 512.0) == OK:
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	_icon_tex[key] = tex
	return tex


# --- Портреты и картинки событий (tools/build_portraits.py, лицензии —
# assets/art_credits.json) -------------------------------------------------

static var _art := {}


static func _art_tex(path: String) -> Texture2D:
	if _art.has(path):
		return _art[path]
	var t: Texture2D = load(path) if ResourceLoader.exists(path) else null
	_art[path] = t
	return t


## Портрет лидера страны по тегу (null — нет).
static func portrait(tag: String) -> Texture2D:
	return _art_tex("res://assets/portraits/%s.jpg" % tag)


## Картинка события по id (null — нет).
static func event_art(id: String) -> Texture2D:
	return _art_tex("res://assets/events/%s.jpg" % id)


## Картинка в рамке: латунная рамка на тёмной подложке (или тёмная — на бумаге).
static func framed(tex: Texture2D, size: Vector2, on_paper := false) -> Control:
	var frame := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.08, 0.06)
	sb.border_color = INK if on_paper else BRASS
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.anti_aliasing = true
	sb.set_content_margin_all(2)
	frame.add_theme_stylebox_override("panel", sb)
	var r := TextureRect.new()
	r.texture = tex
	r.custom_minimum_size = size
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	frame.add_child(r)
	frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return frame
