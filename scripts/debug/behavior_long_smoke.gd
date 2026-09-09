extends SceneTree
## Longer GPU run: meals / eggs / wall proximity.

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 21
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print("backend=", eng.backend_name, " ready=", eng.ready)

	var wall_frames := 0
	var total_agent_frames := 0
	var steps := 6000  # 100 sim seconds
	var t0 := Time.get_ticks_msec()
	for i in steps:
		world.step(cfg.simulation_dt)
		for a in world.agents:
			if not a.alive:
				continue
			total_agent_frames += 1
			var half := cfg.aquarium_half_extents
			var m := cfg.wall_margin + 0.35
			var p: Vector3 = a.body.position
			if absf(p.x) > half.x - m or absf(p.y) > half.y - m or absf(p.z) > half.z - m:
				wall_frames += 1
		if i % 1200 == 1199:
			print(
				"t=%.1f living=%d meals=%d eggs=%d deaths=%d gen=%d near_wall_pct=%.1f"
				% [
					world.time,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					world.stats.deaths,
					world.stats.max_generation,
					100.0 * float(wall_frames) / maxf(float(total_agent_frames), 1.0),
				]
			)

	var ms := Time.get_ticks_msec() - t0
	var near_pct := 100.0 * float(wall_frames) / maxf(float(total_agent_frames), 1.0)
	print(
		"DONE ms=", ms,
		" living=", world.living_count(),
		" meals=", world.stats.meals,
		" eggs=", world.stats.eggs_laid,
		" near_wall_pct=", near_pct
	)
	var ok := eng.ready and world.living_count() >= 4 and world.stats.meals >= 3
	print("VIABLE_SOFT=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
