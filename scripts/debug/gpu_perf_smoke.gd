extends SceneTree
## GPU brain + FPS budget smoke. Needs a display (Vulkan RD).

func _init() -> void:
	_run_case("easy", true)
	_run_case("balanced", false)
	GpuLifEngine.get_engine().shutdown()
	quit(0)


func _run_case(label: String, apply_easy: bool) -> void:
	GpuLifEngine.get_engine().shutdown()
	var cfg := SimulationConfig.new()
	if apply_easy:
		cfg.apply_preset_easy()
	else:
		cfg.apply_preset_balanced()
	cfg.seed = 9
	var t0 := Time.get_ticks_msec()
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var load_ms := Time.get_ticks_msec() - t0
	var eng := GpuLifEngine.get_engine()
	print(
		"[", label, "] load_ms=", load_ms,
		" backend=", eng.backend_name,
		" ready=", eng.ready,
		" agents=", world.living_count(),
		" max=", cfg.max_triops,
		" food=", cfg.food_count
	)

	t0 = Time.get_ticks_msec()
	var steps := 600
	for _i in steps:
		world.step(cfg.simulation_dt)
	var ms := Time.get_ticks_msec() - t0
	var steps_per_sec := float(steps) / maxf(ms / 1000.0, 0.001)
	print(
		"[", label, "] step_ms=", ms,
		" steps_per_sec=", steps_per_sec,
		" living=", world.living_count()
	)
	var ok := eng.ready and steps_per_sec >= 60.0 and world.living_count() > 0
	print("[", label, "] PERF_OK=", ok)
