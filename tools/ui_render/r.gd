extends Node3D
# godot --path /tmp/render -- model.gltf out.png pitch_deg yaw_deg size
func _ready():
	var a := OS.get_cmdline_user_args()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(a[0], st) != OK:
		print("load fail"); get_tree().quit(); return
	var model: Node3D = doc.generate_scene(st)
	add_child(model)
	# габариты
	var aabb := AABB()
	var first := true
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n
		var b: AABB = mi.global_transform * mi.get_aabb()
		aabb = b if first else aabb.merge(b)
		first = false
	print("aabb ", aabb)
	var c := aabb.get_center()
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var pitch := deg_to_rad(float(a[2]))
	var yaw := deg_to_rad(float(a[3]))
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	cam.position = c + dir * 5.0
	add_child(cam)
	cam.look_at(c, Vector3(0, 0, -1) if absf(a[2].to_float()) > 80 else Vector3.UP)
	cam.size = maxf(aabb.size.x, aabb.size.z) * 1.08
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -35, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.9, 0.86, 0.8)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var s := int(a[4])
	get_window().size = Vector2i(s, s)
	get_viewport().transparent_bg = true
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(a[1])
	print("saved")
	get_tree().quit()
