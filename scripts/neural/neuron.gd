class_name Neuron
extends RefCounted
## Compact neuron descriptor for future connectome loading.
## V0: data container only — not used as a Godot Node.

var id: int = 0
var cell_type: String = ""
## Optional biophysical placeholders (unused in V0).
var resting_potential: float = 0.0
var threshold: float = 1.0
var membrane_potential: float = 0.0
var metadata: Dictionary = {}
