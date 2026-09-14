extends Node3D
## Fullscreen Meshy Triops viewer + PNG capture for visual QA.


func _ready() -> void:
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.12, 0.14, 0.18))

	var light := DirectionalLight3D.new()
	light.light_energy = 1.4
	light.rotation_degrees = Vector3(-45, 35, 0)
	add_child(light)

	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.45
	fill.rotation_degrees = Vector3(20, -120, 0)
	add_child(fill)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.14, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.65)
	env.ambient_light_energy = 0.85
	env_node.environment = env
	add_child(env_node)

	var path := "res://assets/models/triops.glb"
	if not ResourceLoader.exists(path):
		push_error("missing %s" % path)
		get_tree().quit(1)
		return

	var packed := load(path) as PackedScene
	var root: Node = packed.instantiate()
	add_child(root)

	var aabb := _combine_aabb(root)
	print("model_aabb size=", aabb.size, " center=", aabb.get_center())
	_dump_materials(root)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 45.0
	add_child(cam)

	var center := aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.5, 0.05)
	var out_dir := ProjectSettings.globalize_path("res://.captures")
	DirAccess.make_dir_recursive_absolute(out_dir)

	await get_tree().process_frame
	await get_tree().process_frame

	# Front 3/4 — fill frame
	cam.fov = 35.0
	cam.look_at_from_position(center + Vector3(radius * 0.85, radius * 0.55, radius * 1.15), center, Vector3.UP)
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	_capture("%s/triops_view_front.png" % out_dir)

	# Top-down
	cam.look_at_from_position(center + Vector3(0.0, radius * 1.85, 0.01), center, Vector3.FORWARD)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	_capture("%s/triops_view_top.png" % out_dir)

	# Side
	cam.look_at_from_position(center + Vector3(radius * 1.55, radius * 0.25, 0.0), center, Vector3.UP)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	_capture("%s/triops_view_side.png" % out_dir)

	print("=== VIEWER_OK ===")
	get_tree().quit(0)


func _capture(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("capture ", path, " err=", err, " size=", img.get_width(), "x", img.get_height())


func _combine_aabb(node: Node) -> AABB:
	var first := true
	var out := AABB()
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D:
			var vi := n as VisualInstance3D
			var local := vi.get_aabb()
			var xf: Transform3D = vi.global_transform if vi.is_inside_tree() else vi.transform
			var world := _xform_aabb(xf, local)
			if first:
				out = world
				first = false
			else:
				out = out.merge(world)
		for c in n.get_children():
			stack.append(c)
	if first:
		return AABB(Vector3.ZERO, Vector3.ONE)
	return out


func _xform_aabb(xf: Transform3D, aabb: AABB) -> AABB:
	var pts: Array[Vector3] = []
	for i in 8:
		pts.append(xf * aabb.get_endpoint(i))
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	return AABB(mn, mx - mn)


func _dump_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		print("MI ", mi.name, " mesh=", mi.mesh, " aabb=", mi.get_aabb().size)
		if mi.mesh:
			for si in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(si)
				print("  mat[", si, "]=", mat)
				if mat is BaseMaterial3D:
					var bm := mat as BaseMaterial3D
					print("   albedo=", bm.albedo_color, " tex=", bm.albedo_texture)
	for c in node.get_children():
		_dump_materials(c)
