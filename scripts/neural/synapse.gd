class_name Synapse
extends RefCounted
## Compact synapse / connection for future connectome loading.

var source: int = 0
var target: int = 0
var weight: float = 0.0
var delay: float = 0.0
var synapse_type: String = ""
var metadata: Dictionary = {}
