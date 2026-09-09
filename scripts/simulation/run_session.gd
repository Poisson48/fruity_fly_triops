extends Node
## Autoload: carries config from setup menu → simulation run.

var config: SimulationConfig = SimulationConfig.new()
var has_pending_run: bool = false


func prepare_run(cfg: SimulationConfig) -> void:
	config = cfg
	has_pending_run = true


func take_config() -> SimulationConfig:
	has_pending_run = false
	return config


func duplicate_config() -> SimulationConfig:
	return config.duplicate(true) as SimulationConfig
