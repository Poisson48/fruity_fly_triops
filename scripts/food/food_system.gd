class_name FoodSystem
extends RefCounted
## V1: food particles in the aquarium volume (simulation data, not Nodes).

var positions: PackedVector3Array = PackedVector3Array()
var amounts: PackedFloat32Array = PackedFloat32Array()
var respawn_timers: PackedFloat32Array = PackedFloat32Array()
var active: PackedByteArray = PackedByteArray()  # 1 = present


func initialize(config: SimulationConfig, rng: RandomNumberGenerator) -> void:
	positions.resize(config.food_count)
	amounts.resize(config.food_count)
	respawn_timers.resize(config.food_count)
	active.resize(config.food_count)
	for i in config.food_count:
		_spawn_at(i, config, rng)
		active[i] = 1
		respawn_timers[i] = 0.0


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


func step(delta: float, config: SimulationConfig, rng: RandomNumberGenerator) -> void:
	for i in positions.size():
		if active[i] == 1:
			continue
		respawn_timers[i] -= delta
		if respawn_timers[i] <= 0.0:
			_spawn_at(i, config, rng)


## Food intensity along a ray (0..1), cone-ish falloff.
func ray_food_signal(origin: Vector3, direction: Vector3, ray_length: float) -> float:
	var dir := direction.normalized()
	var best := 0.0
	for i in positions.size():
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
	var best := 0.0
	for i in positions.size():
		if active[i] == 0:
			continue
		var dist := origin.distance_to(positions[i])
		if dist > radius:
			continue
		var s := 1.0 - dist / radius
		if s > best:
			best = s
	return best


## Eat nearest food within radius. Returns energy gained.
func try_eat(origin: Vector3, eat_radius: float, config: SimulationConfig) -> float:
	var best_i := -1
	var best_d := eat_radius
	for i in positions.size():
		if active[i] == 0:
			continue
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
	return gained


func active_count() -> int:
	var n := 0
	for v in active:
		n += int(v)
	return n
