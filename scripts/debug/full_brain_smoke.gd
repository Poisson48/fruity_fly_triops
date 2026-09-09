extends SceneTree
## Full FFC connectome + LIF+ viability smoke.

func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.brain_type = "drosophila"
	cfg.connectome_path = "res://data/brains/flywire_fafb_v783.ffc"
	cfg.triops_count = 12
	cfg.food_count = 100
	cfg.seed = 3
	cfg.energy_drain_per_second = 0.008
	cfg.food_respawn_seconds = 2.0
	cfg.mature_age_days = 1.0
	cfg.mating_distance = 3.0
	cfg.mating_energy_min = 0.25
	cfg.seconds_per_sim_day = 40.0

	var world := SimulationWorld.new()
	world.initialize(cfg)
	var load_ms := Time.get_ticks_msec() - t0
	var info: Dictionary = world.agents[0].brain.get_debug_info()
	print("load_ms=", load_ms, " info=", info)
	if not bool(info.get("ready", false)) or int(info.get("neuron_count", 0)) < 100000:
		push_error("Full connectome not loaded")
		quit(1)

	t0 = Time.get_ticks_msec()
	for i in 1200:
		world.step(cfg.simulation_dt)
		if i % 300 == 299:
			var sp := int(world.agents[0].brain.get_debug_info().get("spike_count", 0))
			var act := int(world.agents[0].brain.get_debug_info().get("active", 0))
			print(
				"t=%.1f living=%d meals=%d eggs_laid=%d spikes=%d active=%d"
				% [world.time, world.living_count(), world.stats.meals, world.stats.eggs_laid, sp, act]
			)
	var step_ms := Time.get_ticks_msec() - t0
	print("step1200_ms=", step_ms, " final_living=", world.living_count(), " meals=", world.stats.meals, " eggs=", world.stats.eggs_laid)
	var ok := world.living_count() >= 3 and int(info.get("synapse_count", 0)) > 1000000
	print("OK=", ok)
	quit(0 if ok else 1)
