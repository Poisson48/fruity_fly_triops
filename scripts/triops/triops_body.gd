class_name TriopsBody
extends RefCounted
## Locomotion / simple physics for one Triops.
## brain → MotorInterface → acceleration/rotation → velocity → position
## Not a Godot physics body — simulation-owned state.

var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
## Orientation: -Z is forward (Godot convention).
var orientation: Basis = Basis.IDENTITY
var angular_velocity: Vector3 = Vector3.ZERO


func reset(pos: Vector3, basis: Basis) -> void:
	position = pos
	orientation = basis.orthonormalized()
	velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func apply_motor(cmd: MotorInterface.MotorCommand, config: SimulationConfig, delta: float) -> void:
	# Angular: yaw (Y), pitch (X), roll (Z) in local space.
	var local_ang := Vector3(cmd.pitch, cmd.yaw, cmd.roll) * config.angular_accel
	angular_velocity += local_ang * delta
	angular_velocity *= 1.0 / (1.0 + config.angular_drag * delta)

	var yaw := angular_velocity.y * delta
	var pitch := angular_velocity.x * delta
	var roll := angular_velocity.z * delta
	orientation = orientation * Basis.from_euler(Vector3(pitch, yaw, roll))
	orientation = orientation.orthonormalized()

	# Linear thrust in body frame: forward = -Z, up = Y.
	var forward := -orientation.z
	var up := orientation.y
	var accel := forward * cmd.forward * config.linear_accel + up * cmd.vertical * config.linear_accel
	velocity += accel * delta
	velocity *= 1.0 / (1.0 + config.linear_drag * delta)

	var speed := velocity.length()
	if speed > config.max_speed:
		velocity = velocity * (config.max_speed / speed)

	position += velocity * delta
	_keep_inside(config)


func _keep_inside(config: SimulationConfig) -> void:
	var half := config.aquarium_half_extents
	var m := config.wall_margin
	var bounced := false

	for axis in 3:
		var lim: float = half[axis] - m
		if position[axis] > lim:
			position[axis] = lim
			velocity[axis] = -absf(velocity[axis]) * config.wall_bounce
			bounced = true
		elif position[axis] < -lim:
			position[axis] = -lim
			velocity[axis] = absf(velocity[axis]) * config.wall_bounce
			bounced = true

	if bounced and velocity.length_squared() > 0.0001:
		# Gentle reorient after bounce — avoid teleport-facing that looks random.
		var desired := velocity.normalized()
		var current_fwd := -orientation.z
		var blended := (current_fwd * 0.7 + desired * 0.3).normalized()
		if blended.length_squared() > 0.0001:
			var up := orientation.y.normalized()
			if absf(blended.dot(up)) > 0.95:
				up = orientation.x.normalized()
			orientation = Basis.looking_at(blended, up)
