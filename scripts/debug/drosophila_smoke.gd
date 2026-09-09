extends SceneTree
## Verify FlyWire connectome loads and drives agents.

func _init() -> void:
	var cfg := SimulationConfig.new()
	cfg.apply_preset_easy()
	cfg.brain_type = "drosophila"
	cfg.connectome_path = "res://data/brains/flywire_fafb_visual_subset.json"
	cfg.triops_count = 8
	cfg.food_count = 40
	cfg.seed = 7

	var world := SimulationWorld.new()
	world.initialize(cfg)
	var brain0: Brain = world.agents[0].brain
	var info: Dictionary = brain0.get_debug_info()
	print("brain=", info)
	if not bool(info.get("ready", false)):
		push_error("DrosophilaBrain not ready")
		quit(1)
	if int(info.get("neuron_count", 0)) < 100:
		push_error("Expected large connectome")
		quit(1)

	for _i in 180:
		world.step(cfg.simulation_dt)

	var a := world.agents[0]
	print("pos=", a.body.position, " vel=", a.body.velocity)
	print("spikes=", a.brain.get_debug_info().get("spike_count", 0))
	print("meals=", world.stats.meals, " living=", world.living_count())
	quit(0)
