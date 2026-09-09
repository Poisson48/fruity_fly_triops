class_name EvolutionStats
extends RefCounted
## V6: population / selection telemetry.

var births: int = 0
var deaths: int = 0
var eggs_laid: int = 0
var meals: int = 0
var max_generation: int = 0
var death_ages_days: PackedFloat32Array = PackedFloat32Array()


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


func as_dict() -> Dictionary:
	return {
		"births": births,
		"deaths": deaths,
		"eggs_laid": eggs_laid,
		"meals": meals,
		"max_generation": max_generation,
		"avg_death_age_days": avg_death_age_days(),
	}
