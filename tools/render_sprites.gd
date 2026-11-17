extends SceneTree
## Атлас построек и деревьев для карты (data/world1936/sprites.png.bin, 512×512,
## сетка 8×8 по 64 пикс.): 3D-модели под CC0 (Quaternius, Kenney, Poly Haven —
## assets/CREDITS.md) рисуются ортокамерой с юга под углом PITCH, солнце с
## северо-запада (как свет карты), тень на землю — разностью двух проходов
## (с моделью и без). Список ячеек — tools/sprites.json: [{"cell": N, "file":
## путь к .fbx/.glb/.gltf относительно папки моделей, "tint": [r,g,b] (необяз.),
## "yaw": градусы (необяз.)}].
##
##   xvfb-run -a godot --rendering-driver opengl3 --path . --script res://tools/render_sprites.gd -- \
##       --models=ПАПКА_МОДЕЛЕЙ [--out=data/world1936/sprites.png.bin] [--sheet=превью.png]

const CELL := 64
const GRID := 8
const SS := 4                 # рисуем вчетверо крупнее и уменьшаем (сглаживание)
const PITCH := 52.0           # угол взгляда к горизонту, градусы

var vp: SubViewport
var cam: Camera3D
var holder: Node3D
var ground: MeshInstance3D


func _arg(k: String, d := "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + k + "="):
			return a.split("=", true, 1)[1]
	return d


func _init() -> void:
	_run.call_deferred()


func _load_model(path: String) -> Node3D:
	var st
	var doc
	if path.get_extension().to_lower() == "fbx":
		doc = FBXDocument.new()
		st = FBXState.new()
	else:
		doc = GLTFDocument.new()
		st = GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_error("не загрузить " + path)
		return null
	return doc.generate_scene(st)


func _aabb(n: Node, xf: Transform3D) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [[n, xf]]
	while not stack.is_empty():
		var it: Array = stack.pop_back()
		var node: Node = it[0]
		var t: Transform3D = it[1]
		if node is Node3D:
			t = t * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var b: AABB = t * (node as MeshInstance3D).mesh.get_aabb()
			box = b if first else box.merge(b)
			first = false
		for c in node.get_children():
			stack.append([c, t])
	return box


func _grab() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


func _run() -> void:
	var models := _arg("models")
	var spec: Array = JSON.parse_string(FileAccess.get_file_as_string(_arg("spec", "res://tools/sprites.json")))
	vp = SubViewport.new()
	vp.size = Vector2i(CELL * SS, CELL * SS)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_4X
	root.add_child(vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.72, 0.71, 0.70)
	env.environment.ambient_light_energy = 1.35
	vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.light_energy = 1.0
	sun.directional_shadow_max_distance = 60.0
	vp.add_child(sun)
	# свет карты: из (−0,55; −0,65; 0,75) в осях карты (x восток, y юг, z верх) —
	# в 3D (x восток, y верх, z юг) направление на солнце (−0,55; 0,75; −0,65)
	var to_sun := Vector3(-0.55, 0.75, -0.65).normalized()
	sun.look_at_from_position(to_sun * 10.0, Vector3.ZERO, Vector3.UP)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	holder = Node3D.new()
	vp.add_child(holder)
	ground = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(1, 1, 1)
	ground.material_override = gmat
	vp.add_child(ground)
	var atlas := Image.create(CELL * GRID, CELL * GRID, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	for e in spec:
		var cell: int = int(e["cell"])
		var path: String = models.path_join(e["file"])
		var m := _load_model(path)
		if m == null:
			continue
		for c in holder.get_children():
			c.queue_free()
		holder.add_child(m)
		m.rotation_degrees.y = float(e.get("yaw", 0.0))
		await process_frame
		var box := _aabb(m, Transform3D.IDENTITY)
		var ctr := box.get_center()
		m.position = Vector3(-ctr.x, -box.position.y, -ctr.z)
		if e.has("tex"):
			var timg := Image.load_from_file(models.path_join(e["tex"]))
			_set_tex(m, ImageTexture.create_from_image(timg))
		if e.has("recolor"):
			_recolor(m, e["recolor"])
		if e.has("tint"):
			_tint(m, Color(e["tint"][0], e["tint"][1], e["tint"][2]), e.get("tint_what", "roof"))
		# камера: с юга, сверху под PITCH; кадр — по проекции рамки модели
		var ext := box.size
		var pr := deg_to_rad(PITCH)
		var w := maxf(ext.x, 1e-3)
		var h := ext.z * sin(pr) + ext.y * cos(pr)
		var size := maxf(w, h) * 1.12 + 0.25 * maxf(ext.x, ext.z)   # запас под тень
		cam.size = size
		var look := Vector3(0.08 * size, ext.y * 0.5, 0.0)          # тень уходит на юго-восток
		var dir := Vector3(0, sin(pr), cos(pr))
		cam.look_at_from_position(look + dir * 50.0, look, Vector3.UP)
		cam.near = 1.0
		cam.far = 200.0
		ground.visible = true
		var with_obj := await _grab()
		holder.visible = false
		var bare := await _grab()
		holder.visible = true
		ground.visible = false
		var obj := await _grab()
		ground.visible = true
		var spr := Image.create(CELL * SS, CELL * SS, false, Image.FORMAT_RGBA8)
		for y in CELL * SS:
			for x in CELL * SS:
				var o := obj.get_pixel(x, y)
				var a := with_obj.get_pixel(x, y).get_luminance()
				var b := bare.get_pixel(x, y).get_luminance()
				var sh := clampf(1.0 - a / maxf(b, 1e-3), 0.0, 1.0) * 0.55
				var c := Color(0, 0, 0, sh)
				if o.a > 0.0:
					c = Color(o.r, o.g, o.b, 1.0).lerp(c, 0.0)
					c.a = o.a + sh * (1.0 - o.a)
					c.r = o.r * o.a / maxf(c.a, 1e-4)
					c.g = o.g * o.a / maxf(c.a, 1e-4)
					c.b = o.b * o.a / maxf(c.a, 1e-4)
				spr.set_pixel(x, y, c)
		# обрезка по содержимому (модель с тенью) — квадрат, модель заполняет ячейку
		var used := spr.get_used_rect()
		if used.size.x > 4 and used.size.y > 4:
			var side := maxi(used.size.x, used.size.y) + 6
			var sq := Image.create(side, side, false, Image.FORMAT_RGBA8)
			sq.fill(Color(0, 0, 0, 0))
			sq.blit_rect(spr, used, Vector2i((side - used.size.x) / 2, (side - used.size.y) / 2))
			spr = sq
		spr.resize(CELL, CELL, Image.INTERPOLATE_LANCZOS)
		# поля по 1 пикс. прозрачные — mipmap не тянет соседние ячейки
		for i in CELL:
			for edge in [0, CELL - 1]:
				spr.set_pixel(i, edge, Color(0, 0, 0, 0))
				spr.set_pixel(edge, i, Color(0, 0, 0, 0))
		atlas.blit_rect(spr, Rect2i(0, 0, CELL, CELL), Vector2i((cell % GRID) * CELL, (cell / GRID) * CELL))
		print("спрайт %d: %s" % [cell, e["file"]])
	var out := _arg("out", "res://data/world1936/sprites.png.bin")
	var buf := atlas.save_png_to_buffer()
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_buffer(buf)
	f.close()
	if _arg("sheet") != "":
		var sh2 := atlas.duplicate() as Image
		sh2.resize(CELL * GRID * 2, CELL * GRID * 2, Image.INTERPOLATE_NEAREST)
		var bg := Image.create(sh2.get_width(), sh2.get_height(), false, Image.FORMAT_RGBA8)
		bg.fill(Color(0.55, 0.62, 0.42))
		bg.blend_rect(sh2, Rect2i(Vector2i.ZERO, sh2.get_size()), Vector2i.ZERO)
		bg.save_png(_arg("sheet"))
	print("атлас: ", out)
	quit()


## Текстура на все материалы (модели, где она не вшита в файл).
func _set_tex(n: Node, tex: Texture2D) -> void:
	var stack: Array = [n]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var nm := StandardMaterial3D.new()
				nm.albedo_texture = tex
				mi.set_surface_override_material(s, nm)
		for c in node.get_children():
			stack.append(c)


## Замена цвета материалов по имени: {"rooftiles": [r, g, b]}.
func _recolor(n: Node, map: Dictionary) -> void:
	var stack: Array = [n]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var mat = mi.get_active_material(s)
				if mat is BaseMaterial3D:
					var name := str(mat.resource_name).to_lower()
					for k in map:
						if name.contains(str(k).to_lower()):
							var nm := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
							nm.albedo_color = Color(map[k][0], map[k][1], map[k][2])
							nm.albedo_texture = null
							mi.set_surface_override_material(s, nm)
		for c in node.get_children():
			stack.append(c)


## Перекраска: крыши (тёмные/насыщенные материалы сверху) или всё — умножением.
func _tint(n: Node, col: Color, what: String) -> void:
	var stack: Array = [n]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var mat = mi.get_active_material(s)
				if mat is BaseMaterial3D:
					var nm := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
					var name := str(mat.resource_name).to_lower()
					if what == "all" or name.contains(what):
						nm.albedo_color = nm.albedo_color * col
					mi.set_surface_override_material(s, nm)
		for c in node.get_children():
			stack.append(c)
