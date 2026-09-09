extends SceneTree
## Autonomous health check: do Triops live, eat, reproduce?

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 42
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print("=== LIVE CHECK ===")
	print("backend=", eng.backend_name, " ready=", eng.ready, " start_living=", world.living_count())

	var steps := 7200  # 120 sim seconds
	var min_living := 999
	for i in steps:
		world.step(cfg.simulation_dt)
		min_living = mini(min_living, world.living_count())
		if i % 1440 == 1439:
			var day := world.time / cfg.seconds_per_sim_day
			print(
				"t=%.0fs day=%.2f living=%d meals=%d eggs_laid=%d eggs_now=%d deaths=%d gen=%d"
				% [
					world.time,
					day,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					world.eggs.size(),
					world.stats.deaths,
					world.stats.max_generation,
				]
			)

	var living := world.living_count()
	var meals: int = world.stats.meals
	var eggs: int = world.stats.eggs_laid
	var deaths: int = world.stats.deaths
	var gen: int = world.stats.max_generation
	var ok := (
		eng.ready
		and living >= 8
		and min_living >= 4
		and meals >= 20
		and eggs >= 3
		and gen >= 1
	)
	print("=== RESULT ===")
	print(
		"living=", living,
		" min_living=", min_living,
		" meals=", meals,
		" eggs=", eggs,
		" deaths=", deaths,
		" gen=", gen
	)
	print("HEALTHY=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
