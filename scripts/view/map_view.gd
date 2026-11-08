class_name MapView
extends Node2D
## Карта: спрайт с шейдером провинций, камера и сенсорное управление
## (перетаскивание — сдвиг, два пальца — масштаб, касание — выбор).

signal province_tapped(prov: int)
signal view_changed

const SCALE := 2.0
const MIN_ZOOM := 0.1
const MAX_ZOOM := 5.0
const TAP_SLOP := 14.0

enum MapMode { POLITICAL, TERRAIN, INDUSTRY, FACTIONS, SUPPLY }

var world: World
var sprite: Sprite2D
var camera: Camera2D
var mat: ShaderMaterial
var ctrl_img: Image
var owner_img: Image
var ctrl_tex: ImageTexture
var owner_tex: ImageTexture
var map_mode := MapMode.POLITICAL
# Карта рисуется во внутренний буфер (SubViewport) и только при изменениях:
# сдвиг, масштаб, новый день (палитра), выбор. В остальные кадры экран
# просто показывает готовую картинку — шейдер не пересчитывает каждый пиксель.
var map_vp: SubViewport
var sub_cam: Camera2D
var view_sprite: Sprite2D
var res_scale := 1.0
var _dirty := true
# Пока карту двигают, она рисуется упрощённо (низкое качество, 50%), а через
# MOTION_SETTLE после остановки — в выбранном качестве (Settings.map_motion_lite).
const MOTION_SETTLE := 0.15
var quality := 2
var motion_lite := true
var _moving := 0.0           # сколько ещё считать карту «в движении», с
var _lite_drawn := false
var _wheel := false          # масштаб колесом/жестом тачпада — тоже движение     # последний кадр карты нарисован упрощённо
var redraws := 0             # сколько раз перерисована карта (для замеров)
var palette_version := 0     # растёт при каждом обновлении палитры (смена владельцев)
var _pal_ctrl := PackedInt32Array()   # чем покрашена провинция в палитре (политическая карта)
var _pal_own := PackedInt32Array()
var _pal_mode := -1

var _touches := {}           # index -> Vector2 (экранные координаты)
var _gesture_moved := 0.0
var _gesture_multi := false
var _pinch_dist := 0.0


func setup(w: World) -> void:
	world = w
	_pal_ctrl.clear()
	_pal_own.clear()
	_pal_mode = -1
	for c in get_children():
		c.queue_free()
	sprite = Sprite2D.new()
	sprite.centered = false
	sprite.texture = ImageTexture.create_from_image(world.id_image)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.scale = Vector2(SCALE, SCALE)
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/map.gdshader")
	sprite.material = mat
	map_vp = SubViewport.new()
	map_vp.disable_3d = true
	map_vp.transparent_bg = false
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(map_vp)
	map_vp.add_child(sprite)
	sub_cam = Camera2D.new()
	map_vp.add_child(sub_cam)
	sub_cam.make_current()
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	view_sprite = Sprite2D.new()
	view_sprite.centered = false
	view_sprite.texture = map_vp.get_texture()
	view_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(view_sprite)
	RenderingServer.viewport_set_measure_render_time(map_vp.get_viewport_rid(), true)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if not get_viewport().size_changed.is_connected(redraw):
		get_viewport().size_changed.connect(redraw)
	set_res_scale(Settings.RES_SCALES[Settings.map_res()])
	Settings.apply_fps_cap()
	motion_lite = Settings.motion_lite()

	var rows := int(ceil(world.prov_count / 64.0))
	ctrl_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	owner_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	ctrl_tex = ImageTexture.create_from_image(ctrl_img)
	owner_tex = ImageTexture.create_from_image(owner_img)
	mat.set_shader_parameter("id_tex", sprite.texture)
	mat.set_shader_parameter("ctrl_tex", ctrl_tex)
	mat.set_shader_parameter("owner_tex", owner_tex)
	mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(world.height_image))
	if world.terrain_image != null:
		mat.set_shader_parameter("terrain_tex", ImageTexture.create_from_image(world.terrain_image))
		mat.set_shader_parameter("has_terrain", true)
	else:
		mat.set_shader_parameter("has_terrain", false)
	mat.set_shader_parameter("map_size", Vector2(world.width, world.height))

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	var vp := get_viewport_rect().size
	var fit := minf(vp.x / (world.width * SCALE), vp.y / (world.height * SCALE))
	camera.zoom = Vector2.ONE * clampf(fit * 1.05, MIN_ZOOM, MAX_ZOOM)
	camera.position = world_size() * 0.5
	update_palette()
	set_quality(Settings.map_quality())
	_on_view_changed()


func world_size() -> Vector2:
	return Vector2(world.width, world.height) * SCALE


func province_world_pos(p: int) -> Vector2:
	return world.p_center[p] * SCALE


func world_to_screen(p: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform() * p


func screen_to_world(p: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * p


func zoom_level() -> float:
	return camera.zoom.x


func center_on(p: int) -> void:
	camera.position = province_world_pos(p)
	_on_view_changed()


func set_selected(prov: int) -> void:
	mat.set_shader_parameter("selected_id", prov)
	redraw()


func set_highlight_nation(n: int) -> void:
	mat.set_shader_parameter("highlight_nation", n)
	redraw()


## Перерисовать карту в ближайшем кадре.
func redraw() -> void:
	_dirty = true


## Разрешение буфера карты: доля пикселей экрана (0.5–1); 0 — авто: после
## каждой полной перерисовки подстраивается так, чтобы карта рисовалась на
## видеокарте за ~AUTO_TARGET_MS (масштаб разрешения — самое действенное
## средство против нагрузки и нагрева ГП на телефоне).
const AUTO_TARGET_MS := 14.0
var res_auto := false
var _auto_pending := false     # последняя перерисовка — полная, замер ещё не учтён
var last_cost_ms := 0.0        # оценка цены полной перерисовки карты (для нижней строки)


func set_res_scale(s: float) -> void:
	res_auto = s <= 0.0
	res_scale = 0.75 if res_auto else clampf(s, 0.25, 1.0)
	redraw()


var _base_dt := 0.0          # обычное время кадра без перерисовки карты, с
var _drawn_last := false     # в прошлом кадре карта перерисовывалась полностью


## Подбор разрешения. Где видеокарта отдаёт время отрисовки (Vulkan) — по нему;
## в OpenGL ES (Compatibility) этого замера нет — по времени кадра: сколько кадр
## с полной перерисовкой карты длиннее обычного.
func _auto_adjust(dt: float) -> void:
	var drawn := _drawn_last
	_drawn_last = false
	if not drawn:
		if not _auto_pending:
			_base_dt = dt if _base_dt == 0.0 else lerpf(_base_dt, dt, 0.1)
		return
	if not _auto_pending:
		return
	_auto_pending = false
	var cost := RenderingServer.viewport_get_measured_render_time_gpu(map_vp.get_viewport_rid())
	if cost <= 0.0:
		if _base_dt <= 0.0:
			return
		cost = maxf(0.0, (dt - _base_dt) * 1000.0)
	last_cost_ms = cost
	var old := res_scale
	if cost > AUTO_TARGET_MS * 1.3:
		res_scale = maxf(0.5, res_scale * sqrt(AUTO_TARGET_MS / cost))
	elif cost < AUTO_TARGET_MS * 0.6:
		res_scale = minf(1.0, res_scale * 1.1)
	if absf(res_scale - old) > 0.02:
		redraw()
	else:
		res_scale = old


func _process(dt: float) -> void:
	if res_auto and map_vp != null:
		_auto_adjust(dt)
	if _moving > 0.0:
		_moving -= dt
		if _moving <= 0.0 and _lite_drawn:
			_dirty = true   # остановились — перерисовать в полном качестве
	if not _dirty or map_vp == null:
		return
	_dirty = false
	var lite := motion_lite and _moving > 0.0 and (quality > 0 or res_scale > 0.5)
	_lite_drawn = lite
	mat.set_shader_parameter("quality", 0 if lite else quality)
	var rs := 0.5 if lite else res_scale
	var logical := get_viewport_rect().size
	var phys := Vector2(get_window().size)
	var size := Vector2i(maxi(1, int(phys.x * rs)), maxi(1, int(phys.y * rs)))
	if map_vp.size != size:
		map_vp.size = size
	var rk := float(size.x) / maxf(1.0, logical.x)  # пикселей буфера на логический
	sub_cam.position = camera.position
	sub_cam.zoom = camera.zoom * rk
	view_sprite.scale = logical / Vector2(size)
	mat.set_shader_parameter("res_k", rk)
	map_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_auto_pending = not lite
	_drawn_last = not lite
	redraws += 1


## Время отрисовки последнего кадра на видеокарте (мс): карта и весь экран.
func gpu_ms() -> Vector2:
	if map_vp == null:
		return Vector2.ZERO
	return Vector2(RenderingServer.viewport_get_measured_render_time_gpu(map_vp.get_viewport_rid()),
		RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))


## Качество карты: 0 — низкое, 1 — среднее, 2 — высокое (см. shaders/map.gdshader).
func set_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	if mat != null:
		mat.set_shader_parameter("quality", quality)
		redraw()


func set_map_mode(m: int) -> void:
	map_mode = m
	mat.set_shader_parameter("show_occupation", m == MapMode.POLITICAL)
	mat.set_shader_parameter("terrain_mode", m == MapMode.TERRAIN)
	update_palette()
	redraw()


func update_palette() -> void:
	if world == null:
		return
	# политическая карта: перекрашиваем только провинции со сменой владельца
	# (полный проход по всем — при смене режима или первом показе)
	var incremental := map_mode == MapMode.POLITICAL and _pal_mode == MapMode.POLITICAL \
		and _pal_ctrl.size() == world.prov_count
	_pal_mode = map_mode
	if map_mode == MapMode.POLITICAL and _pal_ctrl.size() != world.prov_count:
		_pal_ctrl.resize(world.prov_count)
		_pal_own.resize(world.prov_count)
	var max_ind := 1
	if map_mode == MapMode.INDUSTRY:
		for p in world.prov_count:
			max_ind = maxi(max_ind, world.p_civ[p] + world.p_mil[p])
	var pc := world.p_controller
	var po := world.p_owner
	var changed := 0
	for p in world.prov_count:
		if incremental:
			if _pal_ctrl[p] == pc[p] and _pal_own[p] == po[p]:
				continue
		changed += 1
		if map_mode == MapMode.POLITICAL:
			_pal_ctrl[p] = pc[p]
			_pal_own[p] = po[p]
		var x := p % 64
		var y := p / 64
		if world.p_land[p] == 0:
			ctrl_img.set_pixel(x, y, Color(0, 0, 0, 0))
			owner_img.set_pixel(x, y, Color(0, 0, 0, 0))
			continue
		var c := world.p_controller[p]
		var o := world.p_owner[p]
		var col: Color = world.nations[c].color
		match map_mode:
			MapMode.TERRAIN:
				col = World.TERRAIN_COLORS[world.p_terrain[p]]
			MapMode.SUPPLY:
				# снабжение игрока: зелёный — хорошо, красный — далеко или мало дорог
				var me := world.player_nation()
				col = Color(0.55, 0.55, 0.52)
				if me >= 0 and world.supply_dist.size() > me and not world.supply_dist[me].is_empty():
					var dist: PackedInt32Array = world.supply_dist[me]
					var h: int = dist[p]
					if h >= 0:
						var reach := 1.0 if h <= 5 else maxf(0.35, 1.0 - (h - 5) * 0.06)
						var v := reach * minf(1.0, world.p_supply_cap[p] / 4.0)
						col = Color(0.85, 0.25, 0.2).lerp(Color(0.3, 0.75, 0.3), v)
					elif world.ally[me * world.nation_count + c] == 1:
						col = Color(0.35, 0.1, 0.1)
			MapMode.FACTIONS:
				var r := Diplomacy.root(world, c)
				var f: int = world.nations[r].faction
				col = world.factions[f].color if f >= 0 else Color(0.62, 0.6, 0.55)
				if world.nations[c].overlord >= 0 and f < 0:
					col = world.nations[r].color
			MapMode.INDUSTRY:
				var v := float(world.p_civ[p] + world.p_mil[p]) / max_ind
				var mil_share := float(world.p_mil[p]) / maxf(1.0, world.p_civ[p] + world.p_mil[p])
				col = Color(0.85, 0.85, 0.8).lerp(Color(0.85, 0.35, 0.2).lerp(Color(0.3, 0.45, 0.8), 1.0 - mil_share), sqrt(v))
		col.a = (c + 1) / 255.0
		ctrl_img.set_pixel(x, y, col)
		var oc: Color = world.nations[o].color
		oc.a = (o + 1) / 255.0
		owner_img.set_pixel(x, y, oc)
	world.palette_dirty = false
	if changed == 0:
		return   # владельцы не менялись — ни текстуры, ни перерисовки
	ctrl_tex.update(ctrl_img)
	owner_tex.update(owner_img)
	palette_version += 1
	redraw()




# --- Ввод ----------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if camera == null:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			if _touches.is_empty():
				_gesture_moved = 0.0
				_gesture_multi = false
			_touches[event.index] = event.position
			if _touches.size() >= 2:
				_gesture_multi = true
				_pinch_dist = _pinch_distance()
		else:
			var was_tap: bool = _touches.size() == 1 and not _gesture_multi and _gesture_moved < TAP_SLOP
			_touches.erase(event.index)
			if _touches.size() >= 2:
				_pinch_dist = _pinch_distance()
			if was_tap:
				_tap(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if not _touches.has(event.index):
			return
		var prev: Vector2 = _touches[event.index]
		_touches[event.index] = event.position
		_gesture_moved += (event.position - prev).length()
		if _touches.size() == 1:
			camera.position -= (event.position - prev) / camera.zoom.x
			_on_view_changed()
		elif _touches.size() >= 2:
			var d := _pinch_distance()
			if _pinch_dist > 0.0:
				_zoom_at(_pinch_center(), d / _pinch_dist)
			_pinch_dist = d
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, 1.15)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / 1.15)
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
	elif event is InputEventPanGesture:
		camera.position += event.delta * 8.0 / camera.zoom.x
		_wheel = true
		_on_view_changed()


func _pinch_distance() -> float:
	var pts: Array = _touches.values()
	return (pts[0] - pts[1]).length() if pts.size() >= 2 else 0.0


func _pinch_center() -> Vector2:
	var pts: Array = _touches.values()
	return (pts[0] + pts[1]) * 0.5 if pts.size() >= 2 else Vector2.ZERO


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	_wheel = true
	var before := screen_to_world(screen_pos)
	camera.zoom = Vector2.ONE * clampf(camera.zoom.x * factor, MIN_ZOOM, MAX_ZOOM)
	camera.force_update_scroll()
	var after := screen_to_world(screen_pos)
	camera.position += before - after
	_on_view_changed()


func _tap(screen_pos: Vector2) -> void:
	var wp := screen_to_world(screen_pos) / SCALE
	var p := world.province_at_pixel(wp)
	if p >= 0:
		province_tapped.emit(p)


func _on_view_changed() -> void:
	# не даём увести карту за край экрана, если она шире экрана
	var ws := world_size()
	var half := get_viewport_rect().size * 0.5 / camera.zoom.x
	var lo := Vector2(minf(half.x, ws.x * 0.5), minf(half.y, ws.y * 0.5))
	var hi := Vector2(maxf(ws.x - half.x, ws.x * 0.5), maxf(ws.y - half.y, ws.y * 0.5))
	camera.position = camera.position.clamp(lo, hi)
	mat.set_shader_parameter("zoom", camera.zoom.x)
	if not _touches.is_empty() or _wheel:
		_moving = MOTION_SETTLE
	_wheel = false
	redraw()
	view_changed.emit()
