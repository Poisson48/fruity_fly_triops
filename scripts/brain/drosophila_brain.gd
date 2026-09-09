class_name DrosophilaBrain
extends Brain
## FlyWire connectome brain — prefers GPU Vulkan LIF+, CPU fallback.
## Interface layer (sense gains + linear adapter) is evolvable; synapses are not.

var network: NeuralNetwork = NeuralNetwork.new()
var genome: BrainGenome = BrainGenome.new()
var _outputs: PackedFloat32Array = PackedFloat32Array()
var _last_spikes: int = 0
var _ready: bool = false
var _brain_accum: float = 0.0
var brain_dt: float = 1.0 / 30.0
var use_gpu: bool = false
var gpu_slot: int = -1
var _pending_packet: SensoryPacket = SensoryPacket.new()
var _last_raw: PackedFloat32Array = PackedFloat32Array()


func initialize(config: SimulationConfig, rng: RandomNumberGenerator, genome_in: BrainGenome = null) -> void:
	_outputs = PackedFloat32Array()
	_outputs.resize(MotorInterface.CHANNEL_COUNT)
	_last_raw = PackedFloat32Array()
	_last_raw.resize(MotorInterface.CHANNEL_COUNT)
	_last_raw.fill(0.0)
	_last_spikes = 0
	_ready = false
	_brain_accum = 0.0
	use_gpu = false
	gpu_slot = -1

	if genome_in != null:
		genome = genome_in.duplicate_genome()
		_ensure_interface_genes(rng)
	else:
		genome = BrainGenome.new()
		genome.setup(9, MotorInterface.CHANNEL_COUNT)
		genome.randomize_genes(rng, 0.12)

	var path := config.connectome_path
	if path.ends_with(".json") and not path.ends_with(".ffc.json"):
		if FileAccess.file_exists("res://data/brains/flywire_fafb_v783.ffc"):
			path = "res://data/brains/flywire_fafb_v783.ffc"
	var template := ConnectomeCache.get_template(path)
	if template.neuron_count() == 0:
		push_warning("DrosophilaBrain: empty connectome")
		return
	if not template.is_biological_provenance():
		push_warning("DrosophilaBrain: missing provenance")
		return

	var eng := GpuLifEngine.get_engine()
	if not eng.ready and not eng.setup_failed:
		eng.setup(template, config.max_triops)
	if eng.ready:
		gpu_slot = eng.allocate_slot()
		use_gpu = gpu_slot >= 0
	if not use_gpu:
		network = template.instantiate()
		# CPU path: coarser neural dt so headless stays interactive.
		brain_dt = 1.0 / 10.0
		network.max_active = 400
		network.max_spike_events = 80
		if genome and genome.motor_gains.size() > 0:
			network.drive_gain = 3.2 + genome.motor_gains[0] * 0.4
	_ready = true


func _ensure_interface_genes(rng: RandomNumberGenerator) -> void:
	if genome.input_count < 9 or genome.output_count < MotorInterface.CHANNEL_COUNT:
		genome.setup(9, MotorInterface.CHANNEL_COUNT)
		genome.randomize_genes(rng, 0.12)
		return
	if genome.sense_gains.size() < 6:
		genome.sense_gains = PackedFloat32Array([1.45, 2.35, 0.65, 0.04, 0.5, 1.2, 1.15, 1.55])
	elif genome.sense_gains.size() < 8:
		var sg := genome.sense_gains.duplicate()
		while sg.size() < 8:
			sg.append(1.15 if sg.size() == 6 else 1.55)
		genome.sense_gains = sg
	if genome.interface_mix <= 0.0 or genome.interface_mix > 0.2:
		genome.interface_mix = 0.06
	if genome.forward_tonic < 0.02:
		genome.forward_tonic = 0.05
	if genome.chemotaxis <= 0.0:
		genome.chemotaxis = 0.35
	if genome.mate_taxis <= 0.0:
		genome.mate_taxis = 0.45
	if genome.wall_taxis <= 0.0:
		genome.wall_taxis = 0.55
	if genome.wall_brake <= 0.0:
		genome.wall_brake = 0.5
	if genome.vertical_amp <= 0.0:
		genome.vertical_amp = 0.55
	if genome.pitch_amp <= 0.0:
		genome.pitch_amp = 0.45


func prepare_gpu_drive(packet: SensoryPacket) -> void:
	_pending_packet = packet
	if not (use_gpu and _ready):
		return
	SensoryMapping.apply_gpu(GpuLifEngine.get_engine(), gpu_slot, packet, genome)


func refresh_interface(packet: SensoryPacket) -> void:
	## Re-apply taxis/adapter every physics frame using last neural motor readout.
	_pending_packet = packet
	if not _ready:
		return
	_outputs = _blend_interface(packet, _last_raw)


func fetch_gpu_outputs() -> void:
	if not (use_gpu and _ready):
		return
	var eng := GpuLifEngine.get_engine()
	_last_raw = eng.get_motor(gpu_slot)
	_last_spikes = eng.get_spikes(gpu_slot)
	_outputs = _blend_interface(_pending_packet, _last_raw)


func step(inputs: SensoryPacket, delta: float) -> PackedFloat32Array:
	if not _ready:
		for i in _outputs.size():
			_outputs[i] = 0.0
		return _outputs

	_pending_packet = inputs
	if use_gpu:
		prepare_gpu_drive(inputs)
		return _outputs

	_brain_accum += delta
	var urgency := SensoryMapping.wall_urgency(inputs)
	var max_steps := 2 if urgency > 0.55 else 1
	var steps := 0
	while _brain_accum >= brain_dt and steps < max_steps:
		SensoryMapping.apply(network, inputs, genome)
		_last_spikes = network.step_lif_plus(brain_dt)
		_brain_accum -= brain_dt
		steps += 1

	var raw := network.read_motor_channels(MotorInterface.CHANNEL_COUNT)
	_outputs = _blend_interface(inputs, raw)
	return _outputs


func _blend_interface(packet: SensoryPacket, raw: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(MotorInterface.CHANNEL_COUNT)
	var flat := packet.as_flat()
	# Prefer FlyWire motor readout; tiny adapter only.
	var mix := genome.interface_mix if genome else 0.06
	mix = clampf(mix, 0.0, 0.2)
	var in_n := genome.input_count if genome else 9
	for o in MotorInterface.CHANNEL_COUNT:
		var adapter: float = genome.bias[o] if genome and o < genome.bias.size() else 0.0
		if genome and genome.weights.size() >= in_n * MotorInterface.CHANNEL_COUNT:
			var row := o * in_n
			for i in mini(in_n, flat.size()):
				adapter += genome.weights[row + i] * flat[i]
		var brain_v := raw[o] if o < raw.size() else 0.0
		var blended := brain_v * (1.0 - mix) + tanh(adapter) * mix
		var gain: float = genome.motor_gains[o] if genome and o < genome.motor_gains.size() else 1.0
		out[o] = clampf(blended * gain, -1.0, 1.0)

	# Soft residual assists — only fill in when the connectome is quiet.
	const ASSIST := 0.06
	var brain_energy := (
		absf(raw[0] if raw.size() > 0 else 0.0)
		+ absf(raw[1] if raw.size() > 1 else 0.0)
		+ absf(raw[2] if raw.size() > 2 else 0.0)
		+ absf(raw[3] if raw.size() > 3 else 0.0)
	)
	var brain_gate := clampf(1.0 - brain_energy * 2.2, 0.15, 1.0)
	var assist := ASSIST * brain_gate
	var wall_l := flat[0] if flat.size() > 0 else 0.0
	var food_l := flat[1] if flat.size() > 1 else 0.0
	var mate_l := flat[2] if flat.size() > 2 else 0.0
	var wall_r := flat[3] if flat.size() > 3 else 0.0
	var food_r := flat[4] if flat.size() > 4 else 0.0
	var mate_r := flat[5] if flat.size() > 5 else 0.0
	var wall_m := flat[6] if flat.size() > 6 else 0.0
	var food_m := flat[7] if flat.size() > 7 else 0.0
	var mate_m := flat[8] if flat.size() > 8 else 0.0
	var chemo: float = (genome.chemotaxis if genome else 0.35) * assist
	var mtax: float = (genome.mate_taxis if genome else 0.45) * assist
	var wtax: float = (genome.wall_taxis if genome else 0.55) * assist
	var wbrake: float = (genome.wall_brake if genome else 0.5) * assist
	var food_sum := food_l + food_r + food_m
	var mate_sum := mate_l + mate_r + mate_m
	var wall_max := maxf(wall_m, maxf(wall_l, wall_r))
	var expand_max := maxf(packet.expand_m, maxf(packet.expand_l, packet.expand_r))
	out[MotorInterface.CHANNEL_YAW] = clampf(
		out[MotorInterface.CHANNEL_YAW]
		+ (food_l - food_r) * chemo
		+ (mate_l - mate_r) * mtax
		+ (wall_r - wall_l) * wtax
		+ packet.flow_yaw * assist * 0.4
		+ (packet.expand_r - packet.expand_l) * wtax * 0.3,
		-1.0,
		1.0
	)
	var brake := (wall_m * 1.0 + maxf(wall_l, wall_r) * 0.4 + expand_max * 0.55) * wbrake
	out[MotorInterface.CHANNEL_FORWARD] = clampf(
		out[MotorInterface.CHANNEL_FORWARD] + food_sum * 0.02 * assist + mate_sum * 0.015 * assist - brake,
		-1.0,
		1.0
	)
	var tonic: float = (genome.forward_tonic if genome else 0.05) * (1.0 - maxf(wall_max, expand_max) * 0.8)
	out[MotorInterface.CHANNEL_FORWARD] = clampf(out[MotorInterface.CHANNEL_FORWARD] + tonic, -1.0, 1.0)

	var vamp: float = (genome.vertical_amp if genome else 0.55) * assist
	var pamp: float = (genome.pitch_amp if genome else 0.45) * assist
	var food_v := packet.food_up - packet.food_down
	var mate_v := packet.mate_up - packet.mate_down
	out[MotorInterface.CHANNEL_VERTICAL] = clampf(
		out[MotorInterface.CHANNEL_VERTICAL]
		+ food_v * vamp
		+ mate_v * vamp * 0.5
		+ (packet.ceiling_loom - packet.floor_loom) * assist * 0.55
		+ packet.flow_pitch * assist * 0.35,
		-1.0,
		1.0
	)
	out[MotorInterface.CHANNEL_PITCH] = clampf(
		out[MotorInterface.CHANNEL_PITCH]
		+ food_v * pamp
		+ mate_v * pamp * 0.4
		+ (packet.ceiling_loom - packet.floor_loom) * assist * 0.35
		+ packet.flow_pitch * assist * 0.3,
		-1.0,
		1.0
	)
	return out


func get_activity_snapshot() -> Dictionary:
	var brain_w := 1.0 - clampf(genome.interface_mix if genome else 0.12, 0.0, 0.35)
	if use_gpu and gpu_slot >= 0:
		var snap: Dictionary = GpuLifEngine.get_engine().sample_activity(gpu_slot)
		snap["brain_weight"] = brain_w
		snap["backend"] = "gpu"
		return snap
	# CPU path
	var heat := PackedByteArray()
	heat.resize(72 * 56 * 4)
	var act_l := 0.0
	var act_r := 0.0
	var act_m := 0.0
	var act_mot := 0.0
	if network and network.n_neurons > 0:
		act_l = _cpu_map_act(network.map_left)
		act_r = _cpu_map_act(network.map_right)
		act_m = _cpu_map_act(network.map_median)
		act_mot = _cpu_map_act(network.map_motor)
		var cells := 72 * 56
		var stride := maxi(1, int(floor(float(network.n_neurons) / float(cells))))
		for i in cells:
			var ni := mini(network.n_neurons - 1, i * stride)
			var vv := absf(network.v[ni])
			var t := clampf(vv * 1.8, 0.0, 1.0)
			var o := i * 4
			heat[o] = int(40 + t * 200)
			heat[o + 1] = int(30 + t * 120)
			heat[o + 2] = int(60 + (1.0 - t) * 80)
			heat[o + 3] = 255
	return {
		"act_left": act_l,
		"act_right": act_r,
		"act_median": act_m,
		"act_motor": act_mot,
		"spikes": _last_spikes,
		"neurons": network.n_neurons if network else 0,
		"synapses": network.n_synapses if network else 0,
		"heat": heat,
		"backend": "cpu",
		"brain_weight": brain_w,
	}


func _cpu_map_act(ids: PackedInt32Array) -> float:
	## Prefer synaptic current (eye drive); |V| is ~0 at rest.
	if network == null or ids.is_empty():
		return 0.0
	var n := mini(128, ids.size())
	var peak := 0.0
	var acc := 0.0
	var used := 0
	var has_i := network.i_syn.size() > 0
	for i in n:
		var ni: int = ids[i]
		if ni < 0:
			continue
		var a := 0.0
		if has_i and ni < network.i_syn.size():
			a = absf(network.i_syn[ni])
		elif ni < network.v.size():
			a = absf(network.v[ni])
		acc += a
		peak = maxf(peak, a)
		used += 1
	if used == 0:
		return 0.0
	return clampf(peak / 6.0 + (acc / float(used)) / 12.0, 0.0, 1.5)


func get_outputs() -> PackedFloat32Array:
	return _outputs


func reset() -> void:
	if network and not use_gpu:
		network._init_state_arrays()
	for i in _outputs.size():
		_outputs[i] = 0.0
	_last_spikes = 0
	_brain_accum = 0.0


func get_genome() -> BrainGenome:
	return genome


func get_debug_info() -> Dictionary:
	var neurons := 0
	var syn := 0
	var active := 0
	if use_gpu:
		var eng := GpuLifEngine.get_engine()
		neurons = eng.n_neurons
		syn = eng.n_synapses
		active = -1
	elif network:
		neurons = network.neuron_count()
		syn = network.synapse_count()
		active = network.active_list.size()
	return {
		"name": "DrosophilaBrain",
		"spike_count": _last_spikes,
		"neuron_count": neurons,
		"synapse_count": syn,
		"active": active,
		"ready": _ready,
		"backend": "gpu" if use_gpu else "cpu",
		"generation": genome.generation if genome else 0,
		"interface_mix": genome.interface_mix if genome else 0.0,
		"note": "FlyWire-led LIF+ (adapter %.0f%%, assist gated)" % (clampf(genome.interface_mix if genome else 0.06, 0, 1) * 100.0),
	}
