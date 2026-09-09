extends SceneTree
## Compare near-wall time after avoidance tuning.

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
	var tid: int = world.agents[0].id
	var near := 0
	var total := 0
	var ate := 0
	var wall_entries := 0
	var prev_near := false
	for i in 3600:
		world.step(cfg.simulation_dt)
		var a := world.get_agent_by_id(tid)
		if a == null or not a.alive:
			break
		total += 1
		if a.last_ate:
			ate += 1
		var p: Vector3 = a.body.position
		var half := cfg.aquarium_half_extents
		var n := (
			absf(p.x) > half.x - 0.8
			or absf(p.y) > half.y - 0.8
			or absf(p.z) > half.z - 0.8
		)
		if n:
			near += 1
		if n and not prev_near:
			wall_entries += 1
		prev_near = n
	var pct := 100.0 * float(near) / maxf(float(total), 1.0)
	print(
		"WALL_PCT=%.1f entries=%d ate=%d meals=%d eggs=%d living=%d"
		% [pct, wall_entries, ate, world.stats.meals, world.stats.eggs_laid, world.living_count()]
	)
	var ok := pct < 55.0 and world.stats.meals >= 5 and world.living_count() >= 8
	print("WALL_OK=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
