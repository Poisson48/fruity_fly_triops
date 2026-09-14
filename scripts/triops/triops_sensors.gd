class_name TriopsSensors
extends RefCounted
## Triops eyes → fly-like visual front-end for FlyWire ME / LOP.
##
## Biology mapping (interface, not literal anatomy):
## - Compound L/R → medulla mosaics (ON figure, OFF/loom, local flow)
## - Median / naupliar → frontal + lobula-plate proxies (HS/VS/expansion)
##
## Summaries (3×3) stay genome-compatible; mosaics drive retinotopic injection.
## Ray origins sit on dorsal carapace eye sockets (body local, −Z forward).

const CHANNELS_PER_EYE := 3
const AZ := 8
const EL := 4
const FACETS := AZ * EL ## 32
const MED_AZ := 4
const MED_EL := 4
const MED_FACETS := MED_AZ * MED_EL ## 16

## Body-local eye sockets (−Z forward, +Y up, +X right).
## Tuned to Meshy carapace after model_basis 180° yaw + VISUAL_MODEL_SCALE.
const EYE_SCALE := 2.5
const EYE_LEFT_LOCAL := Vector3(-0.14, 0.16, -0.52) * EYE_SCALE
const EYE_RIGHT_LOCAL := Vector3(0.14, 0.16, -0.52) * EYE_SCALE
const EYE_MEDIAN_LOCAL := Vector3(0.0, 0.12, -0.58) * EYE_SCALE

var last_packet: SensoryPacket = SensoryPacket.new()
var _prev_left_depth: PackedFloat32Array = PackedFloat32Array()
var _prev_right_depth: PackedFloat32Array = PackedFloat32Array()
var _prev_median_depth: PackedFloat32Array = PackedFloat32Array()
var _have_prev: bool = false

## Half-angles (radians) + compound outward cant — set via apply_config().
var compound_fov_h: float = deg_to_rad(55.0)
var compound_fov_v: float = deg_to_rad(42.5)
var compound_cant: float = deg_to_rad(38.0)
var median_fov_h: float = deg_to_rad(35.0)
var median_fov_v: float = deg_to_rad(37.5)


func apply_config(config: SimulationConfig) -> void:
	compound_fov_h = deg_to_rad(config.eye_compound_fov_h_deg * 0.5)
	compound_fov_v = deg_to_rad(config.eye_compound_fov_v_deg * 0.5)
	compound_cant = deg_to_rad(config.eye_compound_cant_deg)
	median_fov_h = deg_to_rad(config.eye_median_fov_h_deg * 0.5)
	median_fov_v = deg_to_rad(config.eye_median_fov_v_deg * 0.5)


static func eye_world_pos(position: Vector3, orientation: Basis, local: Vector3, body_scale: float) -> Vector3:
	return position + orientation * (local * body_scale)


func sense(
	position: Vector3,
	orientation: Basis,
	half_extents: Vector3,
	ray_length: float,
	food: FoodSystem,
	mates: Array[Vector3],
	mate_radius: float,
	velocity: Vector3 = Vector3.ZERO,
	food_radius: float = 8.0,
	body_scale: float = 1.0
) -> SensoryPacket:
	var packet := SensoryPacket.new()
	var left_o := eye_world_pos(position, orientation, EYE_LEFT_LOCAL, body_scale)
	var right_o := eye_world_pos(position, orientation, EYE_RIGHT_LOCAL, body_scale)
	var med_o := eye_world_pos(position, orientation, EYE_MEDIAN_LOCAL, body_scale)
	var left_dirs := _compound_gaze(orientation, true)
	var right_dirs := _compound_gaze(orientation, false)
	var med_dirs := _median_gaze_grid(orientation)
	# One spatial query per agent — facets reuse the shortlist.
	var food_near := food.nearby_indices(position, maxf(ray_length, food_radius)) if food != null else PackedInt32Array()

	var L := _sample_compound(
		left_o, half_extents, ray_length, food, food_near, mates, mate_radius, velocity, left_dirs, AZ, EL, _prev_left_depth
	)
	var R := _sample_compound(
		right_o, half_extents, ray_length, food, food_near, mates, mate_radius, velocity, right_dirs, AZ, EL, _prev_right_depth
	)
	var M := _sample_compound(
		med_o, half_extents, ray_length, food, food_near, mates, mate_radius, velocity, med_dirs, MED_AZ, MED_EL, _prev_median_depth
	)

	packet.left_on = L.on
	packet.left_off = L.off
	packet.left_mate = L.mate
	packet.left_flow_h = L.flow_h
	packet.left_flow_v = L.flow_v
	packet.expand_l = L.expand
	packet.contrast_l = L.contrast
	packet.left_eye = PackedFloat32Array([L.loom_sum, L.food_sum, L.mate_sum])

	packet.right_on = R.on
	packet.right_off = R.off
	packet.right_mate = R.mate
	packet.right_flow_h = R.flow_h
	packet.right_flow_v = R.flow_v
	packet.expand_r = R.expand
	packet.contrast_r = R.contrast
	packet.right_eye = PackedFloat32Array([R.loom_sum, R.food_sum, R.mate_sum])

	packet.median_on = M.on
	packet.median_off = M.off
	packet.median_mate = M.mate
	packet.median_flow_h = M.flow_h
	packet.median_flow_v = M.flow_v
	packet.expand_m = M.expand
	packet.contrast_m = M.contrast
	# Omnidirectional food backup into median ON summary + center facets.
	if food != null:
		var prox := food.proximity_food(position, food_radius)
		packet.median_eye = PackedFloat32Array([M.loom_sum, maxf(M.food_sum, prox), M.mate_sum])
		if prox > 0.01 and packet.median_on.size() > 0:
			var mid := int(packet.median_on.size() / 2)
			packet.median_on[mid] = maxf(packet.median_on[mid], prox)
	else:
		packet.median_eye = PackedFloat32Array([M.loom_sum, M.food_sum, M.mate_sum])

	# Binocular HS / VS proxies (lobula plate style).
	var hs_l := _mean_arr(L.flow_h)
	var hs_r := _mean_arr(R.flow_h)
	var vs_l := _mean_arr(L.flow_v)
	var vs_r := _mean_arr(R.flow_v)
	packet.flow_yaw = clampf((hs_r - hs_l) * 0.5 + (R.loom_sum - L.loom_sum) * 0.35, -1.5, 1.5)
	packet.flow_pitch = clampf((vs_l + vs_r) * 0.5 + _mean_arr(M.flow_v), -1.5, 1.5)

	packet.floor_loom = _wall_loom(position, Vector3.DOWN, half_extents, ray_length, velocity)
	packet.ceiling_loom = _wall_loom(position, Vector3.UP, half_extents, ray_length, velocity)
	packet.depth_norm = clampf(position.y / maxf(half_extents.y, 0.01), -1.0, 1.0)
	if food != null:
		var food_vert := food_near if not food_near.is_empty() else (
			food.nearby_indices(position, food_radius) if food != null else PackedInt32Array()
		)
		packet.food_up = food.ray_food_signal_candidates(position, Vector3.UP, food_radius, food_vert)
		packet.food_down = food.ray_food_signal_candidates(position, Vector3.DOWN, food_radius, food_vert)
		packet.food_up = maxf(
			packet.food_up,
			food.ray_food_signal_candidates(
				position, (Vector3.UP + -orientation.z * 0.35).normalized(), food_radius, food_vert
			)
		)
		packet.food_down = maxf(
			packet.food_down,
			food.ray_food_signal_candidates(
				position, (Vector3.DOWN + -orientation.z * 0.35).normalized(), food_radius, food_vert
			)
		)
	packet.mate_up = _mate_hemisphere(position, Vector3.UP, mates, mate_radius)
	packet.mate_down = _mate_hemisphere(position, Vector3.DOWN, mates, mate_radius)

	# Explicit nearest-target bearings — also bias ON mosaics so LIF sees L/R food.
	if food != null and not food_near.is_empty():
		var bear := _nearest_bearing(position, orientation, food, food_near, food_radius)
		packet.food_bearing_yaw = bear.x
		packet.food_bearing_strength = bear.y
		if packet.food_bearing_strength > 0.08 and absf(packet.food_bearing_yaw) > 0.04:
			var nudge := packet.food_bearing_yaw * packet.food_bearing_strength * 0.65
			if packet.left_eye.size() > 1:
				packet.left_eye[1] = minf(packet.left_eye[1] + maxf(nudge, 0.0), 3.5)
			if packet.right_eye.size() > 1:
				packet.right_eye[1] = minf(packet.right_eye[1] + maxf(-nudge, 0.0), 3.5)
			# Drive the connectome, not just the adapter summaries.
			_bias_on_mosaic(packet.left_on, maxf(nudge, 0.0) * 0.85)
			_bias_on_mosaic(packet.right_on, maxf(-nudge, 0.0) * 0.85)
	if not mates.is_empty():
		var mb := _nearest_mate_bearing(position, orientation, mates, mate_radius)
		packet.mate_bearing_yaw = mb.x

	_prev_left_depth = L.depth
	_prev_right_depth = R.depth
	_prev_median_depth = M.depth
	_have_prev = true
	last_packet = packet
	return packet


class EyeSample:
	var on: PackedFloat32Array = PackedFloat32Array()
	var off: PackedFloat32Array = PackedFloat32Array()
	var mate: PackedFloat32Array = PackedFloat32Array()
	var depth: PackedFloat32Array = PackedFloat32Array()
	var flow_h: PackedFloat32Array = PackedFloat32Array()
	var flow_v: PackedFloat32Array = PackedFloat32Array()
	var expand: float = 0.0
	var contrast: float = 0.0
	var loom_sum: float = 0.0
	var food_sum: float = 0.0
	var mate_sum: float = 0.0


func sense_walls_fast(
	position: Vector3,
	orientation: Basis,
	half_extents: Vector3,
	ray_length: float,
	velocity: Vector3 = Vector3.ZERO,
	body_scale: float = 1.0
) -> SensoryPacket:
	## Cheap refresh between brain ticks: walls / loom / flow only (no food scans).
	var packet := last_packet if last_packet != null else SensoryPacket.new()
	var left_o := eye_world_pos(position, orientation, EYE_LEFT_LOCAL, body_scale)
	var right_o := eye_world_pos(position, orientation, EYE_RIGHT_LOCAL, body_scale)
	var med_o := eye_world_pos(position, orientation, EYE_MEDIAN_LOCAL, body_scale)
	var left_dirs := _compound_gaze(orientation, true)
	var right_dirs := _compound_gaze(orientation, false)
	var med_dirs := _median_gaze_grid(orientation)
	var empty_food := PackedInt32Array()
	var empty_mates: Array[Vector3] = []

	var L := _sample_compound(
		left_o, half_extents, ray_length, null, empty_food, empty_mates, 0.0, velocity, left_dirs, AZ, EL, _prev_left_depth
	)
	var R := _sample_compound(
		right_o, half_extents, ray_length, null, empty_food, empty_mates, 0.0, velocity, right_dirs, AZ, EL, _prev_right_depth
	)
	var M := _sample_compound(
		med_o, half_extents, ray_length, null, empty_food, empty_mates, 0.0, velocity, med_dirs, MED_AZ, MED_EL, _prev_median_depth
	)

	# Keep previous ON/food & mate mosaics; refresh OFF/loom/flow/expand.
	packet.left_off = L.off
	packet.right_off = R.off
	packet.median_off = M.off
	packet.left_flow_h = L.flow_h
	packet.left_flow_v = L.flow_v
	packet.right_flow_h = R.flow_h
	packet.right_flow_v = R.flow_v
	packet.median_flow_h = M.flow_h
	packet.median_flow_v = M.flow_v
	packet.expand_l = L.expand
	packet.expand_r = R.expand
	packet.expand_m = M.expand
	packet.contrast_l = L.contrast
	packet.contrast_r = R.contrast
	packet.contrast_m = M.contrast
	if packet.left_eye.size() >= 3:
		packet.left_eye[0] = L.loom_sum
	else:
		packet.left_eye = PackedFloat32Array([L.loom_sum, 0.0, 0.0])
	if packet.right_eye.size() >= 3:
		packet.right_eye[0] = R.loom_sum
	else:
		packet.right_eye = PackedFloat32Array([R.loom_sum, 0.0, 0.0])
	if packet.median_eye.size() >= 3:
		packet.median_eye[0] = M.loom_sum
	else:
		packet.median_eye = PackedFloat32Array([M.loom_sum, 0.0, 0.0])

	var hs_l := _mean_arr(L.flow_h)
	var hs_r := _mean_arr(R.flow_h)
	var vs_l := _mean_arr(L.flow_v)
	var vs_r := _mean_arr(R.flow_v)
	packet.flow_yaw = clampf((hs_r - hs_l) * 0.5 + (R.loom_sum - L.loom_sum) * 0.35, -1.5, 1.5)
	packet.flow_pitch = clampf((vs_l + vs_r) * 0.5 + _mean_arr(M.flow_v), -1.5, 1.5)
	packet.floor_loom = _wall_loom(position, Vector3.DOWN, half_extents, ray_length, velocity)
	packet.ceiling_loom = _wall_loom(position, Vector3.UP, half_extents, ray_length, velocity)
	packet.depth_norm = clampf(position.y / maxf(half_extents.y, 0.01), -1.0, 1.0)

	_prev_left_depth = L.depth
	_prev_right_depth = R.depth
	_prev_median_depth = M.depth
	_have_prev = true
	last_packet = packet
	return packet


func apply_obstacles(
	packet: SensoryPacket,
	position: Vector3,
	orientation: Basis,
	velocity: Vector3,
	void_world: ProceduralVoid,
	ray_length: float,
	body_scale: float = 1.0
) -> void:
	## FlyWire-facing LPLC-style loom: early detect, strong L/R asymmetry, clear-side bias.
	if void_world == null or void_world.obstacle_count <= 0:
		return
	var ray := maxf(ray_length, 48.0)
	var left_o := eye_world_pos(position, orientation, EYE_LEFT_LOCAL, body_scale)
	var right_o := eye_world_pos(position, orientation, EYE_RIGHT_LOCAL, body_scale)
	var med_o := eye_world_pos(position, orientation, EYE_MEDIAN_LOCAL, body_scale)
	var fwd := -orientation.z
	var right := orientation.x
	var up := orientation.y

	var loom_l := 0.0
	var loom_r := 0.0
	var loom_m := 0.0
	var t_l_best := ray
	var t_r_best := ray
	# Wide fan for L/R eyes; NARROW cone only for frontal expand (don't panic on side gates).
	var fans_side: Array = [
		fwd,
		(fwd + right * 0.22).normalized(),
		(fwd - right * 0.22).normalized(),
		(fwd + right * 0.45).normalized(),
		(fwd - right * 0.45).normalized(),
		(fwd + right * 0.75).normalized(),
		(fwd - right * 0.75).normalized(),
		(fwd + up * 0.2).normalized(),
		(fwd - up * 0.15).normalized(),
	]
	var fans_front: Array = [
		fwd,
		(fwd + right * 0.12).normalized(),
		(fwd - right * 0.12).normalized(),
		(fwd + up * 0.1).normalized(),
		(fwd - up * 0.08).normalized(),
	]
	for d in fans_side:
		var dir: Vector3 = d
		var tl := void_world.ray_obstacle_t(left_o, dir, ray)
		var tr := void_world.ray_obstacle_t(right_o, dir, ray)
		t_l_best = minf(t_l_best, tl)
		t_r_best = minf(t_r_best, tr)
		loom_l = maxf(loom_l, _obstacle_loom_from_t(tl, dir, ray, velocity))
		loom_r = maxf(loom_r, _obstacle_loom_from_t(tr, dir, ray, velocity))
	for d2 in fans_front:
		var dir2: Vector3 = d2
		var tm := void_world.ray_obstacle_t(med_o, dir2, ray)
		loom_m = maxf(loom_m, _obstacle_loom_from_t(tm, dir2, ray, velocity))

	# Clear-side probe: if dead-ahead, force asymmetry toward the open gap.
	var t_open_l := void_world.ray_obstacle_t(med_o, (fwd - right * 0.55).normalized(), ray)
	var t_open_r := void_world.ray_obstacle_t(med_o, (fwd + right * 0.55).normalized(), ray)
	if loom_m > 0.35 and absf(loom_l - loom_r) < 0.10:
		if t_open_l > t_open_r + 2.5:
			loom_r = maxf(loom_r, loom_m * 0.9 + 0.18)
		elif t_open_r > t_open_l + 2.5:
			loom_l = maxf(loom_l, loom_m * 0.9 + 0.18)
		elif minf(t_l_best, t_r_best) < 12.0:
			if t_l_best <= t_r_best:
				loom_l = maxf(loom_l, loom_m * 0.85 + 0.15)
			else:
				loom_r = maxf(loom_r, loom_m * 0.85 + 0.15)

	var frontal := loom_m
	# Side pillars in periphery ≠ escape saccade. Gate L/R by frontal threat.
	var side_gate := clampf((frontal - 0.15) / 0.4, 0.0, 1.0)
	var side_l := loom_l * (0.2 + 0.8 * side_gate)
	var side_r := loom_r * (0.2 + 0.8 * side_gate)
	packet.expand_l = maxf(packet.expand_l, side_l * 1.15)
	packet.expand_r = maxf(packet.expand_r, side_r * 1.15)
	# Frontal expand only (true LPLC) — don't saturate from side clutter.
	packet.expand_m = maxf(packet.expand_m, frontal * 1.35)
	if packet.left_eye.size() >= 1:
		packet.left_eye[0] = maxf(packet.left_eye[0], side_l * 1.15)
	if packet.right_eye.size() >= 1:
		packet.right_eye[0] = maxf(packet.right_eye[0], side_r * 1.15)
	if packet.median_eye.size() >= 1:
		packet.median_eye[0] = maxf(packet.median_eye[0], frontal * 1.3)
	_boost_ventral_off(packet.left_off, side_l * 1.2)
	_boost_ventral_off(packet.right_off, side_r * 1.2)
	_boost_ventral_off(packet.median_off, frontal * 1.35)
	_boost_side_off(packet.left_off, side_l * 1.1, true)
	_boost_side_off(packet.right_off, side_r * 1.1, false)
	if packet.left_eye.size() >= 1 and side_r > side_l:
		packet.left_eye[0] = maxf(packet.left_eye[0], side_r * 0.3)
	if packet.right_eye.size() >= 1 and side_l > side_r:
		packet.right_eye[0] = maxf(packet.right_eye[0], side_l * 0.3)
	var avoid_yaw := clampf((side_r - side_l) * 1.25 * side_gate, -1.5, 1.5)
	packet.flow_yaw = clampf(packet.flow_yaw * 0.15 + avoid_yaw, -1.5, 1.5)
	if packet.left_eye.size() > 1:
		packet.left_eye[1] *= 0.08
	if packet.right_eye.size() > 1:
		packet.right_eye[1] *= 0.08
	if packet.median_eye.size() > 1:
		packet.median_eye[1] *= 0.08


func _obstacle_loom_from_t(min_t: float, dir: Vector3, ray_length: float, velocity: Vector3) -> float:
	## Hot when close or closing fast (tau) — not a distant wall of panic.
	if min_t >= ray_length:
		return 0.0
	# Ignore far static clutter; react inside ~18u or on collision course.
	var closing := maxf(0.0, velocity.dot(dir.normalized()))
	var tau := 0.0
	if min_t > 0.08:
		tau = clampf(closing / min_t, 0.0, 12.0) / 12.0
	else:
		tau = 1.0
	var near := clampf(1.0 - min_t / 14.0, 0.0, 1.0)
	near = near * near
	var prox := clampf(1.0 - min_t / 22.0, 0.0, 1.0)
	prox = prox * prox * prox
	var loom := near * 0.85 + tau * 0.95 + prox * tau * 0.65 + prox * 0.25
	return clampf(loom, 0.0, 1.0)


func _boost_side_off(field: PackedFloat32Array, amp: float, left_eye: bool) -> void:
	if field.is_empty() or amp < 0.03:
		return
	var n := field.size()
	var half := int(n / 2)
	var start := 0 if left_eye else half
	var stop := half if left_eye else n
	for i in range(start, stop):
		field[i] = minf(field[i] + amp * 1.1, 3.5)


func apply_corridor_goal(packet: SensoryPacket, orientation: Basis, void_world: ProceduralVoid) -> void:
	## Corridor objective → optic HS / bearing into FlyWire (not a body autopilot).
	if void_world == null:
		return
	var yaw := void_world.heading_error_yaw(orientation)
	# Cross-track: +X drift → right turn (−yaw) back to centerline.
	var cross := clampf(-void_world.lateral_error / 8.0, -1.0, 1.0)
	var threat := packet.expand_m
	var goal_w := clampf(1.0 - maxf(threat - 0.4, 0.0) * 1.5, 0.6, 1.0)
	packet.food_bearing_yaw = clampf((yaw * 1.2 + cross * 0.7) * goal_w, -1.2, 1.2)
	packet.food_bearing_strength = 1.3 * goal_w
	var avoid_keep := clampf((threat - 0.35) / 0.45, 0.0, 0.75)
	packet.flow_yaw = clampf(
		packet.flow_yaw * avoid_keep + packet.food_bearing_yaw * (0.95 * goal_w),
		-1.5,
		1.5
	)
	var on_goal := 1.25 * goal_w
	if packet.median_eye.size() > 1:
		packet.median_eye[1] = maxf(packet.median_eye[1], on_goal)
	# Need left (+yaw) → more ON on left eye (and vice versa).
	if packet.left_eye.size() > 1:
		packet.left_eye[1] = maxf(packet.left_eye[1], on_goal * (0.55 + 0.45 * maxf(yaw, 0.0)))
	if packet.right_eye.size() > 1:
		packet.right_eye[1] = maxf(packet.right_eye[1], on_goal * (0.55 + 0.45 * maxf(-yaw, 0.0)))
	_boost_goal_on(packet.median_on, on_goal)
	_boost_goal_on(packet.left_on, on_goal * (0.5 + 0.4 * maxf(yaw, 0.0)))
	_boost_goal_on(packet.right_on, on_goal * (0.5 + 0.4 * maxf(-yaw, 0.0)))


func _boost_goal_on(field: PackedFloat32Array, amp: float) -> void:
	if field.is_empty() or amp < 0.02:
		return
	# Central / frontal facets.
	var n := field.size()
	var mid := int(n / 2)
	var span := maxi(2, int(n / 5))
	for i in range(maxi(0, mid - span), mini(n, mid + span + 1)):
		field[i] = minf(field[i] + amp, 3.5)


func _ch_eye(eye: PackedFloat32Array, i: int) -> float:
	return eye[i] if i < eye.size() else 0.0


func apply_flight_altitude(
	packet: SensoryPacket,
	position: Vector3,
	velocity: Vector3,
	preferred_alt: float,
	band: float,
	ray_length: float,
	ground_y: float = 0.0
) -> void:
	## Drosophila-style altitude: ventral loom + regulate ground optic-flow rate.
	## Feeds floor/ceiling loom, VS pitch, expand/OFF — SEZ must climb/dive.
	var h := maxf(position.y - ground_y, 0.05)
	var pref := maxf(preferred_alt, 0.8)
	var band_w := maxf(band, 0.6)
	var ray := maxf(ray_length, pref * 2.0)

	# Hard proximity to ground (collision loom).
	var floor_hit := _wall_loom_from_t(h, Vector3.DOWN, ray, velocity)

	# Ventral optic-flow rate ~ horiz_speed / altitude (classic fly altitude cue).
	# Only when translating — near-hover low flow must NOT read as "too high".
	var horiz := Vector2(velocity.x, velocity.z).length()
	var move := clampf((horiz - 0.6) / 3.0, 0.0, 1.0)
	var optic := horiz / h
	var target_optic := 5.5 / pref  ## cruise ~5.5 u/s at preferred height
	var flow_err := clampf(optic - target_optic, -1.5, 1.5)
	# Positive flow_err → too close / ground rushing → climb.
	var flow_climb := clampf(flow_err, 0.0, 1.5) * move
	var flow_dive := clampf(-flow_err, 0.0, 1.5) * move

	# Soft band around preferred altitude (even when nearly hovering).
	var below := clampf((pref - h) / band_w, 0.0, 1.0)
	var above := clampf((h - pref) / (band_w * 1.15), 0.0, 1.0)

	packet.floor_loom = clampf(maxf(floor_hit, maxf(flow_climb * 0.75, below * 0.85)), 0.0, 1.0)
	# Ceiling only when actually above preferred (plus mild optic dive while moving).
	packet.ceiling_loom = clampf(above * 0.95 + flow_dive * 0.55 * above, 0.0, 1.0)
	# Stronger sky pressure once clearly above the band (prevent climb overshoot).
	if h > pref + band_w * 0.35:
		packet.ceiling_loom = clampf(packet.ceiling_loom + above * 0.35, 0.0, 1.0)
		packet.floor_loom *= 0.4
	# Near ground: never allow a dive cue.
	if h < pref * 0.75:
		packet.ceiling_loom = 0.0
		packet.floor_loom = clampf(packet.floor_loom + 0.25, 0.0, 1.0)
	# depth_norm: -1 near ground, 0 at preferred, +1 too high.
	packet.depth_norm = clampf((h - pref) / band_w, -1.5, 1.5)

	# Pitch flow: climb request positive (nose-up / VS).
	var alt_pitch := packet.floor_loom * 0.85 - packet.ceiling_loom * 1.05
	packet.flow_pitch = clampf(packet.flow_pitch * 0.35 + alt_pitch, -1.5, 1.5)

	# Ventral OFF / expansion when ground is close (LPLC-like).
	var ground_expand := clampf(floor_hit * 1.35 + below * 0.4, 0.0, 1.6)
	packet.expand_m = maxf(packet.expand_m, ground_expand)
	packet.expand_l = maxf(packet.expand_l, ground_expand * 0.7)
	packet.expand_r = maxf(packet.expand_r, ground_expand * 0.7)
	if packet.median_eye.size() >= 1:
		packet.median_eye[0] = maxf(packet.median_eye[0], ground_expand)
	if packet.left_eye.size() >= 1:
		packet.left_eye[0] = maxf(packet.left_eye[0], ground_expand * 0.55)
	if packet.right_eye.size() >= 1:
		packet.right_eye[0] = maxf(packet.right_eye[0], ground_expand * 0.55)
	_boost_ventral_off(packet.median_off, ground_expand)
	_boost_ventral_off(packet.left_off, ground_expand * 0.45)
	_boost_ventral_off(packet.right_off, ground_expand * 0.45)

	# Reuse vertical ON channels as altitude drive (no food in free flight).
	packet.food_up = packet.floor_loom * 1.25
	packet.food_down = packet.ceiling_loom * 1.35


func _boost_ventral_off(field: PackedFloat32Array, amp: float) -> void:
	if field.is_empty() or amp < 0.02:
		return
	# Lower half of mosaic ≈ more ventral facets.
	var start := int(field.size() / 2)
	for i in range(start, field.size()):
		field[i] = minf(field[i] + amp, 3.5)


func axis_loom(
	origin: Vector3,
	axis: Vector3,
	half_extents: Vector3,
	ray_length: float,
	velocity: Vector3
) -> float:
	return _wall_loom(origin, axis, half_extents, ray_length, velocity)


func wall_urgency_fast(
	position: Vector3,
	orientation: Basis,
	half_extents: Vector3,
	ray_length: float,
	velocity: Vector3
) -> float:
	## 5 forward rays — enough to decide brain tick boost without full mosaic.
	var fwd := -orientation.z
	var u := 0.0
	u = maxf(u, _wall_loom(position, fwd, half_extents, ray_length, velocity))
	u = maxf(u, _wall_loom(position, (fwd + orientation.x * 0.45).normalized(), half_extents, ray_length, velocity))
	u = maxf(u, _wall_loom(position, (fwd - orientation.x * 0.45).normalized(), half_extents, ray_length, velocity))
	u = maxf(u, _wall_loom(position, Vector3.DOWN, half_extents, ray_length, velocity))
	u = maxf(u, _wall_loom(position, Vector3.UP, half_extents, ray_length, velocity))
	return u


func _sample_compound(
	origin: Vector3,
	half: Vector3,
	ray_length: float,
	food: FoodSystem,
	food_near: PackedInt32Array,
	mates: Array[Vector3],
	mate_radius: float,
	velocity: Vector3,
	dirs: PackedVector3Array,
	az_n: int,
	el_n: int,
	prev_depth: PackedFloat32Array
) -> EyeSample:
	var s := EyeSample.new()
	var n := az_n * el_n
	s.on.resize(n)
	s.off.resize(n)
	s.mate.resize(n)
	s.depth.resize(n)
	s.flow_h.resize(az_n)
	s.flow_v.resize(el_n)
	s.flow_h.fill(0.0)
	s.flow_v.fill(0.0)

	var depth_acc := 0.0
	var expand_acc := 0.0
	var expand_n := 0
	for i in n:
		var dir: Vector3 = dirs[i] if i < dirs.size() else Vector3.FORWARD
		var t_hit := _wall_hit_t(origin, dir, half, ray_length)
		var d_norm := clampf(t_hit / ray_length, 0.0, 1.0)
		var loom := _wall_loom_from_t(t_hit, dir, ray_length, velocity)
		var food_s := (
			food.ray_food_signal_candidates(origin, dir, ray_length, food_near) if food != null else 0.0
		)
		var mate_s := _mate_in_dir(origin, dir, mates, mate_radius)
		# OFF ≈ near / dark edge (walls); ON ≈ bright figure (food).
		s.depth[i] = d_norm
		s.off[i] = loom
		s.on[i] = food_s
		s.mate[i] = mate_s
		s.loom_sum = maxf(s.loom_sum, loom)
		s.food_sum = maxf(s.food_sum, food_s)
		s.mate_sum = maxf(s.mate_sum, mate_s)
		depth_acc += d_norm
		if _have_prev and i < prev_depth.size():
			# Approaching surface → positive expansion (LPLC-like).
			var dd := prev_depth[i] - d_norm
			expand_acc += dd
			expand_n += 1

	# Local contrast across mosaic (edge density).
	var contrast := 0.0
	var c_n := 0
	for el in el_n:
		for az in az_n:
			var i := el * az_n + az
			if az + 1 < az_n:
				contrast += absf(s.depth[i] - s.depth[i + 1])
				c_n += 1
			if el + 1 < el_n:
				contrast += absf(s.depth[i] - s.depth[i + az_n])
				c_n += 1
	s.contrast = clampf(contrast / float(maxi(c_n, 1)) * 2.5, 0.0, 1.5)

	# Column / row optic flow from temporal depth + ego-motion bias.
	var lat := velocity.dot(dirs[az_n / 2] if dirs.size() > az_n / 2 else Vector3.RIGHT) * 0.08
	for az in az_n:
		var col := 0.0
		var cn := 0
		for el in el_n:
			var i := el * az_n + az
			if _have_prev and i < prev_depth.size():
				col += (prev_depth[i] - s.depth[i])
				cn += 1
		s.flow_h[az] = clampf((col / float(maxi(cn, 1))) * 4.0 + lat * float(az - az_n * 0.5) / float(az_n), -1.5, 1.5)

	var vert := velocity.y * 0.06
	for el in el_n:
		var row := 0.0
		var rn := 0
		for az in az_n:
			var i := el * az_n + az
			if _have_prev and i < prev_depth.size():
				row += (prev_depth[i] - s.depth[i])
				rn += 1
		s.flow_v[el] = clampf((row / float(maxi(rn, 1))) * 4.0 + vert * float(el - el_n * 0.5) / float(el_n), -1.5, 1.5)

	s.expand = clampf((expand_acc / float(maxi(expand_n, 1))) * 5.0 + s.loom_sum * 0.45, 0.0, 1.5)
	return s


func _compound_gaze(basis: Basis, is_left: bool) -> PackedVector3Array:
	## Retinotopic grid inside compound FOV, boresight canted outward from body forward.
	var body_fwd := -basis.z
	var side := (-basis.x) if is_left else basis.x
	var up := basis.y
	var bore := (body_fwd * cos(compound_cant) + side * sin(compound_cant)).normalized()
	var bore_right := bore.cross(up)
	if bore_right.length_squared() < 1e-8:
		bore_right = side
	else:
		bore_right = bore_right.normalized()
	var bore_up := bore_right.cross(bore).normalized()
	var out := PackedVector3Array()
	out.resize(FACETS)
	for el in EL:
		var el_t := (float(el) + 0.5) / float(EL) ## 0..1 bottom→top
		var pitch := lerpf(-compound_fov_v, compound_fov_v, el_t)
		for az in AZ:
			var az_t := (float(az) + 0.5) / float(AZ)
			# Sweep from front-ish toward lateral within FOV (asymmetric bias ok for ME).
			var yaw := lerpf(-compound_fov_h * 0.35, compound_fov_h, az_t)
			if not is_left:
				yaw = -yaw
			var dir := (
				bore * cos(yaw) * cos(pitch)
				+ bore_right * sin(yaw) * cos(pitch)
				+ bore_up * sin(pitch)
			).normalized()
			out[el * AZ + az] = dir
	return out


func _median_gaze_grid(basis: Basis) -> PackedVector3Array:
	## Frontal acute zone within median FOV (naupliar → LOP / frontal ME).
	var forward := -basis.z
	var right := basis.x
	var up := basis.y
	var out := PackedVector3Array()
	out.resize(MED_FACETS)
	for el in MED_EL:
		var el_t := (float(el) + 0.5) / float(MED_EL)
		var pitch := lerpf(-median_fov_v, median_fov_v, el_t)
		for az in MED_AZ:
			var az_t := (float(az) + 0.5) / float(MED_AZ)
			var yaw := lerpf(-median_fov_h, median_fov_h, az_t)
			var dir := (
				forward * cos(yaw) * cos(pitch)
				+ right * sin(yaw) * cos(pitch)
				+ up * sin(pitch)
			).normalized()
			out[el * MED_AZ + az] = dir
	return out


func _mate_in_dir(origin: Vector3, dir: Vector3, mates: Array[Vector3], radius: float) -> float:
	var best := 0.0
	var d := dir.normalized()
	for mpos in mates:
		var to: Vector3 = mpos - origin
		var dist := to.length()
		if dist < 0.001 or dist > radius:
			continue
		var align := (to / dist).dot(d)
		if align < 0.55:
			continue
		best = maxf(best, align * (1.0 - dist / radius))
	return best


func _mate_hemisphere(origin: Vector3, axis: Vector3, mates: Array[Vector3], radius: float) -> float:
	var best := 0.0
	var ax := axis.normalized()
	for mpos in mates:
		var to: Vector3 = mpos - origin
		var dist := to.length()
		if dist < 0.001 or dist > radius:
			continue
		var align := (to / dist).dot(ax)
		if align < 0.25:
			continue
		best = maxf(best, align * (1.0 - dist / radius))
	return best


func _bias_on_mosaic(on: PackedFloat32Array, amount: float) -> void:
	if amount <= 0.001 or on.is_empty():
		return
	for i in on.size():
		# Prefer outer azimuth columns (every AZ facets) for a sharper L/R drive.
		var az := i % AZ
		var col_w := 0.55 + 0.9 * (float(az) / float(maxi(AZ - 1, 1)))
		on[i] = minf(on[i] + amount * col_w, 3.5)


func _nearest_bearing(
	origin: Vector3,
	orientation: Basis,
	food: FoodSystem,
	candidates: PackedInt32Array,
	radius: float
) -> Vector2:
	## x = yaw cmd bias (+ left), y = strength 0..1
	var best_i := -1
	var best_d2 := radius * radius
	for idx in candidates:
		if idx < 0 or idx >= food.positions.size() or food.active[idx] == 0:
			continue
		var d2 := origin.distance_squared_to(food.positions[idx])
		if d2 < best_d2:
			best_d2 = d2
			best_i = idx
	if best_i < 0:
		return Vector2.ZERO
	var local: Vector3 = orientation.inverse() * (food.positions[best_i] - origin)
	var fwd := -local.z
	var right := local.x
	# Only steer to food in the frontal field — behind-target taxis looks stupid / walls pin.
	if fwd < 0.15:
		return Vector2.ZERO
	var ang := atan2(right, maxf(fwd, 0.08))
	var dist := sqrt(best_d2)
	var strength := clampf(1.0 - dist / maxf(radius, 0.01), 0.0, 1.0)
	strength *= clampf(fwd / maxf(dist, 0.01), 0.0, 1.0)
	# Positive motor yaw turns left; food to the right (ang>0) → negative yaw.
	var yaw := clampf(-ang / (PI * 0.55), -1.5, 1.5) * strength
	return Vector2(yaw, strength)


func _nearest_mate_bearing(
	origin: Vector3,
	orientation: Basis,
	mates: Array[Vector3],
	radius: float
) -> Vector2:
	var best_d2 := radius * radius
	var best := Vector3.ZERO
	var found := false
	for mpos in mates:
		var d2 := origin.distance_squared_to(mpos)
		if d2 < best_d2 and d2 > 0.0001:
			best_d2 = d2
			best = mpos
			found = true
	if not found:
		return Vector2.ZERO
	var local: Vector3 = orientation.inverse() * (best - origin)
	var ang := atan2(local.x, maxf(-local.z, 0.08))
	var strength := clampf(1.0 - sqrt(best_d2) / maxf(radius, 0.01), 0.0, 1.0)
	return Vector2(clampf(-ang / (PI * 0.55), -1.5, 1.5) * strength, strength)


func _wall_depth_norm(origin: Vector3, direction: Vector3, half: Vector3, ray_length: float) -> float:
	var t := _wall_hit_t(origin, direction, half, ray_length)
	return clampf(t / ray_length, 0.0, 1.0)


func _wall_hit_t(origin: Vector3, direction: Vector3, half: Vector3, ray_length: float) -> float:
	var dir := direction.normalized()
	var min_t := ray_length
	for axis in 3:
		var o := origin[axis]
		var d := dir[axis]
		var h := half[axis]
		if absf(d) < 0.00001:
			continue
		var t1 := (-h - o) / d
		var t2 := (h - o) / d
		var t_hit := t1 if t1 > 0.0 else t2
		if t2 > 0.0 and (t_hit <= 0.0 or t2 < t_hit):
			t_hit = t2
		if t_hit > 0.0 and t_hit < min_t:
			min_t = t_hit
	return min_t


func _wall_loom(
	origin: Vector3,
	direction: Vector3,
	half: Vector3,
	ray_length: float,
	velocity: Vector3
) -> float:
	var min_t := _wall_hit_t(origin, direction, half, ray_length)
	return _wall_loom_from_t(min_t, direction.normalized(), ray_length, velocity)


func _wall_loom_from_t(min_t: float, dir: Vector3, ray_length: float, velocity: Vector3) -> float:
	if min_t >= ray_length:
		return 0.0
	var prox := clampf(1.0 - min_t / (ray_length * 0.7), 0.0, 1.0)
	prox = prox * prox
	var closing := maxf(0.0, velocity.dot(dir))
	var tau_urgency := 0.0
	if min_t > 0.04:
		tau_urgency = clampf(closing / min_t, 0.0, 6.0) / 6.0
	else:
		tau_urgency = 1.0
	return clampf(prox * 0.75 + prox * tau_urgency * 0.7 + tau_urgency * 0.35, 0.0, 1.0)


func _mean_arr(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / float(a.size())
