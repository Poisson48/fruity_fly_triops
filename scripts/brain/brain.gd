class_name Brain
extends RefCounted
## Abstract brain interface.
## Swap TestBrain for a connectome-driven DrosophilaBrain later.
## Never invent biological Drosophila data here.

func initialize(_config: SimulationConfig, _rng: RandomNumberGenerator, _genome: BrainGenome = null) -> void:
	pass


## Advance brain by one simulation step.
func step(_inputs: SensoryPacket, _delta: float) -> PackedFloat32Array:
	return PackedFloat32Array()


func get_outputs() -> PackedFloat32Array:
	return PackedFloat32Array()


func reset() -> void:
	pass


func get_genome() -> BrainGenome:
	return null


func get_debug_info() -> Dictionary:
	return {
		"name": "Brain",
		"spike_count": 0,
		"neuron_count": 0,
	}
