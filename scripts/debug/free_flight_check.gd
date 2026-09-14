extends SceneTree
## Smoke: corridor obstacles + forward progress + loom dodge.


func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_free_flight()
	var world := SimulationWorld.new()
	world.initialize(cfg)
	assert(world.void_space.obstacle_count > 0)
	print("obstacles=", world.void_space.obstacle_count, " tiles=", world.void_space.tile_keys.size())

	var a: TriopsAgent = world.agents[0]
	# Face goal, nudge forward into the corridor.
	a.body.reset(Vector3(0, 4, 0), Basis.IDENTITY)
	a.body.velocity = Vector3(0, 0, -6)

	var max_expand := 0.0
	var collisions := 0
	for i in 600:
		var before := a.body.position
		world.step(cfg.simulation_dt)
		a = world.agents[0]
		var pkt: SensoryPacket = a.sensors.last_packet
		if pkt:
			max_expand = maxf(max_expand, pkt.expand_m)
		# Count soft pillar pushes (teleport-like xz jump from collide).
		var dxz := Vector2(a.body.position.x - before.x, a.body.position.z - before.z).length()
		if dxz > cfg.max_speed * cfg.simulation_dt * 2.2:
			collisions += 1

	print(
		"progress=",
		world.void_space.best_progress,
		" lateral=",
		world.void_space.lateral_error,
		" max_expand=",
		max_expand,
		" hard_hits≈",
		collisions,
		" y=",
		a.body.position.y,
		" upright=",
		a.body.orientation.y.y
	)
	var ok := (
		world.void_space.best_progress > 8.0
		and max_expand > 0.15
		and a.body.orientation.y.y > 0.4
		and a.body.position.y > 0.5
	)
	print("FREE_FLIGHT_CORRIDOR_OK" if ok else "FREE_FLIGHT_CORRIDOR_FAIL")
	quit(0 if ok else 1)
