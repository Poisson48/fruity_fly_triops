class_name TestBrain
extends Brain
## Technical placeholder brain — NOT Drosophila.
## Maps flat sensory vector → motor channels via a heritable linear genome (V4).
## No explicit "if food then chase" rules.

const OUTPUT_COUNT := MotorInterface.CHANNEL_COUNT
## 3 eyes × 3 channels
const INPUT_COUNT := 9

var genome: BrainGenome = BrainGenome.new()
var _outputs: PackedFloat32Array = PackedFloat32Array()
var _phase: float = 0.0
var _spike_count: int = 0
var _step_count: int = 0


func initialize(_config: SimulationConfig, rng: RandomNumberGenerator, genome_in: BrainGenome = null) -> void:
	_outputs = PackedFloat32Array()
	_outputs.resize(OUTPUT_COUNT)
	if genome_in != null:
		genome = genome_in.duplicate_genome()
	else:
		genome = BrainGenome.new()
		genome.setup(INPUT_COUNT, OUTPUT_COUNT)
		genome.randomize_genes(rng)
	if genome.input_count != INPUT_COUNT or genome.output_count != OUTPUT_COUNT:
		genome.setup(INPUT_COUNT, OUTPUT_COUNT)
		genome.randomize_genes(rng)
	_phase = rng.randf_range(0.0, TAU)
	_spike_count = 0
	_step_count = 0


func step(inputs: SensoryPacket, delta: float) -> PackedFloat32Array:
	_step_count += 1
	_phase += genome.phase_rate * delta
	var flat := inputs.as_flat()
	# Pad / trim to expected input size.
	var x := PackedFloat32Array()
	x.resize(INPUT_COUNT)
	for i in INPUT_COUNT:
		x[i] = flat[i] if i < flat.size() else 0.0

	for o in OUTPUT_COUNT:
		var sum: float = genome.bias[o]
		var row := o * INPUT_COUNT
		for i in INPUT_COUNT:
			sum += genome.weights[row + i] * x[i]
		# Mild intrinsic drive so agents move even with near-zero weights.
		sum += 0.15 * sin(_phase + float(o))
		var gain: float = genome.motor_gains[o] if o < genome.motor_gains.size() else 1.0
		_outputs[o] = clampf(tanh(sum) * gain, -1.0, 1.0)

	var activity := 0.0
	for v in _outputs:
		activity += absf(v)
	_spike_count = int(activity * 10.0)
	return _outputs


func get_outputs() -> PackedFloat32Array:
	return _outputs


func reset() -> void:
	for i in _outputs.size():
		_outputs[i] = 0.0
	_spike_count = 0
	_step_count = 0


func get_genome() -> BrainGenome:
	return genome


func get_debug_info() -> Dictionary:
	return {
		"name": "TestBrain",
		"spike_count": _spike_count,
		"neuron_count": 0,
		"step_count": _step_count,
		"generation": genome.generation,
		"note": "heritable placeholder — not Drosophila",
	}
