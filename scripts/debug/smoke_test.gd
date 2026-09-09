extends SceneTree
## Headless smoke test for V1–V6 pipeline.

func _init() -> void:
	var cfg := SimulationConfig.new()
	cfg.seed = 12345
	cfg.triops_count = 24
	cfg.food_count = 80
	cfg.max_lifespan_days = 12.0
	cfg.seconds_per_sim_day = 8.0
	cfg.energy_drain_per_second = 0.03
	cfg.mature_age_days = 0.6
	cfg.egg_hatch_seconds = 1.5
	cfg.mating_cooldown_seconds = 2.0
	cfg.mating_distance = 2.5
	cfg.mating_energy_min = 0.3

	var world := SimulationWorld.new()
	world.initialize(cfg)

	for _i in 2400:
		world.step(cfg.simulation_dt)

	print("living=", world.living_count())
	print("eggs=", world.eggs.size())
	print("food=", world.food.active_count())
	print("stats=", world.stats.as_dict())
	print("day=", world.time / cfg.seconds_per_sim_day)

	var world2 := SimulationWorld.new()
	world2.initialize(cfg)
	for _i in 2400:
		world2.step(cfg.simulation_dt)
	var same := world.living_count() == world2.living_count()
	if world.living_count() > 0 and world2.living_count() > 0:
		same = same and world.agents[0].id == world2.agents[0].id
		same = same and world.agents[0].body.position.distance_to(world2.agents[0].body.position) < 0.001
	print("deterministic=", same)
	var ok := same and int(world.stats.meals) > 0
	quit(0 if ok else 1)
