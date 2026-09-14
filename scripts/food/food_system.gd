class_name FoodSystem
extends RefCounted
## V1: food particles in the aquarium volume (simulation data, not Nodes).
## Spatial hash accelerates ray / proximity / eat queries.

const CELL := 4.0

var positions: PackedVector3Array = PackedVector3Array()
var amounts: PackedFloat32Array = PackedFloat32Array()
var respawn_timers: PackedFloat32Array = PackedFloat32Array()
var active: PackedByteArray = PackedByteArray()  # 1 = present

var _grid: Dictionary = {} ## Vector3i -> PackedInt32Array
var _grid_dirty: bool = true


func initialize(config: SimulationConfig, rng: RandomNumberGenerator) -> void:
	positions.resize(config.food_count)
	amounts.resize(config.food_count)
	respawn_timers.resize(config.food_count)
	active.resize(config.food_count)
	for i in config.food_count:
		_spawn_at(i, config, rng)
		active[i] = 1
		respawn_timers[i] = 0.0
	_rebuild_grid()


func _spawn_at(i: int, config: SimulationConfig, rng: RandomNumberGenerator) -> void:
	var half := config.aquarium_half_extents * 0.9
	positions[i] = Vector3(
		rng.randf_range(-half.x, half.x),
		rng.randf_range(-half.y, half.y),
		rng.randf_range(-half.z, half.z)
	)
	amounts[i] = config.food_energy
	active[i] = 1
	respawn_timers[i] = 0.0
	_grid_dirty = true


func step(delta: float, config: SimulationConfig, rng: RandomNumberGenerator) -> void:
	var changed := false
	for i in positions.size():
		if active[i] == 1:
			continue
		respawn_timers[i] -= delta
		if respawn_timers[i] <= 0.0:
			_spawn_at(i, config, rng)
			changed = true
	if changed or _grid_dirty:
		_rebuild_grid()


func _cell_key(p: Vector3) -> Vector3i:
	return Vector3i(
		int(floor(p.x / CELL)),
		int(floor(p.y / CELL)),
		int(floor(p.z / CELL))
	)


func _rebuild_grid() -> void:
	_grid.clear()
	for i in positions.size():
		if active[i] == 0:
			continue
		var key := _cell_key(positions[i])
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		var bucket: PackedInt32Array = _grid[key]
		bucket.append(i)
		_grid[key] = bucket
	_grid_dirty = false


func prepare_queries() -> void:
	if _grid_dirty:
		_rebuild_grid()


func sync_landmarks(landmarks: PackedVector3Array, energy: float = 0.4) -> void:
	## Free-flight: procedural void markers act as visual figures (not edible meals).
	positions = landmarks.duplicate()
	amounts.resize(positions.size())
	respawn_timers.resize(positions.size())
	active.resize(positions.size())
	for i in positions.size():
		amounts[i] = energy
		respawn_timers[i] = 9999.0
		active[i] = 1
	_rebuild_grid()


## Indices of active food within radius (axis-aligned cell neighborhood).
## Call prepare_queries() on the main thread before parallel reads.
func nearby_indices(origin: Vector3, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var r_cells := int(ceil(radius / CELL))
	var c := _cell_key(origin)
	var r2 := radius * radius
	for x in range(c.x - r_cells, c.x + r_cells + 1):
		for y in range(c.y - r_cells, c.y + r_cells + 1):
			for z in range(c.z - r_cells, c.z + r_cells + 1):
				var key := Vector3i(x, y, z)
				if not _grid.has(key):
					continue
				var bucket: PackedInt32Array = _grid[key]
				for j in bucket.size():
					var i: int = bucket[j]
					if active[i] == 0:
						continue
					if origin.distance_squared_to(positions[i]) <= r2:
						out.append(i)
	return out


## Food intensity along a ray (0..1), cone-ish falloff.
func ray_food_signal(origin: Vector3, direction: Vector3, ray_length: float) -> float:
	return ray_food_signal_candidates(origin, direction, ray_length, nearby_indices(origin, ray_length))


const MAX_FOOD_RAY_CANDIDATES := 24


func ray_food_signal_candidates(
	origin: Vector3,
	direction: Vector3,
	ray_length: float,
	candidates: PackedInt32Array
) -> float:
	var dir := direction.normalized()
	var best := 0.0
	var n := mini(candidates.size(), MAX_FOOD_RAY_CANDIDATES)
	for j in n:
		var i: int = candidates[j]
		if active[i] == 0:
			continue
		var to := positions[i] - origin
		var dist := to.length()
		if dist < 0.001 or dist > ray_length:
			continue
		var align := to.normalized().dot(dir)
		if align < 0.35:
			continue
		var strength := align * (1.0 - dist / ray_length)
		if strength > best:
			best = strength
	return best


## Omnidirectional nearest food strength (backup / median eye).
func proximity_food(origin: Vector3, radius: float) -> float:
	var candidates := nearby_indices(origin, radius)
	var best := 0.0
	for j in candidates.size():
		var i: int = candidates[j]
		var dist := origin.distance_to(positions[i])
		if dist > radius:
			continue
		var s := 1.0 - dist / radius
		if s > best:
			best = s
	return best


## Eat nearest food within radius. Returns energy gained.
func try_eat(origin: Vector3, eat_radius: float, config: SimulationConfig) -> float:
	var candidates := nearby_indices(origin, eat_radius)
	var best_i := -1
	var best_d := eat_radius
	for j in candidates.size():
		var i: int = candidates[j]
		var d := origin.distance_to(positions[i])
		if d <= best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return 0.0
	var gained: float = amounts[best_i]
	active[best_i] = 0
	respawn_timers[best_i] = config.food_respawn_seconds
	amounts[best_i] = 0.0
	_grid_dirty = true
	return gained


func active_count() -> int:
	var n := 0
	for v in active:
		n += int(v)
	return n
