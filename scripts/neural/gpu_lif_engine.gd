class_name GpuLifEngine
extends RefCounted
## GPU LIF+ for FlyWire connectomes via Vulkan compute.
## Shared CSR on GPU; batched agent state. Sparse synapse from spikes.

const FP := 1024.0
const MAX_EDGES_PER_SPIKE := 48
const CHANNELS := 5

static var instance: GpuLifEngine

var rd: RenderingDevice
var _owns_rd: bool = false
var ready: bool = false
var setup_failed: bool = false
var backend_name: String = "none"

var n_neurons: int = 0
var n_synapses: int = 0
var max_agents: int = 0
var agent_count: int = 0

var map_left: PackedInt32Array = PackedInt32Array()
var map_right: PackedInt32Array = PackedInt32Array()
var map_median: PackedInt32Array = PackedInt32Array()
var map_motor: PackedInt32Array = PackedInt32Array()

var drive_gain: float = 3.0
var syn_scale: float = 0.035
var v_rest: float = 0.0
var v_thresh: float = 0.4
var v_reset: float = 0.0
var tau_mem: float = 0.020
var tau_syn: float = 0.040
var t_ref: float = 0.002

var _v_rid: RID
var _i_rid: RID
var _r_rid: RID
var _s_rid: RID
var _drive_rid: RID
var _off_rid: RID
var _tgt_rid: RID
var _w_rid: RID
var _motor_map_rid: RID
var _motor_out_rid: RID
var _spike_count_rid: RID
var _p_inj: RID
var _p_int: RID
var _p_syn: RID
var _p_mot: RID

var _shader_inject: RID
var _shader_integrate: RID
var _shader_synapse: RID
var _shader_motor: RID
var _pipe_inject: RID
var _pipe_integrate: RID
var _pipe_synapse: RID
var _pipe_motor: RID

var _set_inject: RID
var _set_integrate: RID
var _set_synapse: RID
var _set_motor: RID

var _drive_cpu: PackedInt32Array = PackedInt32Array()
var _last_spikes: PackedInt32Array = PackedInt32Array()
var _motor_cache: Array = []
var _free_slots: PackedInt32Array = PackedInt32Array()
var _slot_used: PackedByteArray = PackedByteArray()


static func get_engine() -> GpuLifEngine:
	if instance == null:
		instance = GpuLifEngine.new()
	return instance


func setup(template: NeuralNetwork, p_max_agents: int) -> bool:
	if ready:
		return true
	shutdown()
	setup_failed = false
	if template == null or template.neuron_count() == 0 or template.csr_offsets.is_empty():
		backend_name = "cpu_fallback"
		setup_failed = true
		return false

	rd = RenderingServer.create_local_rendering_device()
	_owns_rd = rd != null
	if rd == null:
		rd = RenderingServer.get_rendering_device()
		_owns_rd = false
	if rd == null:
		push_warning("GpuLifEngine: RenderingDevice unavailable (GPU needs a display window)")
		backend_name = "cpu_fallback"
		setup_failed = true
		return false

	n_neurons = template.neuron_count()
	n_synapses = template.synapse_count()
	max_agents = maxi(p_max_agents, 1)
	agent_count = 0
	_free_slots = PackedInt32Array()
	_slot_used = PackedByteArray()
	_slot_used.resize(max_agents)
	_slot_used.fill(0)
	map_left = template.map_left
	map_right = template.map_right
	map_median = template.map_median
	map_motor = template.map_motor
	drive_gain = template.drive_gain * 1.25
	syn_scale = template.syn_scale
	v_thresh = template.v_thresh
	tau_mem = template.tau_mem
	tau_syn = template.tau_syn
	t_ref = template.t_ref

	var total := n_neurons * max_agents
	_drive_cpu = PackedInt32Array()
	_drive_cpu.resize(total)
	_drive_cpu.fill(0)
	_last_spikes = PackedInt32Array()
	_last_spikes.resize(max_agents)
	_last_spikes.fill(0)
	_motor_cache.clear()
	for _i in max_agents:
		var m := PackedFloat32Array()
		m.resize(CHANNELS)
		m.fill(0.0)
		_motor_cache.append(m)

	var zf := PackedFloat32Array()
	zf.resize(total)
	zf.fill(0.0)
	var zi := PackedInt32Array()
	zi.resize(total)
	zi.fill(0)

	_v_rid = rd.storage_buffer_create(total * 4, zf.to_byte_array())
	_i_rid = rd.storage_buffer_create(total * 4, zi.to_byte_array())
	_r_rid = rd.storage_buffer_create(total * 4, zf.to_byte_array())
	_s_rid = rd.storage_buffer_create(total * 4, zi.to_byte_array())
	_drive_rid = rd.storage_buffer_create(total * 4, zi.to_byte_array())
	_off_rid = rd.storage_buffer_create(template.csr_offsets.size() * 4, template.csr_offsets.to_byte_array())
	_tgt_rid = rd.storage_buffer_create(n_synapses * 4, template.csr_targets.to_byte_array())
	_w_rid = rd.storage_buffer_create(n_synapses * 4, template.csr_weights.to_byte_array())

	var motor_bytes := map_motor.to_byte_array() if not map_motor.is_empty() else PackedInt32Array([0]).to_byte_array()
	_motor_map_rid = rd.storage_buffer_create(maxi(4, motor_bytes.size()), motor_bytes)
	var mout := PackedFloat32Array()
	mout.resize(max_agents * CHANNELS)
	mout.fill(0.0)
	_motor_out_rid = rd.storage_buffer_create(mout.size() * 4, mout.to_byte_array())
	var sc := PackedInt32Array()
	sc.resize(max_agents)
	sc.fill(0)
	_spike_count_rid = rd.storage_buffer_create(max_agents * 4, sc.to_byte_array())

	_p_inj = rd.storage_buffer_create(16)
	_p_int = rd.storage_buffer_create(40)
	_p_syn = rd.storage_buffer_create(16)
	_p_mot = rd.storage_buffer_create(16)

	if not _build_pipelines():
		shutdown()
		backend_name = "cpu_fallback"
		setup_failed = true
		return false

	_set_inject = _make_set(_shader_inject, [_i_rid, _drive_rid, _p_inj])
	_set_integrate = _make_set(_shader_integrate, [_v_rid, _i_rid, _r_rid, _s_rid, _p_int])
	_set_synapse = _make_set(_shader_synapse, [_i_rid, _s_rid, _off_rid, _tgt_rid, _w_rid, _p_syn])
	_set_motor = _make_set(_shader_motor, [_v_rid, _motor_map_rid, _motor_out_rid, _spike_count_rid, _s_rid, _p_mot])
	if not (
		_set_inject.is_valid()
		and _set_integrate.is_valid()
		and _set_synapse.is_valid()
		and _set_motor.is_valid()
	):
		shutdown()
		backend_name = "cpu_fallback"
		setup_failed = true
		return false

	ready = true
	backend_name = "gpu_vulkan"
	print(
		"GpuLifEngine READY: neurons=%d synapses=%d max_agents=%d owns_rd=%s"
		% [n_neurons, n_synapses, max_agents, str(_owns_rd)]
	)
	return true


func _make_set(shader: RID, buffer_rids: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in buffer_rids.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = i
		u.add_id(buffer_rids[i])
		uniforms.append(u)
	return rd.uniform_set_create(uniforms, shader, 0)


func _build_pipelines() -> bool:
	_shader_inject = _load_shader("res://shaders/lif_inject.glsl")
	_shader_integrate = _load_shader("res://shaders/lif_integrate.glsl")
	_shader_synapse = _load_shader("res://shaders/lif_synapse.glsl")
	_shader_motor = _load_shader("res://shaders/lif_motor.glsl")
	if not (
		_shader_inject.is_valid()
		and _shader_integrate.is_valid()
		and _shader_synapse.is_valid()
		and _shader_motor.is_valid()
	):
		return false
	_pipe_inject = rd.compute_pipeline_create(_shader_inject)
	_pipe_integrate = rd.compute_pipeline_create(_shader_integrate)
	_pipe_synapse = rd.compute_pipeline_create(_shader_synapse)
	_pipe_motor = rd.compute_pipeline_create(_shader_motor)
	return (
		_pipe_inject.is_valid()
		and _pipe_integrate.is_valid()
		and _pipe_synapse.is_valid()
		and _pipe_motor.is_valid()
	)


func _load_shader(path: String) -> RID:
	var shader_file := load(path) as RDShaderFile
	if shader_file == null:
		push_error("GpuLifEngine: load failed %s" % path)
		return RID()
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	var cerr: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if cerr != "":
		push_error("GpuLifEngine SPIR-V error (%s): %s" % [path, cerr])
		return RID()
	return rd.shader_create_from_spirv(spirv)


func allocate_slot() -> int:
	if not ready:
		return -1
	var slot := -1
	if not _free_slots.is_empty():
		slot = _free_slots[_free_slots.size() - 1]
		_free_slots.resize(_free_slots.size() - 1)
	elif agent_count < max_agents:
		slot = agent_count
		agent_count += 1
	else:
		return -1
	_slot_used[slot] = 1
	# Clear drives for recycled slot.
	var base := slot * n_neurons
	for i in n_neurons:
		_drive_cpu[base + i] = 0
	return slot


func release_slot(slot: int) -> void:
	if not ready or slot < 0 or slot >= max_agents:
		return
	if _slot_used[slot] == 0:
		return
	_slot_used[slot] = 0
	_free_slots.append(slot)
	_last_spikes[slot] = 0
	if slot < _motor_cache.size():
		var m: PackedFloat32Array = _motor_cache[slot]
		m.fill(0.0)
		_motor_cache[slot] = m


func inject_eye(slot: int, left: float, right: float, median: float) -> void:
	# Legacy combined drive — prefer inject_range via SensoryMapping.
	if not ready or slot < 0 or slot >= max_agents or _slot_used[slot] == 0:
		return
	var base := slot * n_neurons
	_inject_map(base, map_left, left)
	_inject_map(base, map_right, right)
	_inject_map(base, map_median, median)


func inject_range(slot: int, ids: PackedInt32Array, offset: int, count: int, amp_in: float) -> void:
	if not ready or slot < 0 or slot >= max_agents or _slot_used[slot] == 0:
		return
	if ids.is_empty() or absf(amp_in) < 0.00001:
		return
	var base := slot * n_neurons
	var amp := amp_in * drive_gain
	var n := mini(count, maxi(0, ids.size() - offset))
	for i in n:
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= n_neurons:
			continue
		_drive_cpu[base + ni] += int(amp * FP)


## Retinotopic injection: one weight per map cell starting at offset.
func inject_weights(slot: int, ids: PackedInt32Array, offset: int, weights: PackedFloat32Array, gain: float) -> void:
	if not ready or slot < 0 or slot >= max_agents or _slot_used[slot] == 0:
		return
	if ids.is_empty() or weights.is_empty() or absf(gain) < 0.00001:
		return
	var base := slot * n_neurons
	var scale := gain * drive_gain
	var n := mini(weights.size(), maxi(0, ids.size() - offset))
	for i in n:
		var w: float = weights[i] * scale
		if absf(w) < 0.00001:
			continue
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= n_neurons:
			continue
		_drive_cpu[base + ni] += int(w * FP)


func _inject_map(base: int, ids: PackedInt32Array, amp_in: float) -> void:
	inject_range_at_base(base, ids, 0, 24, amp_in)


func inject_range_at_base(base: int, ids: PackedInt32Array, offset: int, count: int, amp_in: float) -> void:
	if ids.is_empty() or absf(amp_in) < 0.00001:
		return
	var amp := amp_in * drive_gain
	var n := mini(count, maxi(0, ids.size() - offset))
	for i in n:
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= n_neurons:
			continue
		_drive_cpu[base + ni] += int(amp * FP)


func step(dt: float) -> void:
	if not ready or agent_count <= 0:
		return
	# Dispatch over allocated high-water mark (includes freed holes; cheap vs realloc).
	var live_agents := agent_count
	var total: int = n_neurons * live_agents
	rd.buffer_update(_drive_rid, 0, _drive_cpu.size() * 4, _drive_cpu.to_byte_array())

	var inj := PackedByteArray()
	inj.resize(16)
	inj.encode_u32(0, n_neurons)
	inj.encode_u32(4, live_agents)
	rd.buffer_update(_p_inj, 0, inj.size(), inj)

	var inv_tau := 1.0 / maxf(tau_mem, 0.0001)
	var syn_decay := exp(-dt / maxf(tau_syn, 0.0001))
	var ip := PackedByteArray()
	ip.resize(40)
	ip.encode_float(0, dt)
	ip.encode_float(4, inv_tau)
	ip.encode_float(8, syn_decay)
	ip.encode_float(12, v_rest)
	ip.encode_float(16, v_thresh)
	ip.encode_float(20, v_reset)
	ip.encode_float(24, t_ref)
	ip.encode_u32(28, n_neurons)
	ip.encode_u32(32, live_agents)
	ip.encode_u32(36, 0)
	rd.buffer_update(_p_int, 0, ip.size(), ip)

	var sp := PackedByteArray()
	sp.resize(16)
	sp.encode_float(0, syn_scale)
	sp.encode_u32(4, n_neurons)
	sp.encode_u32(8, live_agents)
	sp.encode_u32(12, MAX_EDGES_PER_SPIKE)
	rd.buffer_update(_p_syn, 0, sp.size(), sp)

	var mp := PackedByteArray()
	mp.resize(16)
	mp.encode_u32(0, n_neurons)
	mp.encode_u32(4, live_agents)
	mp.encode_u32(8, maxi(map_motor.size(), 1))
	mp.encode_u32(12, CHANNELS)
	rd.buffer_update(_p_mot, 0, mp.size(), mp)

	_dispatch(_pipe_inject, _set_inject, total, 256)
	_dispatch(_pipe_integrate, _set_integrate, total, 256)
	_dispatch(_pipe_synapse, _set_synapse, total, 256)
	_dispatch(_pipe_motor, _set_motor, live_agents, 64)

	rd.submit()
	rd.sync()

	_download_outputs(live_agents)
	_drive_cpu.fill(0)


func _dispatch(pipeline: RID, set_rid: RID, count: int, local_x: int) -> void:
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set_rid, 0)
	rd.compute_list_dispatch(cl, int(ceil(float(maxi(count, 1)) / float(local_x))), 1, 1)
	rd.compute_list_end()


func _download_outputs(live_agents: int) -> void:
	var motor_bytes := rd.buffer_get_data(_motor_out_rid, 0, live_agents * CHANNELS * 4)
	var spike_bytes := rd.buffer_get_data(_spike_count_rid, 0, live_agents * 4)
	for a in live_agents:
		_last_spikes[a] = int(spike_bytes.decode_u32(a * 4))
		var out: PackedFloat32Array = _motor_cache[a]
		for c in CHANNELS:
			out[c] = motor_bytes.decode_float((a * CHANNELS + c) * 4)
		_motor_cache[a] = out


func get_motor(slot: int) -> PackedFloat32Array:
	if slot < 0 or slot >= _motor_cache.size():
		var empty := PackedFloat32Array()
		empty.resize(CHANNELS)
		return empty
	return _motor_cache[slot]


func get_spikes(slot: int) -> int:
	if slot < 0 or slot >= _last_spikes.size():
		return 0
	return _last_spikes[slot]


## Sample synaptic drive for live brain viz (selected agent only).
## |V| stays near 0 (v_rest=0 + reset); i_syn reflects recent eye injection.
func sample_activity(slot: int, heat_w: int = 72, heat_h: int = 56) -> Dictionary:
	var empty := {
		"act_left": 0.0,
		"act_right": 0.0,
		"act_median": 0.0,
		"act_motor": 0.0,
		"spikes": 0,
		"neurons": n_neurons,
		"synapses": n_synapses,
		"heat": PackedByteArray(),
		"backend": backend_name,
	}
	if not ready or rd == null or slot < 0 or slot >= max_agents or _slot_used[slot] == 0:
		return empty
	var base := slot * n_neurons
	var i_bytes := rd.buffer_get_data(_i_rid, base * 4, n_neurons * 4)
	var v_bytes := rd.buffer_get_data(_v_rid, base * 4, mini(n_neurons, heat_w * heat_h * 8) * 4)
	var s_bytes := rd.buffer_get_data(_s_rid, base * 4, mini(n_neurons, 4096) * 4)

	var act_l := _mean_isyn_map(i_bytes, map_left)
	var act_r := _mean_isyn_map(i_bytes, map_right)
	var act_m := _mean_isyn_map(i_bytes, map_median)
	var act_mot := _mean_isyn_map(i_bytes, map_motor)

	var heat := PackedByteArray()
	heat.resize(heat_w * heat_h * 4)
	var cells := heat_w * heat_h
	var stride := maxi(1, int(floor(float(n_neurons) / float(cells))))
	for i in cells:
		var ni := mini(n_neurons - 1, i * stride)
		var isyn := 0.0
		if ni * 4 + 4 <= i_bytes.size():
			isyn = absf(float(i_bytes.decode_s32(ni * 4)) / FP)
		var vv := 0.0
		if ni * 4 + 4 <= v_bytes.size():
			vv = absf(v_bytes.decode_float(ni * 4))
		var spiked := 0.0
		if ni < 4096 and ni * 4 + 4 <= s_bytes.size():
			spiked = 1.0 if s_bytes.decode_u32(ni * 4) != 0 else 0.0
		var t := clampf(isyn * 0.35 + vv * 1.2 + spiked * 0.55, 0.0, 1.0)
		var o := i * 4
		heat[o] = int(clampf(40.0 + t * 200.0, 0, 255))
		heat[o + 1] = int(clampf(30.0 + t * 120.0, 0, 255))
		heat[o + 2] = int(clampf(60.0 + (1.0 - t) * 80.0 + spiked * 120.0, 0, 255))
		heat[o + 3] = 255

	return {
		"act_left": act_l,
		"act_right": act_r,
		"act_median": act_m,
		"act_motor": act_mot,
		"spikes": get_spikes(slot),
		"neurons": n_neurons,
		"synapses": n_synapses,
		"heat": heat,
		"backend": backend_name,
	}


func _mean_isyn_map(i_bytes: PackedByteArray, ids: PackedInt32Array) -> float:
	if ids.is_empty():
		return 0.0
	# Cover full ME layout (ON/OFF/HS/VS/expand/mate).
	var n := mini(128, ids.size())
	var peak := 0.0
	var acc := 0.0
	var used := 0
	for i in n:
		var ni: int = ids[i]
		if ni < 0 or ni * 4 + 4 > i_bytes.size():
			continue
		var a := absf(float(i_bytes.decode_s32(ni * 4)) / FP)
		acc += a
		peak = maxf(peak, a)
		used += 1
	if used == 0:
		return 0.0
	# Peak dominates so sparse injection still shows; /6 ≈ full sensory drive scale.
	return clampf(peak / 6.0 + (acc / float(used)) / 12.0, 0.0, 1.5)


func shutdown() -> void:
	ready = false
	agent_count = 0
	_free_slots.clear()
	_slot_used.clear()
	if rd == null:
		return
	for rid in [
		_set_inject, _set_integrate, _set_synapse, _set_motor,
		_v_rid, _i_rid, _r_rid, _s_rid, _drive_rid, _off_rid, _tgt_rid, _w_rid,
		_motor_map_rid, _motor_out_rid, _spike_count_rid,
		_p_inj, _p_int, _p_syn, _p_mot,
		_pipe_inject, _pipe_integrate, _pipe_synapse, _pipe_motor,
		_shader_inject, _shader_integrate, _shader_synapse, _shader_motor
	]:
		if rid.is_valid():
			rd.free_rid(rid)
	_set_inject = RID()
	_set_integrate = RID()
	_set_synapse = RID()
	_set_motor = RID()
	if _owns_rd:
		rd.free()
	rd = null
	_owns_rd = false
