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
var gpu_brain_dt: float = 1.0 / 12.0 ## 12 Hz neural at 1× wall-clock
## User time acceleration — brain interval scales so GPU cost stays ~constant in wall time.
var speed_scale: float = 1.0
var fps_ema: float = 60.0
var _brains_this_frame: int = 0
const MAX_BRAINS_PER_FRAME := 1
## Threads help at mid/high agent counts; overhead hurts Easy (N≈12).
const THREAD_AGENT_THRESHOLD := 20
var _wall_urgency_tick: int = 0
## Multithread scratch (group tasks).
var _mt_delta: float = 0.0
var _mt_do_brain: bool = false
var _mt_mate_lists: Array = []
var _mt_packets: Array = []
var _mt_need_mates: bool = false
var _mt_nudge_walls: bool = false
var _use_threads: bool = true
var _nudge_tick: int = 0
var void_space: ProceduralVoid = ProceduralVoid.new()


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
		var spawn: Variant = Vector3(0.0, 4.0, 0.0) if cfg.is_free_flight() else null
		_spawn_agent(null, spawn, null, 0)
	if cfg.is_free_flight() and not agents.is_empty():
		var start: Vector3 = agents[0].body.position
		void_space.initialize(cfg.seed, start)
		food.sync_landmarks(void_space.positions)
		selected_id = agents[0].id


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
	agent.motor.configure_for_mode(config)
	_next_id += 1
	agents.append(agent)
	stats.births += 1
	stats.max_generation = maxi(stats.max_generation, agent.generation)
	if selected_id < 0:
		selected_id = agent.id
	return agent


func begin_frame() -> void:
	_brains_this_frame = 0


func step(delta: float) -> void:
	var free := config.is_free_flight()
	if free and not agents.is_empty():
		var lead: TriopsAgent = agents[0]
		if lead != null and lead.alive:
			void_space.step(lead.body.position)
			food.sync_landmarks(void_space.positions)
			# Immortal solo fly.
			lead.alive = true
			lead.energy = 1.5
			lead.health = 1.0
	elif not free:
		food.step(delta, config, rng)
	food.prepare_queries()

	var gpu := GpuLifEngine.get_engine()
	var use_gpu_batch := config.brain_type == "drosophila" and gpu.ready and gpu.agent_count > 0
	var n := agents.size()
	var threaded := (not free) and _use_threads and n >= THREAD_AGENT_THRESHOLD

	# Mate lists only when a full vision/brain tick may need them (or CPU path).
	_mt_need_mates = (not free) and (not use_gpu_batch)
	if use_gpu_batch and not free:
		var interval_guess := gpu_brain_dt * maxf(1.0, speed_scale)
		_mt_need_mates = (_gpu_brain_accum + delta) >= interval_guess * 0.45

	_mt_mate_lists = []
	_mt_mate_lists.resize(n)
	if threaded and _mt_need_mates:
		var gid := WorkerThreadPool.add_group_task(_mt_build_mates, n, -1, true, "mates")
		WorkerThreadPool.wait_for_group_task_completion(gid)
	else:
		for i in n:
			_mt_build_mates(i)

	if use_gpu_batch:
		_step_agents_gpu(delta, _mt_mate_lists, gpu, threaded)
	elif threaded:
		_step_agents_cpu_mt(delta, _mt_mate_lists)
	else:
		for i in n:
			var agent: TriopsAgent = agents[i]
			agent.step(config, delta, food, _mt_mate_lists[i])
			if agent.last_ate:
				stats.meals += 1
			if not agent.alive:
				stats.record_death(agent.age_days(config))

	if not free:
		_process_mating()
		_process_eggs(delta)
		_remove_dead()
	_ensure_selection()

	time += delta
	step_count += 1
	# Trait telemetry ~1 Hz sim time.
	if step_count % maxi(1, int(round(1.0 / maxf(config.simulation_dt, 0.001)))) == 0:
		stats.sample_population(agents)


func _eat_radius_for(agent: TriopsAgent) -> float:
	var eat_m := agent.genome.eat_radius_mult if agent.genome else 1.0
	return config.eat_radius * agent.scale * eat_m


func _apply_metabolism(agent: TriopsAgent, delta: float) -> void:
	if config.is_free_flight():
		agent.energy = 1.5
		agent.health = 1.0
		return
	var drain_m := agent.genome.energy_drain_mult if agent.genome else 1.0
	var swim_m := agent.genome.swim_cost_mult if agent.genome else 1.0
	var move_cost: float = agent.body.velocity.length() * config.swim_energy_cost * swim_m * delta
	agent.energy -= config.energy_drain_per_second * drain_m * delta + move_cost


func _mt_build_mates(i: int) -> void:
	var list: Array[Vector3] = []
	if _mt_need_mates:
		var a: TriopsAgent = agents[i]
		if a.alive:
			for j in agents.size():
				if i == j:
					continue
				var b: TriopsAgent = agents[j]
				if not b.alive or b.sex == a.sex:
					continue
				list.append(b.body.position)
	_mt_mate_lists[i] = list


func _step_agents_cpu_mt(delta: float, mate_lists: Array) -> void:
	_mt_delta = delta
	_mt_mate_lists = mate_lists
	var n := agents.size()
	var gid := WorkerThreadPool.add_group_task(_mt_cpu_agent_body, n, -1, true, "cpu_agents")
	WorkerThreadPool.wait_for_group_task_completion(gid)
	# Eating must stay serial (mutates food).
	for i in n:
		var agent: TriopsAgent = agents[i]
		if not agent.alive:
			continue
		var gained := food.try_eat(agent.body.position, _eat_radius_for(agent), config)
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


func _mt_cpu_agent_body(i: int) -> void:
	## Sense + brain + motor on worker; eat deferred to main.
	var agent: TriopsAgent = agents[i]
	if agent == null or not agent.alive or agent.brain == null:
		return
	var delta := _mt_delta
	agent.age += delta
	agent.mating_cooldown = maxf(0.0, agent.mating_cooldown - delta)
	agent._update_scale(config)
	agent.sensors.apply_config(config)
	var sensory := agent.sensors.sense(
		agent.body.position,
		agent.body.orientation,
		config.aquarium_half_extents,
		config.eye_ray_length,
		food,
		_mt_mate_lists[i],
		config.mate_sense_radius,
		agent.body.velocity,
		config.food_sense_radius,
		agent.scale
	)
	sensory.apply_energy_motivation(agent.energy)
	agent.sensors.last_packet = sensory
	var outputs := agent.brain.step(sensory, delta)
	var cmd := agent.motor.decode(outputs)
	agent.body.apply_motor(cmd, config, delta)
	_post_body(agent)
	_apply_metabolism(agent, delta)

func _step_agents_gpu(delta: float, mate_lists: Array, gpu: GpuLifEngine, threaded: bool = false) -> void:
	# Walls every few physics frames (cheap); full vision + GPU brain on interval.
	# speed_scale stretches the neural interval so 8×/16× doesn't multiply Vulkan syncs.
	_gpu_brain_accum += delta
	_wall_urgency_tick = (_wall_urgency_tick + 1) % 2
	var wall_alert := false
	var food_alert := false
	if _wall_urgency_tick == 0:
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive:
				continue
			if config.is_free_flight():
				var h: float = agent.body.position.y
				var pref: float = config.flight_preferred_altitude
				var band: float = config.flight_altitude_band
				if h < pref - band * 0.55 or h > pref + band * 0.85:
					wall_alert = true
				var lp0: SensoryPacket = agent.sensors.last_packet
				if lp0 != null:
					if maxf(lp0.floor_loom, lp0.ceiling_loom) > 0.45:
						wall_alert = true
					if maxf(lp0.expand_m, maxf(_ch_pkt(lp0.left_eye, 0), _ch_pkt(lp0.right_eye, 0))) > 0.22:
						wall_alert = true
			elif agent.sensors.wall_urgency_fast(
				agent.body.position,
				agent.body.orientation,
				config.aquarium_half_extents,
				config.eye_ray_length,
				agent.body.velocity
			) > 0.5:
				wall_alert = true
			var lp: SensoryPacket = agent.sensors.last_packet
			if lp != null and lp.food_bearing_strength > 0.35:
				food_alert = true
			if wall_alert and food_alert:
				break
	else:
		# Reuse last alerts lightly — prefer food from packets without 5-ray scan.
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive:
				continue
			var lp: SensoryPacket = agent.sensors.last_packet
			if lp != null:
				if config.is_free_flight():
					if maxf(lp.floor_loom, lp.ceiling_loom) > 0.45 or lp.expand_m > 0.5:
						wall_alert = true
				elif lp.expand_m > 0.5:
					wall_alert = true
				if lp.food_bearing_strength > 0.35:
					food_alert = true
			if wall_alert and food_alert:
				break

	var interval := gpu_brain_dt * maxf(1.0, speed_scale)
	# Mild alert boost — aggressive 0.55× doubled Vulkan syncs and killed FPS.
	if wall_alert:
		interval *= 0.8
	elif food_alert:
		interval *= 0.9
	# Solo free-flight: SEZ every physics tick so loom → dodge stays sharp.
	var do_brain := true if config.is_free_flight() else (
		_gpu_brain_accum >= interval and _brains_this_frame < MAX_BRAINS_PER_FRAME
	)
	if do_brain:
		_gpu_brain_accum = 0.0
		_brains_this_frame += 1

	_mt_delta = delta
	_mt_do_brain = do_brain
	_mt_mate_lists = mate_lists
	_mt_packets = []
	_mt_packets.resize(agents.size())
	# Cheap wall nudge only every other physics step when not running a brain tick.
	_nudge_tick = (_nudge_tick + 1) % 2
	_mt_nudge_walls = do_brain or _nudge_tick == 0

	if threaded:
		var gid := WorkerThreadPool.add_group_task(_mt_gpu_sense, agents.size(), -1, true, "sense")
		WorkerThreadPool.wait_for_group_task_completion(gid)
	else:
		for i in agents.size():
			_mt_gpu_sense(i)

	if do_brain:
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive or _mt_packets[i] == null:
				continue
			var db := agent.brain as DrosophilaBrain
			if db == null:
				continue
			if db.use_gpu:
				db.prepare_gpu_drive(_mt_packets[i])
			else:
				# Plastic / CPU-fallback agent inside a GPU world.
				db.step(_mt_packets[i], interval)
		if gpu.agent_count > 0:
			gpu.step(interval)
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if not agent.alive:
				continue
			var db := agent.brain as DrosophilaBrain
			if db and db.use_gpu:
				db.fetch_gpu_outputs()
	else:
		if threaded:
			var gid2 := WorkerThreadPool.add_group_task(_mt_refresh_iface, agents.size(), -1, true, "iface")
			WorkerThreadPool.wait_for_group_task_completion(gid2)
		else:
			for i in agents.size():
				_mt_refresh_iface(i)

	if threaded:
		var gid3 := WorkerThreadPool.add_group_task(_mt_gpu_body, agents.size(), -1, true, "body")
		WorkerThreadPool.wait_for_group_task_completion(gid3)
	else:
		for i in agents.size():
			_mt_gpu_body(i)

	# Serial food mutation + death bookkeeping.
	if config.is_free_flight():
		for i in agents.size():
			var agent: TriopsAgent = agents[i]
			if agent == null:
				continue
			agent.alive = true
			agent.energy = 1.5
			agent.health = 1.0
			agent.last_ate = false
		return
	for i in agents.size():
		var agent: TriopsAgent = agents[i]
		if not agent.alive:
			continue
		var gained := food.try_eat(agent.body.position, _eat_radius_for(agent), config)
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


func _mt_gpu_sense(i: int) -> void:
	var agent: TriopsAgent = agents[i]
	if not agent.alive:
		_mt_packets[i] = null
		return
	var delta := _mt_delta
	agent.age += delta
	agent.mating_cooldown = maxf(0.0, agent.mating_cooldown - delta)
	agent._update_scale(config)
	var sensory: SensoryPacket
	var half := config.aquarium_half_extents
	if config.is_free_flight():
		half = Vector3(1.0e6, 1.0e6, 1.0e6)
	if _mt_do_brain:
		agent.sensors.apply_config(config)
		sensory = agent.sensors.sense(
			agent.body.position,
			agent.body.orientation,
			half,
			config.eye_ray_length,
			food,
			_mt_mate_lists[i],
			config.mate_sense_radius,
			agent.body.velocity,
			config.food_sense_radius,
			agent.scale
		)
		if config.is_free_flight():
			# Landmark ON is for weak optic texture only — obstacles own loom.
			sensory.expand_l *= 0.2
			sensory.expand_r *= 0.2
			sensory.expand_m *= 0.2
			agent.sensors.apply_obstacles(
				sensory,
				agent.body.position,
				agent.body.orientation,
				agent.body.velocity,
				void_space,
				config.eye_ray_length,
				agent.scale
			)
			agent.sensors.apply_flight_altitude(
				sensory,
				agent.body.position,
				agent.body.velocity,
				config.flight_preferred_altitude,
				config.flight_altitude_band,
				config.eye_ray_length
			)
			agent.sensors.apply_corridor_goal(sensory, agent.body.orientation, void_space)
		sensory.apply_energy_motivation(agent.energy)
		agent.sensors.last_packet = sensory
	else:
		sensory = agent.sensors.last_packet
		if sensory == null:
			sensory = SensoryPacket.new()
		if config.is_free_flight():
			agent.sensors.apply_obstacles(
				sensory,
				agent.body.position,
				agent.body.orientation,
				agent.body.velocity,
				void_space,
				config.eye_ray_length,
				agent.scale
			)
			agent.sensors.apply_flight_altitude(
				sensory,
				agent.body.position,
				agent.body.velocity,
				config.flight_preferred_altitude,
				config.flight_altitude_band,
				config.eye_ray_length
			)
			agent.sensors.apply_corridor_goal(sensory, agent.body.orientation, void_space)
		elif _mt_nudge_walls:
			_nudge_wall_scalars(agent, sensory)
	_mt_packets[i] = sensory


func _mt_refresh_iface(i: int) -> void:
	var agent: TriopsAgent = agents[i]
	if not agent.alive or _mt_packets[i] == null:
		return
	var db := agent.brain as DrosophilaBrain
	if db:
		db.refresh_interface(_mt_packets[i])


func _mt_gpu_body(i: int) -> void:
	var agent: TriopsAgent = agents[i]
	if agent == null or not agent.alive or agent.brain == null:
		return
	var delta := _mt_delta
	var db := agent.brain as DrosophilaBrain
	var outputs := db.get_outputs() if db else agent.brain.get_outputs()
	var cmd := agent.motor.decode(outputs)
	agent.body.apply_motor(cmd, config, delta)
	_post_body(agent)
	_apply_metabolism(agent, delta)


func _post_body(agent: TriopsAgent) -> void:
	if config != null and config.is_free_flight():
		agent.body.collide_void_obstacles(void_space)


func _ch_pkt(eye: PackedFloat32Array, i: int) -> float:
	return eye[i] if i < eye.size() else 0.0


func _nudge_wall_scalars(agent: TriopsAgent, sensory: SensoryPacket) -> void:
	## AABB proximity only — full 5-ray urgency every physics step was a FPS killer.
	var half := config.aquarium_half_extents
	var m := config.wall_margin
	var p := agent.body.position
	var d_wall := minf(
		minf(half.x - m - absf(p.x), half.z - m - absf(p.z)),
		half.y - m - absf(p.y)
	)
	var u := clampf(1.0 - d_wall / maxf(config.eye_ray_length * 0.35, 1.0), 0.0, 1.0)
	sensory.expand_m = maxf(sensory.expand_m * 0.85, u)
	sensory.expand_l = maxf(sensory.expand_l * 0.85, u * 0.7)
	sensory.expand_r = maxf(sensory.expand_r * 0.85, u * 0.7)
	if sensory.median_eye.size() >= 1:
		sensory.median_eye[0] = maxf(sensory.median_eye[0] * 0.85, u)
	if sensory.left_eye.size() >= 1:
		sensory.left_eye[0] = maxf(sensory.left_eye[0] * 0.85, u * 0.65)
	if sensory.right_eye.size() >= 1:
		sensory.right_eye[0] = maxf(sensory.right_eye[0] * 0.85, u * 0.65)
	sensory.floor_loom = clampf(1.0 - (p.y + half.y - m) / 3.0, 0.0, 1.0)
	sensory.ceiling_loom = clampf(1.0 - (half.y - m - p.y) / 3.0, 0.0, 1.0)
	# Refresh nearest-food bearing cheaply so yaw stays purposeful between brain ticks.
	if food != null and u < 0.85:
		var near := food.nearby_indices(agent.body.position, config.food_sense_radius)
		var bear: Vector2 = agent.sensors._nearest_bearing(
			agent.body.position, agent.body.orientation, food, near, config.food_sense_radius
		)
		sensory.food_bearing_yaw = bear.x
		sensory.food_bearing_strength = bear.y
		if sensory.food_bearing_strength > 0.08 and absf(sensory.food_bearing_yaw) > 0.04:
			var nudge := sensory.food_bearing_yaw * sensory.food_bearing_strength * 0.45
			if sensory.left_eye.size() > 1:
				sensory.left_eye[1] = minf(maxf(sensory.left_eye[1] * 0.92, 0.0) + maxf(nudge, 0.0), 3.5)
			if sensory.right_eye.size() > 1:
				sensory.right_eye[1] = minf(maxf(sensory.right_eye[1] * 0.92, 0.0) + maxf(-nudge, 0.0), 3.5)


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
	# Drosophila: skip dead adapter loci unless interface_mix is active.
	var mutate_adapter := (
		config.brain_type != "drosophila" or child_genome.interface_mix > 0.01
	)
	child_genome.mutate(
		rng,
		config.mutation_rate,
		config.mutation_scale,
		mutate_adapter,
		config.connectome_evolution_enabled
	)
	if config.connectome_evolution_enabled and child_genome.synapse_ids.is_empty():
		# Inherit loci from a parent if present; else fill at hatch via brain init.
		if not ga.synapse_ids.is_empty():
			child_genome.ensure_sparse_synapses(ga.synapse_ids)
			for i in mini(child_genome.synapse_mults.size(), ga.synapse_mults.size()):
				child_genome.synapse_mults[i] = ga.synapse_mults[i]
		elif not gb.synapse_ids.is_empty():
			child_genome.ensure_sparse_synapses(gb.synapse_ids)

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
