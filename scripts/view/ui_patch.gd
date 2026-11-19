class_name UiPatch
## Сверка окна: новое окно собирается вне дерева (дёшево, ~15 мкс на узел),
## потом переносится в уже стоящее на экране. Совпавший по классу узел
## остаётся, у него меняются только отличия и переезжают нажатия; новые узлы
## вставляются, лишние удаляются. Новая подпись при входе в дерево стоит
## ~0,3 мс (тема, шрифт, раскладка текста), правка текста у стоящей — ~0,04 мс:
## повторное открытие и пересборка окна после нажатия — в разы дешевле (`ui.md`).
##
## Ограничения для кода окон: лямбды не держат ссылок на узлы окна (узлы новой
## сборки, совпавшие со старыми, удаляются); ссылки на узлы, нужные после
## сборки, — перенаправить по карте, которую возвращает patch (как `_dynamic`).

## Сигналы, которые подключает код окон (внутренние подключения движка —
## контейнеры к детям — не трогаем). Сверка смотрит только сигналы класса из
## SIG_OF (просмотр всех стоил ~17 мкс на узел); проверка — все из SIGNALS.
const SIGNALS := ["pressed", "toggled", "text_changed", "text_submitted", "value_changed",
	"mouse_entered", "mouse_exited", "gui_input", "item_selected", "draw", "button_down", "button_up"]
const SIG_OF := {"BaseButton": ["pressed", "toggled"], "LineEdit": ["text_changed", "text_submitted"],
	"Range": ["value_changed"]}
## Раскладку в контейнере ставит сам контейнер — не переносить.
const LAYOUT := {"position": true, "size": true, "global_position": true,
	"offset_left": true, "offset_top": true, "offset_right": true, "offset_bottom": true,
	"anchor_left": true, "anchor_top": true, "anchor_right": true, "anchor_bottom": true,
	"anchors_preset": true, "layout_mode": true, "rotation": true, "scale": true,
	"pivot_offset": true, "grow_horizontal": true, "grow_vertical": true}
const SKIP := {"name": true, "script": true, "unique_name_in_owner": true, "owner": true,
	"scene_file_path": true, "button_pressed": true, "scroll_horizontal": true,
	"scroll_vertical": true}
## Замены темы, которые ставит код окон (прямыми вызовами: через имя свойства
## «theme_override_…» — разбор строки на каждый узел).
const T_COLOR := [&"font_color", &"font_disabled_color", &"font_outline_color"]
const T_CONST := [&"separation", &"h_separation", &"v_separation", &"outline_size", &"line_spacing",
	&"margin_left", &"margin_top", &"margin_right", &"margin_bottom", &"icon_max_width"]
const T_FONT := [&"font"]
const T_FSIZE := [&"font_size"]
const T_STYLE := [&"panel"]

static var _props := {}   # класс → имена свойств для сверки
static var stats := [0, 0, 0]   # сверено узлов, вставлено, изменено свойств


## Перенести детей src в dst. Возвращает карту «узел src → узел dst» для
## совпавших узлов (src и оставшиеся в нём узлы потом удаляет вызывающий).
static func patch(dst: Node, src: Node) -> Dictionary:
	var map := {}
	_patch(dst, src, map)
	return map


static func _patch(dst: Node, src: Node, map: Dictionary) -> void:
	var kids := src.get_children()
	var i := 0
	for s in kids:
		var d: Node = dst.get_child(i) if i < dst.get_child_count() else null
		if d != null and d.get_class() == s.get_class() and d.get_script() == s.get_script():
			_copy(d, s, dst is Container)
			_patch(d, s, map)
			map[s] = d
			stats[0] += 1
		else:
			src.remove_child(s)
			if d != null:
				dst.remove_child(d)
				d.queue_free()
			dst.add_child(s)
			dst.move_child(s, i)
			stats[1] += 1
		i += 1
	while dst.get_child_count() > i:
		var d := dst.get_child(i)
		dst.remove_child(d)
		d.queue_free()


## Свойства, которые задаёт код окон (сверка — только их: полный список ~100
## свойств на узел стоил ~85 мкс). Пропуск ловит проверка `--patchtest`: она
## сравнивает все сохраняемые свойства (_all).
const COPY := ["visible", "modulate", "self_modulate", "custom_minimum_size",
	"size_flags_horizontal", "size_flags_vertical", "size_flags_stretch_ratio", "mouse_filter",
	"tooltip_text", "clip_contents", "theme_type_variation", "theme", "pivot_offset",
	"texture_filter", "grow_horizontal", "grow_vertical",
	"position", "size", "rotation", "scale",
	"offset_left", "offset_top", "offset_right", "offset_bottom",
	"anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
	"text", "horizontal_alignment", "vertical_alignment", "autowrap_mode", "clip_text",
	"text_overrun_behavior",
	"icon", "disabled", "alignment", "flat", "toggle_mode", "expand_icon", "icon_alignment",
	"vertical_icon_alignment", "action_mode", "button_group",
	"texture_normal", "texture_pressed", "texture_hover", "texture_disabled", "texture_focused",
	"ignore_texture_size", "texture", "expand_mode", "stretch_mode", "flip_h", "flip_v",
	"region_rect", "patch_margin_left", "patch_margin_top", "patch_margin_right", "patch_margin_bottom",
	"axis_stretch_horizontal", "axis_stretch_vertical", "draw_center", "color",
	"min_value", "max_value", "value", "step", "show_percentage", "fill_mode", "rounded",
	"placeholder_text", "max_length", "editable", "secret", "vertical", "columns",
	"horizontal_scroll_mode", "vertical_scroll_mode", "bbcode_enabled", "fit_content", "scroll_active"]
static var _copy_set := {}
static var _all := {}


## [свойства в контейнере, свойства вне контейнера, сигналы] для класса узла.
static func _meta(n: Node) -> Array:
	var key := n.get_class()
	if _props.has(key):
		return _props[key]
	if _copy_set.is_empty():
		for nm in COPY:
			_copy_set[nm] = true
	var box: Array = []
	var free: Array = []
	for p in n.get_property_list():
		var nm: String = p["name"]
		if _copy_set.has(nm):
			free.append(StringName(nm))
			if not LAYOUT.has(nm):
				box.append(StringName(nm))
	var sig: Array = []
	for base in SIG_OF:
		if n.is_class(base):
			sig.append_array(SIG_OF[base])
	# замены темы — только те, что есть у класса в теме по умолчанию
	var th := ThemeDB.get_default_theme()
	var tc: Array = []
	var tk: Array = []
	var tf: Array = []
	var tz: Array = []
	var ts: Array = []
	var cls := key
	while cls != "" and cls != "Node":
		for nm in T_COLOR:
			if th.has_color(nm, cls) and not tc.has(nm):
				tc.append(nm)
		for nm in T_CONST:
			if th.has_constant(nm, cls) and not tk.has(nm):
				tk.append(nm)
		for nm in T_FONT:
			if th.has_font(nm, cls) and not tf.has(nm):
				tf.append(nm)
		for nm in T_FSIZE:
			if th.has_font_size(nm, cls) and not tz.has(nm):
				tz.append(nm)
		for nm in T_STYLE:
			if th.has_stylebox(nm, cls) and not ts.has(nm):
				ts.append(nm)
		cls = ClassDB.get_parent_class(cls)
	_props[key] = [box, free, sig, tc, tk, tf, tz, ts]
	return _props[key]


## Все сохраняемые свойства и все замены темы — для проверки.
static func _all_names(n: Node) -> Array:
	var key := n.get_class()
	if _all.has(key):
		return _all[key]
	var out: Array = []
	for p in n.get_property_list():
		var nm: String = p["name"]
		if SKIP.has(nm) or nm.begins_with("metadata/"):
			continue
		if nm.begins_with("theme_override_") or (int(p["usage"]) & PROPERTY_USAGE_STORAGE):
			out.append(StringName(nm))
	_all[key] = out
	return out


static func _copy(d: Node, s: Node, in_box: bool) -> void:
	var m: Array = _meta(s)
	var sig: Array = m[2]
	# старые нажатия — снять до правки свойств (переключатель не дёрнет старую лямбду)
	for sg in sig:
		for c in d.get_signal_connection_list(sg):
			var cb: Callable = c["callable"]
			if cb.get_method() != "_play_click":
				d.disconnect(sg, cb)
	for nm in m[0] if in_box else m[1]:
		var a = s.get(nm)
		var b = d.get(nm)
		if typeof(a) != typeof(b) or a != b:
			d.set(nm, a)
			stats[2] += 1
	if s is Control:
		_theme(d as Control, s as Control, m)
	if s is BaseButton and (s as BaseButton).button_pressed != (d as BaseButton).button_pressed:
		(d as BaseButton).set_pressed_no_signal((s as BaseButton).button_pressed)
	for mk in s.get_meta_list():
		d.set_meta(mk, s.get_meta(mk))
	for sg in sig:
		for c in s.get_signal_connection_list(sg):
			d.connect(sg, c["callable"], int(c["flags"]))


static func _theme(d: Control, s: Control, m: Array) -> void:
	for nm in m[3]:
		var hs := s.has_theme_color_override(nm)
		if hs:
			var v := s.get_theme_color(nm)
			if not d.has_theme_color_override(nm) or d.get_theme_color(nm) != v:
				d.add_theme_color_override(nm, v)
		elif d.has_theme_color_override(nm):
			d.remove_theme_color_override(nm)
	for nm in m[4]:
		if s.has_theme_constant_override(nm):
			var v := s.get_theme_constant(nm)
			if not d.has_theme_constant_override(nm) or d.get_theme_constant(nm) != v:
				d.add_theme_constant_override(nm, v)
		elif d.has_theme_constant_override(nm):
			d.remove_theme_constant_override(nm)
	for nm in m[6]:
		if s.has_theme_font_size_override(nm):
			var v := s.get_theme_font_size(nm)
			if not d.has_theme_font_size_override(nm) or d.get_theme_font_size(nm) != v:
				d.add_theme_font_size_override(nm, v)
		elif d.has_theme_font_size_override(nm):
			d.remove_theme_font_size_override(nm)
	for nm in m[5]:
		if s.has_theme_font_override(nm):
			var v := s.get_theme_font(nm)
			if not d.has_theme_font_override(nm) or d.get_theme_font(nm) != v:
				d.add_theme_font_override(nm, v)
		elif d.has_theme_font_override(nm):
			d.remove_theme_font_override(nm)
	for nm in m[7]:
		if s.has_theme_stylebox_override(nm):
			var v := s.get_theme_stylebox(nm)
			if not d.has_theme_stylebox_override(nm) or d.get_theme_stylebox(nm) != v:
				d.add_theme_stylebox_override(nm, v)
		elif d.has_theme_stylebox_override(nm):
			d.remove_theme_stylebox_override(nm)


## Эти правит Hud._fit_width после сборки (узкий лист) — в проверке не сравнивать.
const FIT := {&"clip_text": true, &"autowrap_mode": true, &"size_flags_horizontal": true}


## Проверка (стенд, `--patchcheck`): чем дерево a отличается от свежей сборки b;
## "" — ничем. Раскладку в контейнерах не сравнивает (её ставит контейнер).
static func diff(a: Node, b: Node, path := "") -> String:
	if a.get_child_count() != b.get_child_count():
		return "%s: детей %d, а надо %d" % [path, a.get_child_count(), b.get_child_count()]
	for i in a.get_child_count():
		var x := a.get_child(i)
		var y := b.get_child(i)
		var p := "%s/%d:%s" % [path, i, y.get_class()]
		if x.get_class() != y.get_class():
			return "%s: класс %s" % [p, x.get_class()]
		for nm in _all_names(y):
			if (a is Container and LAYOUT.has(nm)) or FIT.has(nm):
				continue
			var u = x.get(nm)
			var v = y.get(nm)
			if typeof(u) != typeof(v) or (u != v and not (u is Resource and v is Resource)):
				return "%s: %s = %s, а надо %s" % [p, nm, str(u), str(v)]
		if x is BaseButton and (x as BaseButton).button_pressed != (y as BaseButton).button_pressed:
			return "%s: нажата" % p
		for sg in SIGNALS:
			if not y.has_signal(sg):
				continue
			var nx := 0
			for c in x.get_signal_connection_list(sg):
				if (c["callable"] as Callable).get_method() != "_play_click":
					nx += 1
			if nx != y.get_signal_connection_list(sg).size():
				return "%s: сигнал %s — %d подключений, а надо %d" % [p, sg, nx, y.get_signal_connection_list(sg).size()]
		var r := diff(x, y, p)
		if r != "":
			return r
	return ""
