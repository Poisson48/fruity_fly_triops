class_name SensoryMapping
extends RefCounted
## Triops fly-like vision → FlyWire ME_L / ME_R / LOP populations.
##
## Map layout (128 cells, retinotopic interface — not biological labels):
##   ME L/R:
##     0..31   ON mosaic (food / figure)     ← lamina/medulla ON proxy
##     32..63  OFF / loom mosaic             ← edge / collision
##     64..79  HS column flow               ← horizontal motion
##     80..95  VS row flow                  ← vertical motion
##     96..111 expansion + contrast         ← LPLC-like / edge density
##     112..127 mate + binocular conflict
##   LOP (median map):
##     0..15   frontal ON
##     16..31  frontal OFF
##     32..47  binocular HS (yaw flow)
##     48..63  VS / pitch flow
##     64..95  expansion loom
##     96..111 mate figure
##     112..127 L/R conflict + tonic

const ME_ON := 0
const ME_OFF := 32
const ME_HS := 64
const ME_VS := 80
const ME_EXP := 96
const ME_MISC := 112

const LOP_ON := 0
const LOP_OFF := 16
const LOP_HS := 32
const LOP_VS := 48
const LOP_EXP := 64
const LOP_MATE := 96
const LOP_MISC := 112


class Gains:
	var food: float = 1.6
	var wall: float = 2.4
	var mate: float = 0.85
	var tonic: float = 0.06
	var conflict: float = 0.7
	var contra: float = 1.25
	var flow: float = 1.1
	var expand: float = 1.35


static func gains_from_genome(genome: BrainGenome) -> Gains:
	var g := Gains.new()
	if genome == null or genome.sense_gains.size() < 6:
		return g
	g.food = genome.sense_gains[0]
	g.wall = genome.sense_gains[1]
	g.mate = genome.sense_gains[2]
	g.tonic = genome.sense_gains[3]
	g.conflict = genome.sense_gains[4]
	g.contra = genome.sense_gains[5]
	if genome.sense_gains.size() > 6:
		g.flow = genome.sense_gains[6]
	if genome.sense_gains.size() > 7:
		g.expand = genome.sense_gains[7]
	return g


static func apply(network: NeuralNetwork, packet: SensoryPacket, genome: BrainGenome = null) -> void:
	var g := gains_from_genome(genome)
	_apply_me(network, network.map_left, packet.left_on, packet.left_off, packet.left_mate, packet.left_flow_h, packet.left_flow_v, packet.expand_l, packet.contrast_l, g, true)
	_apply_me(network, network.map_right, packet.right_on, packet.right_off, packet.right_mate, packet.right_flow_h, packet.right_flow_v, packet.expand_r, packet.contrast_r, g, true)
	# Contralateral OFF cross-talk (loom asymmetry → opposite ME).
	_inject_field(network, network.map_right, ME_OFF, packet.left_off, g.wall * g.contra * 0.45)
	_inject_field(network, network.map_left, ME_OFF, packet.right_off, g.wall * g.contra * 0.45)
	_apply_lop(network, network.map_median, packet, g)
	# Weak tonic so ME doesn't go silent in open water.
	_inject_uniform(network, network.map_left, ME_MISC, 8, g.tonic)
	_inject_uniform(network, network.map_right, ME_MISC, 8, g.tonic)


static func apply_gpu(engine: GpuLifEngine, slot: int, packet: SensoryPacket, genome: BrainGenome = null) -> void:
	var g := gains_from_genome(genome)
	_apply_me_gpu(engine, slot, engine.map_left, packet.left_on, packet.left_off, packet.left_mate, packet.left_flow_h, packet.left_flow_v, packet.expand_l, packet.contrast_l, g)
	_apply_me_gpu(engine, slot, engine.map_right, packet.right_on, packet.right_off, packet.right_mate, packet.right_flow_h, packet.right_flow_v, packet.expand_r, packet.contrast_r, g)
	engine.inject_weights(slot, engine.map_right, ME_OFF, packet.left_off, g.wall * g.contra * 0.45)
	engine.inject_weights(slot, engine.map_left, ME_OFF, packet.right_off, g.wall * g.contra * 0.45)
	_apply_lop_gpu(engine, slot, packet, g)
	engine.inject_range(slot, engine.map_left, ME_MISC, 8, g.tonic)
	engine.inject_range(slot, engine.map_right, ME_MISC, 8, g.tonic)


static func wall_urgency(packet: SensoryPacket) -> float:
	return maxf(
		packet.expand_l,
		maxf(packet.expand_r, maxf(packet.expand_m, maxf(_ch(packet.left_eye, 0), maxf(_ch(packet.right_eye, 0), _ch(packet.median_eye, 0)))))
	)


static func _apply_me(
	network: NeuralNetwork,
	ids: PackedInt32Array,
	on_f: PackedFloat32Array,
	off_f: PackedFloat32Array,
	mate_f: PackedFloat32Array,
	flow_h: PackedFloat32Array,
	flow_v: PackedFloat32Array,
	expand: float,
	contrast: float,
	g: Gains,
	_ipsi: bool
) -> void:
	_inject_field(network, ids, ME_ON, on_f, g.food)
	_inject_field(network, ids, ME_OFF, off_f, g.wall)
	_inject_field(network, ids, ME_HS, _abs_field(flow_h), g.flow)
	_inject_field(network, ids, ME_VS, _abs_field(flow_v), g.flow)
	_inject_uniform(network, ids, ME_EXP, 8, expand * g.expand)
	_inject_uniform(network, ids, ME_EXP + 8, 8, contrast * g.flow * 0.8)
	_inject_field(network, ids, ME_MISC, mate_f, g.mate * 0.6)


static func _apply_me_gpu(
	engine: GpuLifEngine,
	slot: int,
	ids: PackedInt32Array,
	on_f: PackedFloat32Array,
	off_f: PackedFloat32Array,
	mate_f: PackedFloat32Array,
	flow_h: PackedFloat32Array,
	flow_v: PackedFloat32Array,
	expand: float,
	contrast: float,
	g: Gains
) -> void:
	engine.inject_weights(slot, ids, ME_ON, on_f, g.food)
	engine.inject_weights(slot, ids, ME_OFF, off_f, g.wall)
	engine.inject_weights(slot, ids, ME_HS, _abs_field(flow_h), g.flow)
	engine.inject_weights(slot, ids, ME_VS, _abs_field(flow_v), g.flow)
	engine.inject_range(slot, ids, ME_EXP, 8, expand * g.expand)
	engine.inject_range(slot, ids, ME_EXP + 8, 8, contrast * g.flow * 0.8)
	engine.inject_weights(slot, ids, ME_MISC, mate_f, g.mate * 0.6)


static func _apply_lop(network: NeuralNetwork, ids: PackedInt32Array, packet: SensoryPacket, g: Gains) -> void:
	_inject_field(network, ids, LOP_ON, packet.median_on, g.food * 0.85)
	_inject_field(network, ids, LOP_OFF, packet.median_off, g.wall * 1.05)
	# Binocular HS into LOP: signed yaw flow + L/R loom imbalance.
	var hs := PackedFloat32Array()
	hs.resize(16)
	var yaw := packet.flow_yaw
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		hs[i] = absf(yaw) * (0.55 + 0.45 * absf(t)) + absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * 0.4
	_inject_field(network, ids, LOP_HS, hs, g.flow)
	var vs := PackedFloat32Array()
	vs.resize(16)
	var pitch := packet.flow_pitch
	for i in 16:
		vs[i] = absf(pitch) * (0.5 + 0.5 * float(i) / 15.0)
	_inject_field(network, ids, LOP_VS, vs, g.flow)
	var exp_v := maxf(packet.expand_m, maxf(packet.expand_l, packet.expand_r) * 0.7)
	_inject_uniform(network, ids, LOP_EXP, 32, exp_v * g.expand)
	_inject_field(network, ids, LOP_MATE, packet.median_mate, g.mate)
	var conflict := (
		absf(_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)) * g.conflict
		+ absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * g.conflict * 1.25
		+ absf(packet.expand_l - packet.expand_r) * g.conflict
	)
	_inject_uniform(network, ids, LOP_MISC, 16, conflict + g.tonic * 0.5)


static func _apply_lop_gpu(engine: GpuLifEngine, slot: int, packet: SensoryPacket, g: Gains) -> void:
	var ids := engine.map_median
	engine.inject_weights(slot, ids, LOP_ON, packet.median_on, g.food * 0.85)
	engine.inject_weights(slot, ids, LOP_OFF, packet.median_off, g.wall * 1.05)
	var hs := PackedFloat32Array()
	hs.resize(16)
	var yaw := packet.flow_yaw
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		hs[i] = absf(yaw) * (0.55 + 0.45 * absf(t)) + absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * 0.4
	engine.inject_weights(slot, ids, LOP_HS, hs, g.flow)
	var vs := PackedFloat32Array()
	vs.resize(16)
	var pitch := packet.flow_pitch
	for i in 16:
		vs[i] = absf(pitch) * (0.5 + 0.5 * float(i) / 15.0)
	engine.inject_weights(slot, ids, LOP_VS, vs, g.flow)
	var exp_v := maxf(packet.expand_m, maxf(packet.expand_l, packet.expand_r) * 0.7)
	engine.inject_range(slot, ids, LOP_EXP, 32, exp_v * g.expand)
	engine.inject_weights(slot, ids, LOP_MATE, packet.median_mate, g.mate)
	var conflict := (
		absf(_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)) * g.conflict
		+ absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * g.conflict * 1.25
		+ absf(packet.expand_l - packet.expand_r) * g.conflict
	)
	engine.inject_range(slot, ids, LOP_MISC, 16, conflict + g.tonic * 0.5)


static func _inject_field(network: NeuralNetwork, ids: PackedInt32Array, offset: int, field: PackedFloat32Array, gain: float) -> void:
	if ids.is_empty() or field.is_empty() or absf(gain) < 0.00001:
		return
	var amp_scale := network.drive_gain * gain
	var n := mini(field.size(), maxi(0, ids.size() - offset))
	for i in n:
		var a: float = field[i] * amp_scale
		if absf(a) < 0.00001:
			continue
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= network.n_neurons:
			continue
		network.i_syn[ni] += a
		network._activate(ni)


static func _inject_uniform(network: NeuralNetwork, ids: PackedInt32Array, offset: int, count: int, amp_in: float) -> void:
	if ids.is_empty() or absf(amp_in) < 0.00001:
		return
	var amp := amp_in * network.drive_gain
	var n := mini(count, maxi(0, ids.size() - offset))
	for i in n:
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= network.n_neurons:
			continue
		network.i_syn[ni] += amp
		network._activate(ni)


static func _abs_field(field: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(field.size())
	for i in field.size():
		out[i] = absf(field[i])
	return out


static func _ch(channels: PackedFloat32Array, idx: int) -> float:
	if idx < 0 or idx >= channels.size():
		return 0.0
	return channels[idx]
