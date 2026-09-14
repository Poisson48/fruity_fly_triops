class_name ProceduralVoid
extends RefCounted
## Free-flight corridor: stream ground + pillars; goal = advance along -Z.

const TILE := 24.0
const KEEP_RADIUS := 3
const GROUND_Y := 0.0
const MARKERS_PER_TILE := 4
## World goal direction (Godot forward).
const GOAL_DIR := Vector3(0.0, 0.0, -1.0)
const OBSTACLES_PER_TILE := 2
const OBSTACLE_MIN_R := 1.0
const OBSTACLE_MAX_R := 2.0
const OBSTACLE_MIN_H := 5.0
const OBSTACLE_MAX_H := 10.0
## Racing corridor: clear center lane, staggered side gates to dodge.
const CLEAR_FORWARD := 22.0
const CLEAR_LANE := 4.0
const GATE_OFFSET := 6.5

var seed: int = 42
var spawn_pos: Vector3 = Vector3.ZERO
var tile_keys: Dictionary = {}
## Ground optic-flow markers (not collision).
var positions: PackedVector3Array = PackedVector3Array()
## Pillar obstacles: x, y_base, z, radius, height (5 floats each).
var obstacle_data: PackedFloat32Array = PackedFloat32Array()
var obstacle_count: int = 0
## Progress along goal axis (always go further forward).
var forward_progress: float = 0.0
var best_progress: float = 0.0
var current_distance: float = 0.0
var best_distance: float = 0.0
## Lateral drift from corridor centerline (spawn X).
var lateral_error: float = 0.0


func initialize(world_seed: int, start: Vector3 = Vector3(0.0, 4.0, 0.0)) -> void:
	seed = world_seed
	spawn_pos = start
	tile_keys.clear()
	positions = PackedVector3Array()
	obstacle_data = PackedFloat32Array()
	obstacle_count = 0
	forward_progress = 0.0
	best_progress = 0.0
	current_distance = 0.0
	best_distance = 0.0
	lateral_error = 0.0
	step(start)


func step(center: Vector3) -> void:
	# Progress = how far along -Z from spawn (straight-ahead objective).
	forward_progress = spawn_pos.z - center.z
	best_progress = maxf(best_progress, forward_progress)
	current_distance = Vector2(center.x - spawn_pos.x, center.z - spawn_pos.z).length()
	best_distance = maxf(best_distance, current_distance)
	lateral_error = center.x - spawn_pos.x

	var cx := int(floor(center.x / TILE))
	var cz := int(floor(center.z / TILE))
	var needed: Dictionary = {}
	var added := false
	for dx in range(-KEEP_RADIUS, KEEP_RADIUS + 1):
		for dz in range(-KEEP_RADIUS, KEEP_RADIUS + 1):
			var key := Vector2i(cx + dx, cz + dz)
			needed[key] = true
			if not tile_keys.has(key):
				tile_keys[key] = true
				added = true
	var dropped := false
	var drop: Array = []
	for k in tile_keys.keys():
		if not needed.has(k):
			drop.append(k)
	for k in drop:
		tile_keys.erase(k)
		dropped = true
	if added or dropped or positions.is_empty() or obstacle_count == 0:
		_rebuild_world()


func ground_y_at(_xz: Vector3) -> float:
	return GROUND_Y


func active_tile_list() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in tile_keys.keys():
		out.append(k)
	return out


func nearby(origin: Vector3, radius: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var r2 := radius * radius
	for i in positions.size():
		if origin.distance_squared_to(positions[i]) <= r2:
			out.append(positions[i])
	return out


func obstacle_center(i: int) -> Vector3:
	var o := i * 5
	return Vector3(obstacle_data[o], obstacle_data[o + 1] + obstacle_data[o + 4] * 0.5, obstacle_data[o + 2])


func obstacle_radius(i: int) -> float:
	return obstacle_data[i * 5 + 3]


func obstacle_height(i: int) -> float:
	return obstacle_data[i * 5 + 4]


func ray_obstacle_t(origin: Vector3, direction: Vector3, ray_length: float) -> float:
	## Nearest hit distance along ray against vertical cylinders (0..ray_length).
	var dir := direction.normalized()
	var best := ray_length
	for i in obstacle_count:
		var o := i * 5
		var cx: float = obstacle_data[o]
		var y0: float = obstacle_data[o + 1]
		var cz: float = obstacle_data[o + 2]
		var rad: float = obstacle_data[o + 3]
		var h: float = obstacle_data[o + 4]
		var t := _ray_cylinder_t(origin, dir, Vector3(cx, y0, cz), rad, h, ray_length)
		if t < best:
			best = t
	return best


func collide_body(position: Vector3, clearance: float = 0.65) -> Vector3:
	## Soft push out of overlapping pillars (XZ). Returns corrected position.
	var p := position
	for i in obstacle_count:
		var o := i * 5
		var cx: float = obstacle_data[o]
		var y0: float = obstacle_data[o + 1]
		var cz: float = obstacle_data[o + 2]
		var rad: float = obstacle_data[o + 3]
		var h: float = obstacle_data[o + 4]
		if p.y < y0 - 0.2 or p.y > y0 + h + 0.5:
			continue
		var dx := p.x - cx
		var dz := p.z - cz
		var d := sqrt(dx * dx + dz * dz)
		var need := rad + clearance
		if d < need and d > 1e-4:
			var push := (need - d) / d
			p.x += dx * push
			p.z += dz * push
		elif d <= 1e-4:
			p.x += need
	return p


func heading_error_yaw(orientation: Basis) -> float:
	## Signed yaw to align body forward (-Z) with GOAL_DIR. + = turn left (CCW).
	var flat := Vector2(-orientation.z.x, -orientation.z.z)
	if flat.length_squared() < 1e-8:
		return 0.0
	flat = flat.normalized()
	var goal := Vector2(GOAL_DIR.x, GOAL_DIR.z)  ## (0, -1)
	var ang := flat.angle_to(goal)  ## CCW from forward to goal
	return clampf(ang / (PI * 0.5), -1.5, 1.5)


func _rebuild_world() -> void:
	positions = PackedVector3Array()
	obstacle_data = PackedFloat32Array()
	obstacle_count = 0
	for k in tile_keys.keys():
		var key: Vector2i = k
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(Vector3i(seed, key.x, key.y))
		var base := Vector3(float(key.x) * TILE, GROUND_Y, float(key.y) * TILE)
		for _i in MARKERS_PER_TILE:
			positions.append(
				base
				+ Vector3(
					rng.randf_range(1.0, TILE - 1.0),
					rng.randf_range(0.35, 1.6),
					rng.randf_range(1.0, TILE - 1.0)
				)
			)
		# Staggered gates along -Z: alternate L/R so a straight dash weaves briefly.
		# Only place on tiles near the centerline corridor (not the whole plane).
		if absf(float(key.x) * TILE + TILE * 0.5 - spawn_pos.x) < TILE * 1.6:
			for g in 2:
				var oz := base.z + 6.0 + float(g) * 10.0 + rng.randf_range(-1.5, 1.5)
				var ahead := spawn_pos.z - oz
				if ahead > -2.0 and ahead < CLEAR_FORWARD:
					continue
				# Alternate side by world-z index so path is a gentle slalom.
				var side := 1.0 if (key.y * 2 + g) % 2 == 0 else -1.0
				var ox := spawn_pos.x + side * (GATE_OFFSET + rng.randf_range(-0.8, 1.2))
	# Near-center blockers less often — prefer side gates for a straight dash.
				if rng.randf() < 0.12:
					ox = spawn_pos.x + side * rng.randf_range(2.4, 3.8)
				var rad := rng.randf_range(OBSTACLE_MIN_R, OBSTACLE_MAX_R)
				var h := rng.randf_range(OBSTACLE_MIN_H, OBSTACLE_MAX_H)
				obstacle_data.append(ox)
				obstacle_data.append(GROUND_Y)
				obstacle_data.append(oz)
				obstacle_data.append(rad)
				obstacle_data.append(h)
				obstacle_count += 1


func _ray_cylinder_t(
	origin: Vector3,
	dir: Vector3,
	base: Vector3,
	radius: float,
	height: float,
	ray_length: float
) -> float:
	## Finite vertical cylinder: solve XZ circle, clip to [y0, y0+h].
	var ox := origin.x - base.x
	var oz := origin.z - base.z
	var dx := dir.x
	var dz := dir.z
	var a := dx * dx + dz * dz
	var best := ray_length
	if a < 1e-8:
		# Vertical ray: hit only if inside circle and going toward height band.
		if ox * ox + oz * oz > radius * radius:
			return ray_length
		var y0 := base.y
		var y1 := base.y + height
		if dir.y > 0.0 and origin.y < y0:
			best = minf(best, (y0 - origin.y) / dir.y)
		elif dir.y < 0.0 and origin.y > y1:
			best = minf(best, (y1 - origin.y) / dir.y)
		elif origin.y >= y0 and origin.y <= y1:
			best = 0.0
		return best if best >= 0.0 and best <= ray_length else ray_length
	var b := 2.0 * (ox * dx + oz * dz)
	var c := ox * ox + oz * oz - radius * radius
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return ray_length
	var sd := sqrt(disc)
	for sign_i in 2:
		var sign := -1.0 if sign_i == 0 else 1.0
		var t: float = (-b + sign * sd) / (2.0 * a)
		if t < 0.0 or t > ray_length:
			continue
		var y: float = origin.y + dir.y * t
		if y >= base.y - 0.05 and y <= base.y + height + 0.05:
			best = minf(best, t)
	return best
