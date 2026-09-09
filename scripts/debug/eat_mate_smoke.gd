extends SceneTree
## Check meals + eggs appear with current Easy + interface taxis.

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 7
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print("backend=", eng.backend_name, " ready=", eng.ready)

	var steps := 3600  # 60s
	for i in steps:
		world.step(cfg.simulation_dt)
		if i % 900 == 899:
			print(
				"t=%.1f living=%d meals=%d eggs=%d gen=%d"
				% [world.time, world.living_count(), world.stats.meals, world.stats.eggs_laid, world.stats.max_generation]
			)

	var ok := eng.ready and world.stats.meals >= 5 and world.stats.eggs_laid >= 1 and world.living_count() >= 4
	print(
		"DONE meals=", world.stats.meals,
		" eggs=", world.stats.eggs_laid,
		" living=", world.living_count(),
		" OK=", ok
	)
	eng.shutdown()
	quit(0 if ok else 1)
