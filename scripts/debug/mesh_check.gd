extends SceneTree
## Dump Meshy mesh AABB + material texture status.


func _initialize() -> void:
	var path := "res://assets/models/triops.glb"
	print("=== MESH CHECK ===")
	if not ResourceLoader.exists(path):
		push_error("missing %s" % path)
		quit(1)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("not PackedScene")
		quit(1)
		return
	var scene: Node = packed.instantiate()
	var mesh := _find_mesh(scene)
	if mesh == null:
		push_error("no MeshInstance3D")
		scene.queue_free()
		quit(1)
		return
	var aabb := mesh.get_aabb()
	print("aabb size=%s center=%s" % [aabb.size, aabb.get_center()])
	print("surfaces=%d" % mesh.get_surface_count())
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		print(" surface[%d] mat=%s" % [si, mat])
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			print("  albedo=%s tex=%s metallic=%s roughness=%s shading=%d" % [
				bm.albedo_color, bm.albedo_texture, bm.metallic, bm.roughness, bm.shading_mode
			])
	# Also check MI overrides
	_dump_mi(scene)
	scene.queue_free()
	print("=== MESH_OK ===")
	quit(0)


func _dump_mi(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		print("MI %s mesh=%s" % [mi.name, mi.mesh])
		if mi.mesh:
			for si in mi.mesh.get_surface_count():
				var ov := mi.get_active_material(si)
				print("  active_mat[%d]=%s" % [si, ov])
				if ov is BaseMaterial3D:
					var bm := ov as BaseMaterial3D
					print("   albedo_tex=%s path=%s" % [
						bm.albedo_texture,
						bm.albedo_texture.resource_path if bm.albedo_texture else ""
					])
	for c in node.get_children():
		_dump_mi(c)


func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for c in node.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null
