class_name UiStyle
extends RefCounted
## Оформление интерфейса: шрифты (Google Fonts, лицензия OFL — assets/fonts/)
## и тема «штабной документ 1930-х»: тёмные панели с латунной окантовкой,
## кнопки с плакатным шрифтом Oswald, окна событий — на «бумаге».

const BRASS := Color(0.74, 0.61, 0.36)
const BRASS_DIM := Color(0.50, 0.42, 0.27)
const INK := Color(0.16, 0.13, 0.10)
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
	var t := Theme.new()
	t.default_font = text_font()
	t.default_font_size = 20
	var panel := _box(Color(0.095, 0.10, 0.085, 0.94), BRASS_DIM, 2, 10, 10)
	panel.shadow_color = Color(0, 0, 0, 0.45)
	panel.shadow_size = 6
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)
	var btn := _box(Color(0.19, 0.19, 0.15), BRASS_DIM, 2, 8, 8)
	btn.border_width_bottom = 3
	var hover := _box(Color(0.27, 0.26, 0.20), BRASS, 2, 8, 8)
	hover.border_width_bottom = 3
	var pressed := _box(Color(0.60, 0.48, 0.25), BRASS, 2, 8, 8)
	var disabled := _box(Color(0.14, 0.14, 0.13), Color(0.30, 0.29, 0.26), 2, 8, 8)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_font("font", "Button", title_font(500, 1))
	t.set_color("font_color", "Button", CREAM)
	t.set_color("font_hover_color", "Button", Color(1, 0.96, 0.86))
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", Color(0.48, 0.47, 0.44))
	t.set_color("icon_normal_color", "Button", BRASS)
	t.set_color("icon_hover_color", "Button", Color(1, 0.86, 0.55))
	t.set_color("icon_pressed_color", "Button", INK)
	t.set_constant("icon_max_width", "Button", 26)
	t.set_constant("h_separation", "Button", 8)
	t.set_color("font_color", "Label", CREAM)
	var bar_bg := _box(Color(0.04, 0.04, 0.035), Color(0.3, 0.26, 0.18), 1, 5, 0)
	var bar_fill := _box(BRASS, BRASS, 0, 5, 0)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)
	# прокрутка — тонкая латунная
	var grab := _box(BRASS_DIM, BRASS_DIM, 0, 3, 0)
	var scroll := _box(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 3, 0)
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, scroll)
		t.set_stylebox("grabber", sb, grab)
		t.set_stylebox("grabber_highlight", sb, _box(BRASS, BRASS, 0, 3, 0))
		t.set_stylebox("grabber_pressed", sb, _box(BRASS, BRASS, 0, 3, 0))
	return t


## «Бумажная» панель для окон событий: светлая, текст тёмный, шрифт с засечками.
static func paper_theme() -> Theme:
	var t := make_theme()
	var paper := _box(PAPER, Color(0.42, 0.33, 0.20), 3, 10, 14)
	paper.shadow_color = Color(0, 0, 0, 0.55)
	paper.shadow_size = 10
	t.set_stylebox("panel", "PanelContainer", paper)
	t.set_color("font_color", "Label", INK)
	t.set_font("font", "Label", serif_font())
	return t


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
