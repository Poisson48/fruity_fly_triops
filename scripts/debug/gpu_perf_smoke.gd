extends SceneTree
## GPU brain + FPS budget smoke. Needs a display (Vulkan RD).

func _init() -> void:
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 9
	var t0 := Time.get_ticks_msec()
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var load_ms := Time.get_ticks_msec() - t0
	var eng := GpuLifEngine.get_engine()
	var info: Dictionary = {}
	if world.agents.size() > 0:
		info = world.agents[0].brain.get_debug_info()
	print(
		"load_ms=", load_ms,
		" backend=", eng.backend_name,
		" ready=", eng.ready,
		" brain=", info
	)

	t0 = Time.get_ticks_msec()
	var steps := 600
	for _i in steps:
		world.step(cfg.simulation_dt)
	var ms := Time.get_ticks_msec() - t0
	var sim_s := steps * cfg.simulation_dt
	var steps_per_sec := float(steps) / maxf(ms / 1000.0, 0.001)
	print(
		"step_ms=", ms,
		" sim_s=", sim_s,
		" steps_per_sec=", steps_per_sec,
		" living=", world.living_count()
	)
	# ≥60 physics steps/s leaves headroom for 30 FPS render + visuals.
	var ok := eng.ready and steps_per_sec >= 60.0 and world.living_count() > 0
	print("PERF_OK=", ok)
	GpuLifEngine.get_engine().shutdown()
	quit(0 if ok else 1)
