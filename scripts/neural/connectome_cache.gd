class_name ConnectomeCache
extends Object
## Shared FFC topology cache (CSR shared; each brain clones membrane state).

static var _cache: Dictionary = {}
static var _motor_synapse_ids: Dictionary = {}


static func get_template(path: String) -> NeuralNetwork:
	if _cache.has(path):
		return _cache[path]
	var net := NeuralNetwork.new()
	var err := OK
	if path.ends_with(".ffc"):
		err = net.load_from_ffc(path)
	else:
		err = net.load_from_json(path)
	if err != OK:
		push_error("ConnectomeCache: failed %s (%s)" % [path, error_string(err)])
		return net
	_cache[path] = net
	print(
		"ConnectomeCache: %s neurons=%d synapses=%d L=%d R=%d M=%d motor=%d"
		% [
			path,
			net.neuron_count(),
			net.synapse_count(),
			net.map_left.size(),
			net.map_right.size(),
			net.map_median.size(),
			net.map_motor.size(),
		]
	)
	return net


static func get_motor_synapse_loci(path: String, k: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	## Stable shared SEZ/motor CSR indices for sparse connectome evolution.
	var key := "%s#%d" % [path, k]
	if _motor_synapse_ids.has(key):
		return _motor_synapse_ids[key]
	var template := get_template(path)
	var ids := template.sample_motor_synapse_ids(k, rng)
	_motor_synapse_ids[key] = ids
	return ids


static func clear() -> void:
	_cache.clear()
	_motor_synapse_ids.clear()
