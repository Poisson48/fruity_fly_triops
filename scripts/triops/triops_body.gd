class_name TriopsBody
extends RefCounted
## Locomotion / simple physics for one Triops.
## brain → MotorInterface → acceleration/rotation → velocity → position
## Not a Godot physics body — simulation-owned state.

## EMA rate (Hz) on motor channels — kills 12 Hz SEZ stair-steps without killing steer.
const MOTOR_SMOOTH_HZ := 9.0
## Soft boundary band (inside wall_margin).
const WALL_ESCAPE_RANGE := 4.0
const FLOOR_ESCAPE_RANGE := 2.8
## Soft cap on sustained yaw (SEZ often saturates → permanent orbits).
const YAW_LOCK_CAP := 0.52
## Only force center-turn this far out (fraction of half-extent).
const OUTER_STEER_START := 0.78

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
## Orientation: -Z is forward (Godot convention).
var orientation: Basis = Basis.IDENTITY
var angular_velocity: Vector3 = Vector3.ZERO

var _sm_forward: float = 0.0
var _sm_vertical: float = 0.0
var _sm_yaw: float = 0.0
var _sm_pitch: float = 0.0
var _sm_roll: float = 0.0
## Sticky turn sign while peeling inland (avoids ± chatter when perpendicular to center).
var _inland_yaw_sign: float = 1.0
## Keep climbing after leaving the floor band so SEZ dive can't re-glue instantly.
var _floor_peel_timer: float = 0.0


func reset(pos: Vector3, basis: Basis) -> void:
	position = pos
	orientation = basis.orthonormalized()
	velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_sm_forward = 0.0
	_sm_vertical = 0.0
	_sm_yaw = 0.0
	_sm_pitch = 0.0
	_sm_roll = 0.0
	_inland_yaw_sign = 1.0
	_floor_peel_timer = 0.0


func apply_motor(cmd: MotorInterface.MotorCommand, config: SimulationConfig, delta: float) -> void:
	var free := config != null and config.is_free_flight()
	var a := 1.0 - exp(-MOTOR_SMOOTH_HZ * maxf(delta, 0.0001))
	_sm_forward = lerpf(_sm_forward, cmd.forward, a)
	_sm_vertical = lerpf(_sm_vertical, cmd.vertical, a)
	_sm_yaw = lerpf(_sm_yaw, cmd.yaw, a)
	_sm_pitch = lerpf(_sm_pitch, cmd.pitch, a)
	_sm_roll = lerpf(_sm_roll, cmd.roll, a)

	if free:
		# Commit forward — corridor fly charges; dodge is yaw, not stall.
		_sm_forward = maxf(_sm_forward, 0.55)
		_sm_roll = clampf(_sm_roll * 0.2, -0.28, 0.28)
		_sm_pitch = clampf(_sm_pitch, -0.85, 0.85)
	else:
		_break_yaw_lock(delta)
		if _floor_peel_timer > 0.0:
			_floor_peel_timer = maxf(_floor_peel_timer - delta, 0.0)
		_steer_off_boundaries(config)

	# Angular: yaw (Y), pitch (X), roll (Z) in local space.
	var ang_scale := 1.35 if free else 1.0
	var local_ang := Vector3(_sm_pitch, _sm_yaw, _sm_roll) * config.angular_accel * ang_scale
	angular_velocity += local_ang * delta
	angular_velocity *= 1.0 / (1.0 + config.angular_drag * delta)
	var max_ang := config.angular_accel * (1.6 if free else 1.15)
	var ang_len := angular_velocity.length()
	if ang_len > max_ang:
		angular_velocity *= max_ang / ang_len

	var yaw := angular_velocity.y * delta
	var pitch := angular_velocity.x * delta
	var roll := angular_velocity.z * delta
	orientation = orientation * Basis.from_euler(Vector3(pitch, yaw, roll))
	orientation = orientation.orthonormalized()
	if free:
		_flight_level_attitude(delta)
		_flight_hold_course(delta, _sm_yaw)

	# Linear thrust in body frame: forward = -Z, up = Y.
	var forward := -orientation.z
	var up := orientation.y
	var accel := forward * _sm_forward * config.linear_accel + up * _sm_vertical * config.linear_accel
	if free:
		# Mild sideslip only — no wild roll-coupled flip.
		accel += orientation.x * _sm_roll * config.linear_accel * 0.08
	velocity += accel * delta
	if free and config.flight_gravity > 0.0:
		# Mild gravity so altitude must be held by SEZ vertical / pitch, not float.
		velocity.y -= config.flight_gravity * delta
	velocity *= 1.0 / (1.0 + config.linear_drag * delta)

	if not free:
		_push_off_boundaries(config, delta)

	var speed := velocity.length()
	if speed > config.max_speed:
		velocity = velocity * (config.max_speed / speed)

	position += velocity * delta
	if free:
		_collide_ground(config)
		_soft_far_wrap(config)
	else:
		_keep_inside(config)


func collide_void_obstacles(void_world: ProceduralVoid) -> void:
	if void_world == null:
		return
	var before := position
	position = void_world.collide_body(position, 0.7)
	var push := position - before
	if push.length_squared() > 1e-6:
		# Kill velocity into the pillar.
		var n := push.normalized()
		var into := velocity.dot(-n)
		if into > 0.0:
			velocity += n * into
		velocity.x *= 0.85
		velocity.z *= 0.85


func _collide_ground(_config: SimulationConfig) -> void:
	## Physics floor only — climb is the brain's job via ventral loom → SEZ.
	const GROUND := 0.0
	const CLEARANCE := 0.55
	if position.y < GROUND + CLEARANCE:
		position.y = GROUND + CLEARANCE
		if velocity.y < 0.0:
			velocity.y = -velocity.y * 0.25


func _flight_level_attitude(delta: float) -> void:
	## Keep belly-down: rebuild attitude from forward + world up (soft aircraft leveling).
	## Allows limited bank from residual roll; snaps harder when inverted.
	var fwd := (-orientation.z).normalized()
	# Clamp nose pitch so she can't loop inverted.
	const MAX_PITCH := 0.72  ## ~41°
	if absf(fwd.y) > MAX_PITCH:
		var fy := clampf(fwd.y, -MAX_PITCH, MAX_PITCH)
		var horiz := Vector3(fwd.x, 0.0, fwd.z)
		if horiz.length_squared() < 1e-6:
			horiz = Vector3(orientation.x.x, 0.0, orientation.x.z)
			if horiz.length_squared() < 1e-6:
				horiz = Vector3(0.0, 0.0, -1.0)
		horiz = horiz.normalized()
		fwd = (horiz * sqrt(maxf(0.0, 1.0 - fy * fy)) + Vector3(0.0, fy, 0.0)).normalized()
	# Godot basis: X=right, Y=up, Z=back (= -forward).
	var z_axis := -fwd
	var x_axis := Vector3.UP.cross(z_axis)
	if x_axis.length_squared() < 1e-6:
		x_axis = orientation.x
	else:
		x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	# Mild bank from roll stick (not enough to invert).
	var bank := clampf(_sm_roll, -0.3, 0.3) * 0.55
	if absf(bank) > 0.001:
		y_axis = y_axis.rotated(fwd, bank).normalized()
		x_axis = y_axis.cross(z_axis).normalized()
		y_axis = z_axis.cross(x_axis).normalized()
	if y_axis.y < 0.0:
		x_axis = -x_axis
		y_axis = -y_axis
	var desired := Basis(x_axis, y_axis, z_axis).orthonormalized()
	var upright := orientation.y.y
	var hz := 5.5 if upright > 0.25 else 12.0
	var k := 1.0 - exp(-hz * delta)
	var q0 := orientation.get_rotation_quaternion()
	var q1 := desired.get_rotation_quaternion()
	orientation = Basis(q0.slerp(q1, k)).orthonormalized()
	# Kill tumble when inverted / on the side.
	if upright < 0.35:
		angular_velocity.x *= 0.7
		angular_velocity.z *= 0.55


func _flight_hold_course(delta: float, yaw_stick: float) -> void:
	# Charge -Z when clear; hard yaw stick = SEZ dodge owns the turn.
	var dodge := clampf((absf(yaw_stick) - 0.28) / 0.5, 0.0, 1.0)
	if dodge > 0.85:
		return
	var fwd := Vector3(-orientation.z.x, 0.0, -orientation.z.z)
	if fwd.length_squared() < 1e-8:
		return
	fwd = fwd.normalized()
	var goal := Vector3(0.0, 0.0, -1.0)
	var sin_a := fwd.cross(goal).y
	var cos_a := clampf(fwd.dot(goal), -1.0, 1.0)
	var err := atan2(sin_a, cos_a)
	var hold := 1.0 - dodge
	var k := 1.0 - exp(-6.5 * hold * delta)
	orientation = (Basis.from_euler(Vector3(0.0, err * k, 0.0)) * orientation).orthonormalized()
	if hold > 0.5:
		angular_velocity.y *= lerpf(1.0, 0.55, hold)


func _soft_far_wrap(config: SimulationConfig) -> void:
	## Very distant soft tether — keeps float precision sane, not a visible wall.
	var lim := config.aquarium_half_extents * 4.0
	for axis in [0, 2]:
		if position[axis] > lim[axis]:
			position[axis] -= lim[axis] * 2.0
		elif position[axis] < -lim[axis]:
			position[axis] += lim[axis] * 2.0


func _break_yaw_lock(delta: float) -> void:
	## SEZ readout often sits at ±tanh sat → continuous circles. Cap sustained yaw.
	if absf(_sm_yaw) <= YAW_LOCK_CAP:
		return
	var target := signf(_sm_yaw) * YAW_LOCK_CAP
	_sm_yaw = lerpf(_sm_yaw, target, 1.0 - exp(-4.0 * maxf(delta, 0.0001)))


func _steer_off_boundaries(config: SimulationConfig) -> void:
	## Override smoothed motor near walls/floor so FlyWire can't glue agents there.
	var half := config.aquarium_half_extents
	var m := config.wall_margin
	var right := orientation.x
	var fwd := -orientation.z

	var y_lim: float = half.y - m
	var d_floor: float = position.y + y_lim
	var d_ceil: float = y_lim - position.y
	var floor_prox := clampf(1.0 - d_floor / FLOOR_ESCAPE_RANGE, 0.0, 1.0)
	var ceil_prox := clampf(1.0 - d_ceil / FLOOR_ESCAPE_RANGE, 0.0, 1.0)
	var vert_prox := maxf(floor_prox, ceil_prox)
	if floor_prox > 0.0:
		_floor_peel_timer = maxf(_floor_peel_timer, 2.5)
		_sm_vertical = maxf(_sm_vertical, 0.7 + 0.6 * floor_prox)
		_sm_pitch = maxf(_sm_pitch, 0.2 + 0.25 * floor_prox)
	elif ceil_prox > 0.0:
		_floor_peel_timer = 0.0
		_sm_vertical = minf(_sm_vertical, -(0.7 + 0.6 * ceil_prox))
		_sm_pitch = minf(_sm_pitch, -(0.2 + 0.25 * ceil_prox))
	elif _floor_peel_timer > 0.0:
		_sm_vertical = maxf(_sm_vertical, 0.8)
		_sm_pitch = maxf(_sm_pitch, 0.2)

	var into := Vector3.ZERO
	var min_dist := WALL_ESCAPE_RANGE
	for axis in [0, 2]:
		var lim: float = half[axis] - m
		var d_hi: float = lim - position[axis]
		var d_lo: float = position[axis] + lim
		if d_hi <= WALL_ESCAPE_RANGE:
			var w := 1.0 - d_hi / WALL_ESCAPE_RANGE
			into[axis] += maxf(w, 0.0) * maxf(w, 0.0)
			min_dist = minf(min_dist, d_hi)
		if d_lo <= WALL_ESCAPE_RANGE:
			var w2 := 1.0 - d_lo / WALL_ESCAPE_RANGE
			into[axis] -= maxf(w2, 0.0) * maxf(w2, 0.0)
			min_dist = minf(min_dist, d_lo)

	var outer := maxf(absf(position.x) / maxf(half.x, 0.001), absf(position.z) / maxf(half.z, 0.001))
	# Prefer turning toward center over sideways shoving (avoids anti-aligned crab walk).
	if outer > OUTER_STEER_START:
		var to_c := Vector3(-position.x, 0.0, -position.z)
		if to_c.length_squared() > 0.01:
			to_c = to_c.normalized()
			# Signed turn from forward toward center (stable Y cross, not right.dot chatter).
			var cross_y := fwd.z * to_c.x - fwd.x * to_c.z
			if absf(cross_y) > 0.08:
				_inland_yaw_sign = signf(cross_y)
			var yaw_c := clampf(cross_y * 2.8, -YAW_LOCK_CAP, YAW_LOCK_CAP)
			if absf(yaw_c) < 0.2:
				yaw_c = _inland_yaw_sign * YAW_LOCK_CAP
			var ow := clampf((outer - OUTER_STEER_START) / (1.0 - OUTER_STEER_START), 0.0, 1.0)
			var inland_align := fwd.dot(to_c)
			if inland_align < 0.3:
				_sm_forward = 0.0
				_sm_yaw = yaw_c
			else:
				_sm_yaw = lerpf(_sm_yaw, yaw_c, 0.15 + 0.5 * ow)
				_sm_forward = maxf(_sm_forward, 0.4 + 0.35 * ow)

	if into.length_squared() < 0.0001:
		return

	var prox := clampf(1.0 - min_dist / WALL_ESCAPE_RANGE, 0.0, 1.0)
	var n := into.normalized()
	var away := -n
	var closing := clampf(fwd.dot(n), 0.0, 1.0)
	var cross_w := fwd.z * away.x - fwd.x * away.z
	if absf(cross_w) > 0.08:
		_inland_yaw_sign = signf(cross_w)
	var yaw_away := clampf(cross_w * 2.8, -YAW_LOCK_CAP, YAW_LOCK_CAP)
	if absf(yaw_away) < 0.2:
		yaw_away = _inland_yaw_sign * YAW_LOCK_CAP

	_sm_yaw = lerpf(_sm_yaw, yaw_away, clampf(0.25 + 0.7 * prox, 0.0, 0.95))
	if closing > 0.15:
		_sm_forward = minf(_sm_forward, lerpf(0.35, 0.0, closing))
	if fwd.dot(away) > 0.35:
		_sm_forward = maxf(_sm_forward, 0.35 * prox)


func _push_off_boundaries(config: SimulationConfig, delta: float) -> void:
	## Restoring acceleration applied after drag so agents don't stall on the band edge.
	var half := config.aquarium_half_extents
	var m := config.wall_margin

	var y_lim: float = half.y - m
	var d_floor: float = position.y + y_lim
	var d_ceil: float = y_lim - position.y
	# Quadratic peel — zero at band edge so agents aren't pinned there.
	if d_floor < FLOOR_ESCAPE_RANGE:
		var p := 1.0 - d_floor / FLOOR_ESCAPE_RANGE
		if velocity.y < 0.0:
			velocity.y *= 1.0 - 0.95 * p
		velocity.y += 40.0 * p * p * delta
		# World-space climb — body-up thrust alone couldn't beat SEZ dive.
		velocity.y = maxf(velocity.y, 0.7 + 1.4 * p)
	elif _floor_peel_timer > 0.0:
		velocity.y = maxf(velocity.y, 0.9)
	if d_ceil < FLOOR_ESCAPE_RANGE:
		var p2 := 1.0 - d_ceil / FLOOR_ESCAPE_RANGE
		if velocity.y > 0.0:
			velocity.y *= 1.0 - 0.95 * p2
		velocity.y -= 40.0 * p2 * p2 * delta
		velocity.y = minf(velocity.y, -(0.7 + 1.4 * p2))

	for axis in [0, 2]:
		var lim: float = half[axis] - m
		var d_hi: float = lim - position[axis]
		var d_lo: float = position[axis] + lim
		if d_hi < WALL_ESCAPE_RANGE:
			var p := 1.0 - d_hi / WALL_ESCAPE_RANGE
			if velocity[axis] > 0.0:
				velocity[axis] *= 1.0 - 0.95 * p
			velocity[axis] -= 22.0 * p * p * delta
		if d_lo < WALL_ESCAPE_RANGE:
			var p3 := 1.0 - d_lo / WALL_ESCAPE_RANGE
			if velocity[axis] < 0.0:
				velocity[axis] *= 1.0 - 0.95 * p3
			velocity[axis] += 22.0 * p3 * p3 * delta

	# If nearly stopped while facing inland, nudge toward center.
	var outer := maxf(absf(position.x) / maxf(half.x, 0.001), absf(position.z) / maxf(half.z, 0.001))
	if outer > 0.65 and velocity.length() < 0.3:
		var to_c := Vector3(-position.x, 0.0, -position.z)
		var fwd := -orientation.z
		if to_c.length_squared() > 0.01:
			to_c = to_c.normalized()
			if fwd.dot(to_c) > 0.2:
				velocity += to_c * (5.5 * delta)
				_sm_forward = maxf(_sm_forward, 0.5)


func _keep_inside(config: SimulationConfig) -> void:
	var half := config.aquarium_half_extents
	var m := config.wall_margin
	var bounced := false
	var normal := Vector3.ZERO

	for axis in 3:
		var lim: float = half[axis] - m
		if position[axis] > lim:
			position[axis] = lim
			velocity[axis] = -absf(velocity[axis]) * config.wall_bounce
			normal[axis] -= 1.0
			bounced = true
		elif position[axis] < -lim:
			position[axis] = -lim
			velocity[axis] = absf(velocity[axis]) * config.wall_bounce
			normal[axis] += 1.0
			bounced = true

	if not bounced:
		return

	# No orientation snap (that caused SPIN spikes). Damp turn lock + push inland.
	angular_velocity *= 0.2
	_sm_yaw *= 0.1
	_sm_forward = minf(_sm_forward, 0.0)
	if normal.length_squared() > 0.0001:
		var n := normal.normalized()
		var into_wall := velocity.dot(-n)
		if into_wall > 0.0:
			velocity += n * into_wall
		var slide := velocity - n * velocity.dot(n)
		velocity = slide * 0.3 + n * (1.6 + config.max_speed * 0.2)
		position += n * 0.1
		var right := orientation.x
		var up := orientation.y
		_sm_yaw = clampf(right.dot(n) * 1.1, -YAW_LOCK_CAP, YAW_LOCK_CAP)
		_sm_vertical = clampf(up.dot(n) * 1.0, -1.0, 1.0)
