extends SceneTree
## Headless smarts check: directed foraging/mating vs aimless circling.

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	await process_frame

	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 42
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	print(
		"=== SMARTS CHECK backend=", eng.backend_name,
		" ready=", eng.ready,
		" agents=", world.living_count(),
		" ==="
	)
	if world.agents.is_empty():
		print("SMART_OK=false reason=no_agents")
		quit(1)
		return

	var tid: int = world.agents[0].id
	var steps := 3600  # 60s sim
	var samples := 0
	var path := 0.0
	var net := Vector3.ZERO
	var prev: Vector3 = world.agents[0].body.position
	var start: Vector3 = prev
	var yaw_abs := 0.0
	var fwd_abs := 0.0
	var food_approach := 0
	var mate_approach := 0
	var closing_food := 0
	var closing_food_ok := 0
	var yaw_food_n := 0
	var yaw_food_ok := 0
	var raw_yaw_n := 0
	var raw_yaw_ok := 0
	var raw_yaw_abs := 0.0
	var wall_frames := 0
	var pop_wall := 0
	var pop_n := 0
	var ate := 0

	for i in steps:
		world.step(cfg.simulation_dt)
		# Population wall occupancy (less noisy than a single stuck agent).
		for ag in world.agents:
			if not ag.alive:
				continue
			pop_n += 1
			var pp: Vector3 = ag.body.position
			var hh := cfg.aquarium_half_extents
			if absf(pp.x) > hh.x - 0.45 or absf(pp.y) > hh.y - 0.45 or absf(pp.z) > hh.z - 0.45:
				pop_wall += 1

		var a := world.get_agent_by_id(tid)
		if a == null or not a.alive:
			if world.living_count() == 0:
				break
			# Prefer an agent that is eating / moving, not a wall corpse.
			a = world.agents[0]
			for cand in world.agents:
				if cand.alive and cand.energy < 0.85:
					a = cand
					break
			tid = a.id
			prev = a.body.position
			start = prev
		samples += 1
		var p: Vector3 = a.body.position
		path += p.distance_to(prev)
		prev = p
		var half := cfg.aquarium_half_extents
		if absf(p.x) > half.x - 0.45 or absf(p.y) > half.y - 0.45 or absf(p.z) > half.z - 0.45:
			wall_frames += 1

		var outs: PackedFloat32Array = a.brain.get_outputs() if a.brain else PackedFloat32Array()
		var fwd := outs[MotorInterface.CHANNEL_FORWARD] if outs.size() > 0 else 0.0
		var yaw := outs[MotorInterface.CHANNEL_YAW] if outs.size() > 2 else 0.0
		yaw_abs += absf(yaw)
		fwd_abs += absf(fwd)
		var raw := PackedFloat32Array()
		if a.brain and a.brain.has_method("get_raw_motor"):
			raw = a.brain.get_raw_motor()
		var raw_yaw := raw[MotorInterface.CHANNEL_YAW] if raw.size() > 2 else 0.0
		raw_yaw_abs += absf(raw_yaw)

		var pkt: SensoryPacket = a.sensors.last_packet
		if pkt == null:
			continue
		var fl := _ch(pkt.left_eye, 1)
		var fr := _ch(pkt.right_eye, 1)
		var fm := _ch(pkt.median_eye, 1)
		var ml := _ch(pkt.left_eye, 2)
		var mr := _ch(pkt.right_eye, 2)
		var food_sig := fl + fr + fm
		var mate_sig := ml + mr + _ch(pkt.median_eye, 2)

		if food_sig > 0.3 and fwd > 0.05:
			food_approach += 1
		if mate_sig > 0.2 and (fwd > 0.0 or absf(yaw) > 0.05):
			mate_approach += 1

		if absf(fl - fr) > 0.12:
			yaw_food_n += 1
			if (fl > fr and yaw > 0.04) or (fr > fl and yaw < -0.04):
				yaw_food_ok += 1
			raw_yaw_n += 1
			if (fl > fr and raw_yaw > 0.03) or (fr > fl and raw_yaw < -0.03):
				raw_yaw_ok += 1

		# Also score SEZ vs geometric food bearing (connectome taxis).
		if pkt.food_bearing_strength > 0.2 and absf(pkt.food_bearing_yaw) > 0.1:
			raw_yaw_n += 1
			if raw_yaw * pkt.food_bearing_yaw > 0.0 and absf(raw_yaw) > 0.03:
				raw_yaw_ok += 1

		var food_pos := _nearest_food(world, p)
		if food_pos != Vector3.INF:
			var to_food: Vector3 = food_pos - p
			var dist := to_food.length()
			if dist < cfg.food_sense_radius and dist > 0.2:
				closing_food += 1
				var heading := -a.body.orientation.z
				if heading.dot(to_food / dist) > 0.15 and fwd > -0.05:
					closing_food_ok += 1

		if a.last_ate:
			ate += 1

		if i % 900 == 899:
			print(
				"t=%.0f living=%d meals=%d eggs=%d food_ap=%d mate_ap=%d"
				% [world.time, world.living_count(), world.stats.meals, world.stats.eggs_laid, food_approach, mate_approach]
			)

	net = prev - start
	var straight := net.length() / maxf(path, 0.001)  # 1=beeline, ~0=looping
	var wall_pct := 100.0 * float(pop_wall) / maxf(float(pop_n), 1.0)
	var mean_yaw := yaw_abs / maxf(float(samples), 1.0)
	var mean_fwd := fwd_abs / maxf(float(samples), 1.0)
	var mean_raw_yaw := raw_yaw_abs / maxf(float(samples), 1.0)
	var yaw_acc := 100.0 * float(yaw_food_ok) / maxf(float(yaw_food_n), 1.0)
	var raw_acc := 100.0 * float(raw_yaw_ok) / maxf(float(raw_yaw_n), 1.0)
	var close_acc := 100.0 * float(closing_food_ok) / maxf(float(closing_food), 1.0)
	var meals: int = world.stats.meals
	var eggs: int = world.stats.eggs_laid

	print("=== SMARTS RESULT ===")
	print(
		"living=", world.living_count(),
		" meals=", meals,
		" eggs=", eggs,
		" target_ate=", ate
	)
	print(
		"path=%.1f net=%.1f straightness=%.3f pop_wall=%.1f%% mean_|yaw|=%.3f mean_|fwd|=%.3f mean_|raw_yaw|=%.3f brain_first=1"
		% [path, net.length(), straight, wall_pct, mean_yaw, mean_fwd, mean_raw_yaw]
	)
	print(
		"food_approach=%d mate_approach=%d yaw_food_acc=%.1f%% (n=%d) close_food_acc=%.1f%%"
		% [food_approach, mate_approach, yaw_acc, yaw_food_n, close_acc]
	)
	print("raw_sez_food_acc=%.1f%% (n=%d)  # connectome-only yaw vs food" % [raw_acc, raw_yaw_n])

	# Smart = eats or reproduces, and shows directed approach rather than pure spinning.
	# Smart = eats/reproduces with FlyWire-directed foraging (not wall-stuck spinning).
	var goal_ok := meals >= 5 or eggs >= 1
	var brain_directed := raw_acc >= 55.0 and mean_raw_yaw > 0.05
	var directed := food_approach >= 80 or mate_approach >= 40 or close_acc >= 35.0 or brain_directed
	var not_just_circling := straight >= 0.08 or meals >= 8
	var not_wall_stuck := wall_pct < 85.0
	var smart := goal_ok and directed and not_just_circling and not_wall_stuck and world.living_count() >= 4
	if not eng.ready:
		print("note=cpu_fallback")

	print("goal_ok=", goal_ok, " directed=", directed, " brain_directed=", brain_directed, " not_circling=", not_just_circling, " walls_ok=", not_wall_stuck)
	print("SMART_OK=", smart)
	eng.shutdown()
	quit(0 if smart else 1)


func _ch(arr: PackedFloat32Array, i: int) -> float:
	return arr[i] if i >= 0 and i < arr.size() else 0.0


func _nearest_food(world: SimulationWorld, origin: Vector3) -> Vector3:
	var best := Vector3.INF
	var best_d := 1.0e9
	for i in world.food.positions.size():
		if world.food.active[i] == 0:
			continue
		var d := origin.distance_to(world.food.positions[i])
		if d < best_d:
			best_d = d
			best = world.food.positions[i]
	return best
