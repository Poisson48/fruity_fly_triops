class_name Egg
extends RefCounted
## V3: dormant egg that hatches into a Triops with inherited genome.

var position: Vector3 = Vector3.ZERO
var genome: BrainGenome
var hatch_in: float = 0.0
var energy: float = 0.7
var parent_a: int = -1
var parent_b: int = -1
var generation: int = 0
