class_name BrainGenome
extends RefCounted
## Heritable INTERFACE parameters (V4+).
## FlyWire synapse topology stays fixed; these genes tune Triops↔brain coupling.

var input_count: int = 0
var output_count: int = 0
## Row-major weights: out * in — linear sensory adapter (also used by TestBrain).
var weights: PackedFloat32Array = PackedFloat32Array()
var bias: PackedFloat32Array = PackedFloat32Array()
var phase_rate: float = 1.0
var generation: int = 0
## Motor gain multipliers after brain / adapter blend.
var motor_gains: PackedFloat32Array = PackedFloat32Array()
## [food, wall, mate, tonic, conflict, contra_wall, flow, expand]
var sense_gains: PackedFloat32Array = PackedFloat32Array()
## How much the linear adapter blends with connectome motor readout (0=brain only).
var interface_mix: float = 0.0
## Soft forward tonic (legacy gene; exploration now via SEZ motor inject).
var forward_tonic: float = 0.0
## Legacy interface taxis genes — unused for motor (connectome pilots).
var chemotaxis: float = 0.0
var mate_taxis: float = 0.0
var wall_taxis: float = 0.0
var wall_brake: float = 0.0
## Vertical/pitch amp legacy — unused for motor.
var vertical_amp: float = 0.0
var pitch_amp: float = 0.0
## Soft preferred depth only when no vertical goal is present.
var depth_pref: float = 0.0


func setup(in_n: int, out_n: int) -> void:
	input_count = in_n
	output_count = out_n
	weights.resize(in_n * out_n)
	bias.resize(out_n)
	motor_gains.resize(out_n)
	for i in motor_gains.size():
		motor_gains[i] = 1.0
	# Boost vertical + pitch motor gains by default.
	if out_n > MotorInterface.CHANNEL_VERTICAL:
		motor_gains[MotorInterface.CHANNEL_VERTICAL] = 1.35
	if out_n > MotorInterface.CHANNEL_PITCH:
		motor_gains[MotorInterface.CHANNEL_PITCH] = 1.25
	sense_gains = PackedFloat32Array([2.45, 2.2, 0.65, 0.04, 0.55, 1.2, 1.25, 1.45])
	interface_mix = 0.0
	forward_tonic = 0.0
	chemotaxis = 0.0
	mate_taxis = 0.0
	wall_taxis = 0.0
	wall_brake = 0.0
	vertical_amp = 0.0
	pitch_amp = 0.0
	depth_pref = 0.0
	if out_n > MotorInterface.CHANNEL_YAW:
		motor_gains[MotorInterface.CHANNEL_YAW] = 1.65


func randomize_genes(rng: RandomNumberGenerator, weight_scale: float = 0.35) -> void:
	for i in weights.size():
		weights[i] = rng.randf_range(-weight_scale, weight_scale)
	for i in bias.size():
		bias[i] = rng.randf_range(-0.2, 0.2)
	phase_rate = rng.randf_range(0.7, 2.4)
	for i in motor_gains.size():
		motor_gains[i] = rng.randf_range(0.85, 1.4)
	if motor_gains.size() > MotorInterface.CHANNEL_VERTICAL:
		motor_gains[MotorInterface.CHANNEL_VERTICAL] = rng.randf_range(1.1, 1.7)
	if motor_gains.size() > MotorInterface.CHANNEL_PITCH:
		motor_gains[MotorInterface.CHANNEL_PITCH] = rng.randf_range(1.0, 1.6)
	if motor_gains.size() > MotorInterface.CHANNEL_YAW:
		motor_gains[MotorInterface.CHANNEL_YAW] = rng.randf_range(1.35, 1.9)
	sense_gains = PackedFloat32Array([
		rng.randf_range(2.0, 2.9),
		rng.randf_range(1.8, 2.6),
		rng.randf_range(0.4, 0.9),
		rng.randf_range(0.02, 0.07),
		rng.randf_range(0.35, 0.8),
		rng.randf_range(0.95, 1.55),
		rng.randf_range(0.95, 1.55),
		rng.randf_range(1.1, 1.75),
	])
	interface_mix = rng.randf_range(0.0, 0.03)
	forward_tonic = 0.0
	chemotaxis = 0.0
	mate_taxis = 0.0
	wall_taxis = 0.0
	wall_brake = 0.0
	vertical_amp = 0.0
	pitch_amp = 0.0
	depth_pref = rng.randf_range(-0.25, 0.25)
	# Soft evolvable priors (weak — connectome should carry the load):
	if input_count >= 9 and output_count >= 4:
		_nudge(0, 1, rng.randf_range(0.15, 0.4))
		_nudge(0, 4, rng.randf_range(0.15, 0.4))
		_nudge(0, 7, rng.randf_range(0.1, 0.3))
		_nudge(2, 1, rng.randf_range(0.15, 0.4))
		_nudge(2, 4, rng.randf_range(-0.4, -0.15))
		_nudge(2, 2, rng.randf_range(0.1, 0.3))
		_nudge(2, 5, rng.randf_range(-0.3, -0.1))
		_nudge(2, 0, rng.randf_range(0.25, 0.55))
		_nudge(2, 3, rng.randf_range(-0.55, -0.25))
		_nudge(0, 0, rng.randf_range(-0.45, -0.2))
		_nudge(0, 3, rng.randf_range(-0.45, -0.2))
		_nudge(0, 6, rng.randf_range(-0.55, -0.25))
		_nudge(1, 7, rng.randf_range(-0.2, 0.2))
		_nudge(3, 7, rng.randf_range(-0.25, 0.25))


func _nudge(out_i: int, in_i: int, delta: float) -> void:
	var idx := out_i * input_count + in_i
	if idx >= 0 and idx < weights.size():
		weights[idx] = clampf(weights[idx] + delta, -2.0, 2.0)


func duplicate_genome() -> BrainGenome:
	var g := BrainGenome.new()
	g.setup(input_count, output_count)
	g.weights = weights.duplicate()
	g.bias = bias.duplicate()
	g.phase_rate = phase_rate
	g.generation = generation
	g.motor_gains = motor_gains.duplicate()
	g.sense_gains = sense_gains.duplicate()
	g.interface_mix = interface_mix
	g.forward_tonic = forward_tonic
	g.chemotaxis = chemotaxis
	g.mate_taxis = mate_taxis
	g.wall_taxis = wall_taxis
	g.wall_brake = wall_brake
	g.vertical_amp = vertical_amp
	g.pitch_amp = pitch_amp
	g.depth_pref = depth_pref
	return g


func mutate(rng: RandomNumberGenerator, rate: float, scale: float) -> void:
	for i in weights.size():
		if rng.randf() < rate:
			weights[i] = clampf(weights[i] + rng.randf_range(-scale, scale), -2.0, 2.0)
	for i in bias.size():
		if rng.randf() < rate:
			bias[i] = clampf(bias[i] + rng.randf_range(-scale, scale), -1.5, 1.5)
	if rng.randf() < rate:
		phase_rate = clampf(phase_rate + rng.randf_range(-scale, scale), 0.2, 3.0)
	for i in motor_gains.size():
		if rng.randf() < rate:
			motor_gains[i] = clampf(motor_gains[i] + rng.randf_range(-scale, scale), 0.2, 2.5)
	for i in sense_gains.size():
		if rng.randf() < rate:
			sense_gains[i] = clampf(sense_gains[i] + rng.randf_range(-scale, scale), 0.01, 2.8)
	if rng.randf() < rate:
		interface_mix = clampf(interface_mix + rng.randf_range(-scale, scale), 0.0, 0.08)
	# Taxis genes retired from motor path — keep at zero.
	forward_tonic = 0.0
	chemotaxis = 0.0
	mate_taxis = 0.0
	wall_taxis = 0.0
	wall_brake = 0.0
	vertical_amp = 0.0
	pitch_amp = 0.0
	if rng.randf() < rate:
		depth_pref = clampf(depth_pref + rng.randf_range(-scale, scale), -0.8, 0.8)
	generation += 1


static func crossover(a: BrainGenome, b: BrainGenome, rng: RandomNumberGenerator) -> BrainGenome:
	var child := a.duplicate_genome()
	if a.weights.size() != b.weights.size():
		return child
	for i in child.weights.size():
		if rng.randf() < 0.5:
			child.weights[i] = b.weights[i]
	for i in child.bias.size():
		if rng.randf() < 0.5:
			child.bias[i] = b.bias[i]
	child.phase_rate = a.phase_rate if rng.randf() < 0.5 else b.phase_rate
	for i in child.motor_gains.size():
		if i < b.motor_gains.size() and rng.randf() < 0.5:
			child.motor_gains[i] = b.motor_gains[i]
	for i in child.sense_gains.size():
		if i < b.sense_gains.size() and rng.randf() < 0.5:
			child.sense_gains[i] = b.sense_gains[i]
	child.interface_mix = a.interface_mix if rng.randf() < 0.5 else b.interface_mix
	child.forward_tonic = a.forward_tonic if rng.randf() < 0.5 else b.forward_tonic
	child.chemotaxis = a.chemotaxis if rng.randf() < 0.5 else b.chemotaxis
	child.mate_taxis = a.mate_taxis if rng.randf() < 0.5 else b.mate_taxis
	child.wall_taxis = a.wall_taxis if rng.randf() < 0.5 else b.wall_taxis
	child.wall_brake = a.wall_brake if rng.randf() < 0.5 else b.wall_brake
	child.vertical_amp = a.vertical_amp if rng.randf() < 0.5 else b.vertical_amp
	child.pitch_amp = a.pitch_amp if rng.randf() < 0.5 else b.pitch_amp
	child.depth_pref = a.depth_pref if rng.randf() < 0.5 else b.depth_pref
	child.generation = maxi(a.generation, b.generation) + 1
	return child
