class_name TriopsVisual
extends MultiMeshInstance3D
## Renders living Triops via MultiMesh. Display-only.

@export var point_radius: float = 0.18
@export var selected_color: Color = Color(1.0, 0.85, 0.2)
@export var female_color: Color = Color(0.95, 0.45, 0.55)
@export var male_color: Color = Color(0.35, 0.65, 0.95)


func setup(capacity: int) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = point_radius
	mesh.height = point_radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4

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
	_hide_all()


func ensure_capacity(capacity: int) -> void:
	if multimesh == null or capacity > multimesh.instance_count:
		setup(maxi(capacity, 1))


func _hide_all() -> void:
	if multimesh == null:
		return
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	for i in multimesh.instance_count:
		multimesh.set_instance_transform(i, hidden)


func sync_from_simulation(world: SimulationWorld) -> void:
	ensure_capacity(maxi(world.config.max_triops, world.agents.size()))
	_hide_all()
	for i in world.agents.size():
		if i >= multimesh.instance_count:
			break
		var agent: TriopsAgent = world.agents[i]
		var xf := Transform3D(agent.body.orientation, agent.body.position)
		xf = xf.scaled_local(Vector3.ONE * agent.scale)
		multimesh.set_instance_transform(i, xf)
		var color := selected_color if agent.id == world.selected_id else (
			male_color if agent.sex == TriopsAgent.Sex.MALE else female_color
		)
		multimesh.set_instance_color(i, color)
