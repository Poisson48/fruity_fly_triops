class_name DebugUI
extends CanvasLayer
## Debug overlay + time controls + live FlyWire brain panel.

signal pause_pressed
signal slower_pressed
signal faster_pressed
signal menu_pressed

@onready var label: Label = $Panel/Margin/VBox/Label
@onready var pause_btn: Button = $Panel/Margin/VBox/Controls/PauseBtn
@onready var slower_btn: Button = $Panel/Margin/VBox/Controls/SlowerBtn
@onready var faster_btn: Button = $Panel/Margin/VBox/Controls/FasterBtn
@onready var speed_label: Label = $Panel/Margin/VBox/Controls/SpeedLabel
@onready var menu_btn: Button = $Panel/Margin/VBox/Controls/MenuBtn
@onready var brain_panel: PanelContainer = $BrainPanel


func _ready() -> void:
	pause_btn.pressed.connect(func() -> void: pause_pressed.emit())
	slower_btn.pressed.connect(func() -> void: slower_pressed.emit())
	faster_btn.pressed.connect(func() -> void: faster_pressed.emit())
	menu_btn.pressed.connect(func() -> void: menu_pressed.emit())


func update_display(
	world: SimulationWorld,
	fps: float,
	time_scale: float,
	paused: bool,
	camera_mode: String = "ORBIT"
) -> void:
	if world == null or world.config == null:
		return

	var day_len: float = world.config.seconds_per_sim_day
	var day: float = world.time / day_len if day_len > 0.0 else 0.0
	var day_i: int = int(floor(day))
	var day_frac: float = day - float(day_i)
	var sexes := world.sex_counts()
	var st := world.stats.as_dict()

	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== Fruity Fly Triops ===")
	lines.append("Triops: %d (F:%d M:%d)  eggs: %d  food: %d" % [
		world.living_count(), sexes.x, sexes.y, world.eggs.size(), world.food.active_count()
	])
	lines.append("FPS: %.1f | Cam: %s" % [fps, camera_mode])
	lines.append("Day: %d + %.2f  (%.1f s/day, max life %.0f d)" % [
		day_i, day_frac, day_len, world.config.max_lifespan_days
	])
	lines.append("Sim: %.1fs | steps %d | brain %s" % [world.time, world.step_count, world.config.brain_type])
	lines.append(
		"Evo gen max %d | births %d | deaths %d | eggs %d | meals %d"
		% [st["max_generation"], st["births"], st["deaths"], st["eggs_laid"], st["meals"]]
	)
	lines.append("Avg death age: %.2f days" % st["avg_death_age_days"])
	lines.append("Seed: %d" % world.config.seed)
	lines.append("")
	lines.append("[RMB/MMB] orbit  [Molette] zoom  [C] recenter  [F] follow")
	lines.append("[WASD/QE] pan  [Tab] select  [Space] pause  [Esc] HUD")
	lines.append("Colors: pink=F  blue=M  yellow=selected  green=food")
	if world.living_count() == 0 and world.eggs.is_empty():
		lines.append("")
		lines.append("!!! EXTINCTION — Menu pour reconfigurer !!!")
	lines.append("")

	var agent := world.get_agent_by_id(world.selected_id)
	if agent:
		var info := agent.get_debug_state()
		var pos: Vector3 = info["position"]
		var vel: Vector3 = info["velocity"]
		lines.append("--- Triops #%d (%s) gen %d ---" % [info["id"], info["sex"], info["generation"]])
		lines.append(
			"age %.2fd | energy %.2f | health %.2f | scale %.2f"
			% [agent.age_days(world.config), info["energy"], info["health"], info["scale"]]
		)
		lines.append("pos (%.2f, %.2f, %.2f)" % [pos.x, pos.y, pos.z])
		lines.append("vel (%.2f, %.2f, %.2f) |v|=%.2f" % [vel.x, vel.y, vel.z, vel.length()])
		var sensors: Dictionary = info["sensor_inputs"]
		lines.append("eye L wall/food/mate: %s" % str(sensors.get("left_eye", [])))
		lines.append("eye R wall/food/mate: %s" % str(sensors.get("right_eye", [])))
		lines.append("eye M wall/food/mate: %s" % str(sensors.get("median_eye", [])))
		lines.append(
			"motivation food×%.2f mate×%.2f"
			% [float(sensors.get("food_motivation", 1.0)), float(sensors.get("mate_motivation", 1.0))]
		)
		lines.append("motor: %s" % str(info.get("brain_outputs", [])))
		var brain_info: Dictionary = info.get("brain", {})
		lines.append(
			"brain %s | spikes %s | neurons %s"
			% [
				brain_info.get("name", "?"),
				str(brain_info.get("spike_count", 0)),
				str(brain_info.get("neuron_count", 0)),
			]
		)
		if brain_info.has("note"):
			lines.append("(%s)" % brain_info["note"])
		if brain_panel and brain_panel.visible and brain_panel.has_method("update_from_agent"):
			brain_panel.call("update_from_agent", agent)

	label.text = "\n".join(lines)
	pause_btn.text = "Resume" if paused else "Pause"
	speed_label.text = "PAUSED" if paused else ("%.2fx" % time_scale)
