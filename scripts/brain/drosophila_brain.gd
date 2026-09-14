class_name DrosophilaBrain
extends Brain
## FlyWire connectome brain — prefers GPU Vulkan LIF+, CPU fallback.
## Interface + body genes evolve always; sparse synapse mults when connectome_evolution_enabled.

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
## Free-flight: pass full SEZ stick without aquarium soft-clamps.
var _flight_mode: bool = false
## World-up thrust that counters flight_gravity when attitude is level.
var _flight_hover: float = 0.0


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
	_flight_mode = config.is_free_flight()
	# Solo fly can afford a hotter neural clock (full connectome, 1 agent).
	brain_dt = 1.0 / 60.0 if _flight_mode else 1.0 / 30.0
	_flight_hover = 0.0
	if _flight_mode and config.linear_accel > 0.01:
		_flight_hover = clampf(config.flight_gravity / config.linear_accel, 0.12, 0.55)

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

	if config.connectome_evolution_enabled:
		_ensure_sparse_loci(template, rng, path)

	# Sparse plastic weights need a private CSR copy → CPU path for that agent.
	var need_cpu_weights := (
		config.connectome_evolution_enabled and genome != null and genome.has_plastic_synapses()
	)

	var eng := GpuLifEngine.get_engine()
	if not need_cpu_weights:
		if not eng.ready and not eng.setup_failed:
			eng.setup(template, config.max_triops)
		if eng.ready:
			gpu_slot = eng.allocate_slot()
			use_gpu = gpu_slot >= 0
	if not use_gpu:
		network = template.instantiate(need_cpu_weights)
		if need_cpu_weights and genome != null:
			network.apply_sparse_weight_mults(genome.synapse_ids, genome.synapse_mults)
		# CPU path: coarser neural dt so headless stays interactive.
		brain_dt = 1.0 / 10.0
		network.max_active = 400
		network.max_spike_events = 80
		var base_drive := 3.2
		if genome and genome.motor_gains.size() > 0:
			base_drive = 3.2 + genome.motor_gains[0] * 0.4
		network.drive_gain = base_drive
		if genome:
			network.syn_scale = template.syn_scale * clampf(genome.syn_scale_gene, 0.55, 1.55)
	_ready = true


func _ensure_interface_genes(rng: RandomNumberGenerator) -> void:
	## Migrate array sizes only — do not clamp evolved gains (selection must see traits).
	if genome.input_count < 9 or genome.output_count < MotorInterface.CHANNEL_COUNT:
		genome.setup(9, MotorInterface.CHANNEL_COUNT)
		genome.randomize_genes(rng, 0.12)
		return
	if genome.sense_gains.size() < 6:
		genome.sense_gains = PackedFloat32Array([2.45, 2.2, 0.65, 0.04, 0.55, 1.2, 1.25, 1.45])
	elif genome.sense_gains.size() < 8:
		var sg := genome.sense_gains.duplicate()
		while sg.size() < 8:
			sg.append(1.15 if sg.size() == 6 else 1.55)
		genome.sense_gains = sg
	if genome.motor_gains.size() < MotorInterface.CHANNEL_COUNT:
		var mg := genome.motor_gains.duplicate()
		while mg.size() < MotorInterface.CHANNEL_COUNT:
			mg.append(1.0)
		genome.motor_gains = mg


func _ensure_sparse_loci(template: NeuralNetwork, rng: RandomNumberGenerator, path: String) -> void:
	if genome == null:
		return
	if genome.synapse_ids.is_empty():
		var ids := ConnectomeCache.get_motor_synapse_loci(path, BrainGenome.SPARSE_SYNAPSE_K, rng)
		if ids.is_empty():
			ids = template.sample_motor_synapse_ids(BrainGenome.SPARSE_SYNAPSE_K, rng)
		genome.ensure_sparse_synapses(ids)
		return
	if genome.synapse_mults.size() < genome.synapse_ids.size():
		var old := genome.synapse_mults.duplicate()
		genome.synapse_mults.resize(genome.synapse_ids.size())
		for i in genome.synapse_mults.size():
			genome.synapse_mults[i] = old[i] if i < old.size() else 1.0


func prepare_gpu_drive(packet: SensoryPacket) -> void:
	_pending_packet = packet
	if not (use_gpu and _ready):
		return
	# Soft GPU proxy: fold syn_scale_gene into inject amplitude (shared CSR weights).
	SensoryMapping.apply_gpu(GpuLifEngine.get_engine(), gpu_slot, packet, genome)


func refresh_interface(packet: SensoryPacket) -> void:
	## Re-scale SEZ motor with gains each physics frame (no assist steer).
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
	_last_raw = raw
	_outputs = _blend_interface(inputs, raw)
	return _outputs


func _blend_interface(packet: SensoryPacket, raw: PackedFloat32Array) -> PackedFloat32Array:
	## Pure FlyWire motor: SEZ readout × gains. No post-hoc taxis / chase / wall steer.
	var out := PackedFloat32Array()
	out.resize(MotorInterface.CHANNEL_COUNT)
	var mix := 0.0
	if genome and not _flight_mode:
		mix = clampf(genome.interface_mix, 0.0, 0.05)
	var flat := packet.as_flat()
	var in_n := genome.input_count if genome else 9
	for o in MotorInterface.CHANNEL_COUNT:
		var brain_v := raw[o] if o < raw.size() else 0.0
		var v := brain_v
		if mix > 0.0 and genome:
			var adapter: float = genome.bias[o] if o < genome.bias.size() else 0.0
			if genome.weights.size() >= in_n * MotorInterface.CHANNEL_COUNT:
				var row := o * in_n
				for i in mini(in_n, flat.size()):
					adapter += genome.weights[row + i] * flat[i]
			v = brain_v * (1.0 - mix) + tanh(adapter) * mix
		var gain: float = genome.motor_gains[o] if genome and o < genome.motor_gains.size() else 1.0
		var scaled := v * gain
		if _flight_mode:
			# Full connectome owns the stick — no aquarium soft-clamp on yaw/pitch.
			out[o] = clampf(scaled, -1.0, 1.0)
		elif o == MotorInterface.CHANNEL_YAW or o == MotorInterface.CHANNEL_PITCH:
			out[o] = tanh(scaled * 0.85)
		else:
			out[o] = clampf(scaled, -1.0, 1.0)
	if _flight_mode:
		# SEZ is the stick. Only center single-ended pools + light altitude assist
		# from ventral loom already injected into the LIF.
		var alt := packet.floor_loom - packet.ceiling_loom
		var raw_v := out[MotorInterface.CHANNEL_VERTICAL]
		var raw_p := out[MotorInterface.CHANNEL_PITCH]
		out[MotorInterface.CHANNEL_VERTICAL] = clampf(
			_flight_hover + (raw_v - 0.42) * 0.85 + alt * 0.35,
			-1.0,
			1.0
		)
		if packet.floor_loom > 0.85:
			out[MotorInterface.CHANNEL_VERTICAL] = maxf(
				out[MotorInterface.CHANNEL_VERTICAL],
				0.4 + packet.floor_loom * 0.25
			)
		out[MotorInterface.CHANNEL_PITCH] = clampf(
			(raw_p - 0.12) * 0.8 + alt * 0.25,
			-1.0,
			1.0
		)
		# Roll almost off — body leveling keeps belly down; SEZ yaw steers.
		out[MotorInterface.CHANNEL_ROLL] = clampf(out[MotorInterface.CHANNEL_ROLL] * 0.12, -0.2, 0.2)
		# Yaw: lock course when clear; brief dodge only on hard frontal loom.
		var threat := clampf(packet.expand_m, 0.0, 1.0)
		var dodge_w := clampf((threat - 0.38) / 0.35, 0.0, 1.0)
		var yaw_sez := out[MotorInterface.CHANNEL_YAW]
		var course := clampf(packet.food_bearing_yaw, -0.85, 0.85)
		out[MotorInterface.CHANNEL_YAW] = clampf(
			lerpf(course, yaw_sez * 0.25 + packet.flow_yaw * 0.9, dodge_w),
			-1.0,
			1.0
		)
		out[MotorInterface.CHANNEL_FORWARD] = clampf(
			lerpf(0.92, maxf(out[MotorInterface.CHANNEL_FORWARD], 0.35), dodge_w),
			0.15,
			1.0
		)
	else:
		out[MotorInterface.CHANNEL_ROLL] = clampf(out[MotorInterface.CHANNEL_ROLL] * 0.45, -0.55, 0.55)
	return out


func get_raw_motor() -> PackedFloat32Array:
	return _last_raw


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
		"note": "FlyWire-only motor (SEZ readout; no assist steer)",
	}
