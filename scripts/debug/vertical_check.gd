extends SceneTree
## Check vertical activity (dy usage) after 3D swim tuning.

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
	var ys: PackedFloat32Array = PackedFloat32Array()
	var abs_vy := 0.0
	var abs_vxz := 0.0
	var n := 0
	for i in 2400:
		world.step(cfg.simulation_dt)
		var a := world.get_agent_by_id(tid)
		if a == null or not a.alive:
			break
		ys.append(a.body.position.y)
		abs_vy += absf(a.body.velocity.y)
		abs_vxz += Vector2(a.body.velocity.x, a.body.velocity.z).length()
		n += 1
	var y_min := 1e9
	var y_max := -1e9
	for y in ys:
		y_min = minf(y_min, y)
		y_max = maxf(y_max, y)
	var mean_vy := abs_vy / maxf(float(n), 1.0)
	var mean_vxz := abs_vxz / maxf(float(n), 1.0)
	var ratio := mean_vy / maxf(mean_vxz, 0.001)
	print(
		"y_range=%.2f mean_|vy|=%.3f mean_|vh|=%.3f vy/vh=%.3f meals=%d"
		% [y_max - y_min, mean_vy, mean_vxz, ratio, world.stats.meals]
	)
	var ok := (y_max - y_min) >= 4.0 and ratio >= 0.18 and world.stats.meals >= 3
	print("VERTICAL_OK=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
