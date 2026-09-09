extends SceneTree
## Watch for interesting directed behavior (food/mate vertical + foraging + avoid walls).

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 99
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print("=== BEHAVIOR WATCH start backend=", eng.backend_name, " ===")

	var tid: int = world.agents[0].id
	var samples := 0
	var climb_when_food_up := 0
	var climb_when_food_up_ok := 0
	var dive_when_food_down := 0
	var dive_when_food_down_ok := 0
	var near_wall := 0
	var abs_vy := 0.0
	var abs_vh := 0.0
	var yaw_with_food := 0
	var yaw_food_n := 0

	var steps := 4800  # 80s
	for i in steps:
		world.step(cfg.simulation_dt)
		var a := world.get_agent_by_id(tid)
		if a == null or not a.alive:
			if world.living_count() == 0:
				break
			tid = world.agents[0].id
			a = world.agents[0]
		samples += 1
		var p: Vector3 = a.body.position
		var v: Vector3 = a.body.velocity
		var pkt: SensoryPacket = a.sensors.last_packet
		var outs: PackedFloat32Array = a.brain.get_outputs()
		var vert := outs[MotorInterface.CHANNEL_VERTICAL] if outs.size() > 1 else 0.0
		var yaw := outs[MotorInterface.CHANNEL_YAW] if outs.size() > 2 else 0.0
		abs_vy += absf(v.y)
		abs_vh += Vector2(v.x, v.z).length()

		var half := cfg.aquarium_half_extents
		if absf(p.x) > half.x - 0.8 or absf(p.y) > half.y - 0.8 or absf(p.z) > half.z - 0.8:
			near_wall += 1

		if pkt.food_up > pkt.food_down + 0.12:
			climb_when_food_up += 1
			if vert > 0.05 or v.y > 0.15:
				climb_when_food_up_ok += 1
		if pkt.food_down > pkt.food_up + 0.12:
			dive_when_food_down += 1
			if vert < -0.05 or v.y < -0.15:
				dive_when_food_down_ok += 1

		var fl := pkt.left_eye[1] if pkt.left_eye.size() > 1 else 0.0
		var fr := pkt.right_eye[1] if pkt.right_eye.size() > 1 else 0.0
		if absf(fl - fr) > 0.15:
			yaw_food_n += 1
			if (fl > fr and yaw > 0.05) or (fr > fl and yaw < -0.05):
				yaw_with_food += 1

		if i % 1200 == 1199:
			print(
				"t=%.0f living=%d meals=%d eggs=%d gen=%d"
				% [world.time, world.living_count(), world.stats.meals, world.stats.eggs_laid, world.stats.max_generation]
			)

	var wall_pct := 100.0 * float(near_wall) / maxf(float(samples), 1.0)
	var climb_acc := 100.0 * float(climb_when_food_up_ok) / maxf(float(climb_when_food_up), 1.0)
	var dive_acc := 100.0 * float(dive_when_food_down_ok) / maxf(float(dive_when_food_down), 1.0)
	var yaw_acc := 100.0 * float(yaw_with_food) / maxf(float(yaw_food_n), 1.0)
	var mean_vy := abs_vy / maxf(float(samples), 1.0)
	var mean_vh := abs_vh / maxf(float(samples), 1.0)

	print("=== BEHAVIOR WATCH result ===")
	print("living=", world.living_count(), " meals=", world.stats.meals, " eggs=", world.stats.eggs_laid, " gen=", world.stats.max_generation)
	print("wall_pct=%.1f climb_acc=%.1f%% (n=%d) dive_acc=%.1f%% (n=%d) yaw_food_acc=%.1f%%" % [wall_pct, climb_acc, climb_when_food_up, dive_acc, dive_when_food_down, yaw_acc])
	print("mean_|vy|=%.3f mean_|vh|=%.3f ratio=%.3f" % [mean_vy, mean_vh, mean_vy / maxf(mean_vh, 0.001)])

	var interesting := (
		world.stats.meals >= 15
		and world.stats.eggs_laid >= 2
		and world.living_count() >= 10
		and wall_pct < 40.0
		and (climb_acc >= 55.0 or dive_acc >= 55.0)
		and yaw_acc >= 50.0
	)
	print("INTERESTING=", interesting)
	eng.shutdown()
	quit(0 if interesting else 1)
