extends SceneTree
## 10 minutes simulated time at max acceleration (16×-style large steps).

const SIM_SECONDS := 600.0
const SPEED := 16.0
const SLICE_MAX := 0.10


func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	await process_frame

	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 7
	var world := SimulationWorld.new()
	world.initialize(cfg)
	world.speed_scale = SPEED
	var eng := GpuLifEngine.get_engine()
	print(
		"=== FAST 10MIN start backend=", eng.backend_name,
		" ready=", eng.ready,
		" agents=", world.living_count(),
		" speed=", SPEED,
		" target_sim_s=", SIM_SECONDS,
		" ==="
	)

	var wall0 := Time.get_ticks_msec()
	var sim_left := SIM_SECONDS
	var steps := 0
	var mark := 60.0  # print every sim minute

	while sim_left > 0.001:
		world.begin_frame()
		var max_slices := 10
		var slice := minf(SLICE_MAX, maxf(cfg.simulation_dt, sim_left / float(max_slices)))
		var n := 0
		while n < max_slices and sim_left > 0.001:
			var dt := minf(slice, minf(sim_left, SLICE_MAX))
			world.step(dt)
			sim_left -= dt
			steps += 1
			n += 1
		var done := SIM_SECONDS - sim_left
		if done >= mark or sim_left <= 0.001:
			print(
				"sim=%.0fs wall=%.1fs living=%d meals=%d eggs=%d gen=%d deaths=%d"
				% [
					done,
					(Time.get_ticks_msec() - wall0) / 1000.0,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					world.stats.max_generation,
					world.stats.deaths,
				]
			)
			mark += 60.0

	var wall_s := (Time.get_ticks_msec() - wall0) / 1000.0
	var living := world.living_count()
	var meals: int = world.stats.meals
	var eggs: int = world.stats.eggs_laid
	var gen: int = world.stats.max_generation
	var deaths: int = world.stats.deaths
	var accel := SIM_SECONDS / maxf(wall_s, 0.001)

	print("=== FAST 10MIN DONE ===")
	print(
		"wall_s=%.1f effective_accel=%.1fx steps=%d living=%d meals=%d eggs=%d gen=%d deaths=%d"
		% [wall_s, accel, steps, living, meals, eggs, gen, deaths]
	)

	# Survive 10 sim minutes with foraging + some reproduction under max turbo.
	var ok := (
		living >= 4
		and meals >= 20
		and eggs >= 1
		and accel >= 8.0  # must actually run accelerated
	)
	print("FAST10_OK=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
