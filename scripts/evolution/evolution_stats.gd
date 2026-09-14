class_name EvolutionStats
extends RefCounted
## V6: population / selection telemetry.

var births: int = 0
var deaths: int = 0
var eggs_laid: int = 0
var meals: int = 0
var max_generation: int = 0
var death_ages_days: PackedFloat32Array = PackedFloat32Array()

## Throttled population trait means (updated by SimulationWorld).
var mean_sense_food: float = 0.0
var mean_sense_wall: float = 0.0
var mean_motor_yaw: float = 0.0
var mean_depth_pref: float = 0.0
var mean_body_scale: float = 0.0
var mean_energy_drain: float = 0.0
var mean_syn_scale: float = 0.0
var mean_drive_gain: float = 0.0
var mean_generation: float = 0.0
var plastic_agents: int = 0
var sample_count: int = 0


func record_death(age_days: float) -> void:
	deaths += 1
	death_ages_days.append(age_days)
	if death_ages_days.size() > 200:
		death_ages_days = death_ages_days.slice(death_ages_days.size() - 200)


func avg_death_age_days() -> float:
	if death_ages_days.is_empty():
		return 0.0
	var s := 0.0
	for v in death_ages_days:
		s += v
	return s / float(death_ages_days.size())


func sample_population(agents: Array) -> void:
	var n := 0
	var s_food := 0.0
	var s_wall := 0.0
	var s_yaw := 0.0
	var s_depth := 0.0
	var s_body := 0.0
	var s_drain := 0.0
	var s_syn := 0.0
	var s_drive := 0.0
	var s_gen := 0.0
	var plastic := 0
	for a in agents:
		if a == null or not a.alive or a.genome == null:
			continue
		var g: BrainGenome = a.genome
		n += 1
		if g.sense_gains.size() > 0:
			s_food += g.sense_gains[0]
		if g.sense_gains.size() > 1:
			s_wall += g.sense_gains[1]
		if g.motor_gains.size() > MotorInterface.CHANNEL_YAW:
			s_yaw += g.motor_gains[MotorInterface.CHANNEL_YAW]
		s_depth += g.depth_pref
		s_body += g.body_scale
		s_drain += g.energy_drain_mult
		s_syn += g.syn_scale_gene
		s_drive += g.drive_gain_gene
		s_gen += float(g.generation)
		if g.has_plastic_synapses():
			plastic += 1
	sample_count = n
	plastic_agents = plastic
	if n == 0:
		return
	var inv := 1.0 / float(n)
	mean_sense_food = s_food * inv
	mean_sense_wall = s_wall * inv
	mean_motor_yaw = s_yaw * inv
	mean_depth_pref = s_depth * inv
	mean_body_scale = s_body * inv
	mean_energy_drain = s_drain * inv
	mean_syn_scale = s_syn * inv
	mean_drive_gain = s_drive * inv
	mean_generation = s_gen * inv


func as_dict() -> Dictionary:
	return {
		"births": births,
		"deaths": deaths,
		"eggs_laid": eggs_laid,
		"meals": meals,
		"max_generation": max_generation,
		"avg_death_age_days": avg_death_age_days(),
		"mean_sense_food": mean_sense_food,
		"mean_sense_wall": mean_sense_wall,
		"mean_motor_yaw": mean_motor_yaw,
		"mean_depth_pref": mean_depth_pref,
		"mean_body_scale": mean_body_scale,
		"mean_energy_drain": mean_energy_drain,
		"mean_syn_scale": mean_syn_scale,
		"mean_drive_gain": mean_drive_gain,
		"mean_generation": mean_generation,
		"plastic_agents": plastic_agents,
		"sample_count": sample_count,
	}
