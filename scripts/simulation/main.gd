extends Node3D
## Main scene: fixed-step sim (wall-clock time). FPS only affects visuals, not sim speed.

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
var _visual_skip: int = 0
var _base_gpu_brain_dt: float = 1.0 / 12.0

@onready var aquarium: AquariumVisual = $Aquarium
@onready var triops_visual: TriopsVisual = $TriopsVisual
@onready var food_visual: FoodVisual = $FoodVisual
@onready var egg_visual: EggVisual = $EggVisual
@onready var camera: SimulationCamera = $Camera3D
@onready var debug_ui: DebugUI = $DebugUI
var void_visual: VoidSpaceVisual = null


func _ready() -> void:
	Engine.max_fps = 60
	if RunSession.has_pending_run:
		config = RunSession.take_config()
	elif config == null:
		config = SimulationConfig.new()
		config.apply_preset_easy()

	world.initialize(config)
	_base_gpu_brain_dt = 1.0 / 60.0 if config.is_free_flight() else world.gpu_brain_dt
	world.gpu_brain_dt = _base_gpu_brain_dt

	if config.is_free_flight():
		aquarium.visible = false
		food_visual.visible = false
		egg_visual.visible = false
		void_visual = VoidSpaceVisual.new()
		void_visual.name = "VoidSpace"
		add_child(void_visual)
		void_visual.build()
		# Day-ish sky over the endless flat ground.
		var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
		if we and we.environment:
			we.environment.background_color = Color(0.45, 0.62, 0.82, 1)
			we.environment.ambient_light_color = Color(0.7, 0.75, 0.8, 1)
			we.environment.ambient_light_energy = 0.75
	else:
		aquarium.build(config.aquarium_half_extents)
		food_visual.setup(config.food_count)
		egg_visual.setup(16)

	triops_visual.setup(config.max_triops)
	_sync_visuals()

	camera.bind_world(world)
	camera.setup_aquarium(config.aquarium_half_extents)
	if config.is_free_flight():
		camera.mode = SimulationCamera.Mode.FOLLOW
		camera.follow_distance = 6.0
		camera.max_distance = 120.0

	debug_ui.pause_pressed.connect(_toggle_pause)
	debug_ui.slower_pressed.connect(_slower)
	debug_ui.faster_pressed.connect(_faster)
	debug_ui.menu_pressed.connect(_back_to_menu)


func _process(delta: float) -> void:
	var fps := Engine.get_frames_per_second()
	if fps > 1.0:
		_fps_ema = lerpf(_fps_ema, float(fps), 0.12)

	# Sim clock is fixed-step. Under load we take fewer, coarser slices (not slow-mo)
	# so catch-up can't spiral into <10 FPS.
	world.fps_ema = _fps_ema
	world.speed_scale = time_scale
	# Stretch neural interval when FPS tanks — wall-clock brain budget stays sane.
	if _fps_ema < 18.0:
		world.gpu_brain_dt = _base_gpu_brain_dt * 2.2
	elif _fps_ema < 28.0:
		world.gpu_brain_dt = _base_gpu_brain_dt * 1.5
	else:
		world.gpu_brain_dt = _base_gpu_brain_dt
	world.begin_frame()

	if not paused and time_scale > 0.0:
		_accum += delta * time_scale
		var dt: float = config.simulation_dt
		var max_steps := 6
		if _fps_ema < 16.0:
			max_steps = 2
		elif _fps_ema < 24.0:
			max_steps = 3
		elif _fps_ema < 32.0:
			max_steps = 4
		if time_scale > 1.0:
			max_steps = mini(12, maxi(max_steps, int(ceil(time_scale * 3.0))))
		var steps := 0
		while _accum >= dt and steps < max_steps:
			var step_dt := dt
			# Coarser physics when behind or sped up — one slice covers more wall time.
			var behind := _accum >= dt * 2.0
			if behind or time_scale > 1.0:
				var slice_cap := 0.05 if _fps_ema >= 24.0 else 0.08
				if _fps_ema < 16.0:
					slice_cap = 0.10
				step_dt = minf(_accum, minf(slice_cap, dt * maxf(1.0, time_scale * 0.5)))
				step_dt = maxf(step_dt, dt)
			world.step(step_dt)
			_accum -= step_dt
			steps += 1
		# Drop leftover rather than snowballing (brief time skip > death spiral).
		if _accum > dt * float(max_steps):
			_accum = 0.0
	else:
		_accum = 0.0

	if world.living_count() == 0 and world.eggs.is_empty() and not _extinct_notified:
		_extinct_notified = true
		paused = true

	# Visual skip is display-only (smoothed poses). Does not change sim speed.
	var vis_every := 1
	if _fps_ema < 22.0:
		vis_every = 4
	elif _fps_ema < 28.0:
		vis_every = 3
	elif _fps_ema < 36.0:
		vis_every = 2
	elif time_scale >= 8.0:
		vis_every = 4
	elif time_scale >= 4.0:
		vis_every = 3
	elif time_scale >= 2.0:
		vis_every = 2
	_visual_skip = (_visual_skip + 1) % vis_every
	if _visual_skip == 0:
		_sync_visuals(delta * float(vis_every))
	var cam_mode := camera.mode_name()
	var backend := "cpu"
	var eng := GpuLifEngine.get_engine()
	if eng.ready:
		backend = eng.backend_name
		if world._use_threads:
			backend += "+mt"
	if debug_ui.visible:
		debug_ui.update_display(world, _fps_ema, time_scale, paused, "%s | %s" % [cam_mode, backend])
	var bp := debug_ui.get_node_or_null("BrainPanel") as CanvasItem
	if bp:
		bp.visible = debug_ui.visible and time_scale <= 2.0


func _sync_visuals(delta: float = 1.0 / 60.0) -> void:
	triops_visual.sync_from_simulation(world, delta)
	if config != null and config.is_free_flight():
		if void_visual != null and not world.agents.is_empty():
			var a: TriopsAgent = world.agents[0]
			void_visual.sync_from_void(world.void_space, a.body.position)
	else:
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
	world.speed_scale = time_scale
	if paused:
		paused = false


func _faster() -> void:
	_speed_index = mini(SPEED_STEPS.size() - 1, _speed_index + 1)
	time_scale = SPEED_STEPS[_speed_index]
	world.speed_scale = time_scale
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
