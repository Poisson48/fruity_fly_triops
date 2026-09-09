extends SceneTree
## Trace one Triops trajectory + behavior markers for coherence analysis.
## Writes CSV + summary JSON under user:// then copies to project res://data/debug/

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 42
	cfg.triops_count = 12
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	if world.agents.is_empty():
		push_error("no agents")
		quit(1)
		return

	var target: TriopsAgent = world.agents[0]
	var tid: int = target.id
	print("TRACE target id=", tid, " sex=", ("M" if target.sex == TriopsAgent.Sex.MALE else "F"), " backend=", eng.backend_name)

	var csv := PackedStringArray()
	csv.append("t,x,y,z,vx,vy,vz,speed,energy,health,yaw,food_l,food_r,food_m,mate_l,mate_r,wall_m,fwd,yaw_cmd,ate,near_food,near_mate,near_wall")

	var ate_events := 0
	var wall_hits := 0
	var prev_near_wall := false
	var food_approach_frames := 0
	var mate_approach_frames := 0
	var total_dist := 0.0
	var prev_pos: Vector3 = target.body.position
	var steps := 3600  # 60s

	for i in steps:
		world.step(cfg.simulation_dt)
		target = world.get_agent_by_id(tid)
		if target == null or not target.alive:
			print("target died or missing at t=", world.time)
			break

		var p: Vector3 = target.body.position
		var v: Vector3 = target.body.velocity
		total_dist += p.distance_to(prev_pos)
		prev_pos = p

		var sens := target.sensors.last_packet
		var fl := _ch(sens.left_eye, 1)
		var fr := _ch(sens.right_eye, 1)
		var fm := _ch(sens.median_eye, 1)
		var ml := _ch(sens.left_eye, 2)
		var mr := _ch(sens.right_eye, 2)
		var wm := _ch(sens.median_eye, 0)
		var outs: PackedFloat32Array = target.brain.get_outputs()
		var fwd := outs[0] if outs.size() > 0 else 0.0
		var yawc := outs[2] if outs.size() > 2 else 0.0

		var near_food := _nearest_food_dist(world, p) < 2.5
		var near_mate := _nearest_mate_dist(world, target) < 3.0
		var half := cfg.aquarium_half_extents
		var near_wall := (
			absf(p.x) > half.x - 0.8
			or absf(p.y) > half.y - 0.8
			or absf(p.z) > half.z - 0.8
		)
		if near_wall and not prev_near_wall:
			wall_hits += 1
		prev_near_wall = near_wall

		# Approaching food: food signal rising while moving somewhat toward it
		if fl + fr + fm > 0.35 and fwd > 0.1:
			food_approach_frames += 1
		if ml + mr > 0.25 and fwd > 0.05:
			mate_approach_frames += 1
		if target.last_ate:
			ate_events += 1

		var euler: Vector3 = target.body.orientation.get_euler()
		csv.append(
			"%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d"
			% [
				world.time, p.x, p.y, p.z, v.x, v.y, v.z, v.length(),
				target.energy, target.health, euler.y,
				fl, fr, fm, ml, mr, wm, fwd, yawc,
				1 if target.last_ate else 0,
				1 if near_food else 0,
				1 if near_mate else 0,
				1 if near_wall else 0,
			]
		)

	var path := "user://triops_trace_%d.csv" % tid
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(csv))
	f.close()

	# Also write under project for plotting tools.
	var proj := ProjectSettings.globalize_path("res://data/debug")
	DirAccess.make_dir_recursive_absolute(proj)
	var proj_csv := proj.path_join("triops_trace.csv")
	var abs_user := ProjectSettings.globalize_path(path)
	DirAccess.copy_absolute(abs_user, proj_csv)

	var living := world.living_count()
	var summary := {
		"target_id": tid,
		"duration_s": world.time,
		"path_length": total_dist,
		"ate_events": ate_events,
		"wall_entries": wall_hits,
		"food_approach_frames": food_approach_frames,
		"mate_approach_frames": mate_approach_frames,
		"final_energy": target.energy if target else -1.0,
		"alive": target != null and target.alive,
		"world_meals": world.stats.meals,
		"world_eggs": world.stats.eggs_laid,
		"living": living,
		"csv": proj_csv,
	}
	print("SUMMARY ", JSON.stringify(summary))
	var sf := FileAccess.open(proj.path_join("triops_trace_summary.json"), FileAccess.WRITE)
	sf.store_string(JSON.stringify(summary, "\t"))
	sf.close()

	eng.shutdown()
	quit(0)


func _ch(arr: PackedFloat32Array, i: int) -> float:
	return arr[i] if i < arr.size() else 0.0


func _nearest_food_dist(world: SimulationWorld, p: Vector3) -> float:
	var best := 1e9
	var food := world.food
	for i in food.positions.size():
		if food.active[i] == 0:
			continue
		best = minf(best, p.distance_to(food.positions[i]))
	return best


func _nearest_mate_dist(world: SimulationWorld, me: TriopsAgent) -> float:
	var best := 1e9
	for a in world.agents:
		if a.id == me.id or not a.alive or a.sex == me.sex:
			continue
		best = minf(best, me.body.position.distance_to(a.body.position))
	return best
