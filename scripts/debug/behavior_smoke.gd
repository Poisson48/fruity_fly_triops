extends SceneTree
## Interactive-path smoke: GPU brain + wall contact rate + viability signals.

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# Need one rendered frame so Vulkan RD exists.
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 21
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print(
		"backend=", eng.backend_name,
		" ready=", eng.ready,
		" living=", world.living_count(),
		" mix=", world.agents[0].brain.get_debug_info().get("interface_mix", -1)
	)

	var wall_frames := 0
	var total_agent_frames := 0
	var yaw_abs := 0.0
	var steps := 1800  # 30s at 60 Hz
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
			var near := (
				absf(p.x) > half.x - m
				or absf(p.y) > half.y - m
				or absf(p.z) > half.z - m
			)
			if near:
				wall_frames += 1
			var outs: PackedFloat32Array = a.brain.get_outputs()
			if outs.size() > MotorInterface.CHANNEL_YAW:
				yaw_abs += absf(outs[MotorInterface.CHANNEL_YAW])
		if i % 600 == 599:
			print(
				"t=%.1f living=%d meals=%d eggs=%d near_wall_pct=%.1f"
				% [
					world.time,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					100.0 * float(wall_frames) / maxf(float(total_agent_frames), 1.0),
				]
			)

	var ms := Time.get_ticks_msec() - t0
	var near_pct := 100.0 * float(wall_frames) / maxf(float(total_agent_frames), 1.0)
	var mean_yaw := yaw_abs / maxf(float(total_agent_frames), 1.0)
	var sps := float(steps) / maxf(ms / 1000.0, 0.001)
	print(
		"DONE ms=", ms,
		" steps_per_sec=", sps,
		" near_wall_pct=", near_pct,
		" mean_|yaw|=", mean_yaw,
		" living=", world.living_count(),
		" meals=", world.stats.meals,
		" eggs=", world.stats.eggs_laid
	)
	var ok := (
		eng.ready
		and world.living_count() >= 4
		and world.stats.meals >= 1
		and sps >= 45.0
	)
	print("TEST_OK=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
