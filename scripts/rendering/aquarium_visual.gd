class_name AquariumVisual
extends Node3D
## Simple transparent aquarium box + wireframe edges. No textures.

func build(half_extents: Vector3) -> void:
	# Clear previous children if rebuilt.
	for child in get_children():
		child.queue_free()

	var size := half_extents * 2.0

	var box := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 0.55, 0.75, 0.08)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	box.mesh = mesh
	add_child(box)

	var edges := MeshInstance3D.new()
	edges.mesh = _make_wire_box(half_extents)
	var edge_mat := StandardMaterial3D.new()
	edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_mat.albedo_color = Color(0.55, 0.75, 0.95, 0.9)
	edges.material_override = edge_mat
	add_child(edges)


func _make_wire_box(half: Vector3) -> ArrayMesh:
	var corners: Array[Vector3] = [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, half.z),
		Vector3(-half.x, -half.y, half.z),
		Vector3(-half.x, half.y, -half.z),
		Vector3(half.x, half.y, -half.z),
		Vector3(half.x, half.y, half.z),
		Vector3(-half.x, half.y, half.z),
	]
	var pairs: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 2), Vector2i(2, 3), Vector2i(3, 0),
		Vector2i(4, 5), Vector2i(5, 6), Vector2i(6, 7), Vector2i(7, 4),
		Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
	]

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for p in pairs:
		var i0 := vertices.size()
		vertices.append(corners[p.x])
		vertices.append(corners[p.y])
		indices.append(i0)
		indices.append(i0 + 1)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices

	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return am
