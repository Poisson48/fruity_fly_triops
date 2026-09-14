extends SceneTree
## Trace one Triops path and flag motion incoherences.
## Writes CSV + PNG trail + JSON report under res://data/debug/


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
	csv.append(
		"t,x,y,z,vx,vy,vz,speed,step_dist,yaw,pitch,yaw_rate,heading_align,fwd,yaw_cmd,energy,flags"
	)

	var xs: Array[float] = []
	var zs: Array[float] = []
	var flag_teleport := 0
	var flag_spin := 0
	var flag_jitter := 0
	var flag_align := 0
	var flag_bounce := 0
	var total_dist := 0.0
	var net_disp := 0.0
	var max_step := 0.0
	var max_yaw_rate := 0.0
	var spikes: Array[Dictionary] = []

	var prev_pos: Vector3 = target.body.position
	var prev_yaw: float = target.body.orientation.get_euler().y
	var start_pos: Vector3 = prev_pos
	var dt: float = cfg.simulation_dt
	var steps := 3600  # 60s @ 60 Hz
	var half := cfg.aquarium_half_extents

	for i in steps:
		world.step(dt)
		target = world.get_agent_by_id(tid)
		if target == null or not target.alive:
			print("target died or missing at t=", world.time)
			break

		var p: Vector3 = target.body.position
		var v: Vector3 = target.body.velocity
		var euler: Vector3 = target.body.orientation.get_euler()
		var step_dist := p.distance_to(prev_pos)
		total_dist += step_dist
		max_step = maxf(max_step, step_dist)

		var dyaw := _angle_delta(prev_yaw, euler.y)
		var yaw_rate := absf(dyaw) / dt
		max_yaw_rate = maxf(max_yaw_rate, yaw_rate)

		var fwd := -target.body.orientation.z
		var heading_align := 0.0
		if v.length() > 0.15:
			heading_align = fwd.dot(v.normalized())

		var outs: PackedFloat32Array = target.brain.get_outputs() if target.brain else PackedFloat32Array()
		var cmd_fwd := outs[0] if outs.size() > 0 else 0.0
		var cmd_yaw := outs[2] if outs.size() > 2 else 0.0

		var flags := ""
		# Teleport / wall slap: step much larger than max_speed * dt allows.
		var max_reasonable := cfg.max_speed * dt * 2.5 + 0.05
		if step_dist > max_reasonable:
			flag_teleport += 1
			flags += "TELEPORT;"
			spikes.append({"t": world.time, "kind": "teleport", "step": step_dist, "pos": [p.x, p.y, p.z]})
		# Wild spin: > ~540°/s sustained spike
		if yaw_rate > 9.0:
			flag_spin += 1
			flags += "SPIN;"
			if spikes.size() < 80:
				spikes.append({"t": world.time, "kind": "spin", "yaw_rate": yaw_rate})
		# High-freq jitter: tiny moves with huge yaw changes
		if step_dist < 0.02 and yaw_rate > 4.0 and v.length() > 0.2:
			flag_jitter += 1
			flags += "JITTER;"
		# Swimming sideways / backwards hard
		if v.length() > 0.4 and heading_align < -0.25:
			flag_align += 1
			flags += "ANTI_ALIGN;"
		# Corner pinball
		var margin := 0.55
		if (
			(absf(p.x) > half.x - margin or absf(p.z) > half.z - margin or absf(p.y) > half.y - margin)
			and step_dist > cfg.max_speed * dt * 1.2
		):
			flag_bounce += 1
			flags += "BOUNCE;"

		xs.append(p.x)
		zs.append(p.z)
		csv.append(
			"%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.5f,%.4f,%.4f,%.3f,%.3f,%.3f,%.3f,%.3f,%s"
			% [
				world.time, p.x, p.y, p.z, v.x, v.y, v.z, v.length(), step_dist,
				euler.y, euler.x, yaw_rate, heading_align, cmd_fwd, cmd_yaw, target.energy, flags
			]
		)
		prev_pos = p
		prev_yaw = euler.y

	net_disp = start_pos.distance_to(prev_pos)
	var straight := net_disp / maxf(total_dist, 0.001)

	var proj := ProjectSettings.globalize_path("res://data/debug")
	DirAccess.make_dir_recursive_absolute(proj)
	var csv_path := proj.path_join("triops_trace.csv")
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	f.store_string("\n".join(csv))
	f.close()

	var png_path := proj.path_join("triops_trace_xz.png")
	_write_trail_png(png_path, xs, zs, half, spikes)

	var summary := {
		"target_id": tid,
		"duration_s": world.time,
		"path_length": total_dist,
		"net_displacement": net_disp,
		"straightness": straight,
		"max_step_dist": max_step,
		"max_yaw_rate": max_yaw_rate,
		"flags": {
			"teleport": flag_teleport,
			"spin": flag_spin,
			"jitter": flag_jitter,
			"anti_align": flag_align,
			"bounce": flag_bounce,
		},
		"spikes_sample": spikes.slice(0, mini(spikes.size(), 25)),
		"csv": csv_path,
		"png": png_path,
		"alive": target != null and target.alive,
		"backend": eng.backend_name,
	}
	print("=== TRACE REPORT ===")
	print("path=%.1f net=%.1f straightness=%.3f max_step=%.3f max_yaw_rate=%.1f" % [total_dist, net_disp, straight, max_step, max_yaw_rate])
	print(
		"flags teleport=%d spin=%d jitter=%d anti_align=%d bounce=%d"
		% [flag_teleport, flag_spin, flag_jitter, flag_align, flag_bounce]
	)
	for s in spikes.slice(0, mini(spikes.size(), 12)):
		print("  spike ", s)
	print("SUMMARY ", JSON.stringify(summary))
	var sf := FileAccess.open(proj.path_join("triops_trace_summary.json"), FileAccess.WRITE)
	sf.store_string(JSON.stringify(summary, "\t"))
	sf.close()
	print("wrote ", csv_path)
	print("wrote ", png_path)

	eng.shutdown()
	quit(0)


func _angle_delta(a: float, b: float) -> float:
	var d := b - a
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d


func _write_trail_png(path: String, xs: Array[float], zs: Array[float], half: Vector3, spikes: Array) -> void:
	var w := 900
	var h := 900
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.07, 0.09, 0.12, 1))
	var margin := 40.0
	var sx := (float(w) - 2.0 * margin) / maxf(half.x * 2.0, 0.01)
	var sz := (float(h) - 2.0 * margin) / maxf(half.z * 2.0, 0.01)

	# Border
	var b0 := _to_px(-half.x, -half.z, half, margin, sx, sz, w, h)
	var b1 := _to_px(half.x, half.z, half, margin, sx, sz, w, h)
	_rect(img, b0, b1, Color(0.35, 0.4, 0.5, 1))

	# Path
	for i in range(1, xs.size()):
		var a := _to_px(xs[i - 1], zs[i - 1], half, margin, sx, sz, w, h)
		var b := _to_px(xs[i], zs[i], half, margin, sx, sz, w, h)
		var t := float(i) / float(maxi(xs.size() - 1, 1))
		var col := Color(0.2 + 0.6 * t, 0.85 - 0.4 * t, 0.35 + 0.4 * t, 1)
		_line(img, a, b, col)

	# Start / end
	if xs.size() > 0:
		var s := _to_px(xs[0], zs[0], half, margin, sx, sz, w, h)
		_dot(img, s, 4, Color(0.2, 1.0, 0.4, 1))
		var e := _to_px(xs[xs.size() - 1], zs[xs.size() - 1], half, margin, sx, sz, w, h)
		_dot(img, e, 4, Color(1.0, 0.3, 0.2, 1))

	# Spike markers (teleports)
	for sp in spikes:
		if str(sp.get("kind", "")) != "teleport":
			continue
		var pos: Variant = sp.get("pos", [])
		if pos is Array and (pos as Array).size() >= 3:
			var arr := pos as Array
			var pt := _to_px(float(arr[0]), float(arr[2]), half, margin, sx, sz, w, h)
			_dot(img, pt, 5, Color(1.0, 0.9, 0.1, 1))

	img.save_png(path)


func _to_px(x: float, z: float, half: Vector3, margin: float, sx: float, sz: float, w: int, h: int) -> Vector2i:
	var px := int(margin + (x + half.x) * sx)
	var py := int(margin + (z + half.z) * sz)
	return Vector2i(clampi(px, 0, w - 1), clampi(py, 0, h - 1))


func _dot(img: Image, c: Vector2i, r: int, col: Color) -> void:
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if Vector2(x - c.x, y - c.y).length() <= float(r):
				img.set_pixel(x, y, col)


func _rect(img: Image, a: Vector2i, b: Vector2i, col: Color) -> void:
	_line(img, Vector2i(a.x, a.y), Vector2i(b.x, a.y), col)
	_line(img, Vector2i(b.x, a.y), Vector2i(b.x, b.y), col)
	_line(img, Vector2i(b.x, b.y), Vector2i(a.x, b.y), col)
	_line(img, Vector2i(a.x, b.y), Vector2i(a.x, a.y), col)


func _line(img: Image, a: Vector2i, b: Vector2i, col: Color) -> void:
	var x0 := a.x
	var y0 := a.y
	var x1 := b.x
	var y1 := b.y
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		if x0 >= 0 and y0 >= 0 and x0 < img.get_width() and y0 < img.get_height():
			img.set_pixel(x0, y0, col)
		if x0 == x1 and y0 == y1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
