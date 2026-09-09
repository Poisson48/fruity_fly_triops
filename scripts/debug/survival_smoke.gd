extends SceneTree
## Survival check with Easy-like defaults.

func _init() -> void:
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 42
	var world := SimulationWorld.new()
	world.initialize(cfg)
	for _i in 3600: # ~60s sim
		world.step(cfg.simulation_dt)
	print("living=", world.living_count())
	print("eggs=", world.eggs.size())
	print("stats=", world.stats.as_dict())
	print("day=", world.time / cfg.seconds_per_sim_day)
	quit(0 if world.living_count() > 0 else 1)
