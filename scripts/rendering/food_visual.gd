class_name FoodVisual
extends MultiMeshInstance3D
## Renders food particles.

@export var radius: float = 0.12
@export var color: Color = Color(0.45, 0.9, 0.35)


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


func sync_from_food(food: FoodSystem) -> void:
	if food == null:
		return
	if multimesh == null or multimesh.instance_count < food.positions.size():
		setup(food.positions.size())
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	for i in food.positions.size():
		if food.active[i] == 1:
			multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, food.positions[i]))
			multimesh.set_instance_color(i, color)
		else:
			multimesh.set_instance_transform(i, hidden)
