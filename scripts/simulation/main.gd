extends Node3D
## Main scene: fixed-step sim + FPS governor (target ≥ 30 FPS).

const SPEED_STEPS: Array[float] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]
const MENU_SCENE := "res://scenes/setup_menu.tscn"
const TARGET_FPS := 30.0

@export var config: SimulationConfig

var world: SimulationWorld = SimulationWorld.new()
var _accum: float = 0.0
var paused: bool = false
var time_scale: float = 1.0
var _speed_index: int = 2
var _extinct_notified: bool = false
var _fps_ema: float = 60.0

@onready var aquarium: AquariumVisual = $Aquarium
@onready var triops_visual: TriopsVisual = $TriopsVisual
@onready var food_visual: FoodVisual = $FoodVisual
@onready var egg_visual: EggVisual = $EggVisual
@onready var camera: SimulationCamera = $Camera3D
@onready var debug_ui: DebugUI = $DebugUI


func _ready() -> void:
	Engine.max_fps = 60
	if RunSession.has_pending_run:
		config = RunSession.take_config()
	elif config == null:
		config = SimulationConfig.new()
		config.apply_preset_easy()

	world.initialize(config)
	aquarium.build(config.aquarium_half_extents)
	triops_visual.setup(config.max_triops)
	food_visual.setup(config.food_count)
	egg_visual.setup(16)
	_sync_visuals()

	camera.bind_world(world)
	camera.setup_aquarium(config.aquarium_half_extents)

	debug_ui.pause_pressed.connect(_toggle_pause)
	debug_ui.slower_pressed.connect(_slower)
	debug_ui.faster_pressed.connect(_faster)
	debug_ui.menu_pressed.connect(_back_to_menu)


func _process(delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	if fps > 1.0:
		_fps_ema = lerpf(_fps_ema, float(fps), 0.1)

	# Adaptive sim catch-up: never tank the frame for neural work.
	var max_steps := 2
	if _fps_ema >= 50.0:
		max_steps = mini(8, maxi(2, int(ceil(3.0 * time_scale))))
	elif _fps_ema >= TARGET_FPS:
		max_steps = mini(4, maxi(1, int(ceil(2.0 * time_scale))))
	else:
		max_steps = 1
		# If user sped up too much, auto-ease time_scale toward 1x.
		if time_scale > 1.0 and _fps_ema < 25.0:
			time_scale = maxf(1.0, time_scale * 0.95)
			_speed_index = 2
			for i in SPEED_STEPS.size():
				if absf(SPEED_STEPS[i] - time_scale) < 0.01:
					_speed_index = i
					break

	if not paused and time_scale > 0.0:
		_accum += delta * time_scale
		var dt: float = config.simulation_dt
		var steps := 0
		while _accum >= dt and steps < max_steps:
			world.step(dt)
			_accum -= dt
			steps += 1
		# Drop backlog instead of spiral-of-death.
		if _accum > dt * 4.0:
			_accum = 0.0
	else:
		_accum = 0.0

	if world.living_count() == 0 and world.eggs.is_empty() and not _extinct_notified:
		_extinct_notified = true
		paused = true

	_sync_visuals()
	var cam_mode := camera.mode_name()
	var backend := "cpu"
	var eng := GpuLifEngine.get_engine()
	if eng.ready:
		backend = eng.backend_name
	if debug_ui.visible:
		debug_ui.update_display(world, _fps_ema, time_scale, paused, "%s | %s" % [cam_mode, backend])
	var bp := debug_ui.get_node_or_null("BrainPanel") as CanvasItem
	if bp:
		bp.visible = debug_ui.visible


func _sync_visuals() -> void:
	triops_visual.sync_from_simulation(world)
	food_visual.sync_from_food(world.food)
	egg_visual.sync_from_eggs(world.eggs)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var handled := false
		match event.keycode:
			KEY_ESCAPE:
				_toggle_hud()
				handled = true
			KEY_TAB:
				if event.shift_pressed:
					world.select_prev()
				else:
					world.select_next()
				handled = true
			KEY_F:
				camera.toggle_follow()
				handled = true
			KEY_C, KEY_HOME:
				camera.recenter()
				handled = true
			KEY_R:
				if event.ctrl_pressed:
					_restart()
					handled = true
			KEY_SPACE:
				_toggle_pause()
				handled = true
			KEY_MINUS, KEY_KP_SUBTRACT:
				_slower()
				handled = true
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				_faster()
				handled = true
		if handled:
			var vp := get_viewport()
			if vp:
				vp.set_input_as_handled()


func _toggle_hud() -> void:
	debug_ui.visible = not debug_ui.visible


func _toggle_pause() -> void:
	paused = not paused


func _slower() -> void:
	_speed_index = maxi(0, _speed_index - 1)
	time_scale = SPEED_STEPS[_speed_index]
	if paused:
		paused = false


func _faster() -> void:
	_speed_index = mini(SPEED_STEPS.size() - 1, _speed_index + 1)
	time_scale = SPEED_STEPS[_speed_index]
	if paused:
		paused = false


func _restart() -> void:
	_accum = 0.0
	_extinct_notified = false
	world.initialize(config)
	triops_visual.setup(config.max_triops)
	food_visual.setup(config.food_count)
	paused = false


func _back_to_menu() -> void:
	GpuLifEngine.get_engine().shutdown()
	RunSession.config = config.duplicate(true) as SimulationConfig
	get_tree().change_scene_to_file(MENU_SCENE)
