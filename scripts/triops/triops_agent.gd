class_name TriopsAgent
extends RefCounted
## Simulated Triops: body + 3 eyes + interchangeable brain + life stats.

enum Sex { FEMALE = 0, MALE = 1 }

var id: int = 0
var body: TriopsBody = TriopsBody.new()
var sensors: TriopsSensors = TriopsSensors.new()
var brain: Brain
var motor: MotorInterface = MotorInterface.new()

var alive: bool = true
var age: float = 0.0
var energy: float = 1.0
var health: float = 1.0
var scale: float = 1.0
var sex: int = Sex.FEMALE
var generation: int = 0
var mating_cooldown: float = 0.0
var genome: BrainGenome
var last_ate: bool = false


func setup(
	agent_id: int,
	config: SimulationConfig,
	rng: RandomNumberGenerator,
	brain_instance: Brain,
	genome_in: BrainGenome = null,
	spawn_pos: Variant = null,
	gen: int = 0,
	forced_sex: int = -1
) -> void:
	id = agent_id
	alive = true
	age = 0.0
	energy = config.initial_energy
	health = 1.0
	generation = gen
	mating_cooldown = 0.0
	sex = forced_sex if forced_sex >= 0 else (Sex.MALE if rng.randf() < 0.5 else Sex.FEMALE)

	brain = brain_instance
	brain.initialize(config, rng, genome_in)
	genome = brain.get_genome()
	if genome != null:
		generation = maxi(generation, genome.generation)

	var half := config.aquarium_half_extents * 0.8
	var pos: Vector3
	if typeof(spawn_pos) == TYPE_VECTOR3:
		pos = spawn_pos
	elif config.is_free_flight():
		pos = Vector3(0.0, 4.0, 0.0)
	else:
		# Keep spawn clear of floor/ceiling so peel doesn't fight birth dive.
		pos = Vector3(
			rng.randf_range(-half.x, half.x),
			rng.randf_range(-half.y * 0.55, half.y * 0.55),
			rng.randf_range(-half.z, half.z)
		)
	var yaw := 0.0 if config.is_free_flight() else rng.randf_range(0.0, TAU)
	var pitch := 0.0 if config.is_free_flight() else rng.randf_range(-0.35, 0.35)
	body.reset(pos, Basis.from_euler(Vector3(pitch, yaw, 0.0)))
	motor.configure_for_mode(config)
	_update_scale(config)


func step(
	config: SimulationConfig,
	delta: float,
	food: FoodSystem,
	mate_positions: Array[Vector3]
) -> void:
	if not alive:
		return

	age += delta
	mating_cooldown = maxf(0.0, mating_cooldown - delta)
	_update_scale(config)

	sensors.apply_config(config)
	var sensory := sensors.sense(
		body.position,
		body.orientation,
		config.aquarium_half_extents,
		config.eye_ray_length,
		food,
		mate_positions,
		config.mate_sense_radius,
		body.velocity,
		config.food_sense_radius,
		scale
	)
	sensory.apply_energy_motivation(energy)
	sensors.last_packet = sensory
	var outputs := brain.step(sensory, delta)
	var cmd := motor.decode(outputs)
	body.apply_motor(cmd, config, delta)

	var drain_m := genome.energy_drain_mult if genome else 1.0
	var swim_m := genome.swim_cost_mult if genome else 1.0
	var eat_m := genome.eat_radius_mult if genome else 1.0

	# Metabolism (V2): drain + swimming cost — no scripted foraging.
	var move_cost: float = body.velocity.length() * config.swim_energy_cost * swim_m * delta
	energy -= config.energy_drain_per_second * drain_m * delta + move_cost

	var gained := food.try_eat(body.position, config.eat_radius * scale * eat_m, config)
	last_ate = gained > 0.0
	if last_ate:
		energy = minf(1.5, energy + gained)

	if energy < 0.15:
		health -= config.starvation_health_drain * delta
	elif energy > 0.5:
		health = minf(1.0, health + 0.02 * delta)

	energy = clampf(energy, 0.0, 1.5)
	health = clampf(health, 0.0, 1.0)

	var age_d := age_days(config)
	if health <= 0.0 or age_d >= config.max_lifespan_days:
		alive = false


func _update_scale(config: SimulationConfig) -> void:
	var t := clampf(age_days(config) / maxf(config.mature_age_days, 0.01), 0.0, 1.0)
	var body_s := genome.body_scale if genome else 1.0
	scale = lerpf(config.min_scale, config.max_scale, t) * body_s


func age_days(config: SimulationConfig) -> float:
	if config.seconds_per_sim_day <= 0.0:
		return 0.0
	return age / config.seconds_per_sim_day


func is_mature(config: SimulationConfig) -> bool:
	var mat_m := genome.maturity_age_mult if genome else 1.0
	return age_days(config) >= config.mature_age_days * mat_m


func can_mate(config: SimulationConfig) -> bool:
	return (
		alive
		and is_mature(config)
		and mating_cooldown <= 0.0
		and energy >= config.mating_energy_min
	)


func get_debug_state() -> Dictionary:
	var sensory := sensors.last_packet
	var ginfo := {}
	if genome:
		ginfo = {
			"depth_pref": genome.depth_pref,
			"body_scale": genome.body_scale,
			"energy_drain_mult": genome.energy_drain_mult,
			"swim_cost_mult": genome.swim_cost_mult,
			"eat_radius_mult": genome.eat_radius_mult,
			"maturity_age_mult": genome.maturity_age_mult,
			"syn_scale_gene": genome.syn_scale_gene,
			"drive_gain_gene": genome.drive_gain_gene,
			"sense_food": genome.sense_gains[0] if genome.sense_gains.size() > 0 else 0.0,
			"sense_wall": genome.sense_gains[1] if genome.sense_gains.size() > 1 else 0.0,
			"motor_yaw": (
				genome.motor_gains[MotorInterface.CHANNEL_YAW]
				if genome.motor_gains.size() > MotorInterface.CHANNEL_YAW
				else 0.0
			),
			"plastic_syn": genome.has_plastic_synapses(),
		}
	return {
		"id": id,
		"alive": alive,
		"sex": "M" if sex == Sex.MALE else "F",
		"age": age,
		"energy": energy,
		"health": health,
		"scale": scale,
		"generation": generation,
		"position": body.position,
		"velocity": body.velocity,
		"orientation": body.orientation.get_euler(),
		"sensor_inputs": {
			"left_eye": Array(sensory.left_eye),
			"right_eye": Array(sensory.right_eye),
			"median_eye": Array(sensory.median_eye),
			"food_motivation": sensory.food_motivation,
			"mate_motivation": sensory.mate_motivation,
		},
		"brain_outputs": Array(brain.get_outputs()) if brain else [],
		"brain": brain.get_debug_info() if brain else {},
		"genome": ginfo,
	}
