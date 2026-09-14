class_name BrainGenome
extends RefCounted
## Heritable INTERFACE + body + optional sparse connectome deltas (V4–C).
## FlyWire synapse *topology* stays fixed; genes tune coupling, body, and sparse weight mults.

const SENSE_GAIN_COUNT := 8
const SPARSE_SYNAPSE_K := 64

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
## Soft preferred depth only when no strong vertical food goal is present.
var depth_pref: float = 0.0

## Phase B — morpho / metabolism.
var body_scale: float = 1.0
var energy_drain_mult: float = 1.0
var swim_cost_mult: float = 1.0
var eat_radius_mult: float = 1.0
var maturity_age_mult: float = 1.0

## Phase C — LIF scalars + sparse SEZ-path weight multipliers.
var syn_scale_gene: float = 1.0
var drive_gain_gene: float = 1.0
var synapse_ids: PackedInt32Array = PackedInt32Array()
var synapse_mults: PackedFloat32Array = PackedFloat32Array()


func setup(in_n: int, out_n: int) -> void:
	input_count = in_n
	output_count = out_n
	weights.resize(in_n * out_n)
	bias.resize(out_n)
	motor_gains.resize(out_n)
	for i in motor_gains.size():
		motor_gains[i] = 1.0
	if out_n > MotorInterface.CHANNEL_VERTICAL:
		motor_gains[MotorInterface.CHANNEL_VERTICAL] = 1.35
	if out_n > MotorInterface.CHANNEL_PITCH:
		motor_gains[MotorInterface.CHANNEL_PITCH] = 1.25
	if out_n > MotorInterface.CHANNEL_YAW:
		motor_gains[MotorInterface.CHANNEL_YAW] = 1.35
	sense_gains = PackedFloat32Array([2.45, 2.2, 0.65, 0.04, 0.55, 1.2, 1.25, 1.45])
	interface_mix = 0.0
	depth_pref = 0.0
	body_scale = 1.0
	energy_drain_mult = 1.0
	swim_cost_mult = 1.0
	eat_radius_mult = 1.0
	maturity_age_mult = 1.0
	syn_scale_gene = 1.0
	drive_gain_gene = 1.0
	synapse_ids = PackedInt32Array()
	synapse_mults = PackedFloat32Array()


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
	depth_pref = rng.randf_range(-0.25, 0.25)
	body_scale = rng.randf_range(0.9, 1.1)
	energy_drain_mult = rng.randf_range(0.9, 1.1)
	swim_cost_mult = rng.randf_range(0.9, 1.1)
	eat_radius_mult = rng.randf_range(0.9, 1.1)
	maturity_age_mult = rng.randf_range(0.9, 1.1)
	syn_scale_gene = rng.randf_range(0.9, 1.1)
	drive_gain_gene = rng.randf_range(0.9, 1.1)
	# Soft evolvable priors for TestBrain adapter (weak when mix≈0 on drosophila):
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


func has_plastic_synapses() -> bool:
	if synapse_ids.is_empty() or synapse_mults.is_empty():
		return false
	var n := mini(synapse_ids.size(), synapse_mults.size())
	for i in n:
		if absf(synapse_mults[i] - 1.0) > 0.02:
			return true
	return false


func ensure_sparse_synapses(ids: PackedInt32Array) -> void:
	## Assign stable CSR loci (from motor-path sampling). Mults default to 1.
	synapse_ids = ids.duplicate()
	synapse_mults.resize(synapse_ids.size())
	for i in synapse_mults.size():
		synapse_mults[i] = 1.0


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
	g.depth_pref = depth_pref
	g.body_scale = body_scale
	g.energy_drain_mult = energy_drain_mult
	g.swim_cost_mult = swim_cost_mult
	g.eat_radius_mult = eat_radius_mult
	g.maturity_age_mult = maturity_age_mult
	g.syn_scale_gene = syn_scale_gene
	g.drive_gain_gene = drive_gain_gene
	g.synapse_ids = synapse_ids.duplicate()
	g.synapse_mults = synapse_mults.duplicate()
	return g


func mutate(
	rng: RandomNumberGenerator,
	rate: float,
	scale: float,
	mutate_adapter: bool = true,
	mutate_connectome: bool = false
) -> void:
	if mutate_adapter:
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
		interface_mix = clampf(interface_mix + rng.randf_range(-scale * 0.5, scale * 0.5), 0.0, 0.08)
	if rng.randf() < rate:
		depth_pref = clampf(depth_pref + rng.randf_range(-scale, scale), -0.8, 0.8)
	if rng.randf() < rate:
		body_scale = clampf(body_scale + rng.randf_range(-scale * 0.5, scale * 0.5), 0.75, 1.35)
	if rng.randf() < rate:
		energy_drain_mult = clampf(energy_drain_mult + rng.randf_range(-scale * 0.5, scale * 0.5), 0.6, 1.5)
	if rng.randf() < rate:
		swim_cost_mult = clampf(swim_cost_mult + rng.randf_range(-scale * 0.5, scale * 0.5), 0.6, 1.5)
	if rng.randf() < rate:
		eat_radius_mult = clampf(eat_radius_mult + rng.randf_range(-scale * 0.5, scale * 0.5), 0.7, 1.4)
	if rng.randf() < rate:
		maturity_age_mult = clampf(maturity_age_mult + rng.randf_range(-scale * 0.5, scale * 0.5), 0.7, 1.4)
	if rng.randf() < rate:
		syn_scale_gene = clampf(syn_scale_gene + rng.randf_range(-scale * 0.4, scale * 0.4), 0.55, 1.55)
	if rng.randf() < rate:
		drive_gain_gene = clampf(drive_gain_gene + rng.randf_range(-scale * 0.4, scale * 0.4), 0.55, 1.55)
	if mutate_connectome and not synapse_mults.is_empty():
		for i in synapse_mults.size():
			if rng.randf() < rate:
				synapse_mults[i] = clampf(
					synapse_mults[i] + rng.randf_range(-scale * 0.6, scale * 0.6), 0.5, 1.5
				)
		# Rare locus retarget within existing id list (swap with another slot's id).
		if synapse_ids.size() >= 2 and rng.randf() < rate * 0.25:
			var a := rng.randi_range(0, synapse_ids.size() - 1)
			var b := rng.randi_range(0, synapse_ids.size() - 1)
			var tmp := synapse_ids[a]
			synapse_ids[a] = synapse_ids[b]
			synapse_ids[b] = tmp
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
	child.depth_pref = a.depth_pref if rng.randf() < 0.5 else b.depth_pref
	child.body_scale = a.body_scale if rng.randf() < 0.5 else b.body_scale
	child.energy_drain_mult = a.energy_drain_mult if rng.randf() < 0.5 else b.energy_drain_mult
	child.swim_cost_mult = a.swim_cost_mult if rng.randf() < 0.5 else b.swim_cost_mult
	child.eat_radius_mult = a.eat_radius_mult if rng.randf() < 0.5 else b.eat_radius_mult
	child.maturity_age_mult = a.maturity_age_mult if rng.randf() < 0.5 else b.maturity_age_mult
	child.syn_scale_gene = a.syn_scale_gene if rng.randf() < 0.5 else b.syn_scale_gene
	child.drive_gain_gene = a.drive_gain_gene if rng.randf() < 0.5 else b.drive_gain_gene
	# Sparse loci: prefer parent A ids (stable map); crossover mults per locus.
	var n_syn := mini(child.synapse_mults.size(), b.synapse_mults.size())
	for i in n_syn:
		if rng.randf() < 0.5:
			child.synapse_mults[i] = b.synapse_mults[i]
	child.generation = maxi(a.generation, b.generation) + 1
	return child
