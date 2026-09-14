extends SceneTree
## Trace free-flight corridor: forward progress vs pillar hits.


func _init() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await process_frame
	var cfg := SimulationConfig.new()
	cfg.apply_preset_free_flight()
	var world := SimulationWorld.new()
	world.initialize(cfg)
	if world.agents.is_empty():
		push_error("no agent")
		quit(1)
		return

	var a: TriopsAgent = world.agents[0]
	a.body.reset(Vector3(0.0, 4.0, 0.0), Basis.IDENTITY)
	var pref: float = cfg.flight_preferred_altitude
	var band: float = cfg.flight_altitude_band
	var dt: float = cfg.simulation_dt
	var steps := 2400  # 40 s @ 60 Hz

	var csv := PackedStringArray()
	csv.append(
		"t,x,y,z,progress,lateral,speed,expand,floor,ceil,yaw,fwd,hit,flags"
	)

	var xs: Array[float] = []
	var ys: Array[float] = []
	var zs: Array[float] = []
	var hit_xs: Array[float] = []
	var hit_zs: Array[float] = []

	var scrape := 0
	var inverted := 0
	var hit_frames := 0
	var near_frames := 0
	var max_expand := 0.0
	var sum_lat := 0.0
	var path_len := 0.0
	var prev := a.body.position
	var start := prev

	for _i in steps:
		var before := a.body.position
		world.step(dt)
		a = world.agents[0]
		var p: Vector3 = a.body.position
		var pkt: SensoryPacket = a.sensors.last_packet
		var expand := pkt.expand_m if pkt else 0.0
		var floor_l := pkt.floor_loom if pkt else 0.0
		var ceil_l := pkt.ceiling_loom if pkt else 0.0
		var outs: PackedFloat32Array = a.brain.get_outputs() if a.brain else PackedFloat32Array()
		var cmd := a.motor.decode(outs)
		max_expand = maxf(max_expand, expand)
		sum_lat += absf(world.void_space.lateral_error)
		path_len += p.distance_to(prev)

		var hit := _pillar_penetration(world.void_space, p, 0.55)
		var near := _pillar_near(world.void_space, p, 1.4)
		# Soft collide also shows as oversized XZ step vs thrust.
		var step_xz := Vector2(p.x - before.x, p.z - before.z).length()
		var max_step := cfg.max_speed * dt * 2.0 + 0.08
		var bumped := step_xz > max_step

		var flags := ""
		if hit or bumped:
			hit_frames += 1
			flags += "HIT;"
			hit_xs.append(p.x)
			hit_zs.append(p.z)
		if near:
			near_frames += 1
			flags += "NEAR;"
		if p.y < 1.0:
			scrape += 1
			flags += "SCRAPE;"
		if a.body.orientation.y.y < 0.25:
			inverted += 1
			flags += "INV;"

		xs.append(p.x)
		ys.append(p.y)
		zs.append(p.z)
		csv.append(
			"%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%s"
			% [
				world.time,
				p.x,
				p.y,
				p.z,
				world.void_space.forward_progress,
				world.void_space.lateral_error,
				a.body.velocity.length(),
				expand,
				floor_l,
				ceil_l,
				cmd.yaw,
				cmd.forward,
				1 if (hit or bumped) else 0,
				flags,
			]
		)
		prev = p

	var progress: float = world.void_space.best_progress
	var mean_lat := sum_lat / float(steps)
	var hit_pct := 100.0 * float(hit_frames) / float(steps)
	var near_pct := 100.0 * float(near_frames) / float(steps)
	var upright_pct := 100.0 * (1.0 - float(inverted) / float(steps))
	var efficiency := progress / maxf(path_len, 0.001)

	var proj := ProjectSettings.globalize_path("res://data/debug")
	DirAccess.make_dir_recursive_absolute(proj)
	var csv_path := proj.path_join("free_flight_trace.csv")
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	f.store_string("\n".join(csv))
	f.close()

	var xz_png := proj.path_join("free_flight_trace_xz.png")
	var alt_png := proj.path_join("free_flight_trace_alt.png")
	_write_xz(xz_png, xs, zs, hit_xs, hit_zs, world.void_space)
	_write_alt(alt_png, ys, pref, band)

	var summary := {
		"duration_s": world.time,
		"best_progress": progress,
		"path_length": path_len,
		"forward_efficiency": efficiency,
		"mean_abs_lateral": mean_lat,
		"hit_frames": hit_frames,
		"hit_pct": hit_pct,
		"near_frames": near_frames,
		"near_pct": near_pct,
		"max_expand": max_expand,
		"scrape_frames": scrape,
		"inverted_frames": inverted,
		"upright_pct": upright_pct,
		"obstacles": world.void_space.obstacle_count,
		"csv": csv_path,
		"xz_png": xz_png,
		"alt_png": alt_png,
	}
	var sf := FileAccess.open(proj.path_join("free_flight_trace_summary.json"), FileAccess.WRITE)
	sf.store_string(JSON.stringify(summary, "\t"))
	sf.close()

	print("=== CORRIDOR TRACE (40s) ===")
	print(
		"avance=%.1f  path=%.1f  efficacite=%.2f  derive|X|=%.1f  obstacles=%d"
		% [progress, path_len, efficiency, mean_lat, world.void_space.obstacle_count]
	)
	print(
		"hits=%d (%.1f%%)  near=%d (%.1f%%)  max_loom=%.2f  scrape=%d  upright=%.0f%%"
		% [hit_frames, hit_pct, near_frames, near_pct, max_expand, scrape, upright_pct]
	)
	print("end pos (%.1f, %.1f, %.1f)" % [prev.x, prev.y, prev.z])
	print("wrote ", csv_path)
	print("wrote ", xz_png)
	print("wrote ", alt_png)

	# Success: charge forward, dodge without crashing.
	var ok := (
		progress > 120.0
		and hit_pct < 2.0
		and efficiency > 0.45
		and upright_pct > 90.0
		and mean_lat < 18.0
	)
	print("CORRIDOR_TRACE_OK" if ok else "CORRIDOR_TRACE_WARN")
	var verdict := ""
	if ok:
		verdict = "OK — fonce tout droit, esquive au passage"
	elif hit_pct >= 2.0:
		verdict = "WARN — collisions piliers"
	elif progress < 120.0 or efficiency < 0.45:
		verdict = "WARN — avance / droiture insuffisante"
	else:
		verdict = "WARN — derive / attitude"
	print("VERDICT: ", verdict)

	GpuLifEngine.get_engine().shutdown()
	quit(0)


func _pillar_penetration(void_world: ProceduralVoid, p: Vector3, body_r: float) -> bool:
	for i in void_world.obstacle_count:
		var o := i * 5
		var cx: float = void_world.obstacle_data[o]
		var y0: float = void_world.obstacle_data[o + 1]
		var cz: float = void_world.obstacle_data[o + 2]
		var rad: float = void_world.obstacle_data[o + 3]
		var h: float = void_world.obstacle_data[o + 4]
		if p.y < y0 - 0.1 or p.y > y0 + h + 0.4:
			continue
		var d := Vector2(p.x - cx, p.z - cz).length()
		if d < rad + body_r * 0.35:
			return true
	return false


func _pillar_near(void_world: ProceduralVoid, p: Vector3, margin: float) -> bool:
	for i in void_world.obstacle_count:
		var o := i * 5
		var cx: float = void_world.obstacle_data[o]
		var y0: float = void_world.obstacle_data[o + 1]
		var cz: float = void_world.obstacle_data[o + 2]
		var rad: float = void_world.obstacle_data[o + 3]
		var h: float = void_world.obstacle_data[o + 4]
		if p.y < y0 - 0.1 or p.y > y0 + h + 0.4:
			continue
		var d := Vector2(p.x - cx, p.z - cz).length()
		if d < rad + margin:
			return true
	return false


func _angle_delta(a: float, b: float) -> float:
	var d := b - a
	while d > PI:
		d -= TAU
	while d < -PI:
		d += TAU
	return d


func _write_xz(
	path: String,
	xs: Array[float],
	zs: Array[float],
	hit_xs: Array[float],
	hit_zs: Array[float],
	void_world: ProceduralVoid
) -> void:
	var w := 1000
	var h := 1000
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.07, 0.09, 0.12, 1))
	var min_x := xs[0]
	var max_x := xs[0]
	var min_z := zs[0]
	var max_z := zs[0]
	for i in xs.size():
		min_x = minf(min_x, xs[i])
		max_x = maxf(max_x, xs[i])
		min_z = minf(min_z, zs[i])
		max_z = maxf(max_z, zs[i])
	for i in void_world.obstacle_count:
		var o := i * 5
		var cx: float = void_world.obstacle_data[o]
		var cz: float = void_world.obstacle_data[o + 2]
		var rad: float = void_world.obstacle_data[o + 3]
		min_x = minf(min_x, cx - rad)
		max_x = maxf(max_x, cx + rad)
		min_z = minf(min_z, cz - rad)
		max_z = maxf(max_z, cz + rad)
	var pad := 6.0
	min_x -= pad
	max_x += pad
	min_z -= pad
	max_z += pad
	var span := maxf(max_x - min_x, max_z - min_z)
	var cx := (min_x + max_x) * 0.5
	var cz := (min_z + max_z) * 0.5
	var scale := (float(w) - 80.0) / maxf(span, 1.0)

	# Goal corridor centerline (x=0).
	var c0 := _map(0.0, min_z, cx, cz, scale, w, h)
	var c1 := _map(0.0, max_z, cx, cz, scale, w, h)
	_line(img, c0, c1, Color(0.25, 0.45, 0.3, 1))

	# Pillars.
	for i in void_world.obstacle_count:
		var o := i * 5
		var ox: float = void_world.obstacle_data[o]
		var oz: float = void_world.obstacle_data[o + 2]
		var rad: float = void_world.obstacle_data[o + 3]
		var pc := _map(ox, oz, cx, cz, scale, w, h)
		var pr := maxi(2, int(rad * scale))
		_dot(img, pc, pr, Color(0.45, 0.32, 0.22, 1))

	# Path.
	for i in range(1, xs.size()):
		var a := _map(xs[i - 1], zs[i - 1], cx, cz, scale, w, h)
		var b := _map(xs[i], zs[i], cx, cz, scale, w, h)
		var t := float(i) / float(maxi(xs.size() - 1, 1))
		_line(img, a, b, Color(0.25 + 0.55 * t, 0.85 - 0.35 * t, 0.4 + 0.35 * t, 1))
	_dot(img, _map(xs[0], zs[0], cx, cz, scale, w, h), 5, Color(0.2, 1, 0.4, 1))
	_dot(
		img,
		_map(xs[xs.size() - 1], zs[zs.size() - 1], cx, cz, scale, w, h),
		5,
		Color(1, 0.35, 0.25, 1)
	)
	# Hit markers.
	for i in hit_xs.size():
		_dot(img, _map(hit_xs[i], hit_zs[i], cx, cz, scale, w, h), 4, Color(1.0, 0.15, 0.1, 1))

	img.save_png(path)


func _write_alt(path: String, ys: Array[float], pref: float, band: float) -> void:
	var w := 1000
	var h := 360
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.07, 0.08, 0.11, 1))
	var y_max := maxf(pref + band * 2.0, 12.0)
	for yy in ys:
		y_max = maxf(y_max, yy + 1.0)
	var margin := 36.0
	var y0 := _alt_py(pref - band, y_max, margin, h)
	var y1 := _alt_py(pref + band, y_max, margin, h)
	for x in range(int(margin), w - int(margin)):
		for y in range(mini(y0, y1), maxi(y0, y1) + 1):
			if y >= 0 and y < h:
				img.set_pixel(x, y, Color(0.15, 0.28, 0.18, 1))
	var yp := _alt_py(pref, y_max, margin, h)
	_line(img, Vector2i(int(margin), yp), Vector2i(w - int(margin), yp), Color(0.4, 0.9, 0.5, 1))
	var yg := _alt_py(0.0, y_max, margin, h)
	_line(img, Vector2i(int(margin), yg), Vector2i(w - int(margin), yg), Color(0.55, 0.4, 0.25, 1))
	for i in range(1, ys.size()):
		var x0 := int(margin + float(i - 1) / float(maxi(ys.size() - 1, 1)) * (float(w) - 2.0 * margin))
		var x1 := int(margin + float(i) / float(maxi(ys.size() - 1, 1)) * (float(w) - 2.0 * margin))
		_line(
			img,
			Vector2i(x0, _alt_py(ys[i - 1], y_max, margin, h)),
			Vector2i(x1, _alt_py(ys[i], y_max, margin, h)),
			Color(0.95, 0.75, 0.25, 1)
		)
	img.save_png(path)


func _alt_py(y: float, y_max: float, margin: float, h: int) -> int:
	var t := clampf(y / maxf(y_max, 0.01), 0.0, 1.0)
	return int(float(h) - margin - t * (float(h) - 2.0 * margin))


func _map(x: float, z: float, cx: float, cz: float, scale: float, w: int, h: int) -> Vector2i:
	var px := int(float(w) * 0.5 + (x - cx) * scale)
	var py := int(float(h) * 0.5 + (z - cz) * scale)
	return Vector2i(clampi(px, 0, w - 1), clampi(py, 0, h - 1))


func _dot(img: Image, c: Vector2i, r: int, col: Color) -> void:
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if Vector2(x - c.x, y - c.y).length() <= float(r):
				img.set_pixel(x, y, col)


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
