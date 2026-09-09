class_name ConnectomeCache
extends Object
## Shared FFC topology cache (CSR shared; each brain clones membrane state).

static var _cache: Dictionary = {}


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


static func clear() -> void:
	_cache.clear()
