class_name MapView
extends Node2D
## Карта: спрайт с шейдером провинций, камера и сенсорное управление
## (перетаскивание — сдвиг, два пальца — масштаб, касание — выбор).

signal province_tapped(prov: int)
signal view_changed

const SCALE := 2.0
const MIN_ZOOM := 0.25
const MAX_ZOOM := 5.0
const TAP_SLOP := 14.0

enum MapMode { POLITICAL, TERRAIN, INDUSTRY, FACTIONS }

var world: World
var sprite: Sprite2D
var camera: Camera2D
var mat: ShaderMaterial
var ctrl_img: Image
var owner_img: Image
var ctrl_tex: ImageTexture
var owner_tex: ImageTexture
var map_mode := MapMode.POLITICAL

var _touches := {}           # index -> Vector2 (экранные координаты)
var _gesture_moved := 0.0
var _gesture_multi := false
var _pinch_dist := 0.0


func setup(w: World) -> void:
	world = w
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
	add_child(sprite)

	var rows := int(ceil(world.prov_count / 64.0))
	ctrl_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	owner_img = Image.create(64, rows, false, Image.FORMAT_RGBA8)
	ctrl_tex = ImageTexture.create_from_image(ctrl_img)
	owner_tex = ImageTexture.create_from_image(owner_img)
	mat.set_shader_parameter("id_tex", sprite.texture)
	mat.set_shader_parameter("ctrl_tex", ctrl_tex)
	mat.set_shader_parameter("owner_tex", owner_tex)
	mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(world.height_image))
	mat.set_shader_parameter("map_size", Vector2(world.width, world.height))

	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	var vp := get_viewport_rect().size
	var fit := minf(vp.x / (world.width * SCALE), vp.y / (world.height * SCALE))
	camera.zoom = Vector2.ONE * clampf(fit * 1.05, MIN_ZOOM, MAX_ZOOM)
	camera.position = world_size() * 0.5
	update_palette()
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


func set_highlight_nation(n: int) -> void:
	mat.set_shader_parameter("highlight_nation", n)


func set_map_mode(m: int) -> void:
	map_mode = m
	mat.set_shader_parameter("show_occupation", m == MapMode.POLITICAL)
	update_palette()


func update_palette() -> void:
	if world == null:
		return
	var max_ind := 1
	if map_mode == MapMode.INDUSTRY:
		for p in world.prov_count:
			max_ind = maxi(max_ind, world.p_civ[p] + world.p_mil[p])
	for p in world.prov_count:
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
	ctrl_tex.update(ctrl_img)
	owner_tex.update(owner_img)
	world.palette_dirty = false


func _process(_dt: float) -> void:
	if world != null and world.palette_dirty:
		update_palette()


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
		_on_view_changed()


func _pinch_distance() -> float:
	var pts: Array = _touches.values()
	return (pts[0] - pts[1]).length() if pts.size() >= 2 else 0.0


func _pinch_center() -> Vector2:
	var pts: Array = _touches.values()
	return (pts[0] + pts[1]) * 0.5 if pts.size() >= 2 else Vector2.ZERO


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
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
	view_changed.emit()
