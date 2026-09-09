extends SceneTree
## Headless CI suite: perf + survival + reproduction.
## Prefer GPU via xvfb (`tools/run_tests.sh`). True --headless uses CPU fallback.

const PHYS_DT := 1.0 / 60.0

var _backend: String = "none"
var _gpu: bool = false
var _failures: PackedStringArray = PackedStringArray()


func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	await process_frame

	print("=== HEADLESS SUITE ===")
	_probe_backend()
	_test_perf_easy()
	_test_survival()
	_test_reproduce()

	var ok := _failures.is_empty()
	print("=== SUITE_OK=", ok, " backend=", _backend, " gpu=", _gpu, " ===")
	if not ok:
		for f in _failures:
			print("FAIL: ", f)
	GpuLifEngine.get_engine().shutdown()
	quit(0 if ok else 1)


func _probe_backend() -> void:
	GpuLifEngine.get_engine().shutdown()
	var template := ConnectomeCache.get_template("res://data/brains/flywire_fafb_v783.ffc")
	var eng := GpuLifEngine.get_engine()
	_gpu = eng.setup(template, 8)
	_backend = eng.backend_name
	eng.shutdown()
	print("probe backend=", _backend, " gpu=", _gpu)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("FAIL: ", msg)


func _pass(msg: String) -> void:
	print("PASS: ", msg)


func _make_world(seed: int) -> SimulationWorld:
	GpuLifEngine.get_engine().shutdown()
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = seed
	if not _gpu:
		cfg.triops_count = 6
		cfg.max_triops = 12
		cfg.food_count = 100
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	_gpu = eng.ready
	_backend = eng.backend_name
	print("world agents=", world.living_count(), " backend=", _backend)
	return world


func _test_perf_easy() -> void:
	print("--- perf_easy ---")
	var world := _make_world(9)
	var eng := GpuLifEngine.get_engine()
	var steps := 300 if _gpu else 120
	var t0 := Time.get_ticks_msec()
	for _i in steps:
		world.step(PHYS_DT)
	var ms := maxi(Time.get_ticks_msec() - t0, 1)
	var sps := float(steps) / (float(ms) / 1000.0)
	var need := 60.0 if _gpu else 12.0
	print("steps_per_sec=", sps, " living=", world.living_count(), " need>=", need)
	if _gpu and not eng.ready:
		_fail("perf: expected GPU ready")
	elif sps < need:
		_fail("perf: sps=%.1f < %.1f" % [sps, need])
	elif world.living_count() <= 0:
		_fail("perf: colony dead")
	else:
		_pass("perf sps=%.1f" % sps)
	eng.shutdown()


func _test_survival() -> void:
	print("--- survival 20s ---")
	var world := _make_world(21)
	var steps := int(20.0 / PHYS_DT)
	var wall_hits := 0
	var agent_frames := 0
	for i in steps:
		world.step(PHYS_DT)
		for a in world.agents:
			if not a.alive:
				continue
			agent_frames += 1
			var half: Vector3 = world.config.aquarium_half_extents
			var m: float = world.config.wall_margin + 0.4
			var p: Vector3 = a.body.position
			if absf(p.x) > half.x - m or absf(p.y) > half.y - m or absf(p.z) > half.z - m:
				wall_hits += 1
		if i % 600 == 599:
			print(
				"t=%.1f living=%d meals=%d wall_pct=%.1f"
				% [
					world.time,
					world.living_count(),
					world.stats.meals,
					100.0 * float(wall_hits) / maxf(float(agent_frames), 1.0),
				]
			)
	var wall_pct := 100.0 * float(wall_hits) / maxf(float(agent_frames), 1.0)
	var min_living := 3 if not _gpu else 4
	var min_meals := 1 if not _gpu else 2
	print(
		"DONE living=", world.living_count(),
		" meals=", world.stats.meals,
		" wall_pct=", wall_pct
	)
	if world.living_count() < min_living:
		_fail("survival: living=%d < %d" % [world.living_count(), min_living])
	elif world.stats.meals < min_meals:
		_fail("survival: meals=%d < %d" % [world.stats.meals, min_meals])
	elif wall_pct > 55.0:
		_fail("survival: stuck on walls pct=%.1f" % wall_pct)
	else:
		_pass("survival living=%d meals=%d wall=%.1f%%" % [world.living_count(), world.stats.meals, wall_pct])
	GpuLifEngine.get_engine().shutdown()


func _test_reproduce() -> void:
	print("--- reproduce ---")
	var world := _make_world(7)
	var seconds := 45.0 if _gpu else 25.0
	var steps := int(seconds / PHYS_DT)
	for i in steps:
		world.step(PHYS_DT)
		if i % 900 == 899:
			print(
				"t=%.1f living=%d meals=%d eggs=%d gen=%d"
				% [
					world.time,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					world.stats.max_generation,
				]
			)
	print(
		"DONE meals=", world.stats.meals,
		" eggs=", world.stats.eggs_laid,
		" living=", world.living_count()
	)
	if world.stats.meals < 3:
		_fail("reproduce: meals=%d < 3" % world.stats.meals)
	elif _gpu and world.stats.eggs_laid < 1:
		_fail("reproduce: no eggs on GPU path")
	elif world.living_count() < 3:
		_fail("reproduce: living=%d" % world.living_count())
	else:
		_pass(
			"reproduce meals=%d eggs=%d living=%d"
			% [world.stats.meals, world.stats.eggs_laid, world.living_count()]
		)
	GpuLifEngine.get_engine().shutdown()
