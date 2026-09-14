extends SceneTree
## Boot check: start like a real run (easy preset) and verify sim + mesh for a few seconds.

const PHYS_DT := 1.0 / 60.0


func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	await process_frame
	print("=== BOOT CHECK ===")
	var ok := true

	# Mesh
	if not ResourceLoader.exists("res://assets/models/triops.glb"):
		print("FAIL: missing triops.glb")
		ok = false
	else:
		var packed = load("res://assets/models/triops.glb")
		if packed == null:
			print("FAIL: triops.glb failed to load")
			ok = false
		else:
			print("PASS: triops.glb loaded (", packed.get_class(), ")")

	# World boot
	GpuLifEngine.get_engine().shutdown()
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 7
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var living0 := world.living_count()
	print("boot living=", living0, " food=", world.food.active_count(), " backend=", GpuLifEngine.get_engine().backend_name)
	if living0 <= 0:
		print("FAIL: no agents at start")
		ok = false

	# Sensor FOV / eye sockets sanity on first agent
	if living0 > 0:
		var a: TriopsAgent = world.agents[0]
		a.sensors.apply_config(cfg)
		var pkt := a.sensors.sense(
			a.body.position,
			a.body.orientation,
			cfg.aquarium_half_extents,
			cfg.eye_ray_length,
			world.food,
			[],
			cfg.mate_sense_radius,
			a.body.velocity,
			cfg.food_sense_radius,
			a.scale
		)
		var eye := TriopsSensors.eye_world_pos(a.body.position, a.body.orientation, TriopsSensors.EYE_LEFT_LOCAL, a.scale)
		var dist := eye.distance_to(a.body.position)
		print("eye_socket_dist=", dist, " left_eye=", pkt.left_eye, " fov_h=", a.sensors.compound_fov_h)
		# Local eye socket length ≈ 0.56 * EYE_SCALE (2.5) ≈ 1.4 at body_scale=1.
		if dist < 0.4 or dist > 3.0:
			print("FAIL: eye socket distance out of range")
			ok = false
		else:
			print("PASS: eye sockets + sense packet")

	# Run ~3 sim seconds
	var steps := int(3.0 / PHYS_DT)
	var err := false
	for i in steps:
		world.step(PHYS_DT)
		if world.living_count() <= 0:
			print("FAIL: colony died during boot (", i, " steps)")
			ok = false
			err = true
			break
	if not err:
		print(
			"PASS: ran ", steps, " steps living=", world.living_count(),
			" meals=", world.stats.meals, " fps_proxy_ok"
		)

	print("=== BOOT_OK=", ok, " ===")
	GpuLifEngine.get_engine().shutdown()
	quit(0 if ok else 1)
