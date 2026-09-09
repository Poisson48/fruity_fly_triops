class_name SimulationCamera
extends Camera3D
## Aquarium camera: orbit + zoom + recenter + 3rd-person follow (aligned to Triops gaze).

enum Mode { ORBIT, FOLLOW }

@export var orbit_sensitivity: float = 0.005
@export var follow_look_sensitivity: float = 0.003
@export var zoom_step: float = 1.15
@export var min_distance: float = 2.0
@export var max_distance: float = 80.0
@export var follow_distance: float = 4.5
@export var follow_height: float = 1.2
@export var follow_look_ahead: float = 6.0
@export var follow_smooth: float = 8.0

var mode: Mode = Mode.ORBIT
var focus: Vector3 = Vector3.ZERO
var distance: float = 32.0
var yaw: float = 0.0
var pitch: float = -0.35

## Extra yaw/pitch offset while following (mouse look around gaze).
var follow_yaw_off: float = 0.0
var follow_pitch_off: float = 0.0

var _dragging: bool = false
var _world: SimulationWorld = null


func setup_aquarium(half_extents: Vector3) -> void:
	focus = Vector3.ZERO
	distance = maxf(half_extents.length() * 1.35, 18.0)
	yaw = 0.35
	pitch = -0.4
	mode = Mode.ORBIT
	follow_yaw_off = 0.0
	follow_pitch_off = 0.0
	_apply_orbit()


func bind_world(world: SimulationWorld) -> void:
	_world = world


func mode_name() -> String:
	return "FOLLOW" if mode == Mode.FOLLOW else "ORBIT"


func recenter() -> void:
	focus = Vector3.ZERO
	follow_yaw_off = 0.0
	follow_pitch_off = 0.0
	if mode == Mode.FOLLOW:
		mode = Mode.ORBIT
	_apply_orbit()


func toggle_follow() -> void:
	if mode == Mode.FOLLOW:
		mode = Mode.ORBIT
		_capture_orbit_from_transform()
	else:
		mode = Mode.FOLLOW
		follow_yaw_off = 0.0
		follow_pitch_off = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _dragging else Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.0 / zoom_step)
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(zoom_step)
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		if mode == Mode.ORBIT:
			yaw -= motion.relative.x * orbit_sensitivity
			pitch -= motion.relative.y * orbit_sensitivity
			pitch = clampf(pitch, -1.35, 1.35)
			_apply_orbit()
		else:
			follow_yaw_off -= motion.relative.x * follow_look_sensitivity
			follow_pitch_off -= motion.relative.y * follow_look_sensitivity
			follow_pitch_off = clampf(follow_pitch_off, -0.6, 0.6)
			follow_yaw_off = clampf(follow_yaw_off, -1.0, 1.0)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if mode == Mode.FOLLOW:
		_update_follow(delta)
	else:
		# Optional WASD pan of focus point in orbit mode.
		var pan := Vector3.ZERO
		var right := global_transform.basis.x
		var flat_forward := Vector3(-global_transform.basis.z.x, 0.0, -global_transform.basis.z.z)
		if flat_forward.length_squared() > 0.0001:
			flat_forward = flat_forward.normalized()
		else:
			flat_forward = Vector3.FORWARD
		if Input.is_key_pressed(KEY_W):
			pan += flat_forward
		if Input.is_key_pressed(KEY_S):
			pan -= flat_forward
		if Input.is_key_pressed(KEY_A):
			pan -= right
		if Input.is_key_pressed(KEY_D):
			pan += right
		if Input.is_key_pressed(KEY_Q):
			pan += Vector3.UP
		if Input.is_key_pressed(KEY_E):
			pan -= Vector3.UP
		if pan.length_squared() > 0.0:
			focus += pan.normalized() * distance * 0.35 * delta
			_apply_orbit()


func _zoom(factor: float) -> void:
	if mode == Mode.FOLLOW:
		follow_distance = clampf(follow_distance * factor, 1.2, 25.0)
	else:
		distance = clampf(distance * factor, min_distance, max_distance)
		_apply_orbit()


func _apply_orbit() -> void:
	var offset := Vector3(
		cos(pitch) * sin(yaw),
		-sin(pitch),
		cos(pitch) * cos(yaw)
	) * distance
	global_position = focus + offset
	look_at(focus, Vector3.UP)


func _capture_orbit_from_transform() -> void:
	var to_cam := global_position - focus
	distance = clampf(to_cam.length(), min_distance, max_distance)
	if distance < 0.001:
		distance = 20.0
	var dir := to_cam.normalized()
	pitch = -asin(clampf(dir.y, -1.0, 1.0))
	yaw = atan2(dir.x, dir.z)
	_apply_orbit()


func _update_follow(delta: float) -> void:
	if _world == null:
		return
	var agent := _world.get_agent_by_id(_world.selected_id)
	if agent == null or not agent.alive:
		mode = Mode.ORBIT
		_apply_orbit()
		return

	var basis := agent.body.orientation
	var forward := (-basis.z).normalized()
	var up := basis.y.normalized()
	if absf(forward.dot(up)) > 0.92:
		up = Vector3.UP
	var right := forward.cross(up)
	if right.length_squared() < 0.0001:
		right = basis.x
	right = right.normalized()
	up = right.cross(forward).normalized()

	# Mouse offset around Triops gaze.
	var look := forward
	look = look.rotated(up, follow_yaw_off)
	look = look.rotated(right, follow_pitch_off)
	look = look.normalized()
	var cam_right := look.cross(up)
	if cam_right.length_squared() < 0.0001:
		cam_right = right
	cam_right = cam_right.normalized()
	var cam_up := cam_right.cross(look).normalized()

	var desired_pos := agent.body.position - look * follow_distance + cam_up * follow_height
	var desired_look := agent.body.position + look * follow_look_ahead

	var t := 1.0 - exp(-follow_smooth * delta)
	global_position = global_position.lerp(desired_pos, t)
	# Smooth look: interpolate a look point then aim.
	var prev_target := global_position - global_transform.basis.z * follow_look_ahead
	var look_point := prev_target.lerp(desired_look, t)
	if (look_point - global_position).length_squared() > 0.0001:
		look_at(look_point, cam_up)

	focus = agent.body.position
