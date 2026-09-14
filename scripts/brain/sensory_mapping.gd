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
	var food: float = 2.6
	var wall: float = 2.35
	var mate: float = 0.95
	var tonic: float = 0.05
	var conflict: float = 0.75
	var contra: float = 1.35
	var flow: float = 1.25
	var expand: float = 1.55
	var depth_pref: float = 0.0
	## Phase C — scales inject amplitude (GPU-friendly proxy for drive_gain_gene).
	var drive_scale: float = 1.0


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
	g.depth_pref = genome.depth_pref
	g.drive_scale = clampf(genome.drive_gain_gene, 0.55, 1.55)
	return g


static func apply(network: NeuralNetwork, packet: SensoryPacket, genome: BrainGenome = null) -> void:
	var g := gains_from_genome(genome)
	var ds := g.drive_scale
	_apply_me(network, network.map_left, packet.left_on, packet.left_off, packet.left_mate, packet.left_flow_h, packet.left_flow_v, packet.expand_l, packet.contrast_l, g, true)
	_apply_me(network, network.map_right, packet.right_on, packet.right_off, packet.right_mate, packet.right_flow_h, packet.right_flow_v, packet.expand_r, packet.contrast_r, g, true)
	# Contralateral OFF cross-talk (loom asymmetry → opposite ME).
	_inject_field(network, network.map_right, ME_OFF, packet.left_off, g.wall * g.contra * 0.45 * ds)
	_inject_field(network, network.map_left, ME_OFF, packet.right_off, g.wall * g.contra * 0.45 * ds)
	_apply_lop(network, network.map_median, packet, g)
	# Weak tonic so ME doesn't go silent in open water.
	_inject_uniform(network, network.map_left, ME_MISC, 8, g.tonic * ds)
	_inject_uniform(network, network.map_right, ME_MISC, 8, g.tonic * ds)
	_drive_motor_goals_cpu(network, packet, g)


static func apply_gpu(engine: GpuLifEngine, slot: int, packet: SensoryPacket, genome: BrainGenome = null) -> void:
	var g := gains_from_genome(genome)
	# Soft GPU proxy for syn_scale_gene (shared CSR cannot vary per agent).
	if genome:
		g.drive_scale *= clampf(genome.syn_scale_gene, 0.55, 1.55)
	_apply_me_gpu(engine, slot, engine.map_left, packet.left_on, packet.left_off, packet.left_mate, packet.left_flow_h, packet.left_flow_v, packet.expand_l, packet.contrast_l, g)
	_apply_me_gpu(engine, slot, engine.map_right, packet.right_on, packet.right_off, packet.right_mate, packet.right_flow_h, packet.right_flow_v, packet.expand_r, packet.contrast_r, g)
	engine.inject_weights(slot, engine.map_right, ME_OFF, packet.left_off, g.wall * g.contra * 0.45 * g.drive_scale)
	engine.inject_weights(slot, engine.map_left, ME_OFF, packet.right_off, g.wall * g.contra * 0.45 * g.drive_scale)
	_apply_lop_gpu(engine, slot, packet, g)
	engine.inject_range(slot, engine.map_left, ME_MISC, 8, g.tonic * g.drive_scale)
	engine.inject_range(slot, engine.map_right, ME_MISC, 8, g.tonic * g.drive_scale)
	_drive_motor_goals_gpu(engine, slot, packet, g)


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
	var ds := g.drive_scale
	_inject_field(network, ids, ME_ON, on_f, g.food * ds)
	_inject_field(network, ids, ME_OFF, off_f, g.wall * ds)
	# Signed optic flow so L/R HS asymmetry can reach SEZ yaw pools.
	_inject_field(network, ids, ME_HS, _signed_field(flow_h), g.flow * ds)
	_inject_field(network, ids, ME_VS, _signed_field(flow_v), g.flow * ds)
	_inject_uniform(network, ids, ME_EXP, 8, expand * g.expand * ds)
	_inject_uniform(network, ids, ME_EXP + 8, 8, contrast * g.flow * 0.85 * ds)
	_inject_field(network, ids, ME_MISC, mate_f, g.mate * 0.85 * ds)


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
	var ds := g.drive_scale
	engine.inject_weights(slot, ids, ME_ON, on_f, g.food * ds)
	engine.inject_weights(slot, ids, ME_OFF, off_f, g.wall * ds)
	engine.inject_weights(slot, ids, ME_HS, _signed_field(flow_h), g.flow * ds)
	engine.inject_weights(slot, ids, ME_VS, _signed_field(flow_v), g.flow * ds)
	engine.inject_range(slot, ids, ME_EXP, 8, expand * g.expand * ds)
	engine.inject_range(slot, ids, ME_EXP + 8, 8, contrast * g.flow * 0.85 * ds)
	engine.inject_weights(slot, ids, ME_MISC, mate_f, g.mate * 0.85 * ds)


static func _apply_lop(network: NeuralNetwork, ids: PackedInt32Array, packet: SensoryPacket, g: Gains) -> void:
	var ds := g.drive_scale
	_inject_field(network, ids, LOP_ON, packet.median_on, g.food * 1.05 * ds)
	_inject_field(network, ids, LOP_OFF, packet.median_off, g.wall * 1.05 * ds)
	var hs := PackedFloat32Array()
	hs.resize(16)
	var yaw := packet.flow_yaw
	var loom_lr := _ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)
	# Food L/R + bearing into lobula-plate HS so SEZ yaw pools see chemotaxis neurally.
	var food_lr := (
		_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)
		+ packet.food_bearing_yaw * (0.55 + 0.9 * packet.food_bearing_strength)
	)
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		# Signed: negative t ← left, positive t ← right.
		hs[i] = (
			yaw * (0.35 + 0.65 * t)
			+ loom_lr * (0.25 + 0.35 * t)
			+ food_lr * (0.55 + 0.85 * t)
		)
	_inject_field(network, ids, LOP_HS, hs, g.flow * 1.15 * ds)
	var vs := PackedFloat32Array()
	vs.resize(16)
	var pitch := packet.flow_pitch
	var food_v := packet.food_up - packet.food_down
	var alt_v := packet.floor_loom - packet.ceiling_loom
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		vs[i] = (
			pitch * (0.4 + 0.6 * t)
			+ food_v * (0.35 + 0.4 * t)
			+ alt_v * (0.55 + 0.45 * t)
		)
	_inject_field(network, ids, LOP_VS, vs, g.flow * ds)
	var exp_v := maxf(packet.expand_m, maxf(packet.expand_l, packet.expand_r) * 0.75)
	# Ground proximity expansion into LOP (altitude collision).
	exp_v = maxf(exp_v, packet.floor_loom * 1.1)
	_inject_uniform(network, ids, LOP_EXP, 32, exp_v * g.expand * ds)
	_inject_field(network, ids, LOP_MATE, packet.median_mate, g.mate * ds)
	var conflict := (
		absf(_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)) * g.conflict
		+ absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * g.conflict * 1.25
		+ absf(packet.expand_l - packet.expand_r) * g.conflict
		+ absf(packet.food_bearing_yaw) * g.conflict * 0.35
	)
	_inject_uniform(network, ids, LOP_MISC, 16, (conflict + g.tonic * 0.5) * ds)


static func _apply_lop_gpu(engine: GpuLifEngine, slot: int, packet: SensoryPacket, g: Gains) -> void:
	var ids := engine.map_median
	var ds := g.drive_scale
	engine.inject_weights(slot, ids, LOP_ON, packet.median_on, g.food * 1.05 * ds)
	engine.inject_weights(slot, ids, LOP_OFF, packet.median_off, g.wall * 1.05 * ds)
	var hs := PackedFloat32Array()
	hs.resize(16)
	var yaw := packet.flow_yaw
	var loom_lr := _ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)
	var food_lr := (
		_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)
		+ packet.food_bearing_yaw * (0.55 + 0.9 * packet.food_bearing_strength)
	)
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		hs[i] = (
			yaw * (0.35 + 0.65 * t)
			+ loom_lr * (0.25 + 0.35 * t)
			+ food_lr * (0.55 + 0.85 * t)
		)
	engine.inject_weights(slot, ids, LOP_HS, hs, g.flow * 1.15 * ds)
	var vs := PackedFloat32Array()
	vs.resize(16)
	var pitch := packet.flow_pitch
	var food_v := packet.food_up - packet.food_down
	var alt_v := packet.floor_loom - packet.ceiling_loom
	for i in 16:
		var t := (float(i) / 15.0) * 2.0 - 1.0
		vs[i] = (
			pitch * (0.4 + 0.6 * t)
			+ food_v * (0.35 + 0.4 * t)
			+ alt_v * (0.55 + 0.45 * t)
		)
	engine.inject_weights(slot, ids, LOP_VS, vs, g.flow * ds)
	var exp_v := maxf(packet.expand_m, maxf(packet.expand_l, packet.expand_r) * 0.75)
	exp_v = maxf(exp_v, packet.floor_loom * 1.1)
	engine.inject_range(slot, ids, LOP_EXP, 32, exp_v * g.expand * ds)
	engine.inject_weights(slot, ids, LOP_MATE, packet.median_mate, g.mate * ds)
	var conflict := (
		absf(_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)) * g.conflict
		+ absf(_ch(packet.left_eye, 0) - _ch(packet.right_eye, 0)) * g.conflict * 1.25
		+ absf(packet.expand_l - packet.expand_r) * g.conflict
		+ absf(packet.food_bearing_yaw) * g.conflict * 0.35
	)
	engine.inject_range(slot, ids, LOP_MISC, 16, (conflict + g.tonic * 0.5) * ds)


static func _drive_motor_goals_gpu(engine: GpuLifEngine, slot: int, packet: SensoryPacket, g: Gains) -> void:
	## Triops→fly sensory interface: drive SEZ descending pools from compound vision.
	## This is still INSIDE the LIF (spikes/V), not a post-hoc motor script.
	## map_motor: [fwd | vert | yaw_L | pitch | yaw_R]
	var mot := engine.map_motor
	if mot.is_empty():
		return
	var channels := 5
	var chunk := maxi(1, int(floor(float(mot.size()) / float(channels))))
	var hunger := clampf(packet.food_motivation / 2.8, 0.0, 1.0)
	var food_sal := maxf(_ch(packet.median_eye, 1), maxf(_ch(packet.left_eye, 1), _ch(packet.right_eye, 1)))
	var heading := packet.food_bearing_yaw * (0.7 + 1.0 * packet.food_bearing_strength)
	var food_lr := (
		_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)
		+ heading
	)
	# Cruise / brake from FRONTAL loom only — side pillars must not kill advance.
	var frontal := packet.expand_m
	var ds := g.drive_scale
	var clear := clampf(1.0 - frontal, 0.0, 1.0)
	var fwd_amp := (0.95 + food_sal * g.food * 0.45 + clear * 0.75) * ds
	if frontal > 0.42:
		fwd_amp -= frontal * g.wall * 0.65 * ds
	if frontal > 0.7:
		fwd_amp -= frontal * g.wall * 0.45 * ds
	engine.inject_range(slot, mot, 0, chunk, fwd_amp)
	var food_vert := packet.food_up - packet.food_down
	var alt_vert := packet.floor_loom - packet.ceiling_loom
	var vert_amp := food_vert * g.food * 0.45 * (0.4 + 0.5 * hunger) * ds
	vert_amp += packet.floor_loom * g.wall * 1.05 * ds
	vert_amp -= packet.ceiling_loom * g.wall * 1.15 * ds
	if absf(food_vert) < 0.15 and absf(alt_vert) < 0.08:
		vert_amp += g.depth_pref * 0.35 * ds
	engine.inject_range(slot, mot, chunk, chunk, vert_amp)
	var pitch_amp := (packet.floor_loom * 0.65 - packet.ceiling_loom * 0.75) * g.wall * ds
	if absf(pitch_amp) > 0.03:
		engine.inject_range(slot, mot, 3 * chunk, chunk, pitch_amp)
	# Corridor yaw dominates until hard frontal loom.
	var yaw_amp := clampf(food_lr * g.food * (0.55 + 0.55 * clear), -1.1, 1.1) * ds
	if absf(yaw_amp) > 0.02 and frontal < 0.65:
		engine.inject_range(slot, mot, 2 * chunk, chunk, yaw_amp)
		engine.inject_range(slot, mot, 4 * chunk, chunk, -yaw_amp * 0.35)
	# Escape turn only on hard frontal loom.
	var wall_lr := _ch(packet.right_eye, 0) - _ch(packet.left_eye, 0)
	var flow_escape := packet.flow_yaw
	if frontal > 0.34:
		var wamp := (wall_lr * 1.4 + flow_escape * 0.8) * g.wall * (1.0 + 1.2 * frontal) * ds
		wamp = clampf(wamp, -1.45, 1.45)
		if absf(wamp) > 0.03:
			engine.inject_range(slot, mot, 2 * chunk, chunk, wamp)
			engine.inject_range(slot, mot, 4 * chunk, chunk, -wamp * 0.55)


static func _drive_motor_goals_cpu(network: NeuralNetwork, packet: SensoryPacket, g: Gains) -> void:
	var mot := network.map_motor
	if mot.is_empty():
		return
	var channels := 5
	var chunk := maxi(1, int(floor(float(mot.size()) / float(channels))))
	var hunger := clampf(packet.food_motivation / 2.8, 0.0, 1.0)
	var food_sal := maxf(_ch(packet.median_eye, 1), maxf(_ch(packet.left_eye, 1), _ch(packet.right_eye, 1)))
	var heading := packet.food_bearing_yaw * (0.7 + 1.0 * packet.food_bearing_strength)
	var food_lr := (
		_ch(packet.left_eye, 1) - _ch(packet.right_eye, 1)
		+ heading
	)
	var frontal := packet.expand_m
	var ds := g.drive_scale
	var clear := clampf(1.0 - frontal, 0.0, 1.0)
	var fwd_amp := (0.95 + food_sal * g.food * 0.45 + clear * 0.75) * ds
	if frontal > 0.42:
		fwd_amp -= frontal * g.wall * 0.65 * ds
	if frontal > 0.7:
		fwd_amp -= frontal * g.wall * 0.45 * ds
	_inject_uniform(network, mot, 0, chunk, fwd_amp)
	var food_vert := packet.food_up - packet.food_down
	var alt_vert := packet.floor_loom - packet.ceiling_loom
	var vert_amp := food_vert * g.food * 0.45 * (0.4 + 0.5 * hunger) * ds
	vert_amp += packet.floor_loom * g.wall * 1.05 * ds
	vert_amp -= packet.ceiling_loom * g.wall * 1.15 * ds
	if absf(food_vert) < 0.15 and absf(alt_vert) < 0.08:
		vert_amp += g.depth_pref * 0.35 * ds
	_inject_uniform(network, mot, chunk, chunk, vert_amp)
	var pitch_amp := (packet.floor_loom * 0.65 - packet.ceiling_loom * 0.75) * g.wall * ds
	if absf(pitch_amp) > 0.03:
		_inject_uniform(network, mot, 3 * chunk, chunk, pitch_amp)
	var yaw_amp := clampf(food_lr * g.food * (0.55 + 0.55 * clear), -1.1, 1.1) * ds
	if absf(yaw_amp) > 0.02 and frontal < 0.65:
		_inject_uniform(network, mot, 2 * chunk, chunk, yaw_amp)
		_inject_uniform(network, mot, 4 * chunk, chunk, -yaw_amp * 0.35)
	var wall_lr := _ch(packet.right_eye, 0) - _ch(packet.left_eye, 0)
	var flow_escape := packet.flow_yaw
	if frontal > 0.34:
		var wamp := (wall_lr * 1.4 + flow_escape * 0.8) * g.wall * (1.0 + 1.2 * frontal) * ds
		wamp = clampf(wamp, -1.45, 1.45)
		if absf(wamp) > 0.03:
			_inject_uniform(network, mot, 2 * chunk, chunk, wamp)
			_inject_uniform(network, mot, 4 * chunk, chunk, -wamp * 0.55)


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


static func _signed_field(field: PackedFloat32Array) -> PackedFloat32Array:
	## Pass through signed flow; clamp so inject stays stable.
	var out := PackedFloat32Array()
	out.resize(field.size())
	for i in field.size():
		out[i] = clampf(field[i], -1.5, 1.5)
	return out


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
