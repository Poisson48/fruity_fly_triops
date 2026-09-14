class_name TriopsVisual
extends MultiMeshInstance3D
## Renders living Triops via MultiMesh. Display-only.
## Drop a Meshy export at res://assets/models/triops.glb (see assets/models/README.md).

const MODEL_PATH := "res://assets/models/triops.glb"
const TEXTURE_PATH := "res://assets/models/triops_0.png"
const SWIM_SHADER_PATH := "res://shaders/triops_swim.gdshader"
## Keep in sync with TriopsSensors eye sockets (body-local after model_basis).
## Meshy extents ≈ 1.5×0.5×1.9 → scale 2.5 ≈ 3.7×1.3×4.7 in tank.
const VISUAL_MODEL_SCALE := 2.5

@export var point_radius: float = 0.18
## Near-white tints: MultiMesh multiplies albedo; keep texture readable.
@export var selected_color: Color = Color(1.0, 0.97, 0.88)
@export var female_color: Color = Color(1.0, 0.88, 0.9)
@export var male_color: Color = Color(0.88, 0.93, 1.0)
@export var eye_left_color: Color = Color(0.2, 0.95, 1.0)
@export var eye_right_color: Color = Color(1.0, 0.55, 0.15)
@export var eye_median_color: Color = Color(1.0, 1.0, 0.85)
@export var show_eye_markers: bool = false
@export var eye_marker_radius: float = 0.08
## Extra basis to fix Meshy forward/up without re-exporting.
## Meshy shield faces +Z; Triops body forward is -Z → 180° yaw.
@export var model_basis: Basis = Basis.from_euler(Vector3(0.0, PI, 0.0))
@export var model_scale: float = VISUAL_MODEL_SCALE
@export var visual_follow_hz: float = 18.0
@export var swim_wave_hz: float = 7.5
@export var idle_wave_hz: float = 2.2
## When true, only selected agent gets eye markers (cheap debug).
@export var eye_markers_selected_only: bool = true

var _eye_mmi: MultiMeshInstance3D
## Display poses (smoothed toward sim) — kills render stair-steps.
var _disp_pos: Array[Vector3] = []
var _disp_basis: Array[Basis] = []
var _disp_valid: PackedByteArray = PackedByteArray()
var _swim_phase: PackedFloat32Array = PackedFloat32Array()
var _swim_amp: PackedFloat32Array = PackedFloat32Array()
var _swim_turn: PackedFloat32Array = PackedFloat32Array()
var _using_swim_shader: bool = false


func setup(capacity: int) -> void:
	_using_swim_shader = false
	var mesh := _load_triops_mesh()
	if mesh == null:
		mesh = _make_sphere_mesh()
		_using_swim_shader = false

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = _using_swim_shader
	mm.mesh = mesh
	mm.instance_count = maxi(capacity, 1)
	multimesh = mm
	_hide_all()
	_setup_eye_markers(maxi(capacity, 1))
	_resize_display(maxi(capacity, 1))


func _resize_display(n: int) -> void:
	_disp_pos.resize(n)
	_disp_basis.resize(n)
	_disp_valid.resize(n)
	_swim_phase.resize(n)
	_swim_amp.resize(n)
	_swim_turn.resize(n)
	for i in n:
		_disp_valid[i] = 0
		_disp_pos[i] = Vector3.ZERO
		_disp_basis[i] = Basis.IDENTITY
		if _swim_phase[i] == 0.0:
			_swim_phase[i] = float(i) * 1.7
		_swim_amp[i] = 0.2
		_swim_turn[i] = 0.0


func _setup_eye_markers(capacity: int) -> void:
	if _eye_mmi == null:
		_eye_mmi = MultiMeshInstance3D.new()
		_eye_mmi.name = "EyeMarkers"
		add_child(_eye_mmi)
	var sphere := SphereMesh.new()
	sphere.radius = eye_marker_radius
	sphere.height = eye_marker_radius * 2.0
	sphere.radial_segments = 6
	sphere.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	sphere.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sphere
	mm.instance_count = maxi(capacity, 1) * 3
	_eye_mmi.multimesh = mm
	_hide_eyes()


func _make_sphere_mesh() -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = point_radius
	mesh.height = point_radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	return mesh


func _load_triops_mesh() -> Mesh:
	if not ResourceLoader.exists(MODEL_PATH):
		return null
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		return null
	var scene := packed.instantiate()
	if scene == null:
		return null
	var mesh := _find_first_mesh(scene)
	scene.free()
	if mesh == null:
		return null
	_prepare_multimesh_material(mesh)
	return mesh


func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var mesh: Mesh = mi.mesh.duplicate(true)
			for si in mesh.get_surface_count():
				var override := mi.get_active_material(si)
				if override != null:
					mesh.surface_set_material(si, override.duplicate(true))
			return mesh
	for child in node.get_children():
		var found := _find_first_mesh(child)
		if found != null:
			return found
	return null


func _prepare_multimesh_material(mesh: Mesh) -> void:
	## Swim soft-skeleton shader (carapace rigid, abdomen + furca bend).
	var tex: Texture2D = null
	if ResourceLoader.exists(TEXTURE_PATH):
		tex = load(TEXTURE_PATH) as Texture2D
	# Prefer albedo already on the surface.
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat is BaseMaterial3D:
			var bm := mat as BaseMaterial3D
			if bm.albedo_texture != null:
				tex = bm.albedo_texture
				break

	var shader := load(SWIM_SHADER_PATH) as Shader
	if shader == null:
		_using_swim_shader = false
		_prepare_fallback_material(mesh, tex)
		return

	var sm := ShaderMaterial.new()
	sm.shader = shader
	if tex != null:
		sm.set_shader_parameter("albedo_tex", tex)
	sm.set_shader_parameter("albedo_tint", Color(1, 1, 1, 1))
	sm.set_shader_parameter("z_min", -0.95)
	sm.set_shader_parameter("z_max", 0.95)
	for si in mesh.get_surface_count():
		mesh.surface_set_material(si, sm)
	_using_swim_shader = true


func _prepare_fallback_material(mesh: Mesh, fallback_tex: Texture2D) -> void:
	for si in mesh.get_surface_count():
		var mat := mesh.surface_get_material(si)
		if mat == null:
			mat = StandardMaterial3D.new()
		if mat is BaseMaterial3D:
			var sm := (mat as BaseMaterial3D).duplicate(true) as BaseMaterial3D
			sm.vertex_color_use_as_albedo = true
			sm.albedo_color = Color(1, 1, 1, 1)
			if sm.albedo_texture == null and fallback_tex != null:
				sm.albedo_texture = fallback_tex
			sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			sm.metallic = 0.0
			mesh.surface_set_material(si, sm)
		else:
			mesh.surface_set_material(si, mat)


func ensure_capacity(capacity: int) -> void:
	if multimesh == null or capacity > multimesh.instance_count:
		setup(maxi(capacity, 1))
	elif _eye_mmi == null or _eye_mmi.multimesh == null or _eye_mmi.multimesh.instance_count < capacity * 3:
		_setup_eye_markers(maxi(capacity, 1))
	if _disp_pos.size() < capacity:
		_resize_display(maxi(capacity, 1))


func _hide_all() -> void:
	if multimesh == null:
		return
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	for i in multimesh.instance_count:
		multimesh.set_instance_transform(i, hidden)


func _hide_eyes() -> void:
	if _eye_mmi == null or _eye_mmi.multimesh == null:
		return
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	for i in _eye_mmi.multimesh.instance_count:
		_eye_mmi.multimesh.set_instance_transform(i, hidden)


func sync_from_simulation(world: SimulationWorld, delta: float = 1.0 / 60.0) -> void:
	ensure_capacity(maxi(world.config.max_triops, world.agents.size()))
	var n_show := world.agents.size()
	var n_slots := multimesh.instance_count
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	var model_xf := Transform3D(model_basis.scaled(Vector3.ONE * model_scale), Vector3.ZERO)
	var follow := 1.0 - exp(-visual_follow_hz * maxf(delta, 0.0001))
	# At high time-scale, snap closer to sim so visuals keep up.
	if world.speed_scale >= 4.0:
		follow = minf(1.0, follow * 2.5)
	elif world.speed_scale >= 2.0:
		follow = minf(1.0, follow * 1.6)

	var max_speed := maxf(world.config.max_speed, 0.01)
	var dt_vis := delta * maxf(world.speed_scale, 0.0)
	var breathe := sin(Time.get_ticks_msec() * 0.001 * idle_wave_hz * TAU) * 0.5 + 0.5

	# Only update living slots; hide the rest once past n_show (not every empty max_triops slot work).
	for i in n_show:
		var agent: TriopsAgent = world.agents[i]
		if not agent.alive:
			multimesh.set_instance_transform(i, hidden)
			if i < _disp_valid.size():
				_disp_valid[i] = 0
			continue
		var target_pos := agent.body.position
		var target_basis := agent.body.orientation
		var pos := target_pos
		var basis := target_basis
		if i < _disp_valid.size() and _disp_valid[i] != 0:
			pos = _disp_pos[i].lerp(target_pos, follow)
			var q0 := _disp_basis[i].get_rotation_quaternion()
			var q1 := target_basis.get_rotation_quaternion()
			basis = Basis(q0.slerp(q1, follow))
		_disp_pos[i] = pos
		_disp_basis[i] = basis
		_disp_valid[i] = 1
		var xf := Transform3D(basis, pos)
		xf = xf * model_xf
		xf = xf.scaled_local(Vector3.ONE * agent.scale)
		multimesh.set_instance_transform(i, xf)
		var color := selected_color if agent.id == world.selected_id else (
			male_color if agent.sex == TriopsAgent.Sex.MALE else female_color
		)
		multimesh.set_instance_color(i, color)

		if _using_swim_shader and multimesh.use_custom_data:
			var speed := agent.body.velocity.length()
			var target_amp := clampf(speed / max_speed, 0.18, 1.0)
			var turn_tgt := clampf(agent.body.angular_velocity.y / 2.5, -1.0, 1.0)
			var a := 1.0 - exp(-10.0 * maxf(delta, 0.0001))
			_swim_amp[i] = lerpf(_swim_amp[i], target_amp, a)
			_swim_turn[i] = lerpf(_swim_turn[i], turn_tgt, a)
			var hz := lerpf(idle_wave_hz, swim_wave_hz, _swim_amp[i])
			_swim_phase[i] = fmod(_swim_phase[i] + dt_vis * hz * TAU, TAU * 64.0)
			multimesh.set_instance_custom_data(
				i,
				Color(_swim_phase[i], _swim_amp[i], _swim_turn[i], breathe)
			)
	for i in range(n_show, n_slots):
		multimesh.set_instance_transform(i, hidden)
		if i < _disp_valid.size():
			_disp_valid[i] = 0
	_sync_eye_markers(world, n_show)


func _sync_eye_markers(world: SimulationWorld, n_show: int) -> void:
	if _eye_mmi == null or _eye_mmi.multimesh == null:
		return
	var want := show_eye_markers
	_eye_mmi.visible = want
	if not want:
		return
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -9999, 0))
	var mm := _eye_mmi.multimesh
	var locals := [
		TriopsSensors.EYE_LEFT_LOCAL,
		TriopsSensors.EYE_RIGHT_LOCAL,
		TriopsSensors.EYE_MEDIAN_LOCAL,
	]
	var colors := [eye_left_color, eye_right_color, eye_median_color]
	for i in int(mm.instance_count / 3):
		var show_i := i < n_show
		if show_i and eye_markers_selected_only:
			show_i = world.agents[i].id == world.selected_id
		for e in 3:
			var slot := i * 3 + e
			if not show_i:
				mm.set_instance_transform(slot, hidden)
				continue
			var agent: TriopsAgent = world.agents[i]
			var pos: Vector3
			var basis: Basis
			if i < _disp_valid.size() and _disp_valid[i] != 0:
				pos = _disp_pos[i]
				basis = _disp_basis[i]
			else:
				pos = agent.body.position
				basis = agent.body.orientation
			var eye := TriopsSensors.eye_world_pos(pos, basis, locals[e], agent.scale)
			mm.set_instance_transform(slot, Transform3D(Basis.IDENTITY, eye))
			mm.set_instance_color(slot, colors[e])
