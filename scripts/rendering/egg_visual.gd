class_name EggVisual
extends MultiMeshInstance3D
## Renders eggs as tiny points.

@export var radius: float = 0.08
@export var color: Color = Color(0.95, 0.9, 0.7)


func setup(capacity: int) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = maxi(capacity, 1)
	multimesh = mm


func sync_from_eggs(eggs: Array[Egg]) -> void:
	var need := maxi(eggs.size(), 1)
	if multimesh == null or multimesh.instance_count < need:
		setup(need)
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	for i in multimesh.instance_count:
		if i < eggs.size():
			multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, eggs[i].position))
			multimesh.set_instance_color(i, color)
		else:
			multimesh.set_instance_transform(i, hidden)
