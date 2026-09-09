class_name GpuLifEngine
extends RefCounted
## GPU LIF+ for FlyWire connectomes via Vulkan compute.
## Shared CSR on GPU; batched agent state. Sparse synapse from spikes.

const FP := 1024.0
const MAX_EDGES_PER_SPIKE := 48
const CHANNELS := 5
## If more than this many drive cells dirty, wipe the live bank instead.
const DIRTY_WIPE_THRESHOLD := 8192

static var instance: GpuLifEngine
static var _warned_no_rd: bool = false

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

## Drive stored as bytes to avoid PackedInt32Array.to_byte_array() alloc each step.
var _drive_bytes: PackedByteArray = PackedByteArray()
var _dirty: PackedInt32Array = PackedInt32Array()
var _last_spikes: PackedInt32Array = PackedInt32Array()
var _motor_cache: Array = []
var _free_slots: PackedInt32Array = PackedInt32Array()
var _slot_used: PackedByteArray = PackedByteArray()
## CPU-side map activity from last inject (avoids full i_syn GPU readback for viz).
var _viz_left: PackedFloat32Array = PackedFloat32Array()
var _viz_right: PackedFloat32Array = PackedFloat32Array()
var _viz_median: PackedFloat32Array = PackedFloat32Array()
var _viz_motor: PackedFloat32Array = PackedFloat32Array()

var _param_inj: PackedByteArray = PackedByteArray()
var _param_int: PackedByteArray = PackedByteArray()
var _param_syn: PackedByteArray = PackedByteArray()
var _param_mot: PackedByteArray = PackedByteArray()


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
		if not _warned_no_rd:
			_warned_no_rd = true
			push_warning("GpuLifEngine: RenderingDevice unavailable — CPU LIF fallback (use tools/run_tests.sh / Xvfb for GPU)")
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
	drive_gain = template.drive_gain * 1.55
	syn_scale = template.syn_scale
	v_thresh = template.v_thresh
	tau_mem = template.tau_mem
	tau_syn = template.tau_syn
	t_ref = template.t_ref

	var total := n_neurons * max_agents
	_drive_bytes = PackedByteArray()
	_drive_bytes.resize(total * 4)
	_drive_bytes.fill(0)
	_dirty = PackedInt32Array()
	_last_spikes = PackedInt32Array()
	_last_spikes.resize(max_agents)
	_last_spikes.fill(0)
	_viz_left.resize(max_agents)
	_viz_right.resize(max_agents)
	_viz_median.resize(max_agents)
	_viz_motor.resize(max_agents)
	_viz_left.fill(0.0)
	_viz_right.fill(0.0)
	_viz_median.fill(0.0)
	_viz_motor.fill(0.0)
	_motor_cache.clear()
	for _i in max_agents:
		var m := PackedFloat32Array()
		m.resize(CHANNELS)
		m.fill(0.0)
		_motor_cache.append(m)

	_param_inj.resize(16)
	_param_int.resize(40)
	_param_syn.resize(16)
	_param_mot.resize(16)

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
	_drive_rid = rd.storage_buffer_create(total * 4, _drive_bytes)
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
	_set_motor = _make_set(
		_shader_motor,
		[_v_rid, _motor_map_rid, _motor_out_rid, _spike_count_rid, _s_rid, _i_rid, _p_mot]
	)
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
	var recycled := false
	if not _free_slots.is_empty():
		slot = _free_slots[_free_slots.size() - 1]
		_free_slots.resize(_free_slots.size() - 1)
		recycled = true
	elif agent_count < max_agents:
		slot = agent_count
		agent_count += 1
	else:
		return -1
	_slot_used[slot] = 1
	# Fresh high-water slots are already zero from setup; only wipe recycled ones.
	if recycled:
		_clear_slot_drive(slot)
	if slot < _viz_left.size():
		_viz_left[slot] = 0.0
		_viz_right[slot] = 0.0
		_viz_median[slot] = 0.0
		_viz_motor[slot] = 0.0
	return slot


func _clear_slot_drive(slot: int) -> void:
	# Spawn/recycle only — wipe via int view on a scratch then patch is costly;
	# zeroing s32 cells in a tight loop is acceptable at birth rate.
	var base := slot * n_neurons
	var end := base + n_neurons
	for flat in range(base, end):
		_drive_bytes.encode_s32(flat * 4, 0)


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
	var add_fp := int(amp * FP)
	if add_fp == 0:
		return
	for i in n:
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= n_neurons:
			continue
		_add_drive(base + ni, add_fp)


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
		_add_drive(base + ni, int(w * FP))


func _inject_map(base: int, ids: PackedInt32Array, amp_in: float) -> void:
	inject_range_at_base(base, ids, 0, 24, amp_in)


func inject_range_at_base(base: int, ids: PackedInt32Array, offset: int, count: int, amp_in: float) -> void:
	if ids.is_empty() or absf(amp_in) < 0.00001:
		return
	var amp := amp_in * drive_gain
	var n := mini(count, maxi(0, ids.size() - offset))
	var add_fp := int(amp * FP)
	if add_fp == 0:
		return
	for i in n:
		var ni: int = ids[offset + i]
		if ni < 0 or ni >= n_neurons:
			continue
		_add_drive(base + ni, add_fp)


func _add_drive(flat_idx: int, add_fp: int) -> void:
	var off := flat_idx * 4
	var cur := _drive_bytes.decode_s32(off)
	_drive_bytes.encode_s32(off, cur + add_fp)
	_dirty.append(flat_idx)


func step(dt: float) -> void:
	if not ready or agent_count <= 0:
		return
	# Dispatch over allocated high-water mark (includes freed holes; cheap vs realloc).
	var live_agents := agent_count
	var total: int = n_neurons * live_agents
	var upload_bytes := total * 4
	# Upload only the live high-water region (was: entire max_agents bank).
	rd.buffer_update(_drive_rid, 0, upload_bytes, _drive_bytes)

	_param_inj.encode_u32(0, n_neurons)
	_param_inj.encode_u32(4, live_agents)
	rd.buffer_update(_p_inj, 0, 16, _param_inj)

	var inv_tau := 1.0 / maxf(tau_mem, 0.0001)
	var syn_decay := exp(-dt / maxf(tau_syn, 0.0001))
	_param_int.encode_float(0, dt)
	_param_int.encode_float(4, inv_tau)
	_param_int.encode_float(8, syn_decay)
	_param_int.encode_float(12, v_rest)
	_param_int.encode_float(16, v_thresh)
	_param_int.encode_float(20, v_reset)
	_param_int.encode_float(24, t_ref)
	_param_int.encode_u32(28, n_neurons)
	_param_int.encode_u32(32, live_agents)
	_param_int.encode_u32(36, 0)
	rd.buffer_update(_p_int, 0, 40, _param_int)

	_param_syn.encode_float(0, syn_scale)
	_param_syn.encode_u32(4, n_neurons)
	_param_syn.encode_u32(8, live_agents)
	_param_syn.encode_u32(12, MAX_EDGES_PER_SPIKE)
	rd.buffer_update(_p_syn, 0, 16, _param_syn)

	_param_mot.encode_u32(0, n_neurons)
	_param_mot.encode_u32(4, live_agents)
	_param_mot.encode_u32(8, maxi(map_motor.size(), 1))
	_param_mot.encode_u32(12, CHANNELS)
	rd.buffer_update(_p_mot, 0, 16, _param_mot)

	_cache_viz_from_drive(live_agents)

	_dispatch(_pipe_inject, _set_inject, total, 256)
	_dispatch(_pipe_integrate, _set_integrate, total, 256)
	_dispatch(_pipe_synapse, _set_synapse, total, 256)
	_dispatch(_pipe_motor, _set_motor, live_agents, 64)

	rd.submit()
	rd.sync()

	_download_outputs(live_agents)
	_clear_drive_dirty(live_agents)


func _cache_viz_from_drive(live_agents: int) -> void:
	## Peak |drive| on ME/LOP/motor maps — no GPU readback needed for HUD bars.
	for a in live_agents:
		if a >= max_agents or _slot_used[a] == 0:
			continue
		var base := a * n_neurons
		_viz_left[a] = _peak_drive_map(base, map_left)
		_viz_right[a] = _peak_drive_map(base, map_right)
		_viz_median[a] = _peak_drive_map(base, map_median)
		_viz_motor[a] = _peak_drive_map(base, map_motor)


func _peak_drive_map(base: int, ids: PackedInt32Array) -> float:
	if ids.is_empty():
		return 0.0
	var n := mini(128, ids.size())
	var peak := 0.0
	var acc := 0.0
	var used := 0
	for i in n:
		var ni: int = ids[i]
		if ni < 0 or ni >= n_neurons:
			continue
		var a := absf(float(_drive_bytes.decode_s32((base + ni) * 4)) / FP)
		acc += a
		peak = maxf(peak, a)
		used += 1
	if used == 0:
		return 0.0
	return clampf(peak / 6.0 + (acc / float(used)) / 12.0, 0.0, 1.5)


func _clear_drive_dirty(_live_agents: int) -> void:
	if _dirty.size() > DIRTY_WIPE_THRESHOLD:
		# Full memset is cheaper than millions of encode_s32 calls.
		_drive_bytes.fill(0)
		_dirty.clear()
		return
	for i in _dirty.size():
		var idx: int = _dirty[i]
		if idx < 0 or idx * 4 + 4 > _drive_bytes.size():
			continue
		_drive_bytes.encode_s32(idx * 4, 0)
	_dirty.clear()


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


## Sample activity for live brain viz (selected agent only) — no full-buffer readback.
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
	if not ready or slot < 0 or slot >= max_agents or _slot_used[slot] == 0:
		return empty

	var act_l := _viz_left[slot] if slot < _viz_left.size() else 0.0
	var act_r := _viz_right[slot] if slot < _viz_right.size() else 0.0
	var act_m := _viz_median[slot] if slot < _viz_median.size() else 0.0
	var act_mot := _viz_motor[slot] if slot < _viz_motor.size() else 0.0

	# Cheap procedural heat from map peaks + spikes (heatmap unused by drawer today).
	var heat := PackedByteArray()
	heat.resize(heat_w * heat_h * 4)
	var cells := heat_w * heat_h
	var pulse := clampf((act_l + act_r + act_m) * 0.45 + act_mot * 0.3, 0.0, 1.0)
	var spike_boost := 1.0 if get_spikes(slot) > 0 else 0.0
	for i in cells:
		var t := clampf(pulse * (0.55 + 0.45 * float((i * 17) % 10) / 10.0) + spike_boost * 0.2, 0.0, 1.0)
		var o := i * 4
		heat[o] = int(clampf(40.0 + t * 200.0, 0, 255))
		heat[o + 1] = int(clampf(30.0 + t * 120.0, 0, 255))
		heat[o + 2] = int(clampf(60.0 + (1.0 - t) * 80.0 + spike_boost * 80.0, 0, 255))
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


func shutdown() -> void:
	ready = false
	agent_count = 0
	_free_slots.clear()
	_slot_used.clear()
	_dirty.clear()
	_drive_bytes.clear()
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
