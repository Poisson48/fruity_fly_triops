extends SceneTree
## Longer viability with full FlyWire brain.

func _init() -> void:
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.seed = 11
	var world := SimulationWorld.new()
	world.initialize(cfg)
	var info: Dictionary = world.agents[0].brain.get_debug_info()
	print("neurons=", info.get("neuron_count"), " syn=", info.get("synapse_count"), " ready=", info.get("ready"))

	for i in 5000:
		world.step(cfg.simulation_dt)
		if i % 800 == 799:
			var binfo: Dictionary = world.agents[0].brain.get_debug_info() if world.living_count() > 0 else {}
			print(
				"t=%.1f day=%.2f living=%d meals=%d eggs_laid=%d deaths=%d gen=%d spikes=%d active=%d"
				% [
					world.time,
					world.time / cfg.seconds_per_sim_day,
					world.living_count(),
					world.stats.meals,
					world.stats.eggs_laid,
					world.stats.deaths,
					world.stats.max_generation,
					int(binfo.get("spike_count", 0)),
					int(binfo.get("active", 0)),
				]
			)

	var ok := (
		bool(info.get("ready", false))
		and int(info.get("synapse_count", 0)) > 1000000
		and world.living_count() >= 4
		and world.stats.meals >= 3
		and world.stats.eggs_laid >= 1
	)
	print("VIABLE=", ok, " living=", world.living_count(), " meals=", world.stats.meals, " eggs=", world.stats.eggs_laid)
	quit(0 if ok else 1)
