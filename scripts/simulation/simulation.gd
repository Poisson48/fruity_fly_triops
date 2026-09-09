class_name SimulationWorld
extends RefCounted
## Headless simulation core: agents, food, eggs, evolution (V1–V6).

var config: SimulationConfig
var agents: Array[TriopsAgent] = []
var eggs: Array[Egg] = []
var food: FoodSystem = FoodSystem.new()
var stats: EvolutionStats = EvolutionStats.new()
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var time: float = 0.0
var step_count: int = 0
var selected_id: int = 0
var _next_id: int = 0
var _gpu_brain_accum: float = 0.0
var gpu_brain_dt: float = 1.0 / 12.0 ## 12 Hz neural — leaves headroom for render ≥30 FPS


func initialize(cfg: SimulationConfig) -> void:
	config = cfg
	rng.seed = cfg.seed
	time = 0.0
	step_count = 0
	selected_id = 0
	_next_id = 0
	agents.clear()
	eggs.clear()
	stats = EvolutionStats.new()
	food.initialize(cfg, rng)
	# Reset GPU brain bank for a fresh run, then warm pipelines while RD exists.
	var eng := GpuLifEngine.get_engine()
	eng.shutdown()
	eng.setup_failed = false
	_gpu_brain_accum = 0.0
	if cfg.brain_type == "drosophila":
		var template := ConnectomeCache.get_template(cfg.connectome_path)
		if template.neuron_count() > 0:
			eng.setup(template, cfg.max_triops)

	for _i in cfg.triops_count:
		_spawn_agent(null, null, null, 0)


func _create_brain(brain_type: String) -> Brain:
	match brain_type:
		"drosophila":
			return DrosophilaBrain.new()
		_:
			return TestBrain.new()


func _spawn_agent(
	genome: BrainGenome,
	pos: Variant,
	forced_sex: Variant,
	gen: int
) -> TriopsAgent:
	if agents.size() >= config.max_triops:
		return null
	var agent := TriopsAgent.new()
	var brain := _create_brain(config.brain_type)
	var sex_i: int = int(forced_sex) if typeof(forced_sex) == TYPE_INT else -1
	agent.setup(_next_id, config, rng, brain, genome, pos, gen, sex_i)
	_next_id += 1
	agents.append(agent)
	stats.births += 1
	stats.max_generation = maxi(stats.max_generation, agent.generation)
	if selected_id < 0:
		selected_id = agent.id
	return agent


func step(delta: float) -> void:
	food.step(delta, config, rng)

	var mate_lists: Array = []
	mate_lists.resize(agents.size())
	for i in agents.size():
		var list: Array[Vector3] = []
		var a: TriopsAgent = agents[i]
		if not a.alive:
			mate_lists[i] = list
			continue
		for j in agents.size():
			if i == j:
				continue
			var b: TriopsAgent = agents[j]
			if not b.alive or b.sex == a.sex:
				continue
			list.append(b.body.position)
		mate_lists[i] = list

	var gpu := GpuLifEngine.get_engine()
	var use_gpu_batch := config.brain_type == "drosophila" and gpu.ready and gpu.agent_count > 0

	if use_gpu_batch:
		_step_agents_gpu(delta, mate_lists, gpu)
	else:
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			agent.step(config, delta, food, mate_lists[i])
			if agent.last_ate:
				stats.meals += 1
			if not agent.alive:
				stats.record_death(agent.age_days(config))

	_process_mating()
	_process_eggs(delta)
	_remove_dead()
	_ensure_selection()

	time += delta
	step_count += 1


func _step_agents_gpu(delta: float, mate_lists: Array, gpu: GpuLifEngine) -> void:
	# Walls every physics frame (cheap); full vision + GPU brain on interval.
	_gpu_brain_accum += delta
	var wall_alert := false
	for i in agents.size():
		var agent: TriopsAgent = agents[i]
		if not agent.alive:
			continue
		if agent.sensors.wall_urgency_fast(
			agent.body.position,
			agent.body.orientation,
			config.aquarium_half_extents,
			config.eye_ray_length,
			agent.body.velocity
		) > 0.5:
			wall_alert = true
			break

	var interval := gpu_brain_dt * 0.45 if wall_alert else gpu_brain_dt
	var do_brain := _gpu_brain_accum >= interval
	if do_brain:
		_gpu_brain_accum = 0.0

	var packets: Array = []
	packets.resize(agents.size())

	for i in agents.size():
		var agent: TriopsAgent = agents[i]
		if not agent.alive:
			packets[i] = null
			continue
		agent.age += delta
		agent.mating_cooldown = maxf(0.0, agent.mating_cooldown - delta)
		agent._update_scale(config)
		var sensory: SensoryPacket
		if do_brain:
			sensory = agent.sensors.sense(
				agent.body.position,
				agent.body.orientation,
				config.aquarium_half_extents,
				config.eye_ray_length,
				food,
				mate_lists[i],
				config.mate_sense_radius,
				agent.body.velocity,
				config.food_sense_radius
			)
			sensory.apply_energy_motivation(agent.energy)
			agent.sensors.last_packet = sensory
		else:
			# Reuse last full vision; only nudge loom scalars for assists (no mosaic).
			sensory = agent.sensors.last_packet
			if sensory == null:
				sensory = SensoryPacket.new()
			_nudge_wall_scalars(agent, sensory)
		packets[i] = sensory

	if do_brain:
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive or packets[i] == null:
				continue
			var db := agent.brain as DrosophilaBrain
			if db:
				db.prepare_gpu_drive(packets[i])
		gpu.step(interval)
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive:
				continue
			var db := agent.brain as DrosophilaBrain
			if db:
				db.fetch_gpu_outputs()
	else:
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive or packets[i] == null:
				continue
			var db := agent.brain as DrosophilaBrain
			if db:
				db.refresh_interface(packets[i])

	for i in agents.size():
		var agent: TriopsAgent = agents[i]
		if not agent.alive:
			continue
		var db := agent.brain as DrosophilaBrain
		var outputs := db.get_outputs() if db else agent.brain.get_outputs()
		var cmd := agent.motor.decode(outputs)
		agent.body.apply_motor(cmd, config, delta)
		var move_cost: float = agent.body.velocity.length() * config.swim_energy_cost * delta
		agent.energy -= config.energy_drain_per_second * delta + move_cost
		var gained := food.try_eat(agent.body.position, config.eat_radius * agent.scale, config)
		agent.last_ate = gained > 0.0
		if agent.last_ate:
			agent.energy = minf(1.5, agent.energy + gained)
			stats.meals += 1
		if agent.energy < 0.15:
			agent.health -= config.starvation_health_drain * delta
		elif agent.energy > 0.5:
			agent.health = minf(1.0, agent.health + 0.02 * delta)
		agent.energy = clampf(agent.energy, 0.0, 1.5)
		agent.health = clampf(agent.health, 0.0, 1.0)
		if agent.health <= 0.0 or agent.age_days(config) >= config.max_lifespan_days:
			agent.alive = false
			stats.record_death(agent.age_days(config))


func _nudge_wall_scalars(agent: TriopsAgent, sensory: SensoryPacket) -> void:
	## Keep assist taxis roughly current without rebuilding 80-facet mosaics.
	var u := agent.sensors.wall_urgency_fast(
		agent.body.position,
		agent.body.orientation,
		config.aquarium_half_extents,
		config.eye_ray_length,
		agent.body.velocity
	)
	sensory.expand_m = maxf(sensory.expand_m * 0.85, u)
	sensory.expand_l = maxf(sensory.expand_l * 0.85, u * 0.7)
	sensory.expand_r = maxf(sensory.expand_r * 0.85, u * 0.7)
	if sensory.median_eye.size() >= 1:
		sensory.median_eye[0] = maxf(sensory.median_eye[0] * 0.85, u)
	if sensory.left_eye.size() >= 1:
		sensory.left_eye[0] = maxf(sensory.left_eye[0] * 0.85, u * 0.65)
	if sensory.right_eye.size() >= 1:
		sensory.right_eye[0] = maxf(sensory.right_eye[0] * 0.85, u * 0.65)
	sensory.floor_loom = agent.sensors.axis_loom(
		agent.body.position, Vector3.DOWN, config.aquarium_half_extents, config.eye_ray_length, agent.body.velocity
	)
	sensory.ceiling_loom = agent.sensors.axis_loom(
		agent.body.position, Vector3.UP, config.aquarium_half_extents, config.eye_ray_length, agent.body.velocity
	)


func _process_mating() -> void:
	var n := agents.size()
	for i in n:
		var a: TriopsAgent = agents[i]
		if not a.can_mate(config) or a.sex != TriopsAgent.Sex.FEMALE:
			continue
		for j in n:
			var b: TriopsAgent = agents[j]
			if a.id == b.id or not b.can_mate(config) or b.sex != TriopsAgent.Sex.MALE:
				continue
			if a.body.position.distance_to(b.body.position) > config.mating_distance:
				continue
			_lay_egg(a, b)
			break


func _lay_egg(female: TriopsAgent, male: TriopsAgent) -> void:
	var ga := female.genome
	var gb := male.genome
	if ga == null or gb == null:
		return

	var child_genome: BrainGenome
	if config.crossover_enabled:
		child_genome = BrainGenome.crossover(ga, gb, rng)
	else:
		child_genome = ga.duplicate_genome()
	child_genome.mutate(rng, config.mutation_rate, config.mutation_scale)

	var egg := Egg.new()
	egg.position = (female.body.position + male.body.position) * 0.5
	egg.genome = child_genome
	egg.hatch_in = config.egg_hatch_seconds
	egg.energy = config.egg_energy
	egg.parent_a = female.id
	egg.parent_b = male.id
	egg.generation = child_genome.generation
	eggs.append(egg)

	female.energy -= config.mating_energy_cost
	male.energy -= config.mating_energy_cost * 0.5
	female.mating_cooldown = config.mating_cooldown_seconds
	male.mating_cooldown = config.mating_cooldown_seconds
	stats.eggs_laid += 1


func _process_eggs(delta: float) -> void:
	var remaining: Array[Egg] = []
	for egg in eggs:
		egg.hatch_in -= delta
		if egg.hatch_in > 0.0:
			remaining.append(egg)
			continue
		if agents.size() >= config.max_triops:
			remaining.append(egg)
			continue
		var child := _spawn_agent(egg.genome, egg.position, null, egg.generation)
		if child:
			child.energy = egg.energy
	eggs = remaining


func _remove_dead() -> void:
	var living: Array[TriopsAgent] = []
	var gpu := GpuLifEngine.get_engine()
	for a in agents:
		if a.alive:
			living.append(a)
			continue
		var db := a.brain as DrosophilaBrain
		if db and db.use_gpu and db.gpu_slot >= 0:
			gpu.release_slot(db.gpu_slot)
			db.gpu_slot = -1
			db.use_gpu = false
	agents = living


func _ensure_selection() -> void:
	if agents.is_empty():
		selected_id = -1
		return
	if get_agent_by_id(selected_id) == null:
		selected_id = agents[0].id


func get_agent_by_id(id: int) -> TriopsAgent:
	for a in agents:
		if a.id == id:
			return a
	return null


func get_agent(index_or_selected: int) -> TriopsAgent:
	# Prefer id lookup for UI selection.
	var by_id := get_agent_by_id(index_or_selected)
	if by_id:
		return by_id
	if index_or_selected < 0 or index_or_selected >= agents.size():
		return null
	return agents[index_or_selected]


func select_next() -> void:
	if agents.is_empty():
		return
	var idx := 0
	for i in agents.size():
		if agents[i].id == selected_id:
			idx = i
			break
	selected_id = agents[(idx + 1) % agents.size()].id


func select_prev() -> void:
	if agents.is_empty():
		return
	var idx := 0
	for i in agents.size():
		if agents[i].id == selected_id:
			idx = i
			break
	selected_id = agents[(idx - 1 + agents.size()) % agents.size()].id


func living_count() -> int:
	return agents.size()


func sex_counts() -> Vector2i:
	var f := 0
	var m := 0
	for a in agents:
		if a.sex == TriopsAgent.Sex.MALE:
			m += 1
		else:
			f += 1
	return Vector2i(f, m)
