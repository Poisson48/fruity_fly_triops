class_name VoidSpaceVisual
extends Node3D
## Streaming flat ground + procedural pillars for free-flight corridor.

var _ground: MultiMeshInstance3D
var _markers: MultiMeshInstance3D
var _obstacles: MultiMeshInstance3D
var _tile_size: float = 24.0


func build() -> void:
	for c in get_children():
		c.queue_free()
	_ground = null
	_markers = null
	_obstacles = null

	_ground = MultiMeshInstance3D.new()
	_ground.name = "GroundTiles"
	var plane := PlaneMesh.new()
	plane.size = Vector2(_tile_size, _tile_size)
	plane.orientation = PlaneMesh.FACE_Y
	var gmat := StandardMaterial3D.new()
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gmat.albedo_color = Color(0.18, 0.22, 0.16, 1.0)
	gmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.material = gmat
	var gmm := MultiMesh.new()
	gmm.transform_format = MultiMesh.TRANSFORM_3D
	gmm.use_colors = true
	gmm.mesh = plane
	gmm.instance_count = 1
	_ground.multimesh = gmm
	add_child(_ground)

	_markers = MultiMeshInstance3D.new()
	_markers.name = "SurfaceMarkers"
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	sm.radial_segments = 6
	sm.rings = 3
	var mmat := StandardMaterial3D.new()
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.vertex_color_use_as_albedo = true
	sm.material = mmat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sm
	mm.instance_count = 1
	_markers.multimesh = mm
	add_child(_markers)

	_obstacles = MultiMeshInstance3D.new()
	_obstacles.name = "Obstacles"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 10
	var omat := StandardMaterial3D.new()
	omat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	omat.vertex_color_use_as_albedo = true
	cyl.material = omat
	var omm := MultiMesh.new()
	omm.transform_format = MultiMesh.TRANSFORM_3D
	omm.use_colors = true
	omm.mesh = cyl
	omm.instance_count = 1
	_obstacles.multimesh = omm
	add_child(_obstacles)


func sync_from_void(void_world: ProceduralVoid, _agent_pos: Vector3) -> void:
	if void_world == null:
		return
	_sync_ground(void_world)
	_sync_markers(void_world)
	_sync_obstacles(void_world)


func _sync_ground(void_world: ProceduralVoid) -> void:
	if _ground == null or _ground.multimesh == null:
		return
	var tiles: Array[Vector2i] = void_world.active_tile_list()
	var need := maxi(tiles.size(), 1)
	if _ground.multimesh.instance_count < need:
		_ground.multimesh.instance_count = need
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -99999, 0))
	var n := _ground.multimesh.instance_count
	var gy := ProceduralVoid.GROUND_Y
	for i in n:
		if i < tiles.size():
			var key: Vector2i = tiles[i]
			var center := Vector3(
				(float(key.x) + 0.5) * _tile_size,
				gy,
				(float(key.y) + 0.5) * _tile_size
			)
			var parity := (key.x + key.y) & 1
			var col := Color(0.22, 0.28, 0.18) if parity == 0 else Color(0.16, 0.20, 0.14)
			_ground.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, center))
			_ground.multimesh.set_instance_color(i, col)
		else:
			_ground.multimesh.set_instance_transform(i, hidden)


func _sync_markers(void_world: ProceduralVoid) -> void:
	if _markers == null or _markers.multimesh == null:
		return
	var pts := void_world.positions
	var need := maxi(pts.size(), 1)
	if _markers.multimesh.instance_count < need:
		_markers.multimesh.instance_count = need
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -99999, 0))
	var n := _markers.multimesh.instance_count
	for i in n:
		if i < pts.size():
			var p: Vector3 = pts[i]
			var h := fmod(absf(p.x * 0.07 + p.z * 0.11), 1.0)
			_markers.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
			_markers.multimesh.set_instance_color(i, Color.from_hsv(0.12 + h * 0.1, 0.45, 0.75))
		else:
			_markers.multimesh.set_instance_transform(i, hidden)


func _sync_obstacles(void_world: ProceduralVoid) -> void:
	if _obstacles == null or _obstacles.multimesh == null:
		return
	var need := maxi(void_world.obstacle_count, 1)
	if _obstacles.multimesh.instance_count < need:
		_obstacles.multimesh.instance_count = need
	var hidden := Transform3D(Basis.IDENTITY, Vector3(0, -99999, 0))
	var n := _obstacles.multimesh.instance_count
	for i in n:
		if i < void_world.obstacle_count:
			var o := i * 5
			var x: float = void_world.obstacle_data[o]
			var y0: float = void_world.obstacle_data[o + 1]
			var z: float = void_world.obstacle_data[o + 2]
			var rad: float = void_world.obstacle_data[o + 3]
			var h: float = void_world.obstacle_data[o + 4]
			var xf := Transform3D(
				Basis.from_scale(Vector3(rad, h, rad)),
				Vector3(x, y0 + h * 0.5, z)
			)
			_obstacles.multimesh.set_instance_transform(i, xf)
			var hue := fmod(absf(x * 0.03 + z * 0.05), 1.0)
			_obstacles.multimesh.set_instance_color(i, Color.from_hsv(0.05 + hue * 0.08, 0.55, 0.55))
		else:
			_obstacles.multimesh.set_instance_transform(i, hidden)
