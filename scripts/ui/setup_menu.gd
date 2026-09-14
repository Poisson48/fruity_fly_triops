extends Control
## Startup config menu: edit all SimulationConfig fields, then launch a run.

const MAIN_SCENE := "res://scenes/main.tscn"

var _config: SimulationConfig = SimulationConfig.new()
var _fields: Dictionary = {}  # property_name -> control

@onready var scroll: ScrollContainer = $Panel/Margin/VBox/Scroll
@onready var form: VBoxContainer = $Panel/Margin/VBox/Scroll/Form
@onready var status: Label = $Panel/Margin/VBox/Status


func _ready() -> void:
	if RunSession.config != null:
		_config = RunSession.config.duplicate(true) as SimulationConfig
	else:
		_config = SimulationConfig.new()
		_config.apply_preset_easy()
	_build_form()
	_write_form_from_config()
	status.text = "Astuce: preset Easy si la population s'éteint."


func _build_form() -> void:
	for c in form.get_children():
		c.queue_free()
	_fields.clear()

	_add_section("Presets")
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 8)
	for item in [
		["Easy (survie)", "easy"],
		["Balanced", "balanced"],
		["Harsh", "harsh"],
		["Nage libre (vol mouche)", "free_flight"],
	]:
		var b := Button.new()
		b.text = item[0]
		var key: String = item[1]
		b.pressed.connect(_on_preset.bind(key))
		preset_row.add_child(b)
	form.add_child(preset_row)

	_add_section("Run")
	_add_int("seed", "Seed")
	_add_int("triops_count", "Triops au départ")
	_add_int("max_triops", "Triops max")
	_add_float("simulation_dt", "Timestep (s)", 0.001)
	_add_float("seconds_per_sim_day", "Secondes / jour sim")
	_add_option("brain_type", "Cerveau", ["test", "drosophila"])
	_add_string("connectome_path", "Chemin connectome")

	_add_section("Aquarium")
	_add_float("aquarium_x", "Demi-taille X", 0.5)
	_add_float("aquarium_y", "Demi-taille Y", 0.5)
	_add_float("aquarium_z", "Demi-taille Z", 0.5)

	_add_section("Physique")
	_add_float("max_speed", "Vitesse max")
	_add_float("linear_accel", "Accélération linéaire")
	_add_float("linear_drag", "Drag linéaire")
	_add_float("angular_accel", "Accélération angulaire")
	_add_float("angular_drag", "Drag angulaire")
	_add_float("wall_bounce", "Rebond mur")
	_add_float("wall_margin", "Marge mur")

	_add_section("Capteurs")
	_add_float("eye_ray_length", "Portée yeux")
	_add_float("food_sense_radius", "Rayon détection nourriture")
	_add_float("mate_sense_radius", "Rayon détection partenaire")
	_add_float("eye_compound_fov_h_deg", "FOV composé H (°)")
	_add_float("eye_compound_fov_v_deg", "FOV composé V (°)")
	_add_float("eye_compound_cant_deg", "Cant yeux L/R (°)")
	_add_float("eye_median_fov_h_deg", "FOV médian H (°)")
	_add_float("eye_median_fov_v_deg", "FOV médian V (°)")

	_add_section("Nourriture (V1)")
	_add_int("food_count", "Nombre de particules")
	_add_float("food_energy", "Énergie / particule")
	_add_float("eat_radius", "Rayon de mangeage")
	_add_float("food_respawn_seconds", "Respawn nourriture (s)")

	_add_section("Vie (V2)")
	_add_float("initial_energy", "Énergie initiale")
	_add_float("energy_drain_per_second", "Drain énergie / s")
	_add_float("swim_energy_cost", "Coût nage")
	_add_float("starvation_health_drain", "Drain santé (famine)")
	_add_float("max_lifespan_days", "Durée de vie max (jours)")
	_add_float("mature_age_days", "Âge mature (jours)")
	_add_float("min_scale", "Échelle min")
	_add_float("max_scale", "Échelle max")

	_add_section("Reproduction (V3)")
	_add_float("mating_distance", "Distance accouplement")
	_add_float("mating_energy_cost", "Coût énergie accouplement")
	_add_float("mating_energy_min", "Énergie min pour s'accoupler")
	_add_float("mating_cooldown_seconds", "Cooldown (s)")
	_add_float("egg_hatch_seconds", "Incubation œuf (s)")
	_add_float("egg_energy", "Énergie nouveau-né")

	_add_section("Génétique / Évolution (V4–V6)")
	_add_float("mutation_rate", "Taux mutation")
	_add_float("mutation_scale", "Amplitude mutation")
	_add_bool("crossover_enabled", "Crossover ON")
	_add_bool("connectome_evolution_enabled", "Évolution connectome (sparse SEZ)")


func _add_section(title: String) -> void:
	var l := Label.new()
	l.text = "— %s —" % title
	l.add_theme_font_size_override("font_size", 16)
	form.add_child(l)


func _add_row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var l := Label.new()
	l.text = label_text
	l.custom_minimum_size = Vector2(280, 0)
	row.add_child(l)
	form.add_child(row)
	return row


func _add_int(key: String, label_text: String) -> void:
	var row := _add_row(label_text)
	var box := SpinBox.new()
	box.min_value = 0
	box.max_value = 100000
	box.step = 1
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	_fields[key] = box


func _add_float(key: String, label_text: String, step: float = 0.01) -> void:
	var row := _add_row(label_text)
	var box := SpinBox.new()
	box.min_value = -100000.0
	box.max_value = 100000.0
	box.step = step
	box.allow_greater = true
	box.allow_lesser = true
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	_fields[key] = box


func _add_string(key: String, label_text: String) -> void:
	var row := _add_row(label_text)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	_fields[key] = edit


func _add_bool(key: String, label_text: String) -> void:
	var row := _add_row(label_text)
	var box := CheckBox.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	_fields[key] = box


func _add_option(key: String, label_text: String, options: Array) -> void:
	var row := _add_row(label_text)
	var box := OptionButton.new()
	for o in options:
		box.add_item(str(o))
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	_fields[key] = {"control": box, "options": options}


func _write_form_from_config() -> void:
	_set_num("seed", _config.seed)
	_set_num("triops_count", _config.triops_count)
	_set_num("max_triops", _config.max_triops)
	_set_num("simulation_dt", _config.simulation_dt)
	_set_num("seconds_per_sim_day", _config.seconds_per_sim_day)
	_set_option("brain_type", _config.brain_type)
	_set_string("connectome_path", _config.connectome_path)
	_set_num("aquarium_x", _config.aquarium_half_extents.x)
	_set_num("aquarium_y", _config.aquarium_half_extents.y)
	_set_num("aquarium_z", _config.aquarium_half_extents.z)
	_set_num("max_speed", _config.max_speed)
	_set_num("linear_accel", _config.linear_accel)
	_set_num("linear_drag", _config.linear_drag)
	_set_num("angular_accel", _config.angular_accel)
	_set_num("angular_drag", _config.angular_drag)
	_set_num("wall_bounce", _config.wall_bounce)
	_set_num("wall_margin", _config.wall_margin)
	_set_num("eye_ray_length", _config.eye_ray_length)
	_set_num("food_sense_radius", _config.food_sense_radius)
	_set_num("mate_sense_radius", _config.mate_sense_radius)
	_set_num("eye_compound_fov_h_deg", _config.eye_compound_fov_h_deg)
	_set_num("eye_compound_fov_v_deg", _config.eye_compound_fov_v_deg)
	_set_num("eye_compound_cant_deg", _config.eye_compound_cant_deg)
	_set_num("eye_median_fov_h_deg", _config.eye_median_fov_h_deg)
	_set_num("eye_median_fov_v_deg", _config.eye_median_fov_v_deg)
	_set_num("food_count", _config.food_count)
	_set_num("food_energy", _config.food_energy)
	_set_num("eat_radius", _config.eat_radius)
	_set_num("food_respawn_seconds", _config.food_respawn_seconds)
	_set_num("initial_energy", _config.initial_energy)
	_set_num("energy_drain_per_second", _config.energy_drain_per_second)
	_set_num("swim_energy_cost", _config.swim_energy_cost)
	_set_num("starvation_health_drain", _config.starvation_health_drain)
	_set_num("max_lifespan_days", _config.max_lifespan_days)
	_set_num("mature_age_days", _config.mature_age_days)
	_set_num("min_scale", _config.min_scale)
	_set_num("max_scale", _config.max_scale)
	_set_num("mating_distance", _config.mating_distance)
	_set_num("mating_energy_cost", _config.mating_energy_cost)
	_set_num("mating_energy_min", _config.mating_energy_min)
	_set_num("mating_cooldown_seconds", _config.mating_cooldown_seconds)
	_set_num("egg_hatch_seconds", _config.egg_hatch_seconds)
	_set_num("egg_energy", _config.egg_energy)
	_set_num("mutation_rate", _config.mutation_rate)
	_set_num("mutation_scale", _config.mutation_scale)
	_set_bool("crossover_enabled", _config.crossover_enabled)
	_set_bool("connectome_evolution_enabled", _config.connectome_evolution_enabled)


func _read_form_into_config() -> void:
	_config.seed = int(_get_num("seed"))
	_config.triops_count = int(_get_num("triops_count"))
	_config.max_triops = int(_get_num("max_triops"))
	_config.simulation_dt = _get_num("simulation_dt")
	_config.seconds_per_sim_day = _get_num("seconds_per_sim_day")
	_config.brain_type = _get_option("brain_type")
	_config.connectome_path = _get_string("connectome_path")
	_config.aquarium_half_extents = Vector3(
		_get_num("aquarium_x"), _get_num("aquarium_y"), _get_num("aquarium_z")
	)
	_config.max_speed = _get_num("max_speed")
	_config.linear_accel = _get_num("linear_accel")
	_config.linear_drag = _get_num("linear_drag")
	_config.angular_accel = _get_num("angular_accel")
	_config.angular_drag = _get_num("angular_drag")
	_config.wall_bounce = _get_num("wall_bounce")
	_config.wall_margin = _get_num("wall_margin")
	_config.eye_ray_length = _get_num("eye_ray_length")
	_config.food_sense_radius = _get_num("food_sense_radius")
	_config.mate_sense_radius = _get_num("mate_sense_radius")
	_config.eye_compound_fov_h_deg = _get_num("eye_compound_fov_h_deg")
	_config.eye_compound_fov_v_deg = _get_num("eye_compound_fov_v_deg")
	_config.eye_compound_cant_deg = _get_num("eye_compound_cant_deg")
	_config.eye_median_fov_h_deg = _get_num("eye_median_fov_h_deg")
	_config.eye_median_fov_v_deg = _get_num("eye_median_fov_v_deg")
	_config.food_count = int(_get_num("food_count"))
	_config.food_energy = _get_num("food_energy")
	_config.eat_radius = _get_num("eat_radius")
	_config.food_respawn_seconds = _get_num("food_respawn_seconds")
	_config.initial_energy = _get_num("initial_energy")
	_config.energy_drain_per_second = _get_num("energy_drain_per_second")
	_config.swim_energy_cost = _get_num("swim_energy_cost")
	_config.starvation_health_drain = _get_num("starvation_health_drain")
	_config.max_lifespan_days = _get_num("max_lifespan_days")
	_config.mature_age_days = _get_num("mature_age_days")
	_config.min_scale = _get_num("min_scale")
	_config.max_scale = _get_num("max_scale")
	_config.mating_distance = _get_num("mating_distance")
	_config.mating_energy_cost = _get_num("mating_energy_cost")
	_config.mating_energy_min = _get_num("mating_energy_min")
	_config.mating_cooldown_seconds = _get_num("mating_cooldown_seconds")
	_config.egg_hatch_seconds = _get_num("egg_hatch_seconds")
	_config.egg_energy = _get_num("egg_energy")
	_config.mutation_rate = _get_num("mutation_rate")
	_config.mutation_scale = _get_num("mutation_scale")
	_config.crossover_enabled = _get_bool("crossover_enabled")
	_config.connectome_evolution_enabled = _get_bool("connectome_evolution_enabled")


func _set_num(key: String, value: float) -> void:
	(_fields[key] as SpinBox).value = value


func _get_num(key: String) -> float:
	return (_fields[key] as SpinBox).value


func _set_string(key: String, value: String) -> void:
	(_fields[key] as LineEdit).text = value


func _get_string(key: String) -> String:
	return (_fields[key] as LineEdit).text


func _set_bool(key: String, value: bool) -> void:
	(_fields[key] as CheckBox).button_pressed = value


func _get_bool(key: String) -> bool:
	return (_fields[key] as CheckBox).button_pressed


func _set_option(key: String, value: String) -> void:
	var meta: Dictionary = _fields[key]
	var box: OptionButton = meta["control"]
	var options: Array = meta["options"]
	var idx := options.find(value)
	box.select(maxi(idx, 0))


func _get_option(key: String) -> String:
	var meta: Dictionary = _fields[key]
	var box: OptionButton = meta["control"]
	var options: Array = meta["options"]
	return str(options[box.selected])


func _on_preset(kind: String) -> void:
	match kind:
		"easy":
			_config.apply_preset_easy()
			status.text = "Preset Easy chargé — plus de nourriture, drain faible."
		"harsh":
			_config.apply_preset_harsh()
			status.text = "Preset Harsh chargé — sélection forte."
		"free_flight":
			_config.apply_preset_free_flight()
			status.text = "Nage libre — 1 mouche FlyWire (peau Triops), vide procédural, immortelle."
		_:
			_config.apply_preset_balanced()
			status.text = "Preset Balanced chargé."
	_write_form_from_config()


func _on_launch_pressed() -> void:
	_read_form_into_config()
	if _config.triops_count < 1:
		status.text = "Il faut au moins 1 Triops."
		return
	if _config.simulation_dt <= 0.0:
		status.text = "Timestep invalide."
		return
	RunSession.prepare_run(_config.duplicate(true) as SimulationConfig)
	status.text = "Lancement…"
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()
