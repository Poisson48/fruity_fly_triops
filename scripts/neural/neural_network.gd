class_name NeuralNetwork
extends RefCounted
## Compact FlyWire connectome runtime (CSR) + LIF+ event-driven dynamics.
## Topology from real data; dynamics are an explicit biophysical model layer
## (still not a full Hodgkin–Huxley / neuromodulatory brain).

var n_neurons: int = 0
var n_synapses: int = 0

## CSR outgoing synapses (shared across agents via instantiate()).
var csr_offsets: PackedInt32Array = PackedInt32Array()
var csr_targets: PackedInt32Array = PackedInt32Array()
var csr_weights: PackedFloat32Array = PackedFloat32Array()
var csr_sources: PackedInt32Array = PackedInt32Array()

## Per-neuron state (unique per agent instance).
var v: PackedFloat32Array = PackedFloat32Array()
var i_syn: PackedFloat32Array = PackedFloat32Array()
var refractory: PackedFloat32Array = PackedFloat32Array()
var active: PackedByteArray = PackedByteArray()
var active_list: PackedInt32Array = PackedInt32Array()

## Neuropil-grounded Triops interface indices (shared).
var map_left: PackedInt32Array = PackedInt32Array()
var map_right: PackedInt32Array = PackedInt32Array()
var map_median: PackedInt32Array = PackedInt32Array()
var map_motor: PackedInt32Array = PackedInt32Array()

var neuropil_names: PackedStringArray = PackedStringArray()
var primary_neuropil: PackedInt32Array = PackedInt32Array()
var provenance: Dictionary = {}

## LIF+ parameters (seconds / arbitrary membrane units).
var v_rest: float = 0.0
var v_thresh: float = 0.4
var v_reset: float = 0.0
var tau_mem: float = 0.020
var tau_syn: float = 0.040
var t_ref: float = 0.002
var drive_gain: float = 3.0
## Global synaptic scaling (required for dense FlyWire graphs in realtime).
var syn_scale: float = 0.035
var max_active: int = 600
var max_spike_events: int = 120


func neuron_count() -> int:
	return n_neurons


func synapse_count() -> int:
	return n_synapses


func is_biological_provenance() -> bool:
	if provenance.is_empty():
		return false
	var kind := str(provenance.get("kind", "")).to_lower()
	return kind in ["flywire", "hemibrain", "neuprint", "biological", "real", "connectome"] \
		or provenance.has("dataset") or provenance.has("citation")


func load_from_ffc(path: String) -> Error:
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ERR_CANT_OPEN
	var magic := f.get_buffer(4).get_string_from_ascii()
	if magic != "FFC1":
		push_error("NeuralNetwork: bad magic in %s" % path)
		return ERR_INVALID_DATA

	n_neurons = f.get_32()
	n_synapses = f.get_32()
	var neuropil_count := f.get_32()
	f.get_32()  # flags

	primary_neuropil.resize(n_neurons)
	for i in n_neurons:
		f.get_64()
		primary_neuropil[i] = f.get_16()
		f.get_16()

	neuropil_names.resize(neuropil_count)
	for i in neuropil_count:
		var nlen := f.get_16()
		neuropil_names[i] = f.get_buffer(nlen).get_string_from_utf8()

	csr_offsets.resize(n_neurons + 1)
	var off_bytes := f.get_buffer((n_neurons + 1) * 4)
	for i in n_neurons + 1:
		csr_offsets[i] = off_bytes.decode_s32(i * 4)
	csr_targets.resize(n_synapses)
	var tgt_bytes := f.get_buffer(n_synapses * 4)
	for i in n_synapses:
		csr_targets[i] = tgt_bytes.decode_s32(i * 4)
	csr_weights.resize(n_synapses)
	var w_bytes := f.get_buffer(n_synapses * 4)
	for i in n_synapses:
		csr_weights[i] = w_bytes.decode_float(i * 4)

	# COO sources for GPU synapse pass.
	csr_sources = PackedInt32Array()
	csr_sources.resize(n_synapses)
	for src in n_neurons:
		var a: int = csr_offsets[src]
		var b: int = csr_offsets[src + 1]
		for e in range(a, b):
			csr_sources[e] = src

	map_left = _read_index_list(f)
	map_right = _read_index_list(f)
	map_median = _read_index_list(f)
	map_motor = _read_index_list(f)

	_init_state_arrays()

	var side := path + ".json"
	if FileAccess.file_exists(side):
		var sf := FileAccess.open(side, FileAccess.READ)
		if sf:
			var parsed: Variant = JSON.parse_string(sf.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY and parsed.has("provenance"):
				provenance = parsed["provenance"]
	if provenance.is_empty():
		provenance = {
			"kind": "flywire",
			"dataset": path.get_file(),
			"citation": "FlyWire FAFB connectome (binary FFC1 import)",
		}
	return OK


func _read_index_list(f: FileAccess) -> PackedInt32Array:
	var n := f.get_32()
	var arr := PackedInt32Array()
	arr.resize(n)
	for i in n:
		arr[i] = f.get_32()
	return arr


func _init_state_arrays() -> void:
	v = PackedFloat32Array()
	v.resize(n_neurons)
	v.fill(v_rest)
	i_syn = PackedFloat32Array()
	i_syn.resize(n_neurons)
	i_syn.fill(0.0)
	refractory = PackedFloat32Array()
	refractory.resize(n_neurons)
	refractory.fill(0.0)
	active = PackedByteArray()
	active.resize(n_neurons)
	active.fill(0)
	active_list = PackedInt32Array()


func instantiate(clone_weights: bool = false) -> NeuralNetwork:
	var n := NeuralNetwork.new()
	n.n_neurons = n_neurons
	n.n_synapses = n_synapses
	n.csr_offsets = csr_offsets
	n.csr_targets = csr_targets
	n.csr_weights = csr_weights.duplicate() if clone_weights else csr_weights
	n.csr_sources = csr_sources
	n.map_left = map_left
	n.map_right = map_right
	n.map_median = map_median
	n.map_motor = map_motor
	n.neuropil_names = neuropil_names
	n.primary_neuropil = primary_neuropil
	n.provenance = provenance.duplicate(true)
	n.v_rest = v_rest
	n.v_thresh = v_thresh
	n.v_reset = v_reset
	n.tau_mem = tau_mem
	n.tau_syn = tau_syn
	n.t_ref = t_ref
	n.drive_gain = drive_gain
	n.syn_scale = syn_scale
	n.max_active = max_active
	n.max_spike_events = max_spike_events
	n._init_state_arrays()
	return n


func apply_sparse_weight_mults(ids: PackedInt32Array, mults: PackedFloat32Array) -> void:
	## Mutates this instance's csr_weights (must be a private copy).
	var n := mini(ids.size(), mults.size())
	for i in n:
		var e: int = ids[i]
		if e < 0 or e >= csr_weights.size():
			continue
		csr_weights[e] *= clampf(mults[i], 0.5, 1.5)


func sample_motor_synapse_ids(k: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	## Stable sample of CSR edges touching map_motor neurons.
	var out := PackedInt32Array()
	if k <= 0 or n_synapses <= 0 or map_motor.is_empty():
		return out
	var motor := {}
	for ni in map_motor:
		if ni >= 0:
			motor[ni] = true
	var candidates := PackedInt32Array()
	var has_src := csr_sources.size() == n_synapses
	for e in n_synapses:
		var tgt: int = csr_targets[e] if e < csr_targets.size() else -1
		var src: int = csr_sources[e] if has_src else -1
		if motor.has(tgt) or motor.has(src):
			candidates.append(e)
	if candidates.is_empty():
		# Fallback: uniform sample over all synapses.
		for _i in mini(k, n_synapses):
			out.append(rng.randi_range(0, n_synapses - 1))
		return out
	# Fisher-Yates partial shuffle for unique sample.
	var n_cand := candidates.size()
	var take := mini(k, n_cand)
	for i in take:
		var j := rng.randi_range(i, n_cand - 1)
		var tmp := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp
		out.append(candidates[i])
	return out


func _activate(i: int) -> void:
	if i < 0 or i >= n_neurons:
		return
	if active[i] == 1:
		return
	active[i] = 1
	active_list.append(i)


func inject_population(neuron_ids: PackedInt32Array, amp_in: float) -> void:
	if neuron_ids.is_empty() or absf(amp_in) < 0.00001:
		return
	var amp := amp_in * drive_gain
	# Drive the strongest-mapped cells fully (list is out-degree sorted at build).
	var n_drive := mini(24, neuron_ids.size())
	for i in n_drive:
		var ni: int = neuron_ids[i]
		if ni < 0 or ni >= n_neurons:
			continue
		i_syn[ni] += amp
		_activate(ni)


func step_lif_plus(dt: float) -> int:
	if n_neurons == 0 or dt <= 0.0:
		return 0
	var inv_tau_m := 1.0 / maxf(tau_mem, 0.0001)
	var syn_decay := exp(-dt / maxf(tau_syn, 0.0001))
	var spikes := 0
	var spiked := PackedInt32Array()
	var next_active := PackedInt32Array()

	for ai in active_list.size():
		var i: int = active_list[ai]
		if refractory[i] > 0.0:
			refractory[i] -= dt
			i_syn[i] *= syn_decay
			v[i] = v_reset
			if refractory[i] > 0.0 or absf(i_syn[i]) > 0.01:
				next_active.append(i)
			else:
				active[i] = 0
			continue

		# tau dV/dt = -(V - Vrest) + I_syn  =>  V_inf = Vrest + I_syn
		i_syn[i] *= syn_decay
		v[i] += dt * inv_tau_m * ((v_rest - v[i]) + i_syn[i])

		if v[i] >= v_thresh:
			spikes += 1
			v[i] = v_reset
			refractory[i] = t_ref
			i_syn[i] *= 0.2
			spiked.append(i)
			next_active.append(i)
		elif absf(i_syn[i]) > 0.01 or absf(v[i] - v_rest) > 0.02:
			next_active.append(i)
		else:
			active[i] = 0
			v[i] = v_rest

	active.fill(0)
	for ai in next_active.size():
		active[next_active[ai]] = 1
	active_list = next_active

	# Event-driven synaptic propagation with storm caps.
	var n_prop := mini(spiked.size(), max_spike_events)
	for si in n_prop:
		var src: int = spiked[si]
		var a: int = csr_offsets[src]
		var b: int = csr_offsets[src + 1]
		for e in range(a, b):
			if active_list.size() >= max_active and active[csr_targets[e]] == 0:
				continue
			var tgt: int = csr_targets[e]
			i_syn[tgt] += csr_weights[e] * syn_scale
			_activate(tgt)

	return spikes


func read_motor_channels(count: int) -> PackedFloat32Array:
	## map_motor packing: [forward | vertical | yaw_L | pitch | yaw_R]
	## yaw = mean(yaw_L) - mean(yaw_R)
	var out := PackedFloat32Array()
	out.resize(count)
	if map_motor.is_empty():
		return out
	var chunk := maxi(1, int(floor(float(map_motor.size()) / float(maxi(count, 1)))))
	var fwd := _mean_motor_range(0, mini(map_motor.size(), chunk))
	var vert := _mean_motor_range(chunk, mini(map_motor.size(), 2 * chunk))
	var yaw_l := _mean_motor_range(2 * chunk, mini(map_motor.size(), 3 * chunk))
	var pitch := _mean_motor_range(3 * chunk, mini(map_motor.size(), 4 * chunk))
	var yaw_r := _mean_motor_range(4 * chunk, map_motor.size())
	var vals := [
		fwd * 1.5,
		vert * 1.25,
		(yaw_l - yaw_r) * 2.2,
		pitch * 1.2,
		(yaw_l + yaw_r) * 0.2,
	]
	for c in count:
		out[c] = tanh(vals[c] if c < vals.size() else 0.0)
	return out


func _mean_motor_range(start: int, stop: int) -> float:
	if start >= stop:
		return 0.0
	var acc := 0.0
	var n := 0
	for i in range(start, stop):
		var ni: int = map_motor[i]
		if ni < 0 or ni >= n_neurons:
			continue
		acc += v[ni] + 0.35 * (i_syn[ni] if ni < i_syn.size() else 0.0)
		n += 1
	return acc / float(maxi(n, 1))


func load_from_json(path: String) -> Error:
	if path.ends_with(".ffc"):
		return load_from_ffc(path)
	if FileAccess.file_exists("res://data/brains/flywire_fafb_v783.ffc"):
		return load_from_ffc("res://data/brains/flywire_fafb_v783.ffc")
	return ERR_INVALID_DATA


func step_leaky_integrate_driven(drive: PackedFloat32Array, delta: float, _leak: float = 0.5) -> int:
	for i in mini(drive.size(), n_neurons):
		if absf(drive[i]) > 0.00001:
			i_syn[i] += drive[i]
			_activate(i)
	return step_lif_plus(delta)


func step_leaky_integrate(inputs: PackedFloat32Array, delta: float, leak: float = 0.5) -> int:
	return step_leaky_integrate_driven(inputs, delta, leak)


func clear() -> void:
	n_neurons = 0
	n_synapses = 0
	csr_offsets.clear()
	csr_targets.clear()
	csr_weights.clear()
	map_left.clear()
	map_right.clear()
	map_median.clear()
	map_motor.clear()
	provenance.clear()
	_init_state_arrays()
