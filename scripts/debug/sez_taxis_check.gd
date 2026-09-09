extends SceneTree
## Probe: does SEZ raw yaw follow artificial left/right food?

func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 7
	cfg.triops_count = 1
	cfg.max_triops = 4
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var eng := GpuLifEngine.get_engine()
	if world.agents.is_empty():
		print("SEZ_TAXIS_OK=false reason=no_agent")
		quit(1)
		return
	var a: TriopsAgent = world.agents[0]
	var db := a.brain as DrosophilaBrain
	if db == null:
		print("SEZ_TAXIS_OK=false reason=no_drosophila")
		quit(1)
		return

	var left_ok := 0
	var right_ok := 0
	var n := 40
	for i in n:
		var pkt := SensoryPacket.new()
		pkt.left_eye = PackedFloat32Array([0.1, 1.6, 0.0])
		pkt.right_eye = PackedFloat32Array([0.1, 0.05, 0.0])
		pkt.median_eye = PackedFloat32Array([0.1, 0.8, 0.0])
		pkt.left_on = PackedFloat32Array()
		pkt.left_on.resize(32)
		pkt.right_on = PackedFloat32Array()
		pkt.right_on.resize(32)
		for k in 32:
			pkt.left_on[k] = 1.4
			pkt.right_on[k] = 0.05
		pkt.food_bearing_yaw = 0.85
		pkt.food_bearing_strength = 0.9
		pkt.food_motivation = 2.2
		pkt.apply_energy_motivation(0.25)
		db.prepare_gpu_drive(pkt)
		eng.step(1.0 / 12.0)
		db.fetch_gpu_outputs()
		var raw: PackedFloat32Array = db.get_raw_motor()
		var yaw := raw[MotorInterface.CHANNEL_YAW] if raw.size() > 2 else 0.0
		if yaw > 0.05:
			left_ok += 1
		if i == 0:
			print("left_food raw_yaw=", yaw, " outs=", db.get_outputs())

	for i in n:
		var pkt2 := SensoryPacket.new()
		pkt2.left_eye = PackedFloat32Array([0.1, 0.05, 0.0])
		pkt2.right_eye = PackedFloat32Array([0.1, 1.6, 0.0])
		pkt2.median_eye = PackedFloat32Array([0.1, 0.8, 0.0])
		pkt2.left_on = PackedFloat32Array()
		pkt2.left_on.resize(32)
		pkt2.right_on = PackedFloat32Array()
		pkt2.right_on.resize(32)
		for k in 32:
			pkt2.left_on[k] = 0.05
			pkt2.right_on[k] = 1.4
		pkt2.food_bearing_yaw = -0.85
		pkt2.food_bearing_strength = 0.9
		pkt2.food_motivation = 2.2
		pkt2.apply_energy_motivation(0.25)
		db.prepare_gpu_drive(pkt2)
		eng.step(1.0 / 12.0)
		db.fetch_gpu_outputs()
		var raw2: PackedFloat32Array = db.get_raw_motor()
		var yaw2 := raw2[MotorInterface.CHANNEL_YAW] if raw2.size() > 2 else 0.0
		if yaw2 < -0.05:
			right_ok += 1
		if i == 0:
			print("right_food raw_yaw=", yaw2)

	var left_pct := 100.0 * float(left_ok) / float(n)
	var right_pct := 100.0 * float(right_ok) / float(n)
	print("SEZ left_food→+yaw=%.0f%% right_food→−yaw=%.0f%%" % [left_pct, right_pct])
	var ok := left_pct >= 70.0 and right_pct >= 70.0
	print("SEZ_TAXIS_OK=", ok)
	eng.shutdown()
	quit(0 if ok else 1)
