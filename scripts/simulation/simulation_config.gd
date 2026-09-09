class_name SimulationConfig
extends Resource
## Global simulation parameters. Keep deterministic when seed is fixed.

@export var seed: int = 12345
@export var triops_count: int = 30
@export var max_triops: int = 120

## Aquarium half-extents (full box = 2 * extents).
@export var aquarium_half_extents: Vector3 = Vector3(20.0, 10.0, 20.0)

## Fixed simulation timestep (seconds). Graphics may run at a different rate.
@export var simulation_dt: float = 1.0 / 60.0

## How many simulation seconds equal one in-world day.
@export var seconds_per_sim_day: float = 45.0

## Physics / locomotion (Triops body).
@export var max_speed: float = 4.0
@export var linear_accel: float = 8.0
@export var linear_drag: float = 1.5
@export var angular_accel: float = 3.4
@export var angular_drag: float = 1.7
@export var wall_bounce: float = 0.4
@export var wall_margin: float = 0.3

## Sensor ranges.
@export var eye_ray_length: float = 10.0
@export var food_sense_radius: float = 8.0
@export var mate_sense_radius: float = 5.0

## Brain backend: "test" or "drosophila".
@export var brain_type: String = "drosophila"
## Path to connectome (.ffc binary preferred).
@export var connectome_path: String = "res://data/brains/flywire_fafb_v783.ffc"

## V1 — Food (defaults tuned for survival / evolution)
@export var food_count: int = 140
@export var food_energy: float = 0.55
@export var eat_radius: float = 0.9
@export var food_respawn_seconds: float = 3.5

## V2 — Life
@export var initial_energy: float = 1.2
@export var energy_drain_per_second: float = 0.010
@export var swim_energy_cost: float = 0.003
@export var starvation_health_drain: float = 0.06
@export var max_lifespan_days: float = 35.0
@export var mature_age_days: float = 2.0
@export var min_scale: float = 0.55
@export var max_scale: float = 1.35

## V3 — Reproduction
@export var mating_distance: float = 2.2
@export var mating_energy_cost: float = 0.18
@export var mating_energy_min: float = 0.35
@export var mating_cooldown_seconds: float = 8.0
@export var egg_hatch_seconds: float = 4.0
@export var egg_energy: float = 0.9

## V4 / V6 — Genetics & evolution
@export var mutation_rate: float = 0.12
@export var mutation_scale: float = 0.18
@export var crossover_enabled: bool = true


func apply_preset_easy() -> void:
	triops_count = 12
	max_triops = 40
	food_count = 180
	food_energy = 0.75
	food_respawn_seconds = 2.0
	eat_radius = 1.6
	energy_drain_per_second = 0.012
	swim_energy_cost = 0.002
	starvation_health_drain = 0.03
	initial_energy = 0.85
	max_lifespan_days = 50.0
	mature_age_days = 0.35
	mating_distance = 5.0
	mating_energy_min = 0.25
	mating_energy_cost = 0.08
	mating_cooldown_seconds = 3.0
	egg_hatch_seconds = 2.0
	egg_energy = 1.0
	seconds_per_sim_day = 40.0
	eye_ray_length = 14.0
	food_sense_radius = 10.0
	mate_sense_radius = 7.0
	brain_type = "drosophila"
	connectome_path = "res://data/brains/flywire_fafb_v783.ffc"


func apply_preset_balanced() -> void:
	var d := SimulationConfig.new()
	seed = d.seed
	triops_count = d.triops_count
	max_triops = d.max_triops
	aquarium_half_extents = d.aquarium_half_extents
	simulation_dt = d.simulation_dt
	seconds_per_sim_day = d.seconds_per_sim_day
	max_speed = d.max_speed
	linear_accel = d.linear_accel
	linear_drag = d.linear_drag
	angular_accel = d.angular_accel
	angular_drag = d.angular_drag
	wall_bounce = d.wall_bounce
	wall_margin = d.wall_margin
	eye_ray_length = d.eye_ray_length
	food_sense_radius = d.food_sense_radius
	mate_sense_radius = d.mate_sense_radius
	brain_type = d.brain_type
	connectome_path = d.connectome_path
	food_count = d.food_count
	food_energy = d.food_energy
	eat_radius = d.eat_radius
	food_respawn_seconds = d.food_respawn_seconds
	initial_energy = d.initial_energy
	energy_drain_per_second = d.energy_drain_per_second
	swim_energy_cost = d.swim_energy_cost
	starvation_health_drain = d.starvation_health_drain
	max_lifespan_days = d.max_lifespan_days
	mature_age_days = d.mature_age_days
	min_scale = d.min_scale
	max_scale = d.max_scale
	mating_distance = d.mating_distance
	mating_energy_cost = d.mating_energy_cost
	mating_energy_min = d.mating_energy_min
	mating_cooldown_seconds = d.mating_cooldown_seconds
	egg_hatch_seconds = d.egg_hatch_seconds
	egg_energy = d.egg_energy
	mutation_rate = d.mutation_rate
	mutation_scale = d.mutation_scale
	crossover_enabled = d.crossover_enabled


func apply_preset_harsh() -> void:
	triops_count = 20
	max_triops = 60
	food_count = 50
	food_energy = 0.35
	food_respawn_seconds = 8.0
	eat_radius = 0.6
	energy_drain_per_second = 0.02
	swim_energy_cost = 0.008
	starvation_health_drain = 0.12
	initial_energy = 1.0
	max_lifespan_days = 18.0
	mature_age_days = 2.5
	mating_distance = 1.5
	mating_energy_min = 0.5
	mating_energy_cost = 0.3
	seconds_per_sim_day = 30.0
