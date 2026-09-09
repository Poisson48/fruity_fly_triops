extends Node
## Survives scene changes (must be under root before change_scene). Measures GPU render FPS.

func _ready() -> void:
	# Reparent under root so we survive loading main.tscn.
	if get_parent() != get_tree().root:
		get_tree().root.call_deferred("add_child", self.duplicate())
		# Actually move self:
		call_deferred("_adopt_and_run")
	else:
		call_deferred("_run")


func _adopt_and_run() -> void:
	var root := get_tree().root
	reparent(root)
	_run()


func _run() -> void:
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 11
	RunSession.prepare_run(cfg)
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(1.0).timeout
	var samples: PackedFloat32Array = PackedFloat32Array()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
		var fps := Engine.get_frames_per_second()
		if fps > 1.0:
			samples.append(fps)
	var eng := GpuLifEngine.get_engine()
	var avg := 0.0
	for v in samples:
		avg += v
	if samples.size() > 0:
		avg /= float(samples.size())
	print(
		"RENDER_FPS_AVG=", avg,
		" samples=", samples.size(),
		" backend=", eng.backend_name,
		" ready=", eng.ready
	)
	var ok := eng.ready and avg >= 30.0
	print("FPS_OK=", ok)
	get_tree().quit(0 if ok else 1)
