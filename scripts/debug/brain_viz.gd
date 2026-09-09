extends PanelContainer
## Panneau cerveau — vision type mouche + injection ME/LOP + moteur.

@onready var title: Label = $Margin/VBox/Title
@onready var stats: Label = $Margin/VBox/Stats
@onready var canvas: Control = $Margin/VBox/Canvas

var _on_l: float = 0.0
var _off_l: float = 0.0
var _on_r: float = 0.0
var _off_r: float = 0.0
var _exp_l: float = 0.0
var _exp_r: float = 0.0
var _exp_m: float = 0.0
var _flow_yaw: float = 0.0
var _flow_pitch: float = 0.0
var _contrast: float = 0.0
var _mate: float = 0.0
var _act_left: float = 0.0
var _act_right: float = 0.0
var _act_median: float = 0.0
var _act_motor: float = 0.0
var _spikes: int = 0
var _neurons: int = 0
var _synapses: int = 0
var _backend: String = "?"
var _brain_mix: float = 0.9
var _assist: float = 0.12
var _motor: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0, 0])
var _accum: float = 0.0
var _pulse: float = 0.0


func _ready() -> void:
	if canvas:
		canvas.set_script(load("res://scripts/debug/brain_viz_drawer.gd"))
		canvas.set("panel", self)


func _process(delta: float) -> void:
	_pulse = fmod(_pulse + delta * 1.8, TAU)
	if canvas:
		canvas.queue_redraw()


func update_from_agent(agent: TriopsAgent, force: bool = false) -> void:
	if agent == null or agent.brain == null:
		return
	_accum += 0.016
	if not force and _accum < 0.08:
		return
	_accum = 0.0

	var outs: PackedFloat32Array = agent.brain.get_outputs()
	_motor = outs.duplicate() if outs.size() >= 5 else PackedFloat32Array([0, 0, 0, 0, 0])

	var pkt: SensoryPacket = agent.sensors.last_packet if agent.sensors else null
	if pkt:
		_on_l = _ch(pkt.left_eye, 1)
		_off_l = _ch(pkt.left_eye, 0)
		_on_r = _ch(pkt.right_eye, 1)
		_off_r = _ch(pkt.right_eye, 0)
		_exp_l = pkt.expand_l
		_exp_r = pkt.expand_r
		_exp_m = pkt.expand_m
		_flow_yaw = pkt.flow_yaw
		_flow_pitch = pkt.flow_pitch
		_contrast = maxf(pkt.contrast_l, maxf(pkt.contrast_r, pkt.contrast_m))
		_mate = maxf(_ch(pkt.left_eye, 2), maxf(_ch(pkt.right_eye, 2), _ch(pkt.median_eye, 2)))

	var db := agent.brain as DrosophilaBrain
	if db == null:
		if title:
			title.text = "Cerveau"
		if stats:
			stats.text = str(agent.brain.get_debug_info().get("note", "n/a"))
		return

	var snap: Dictionary = db.get_activity_snapshot()
	_spikes = int(snap.get("spikes", 0))
	_neurons = int(snap.get("neurons", 0))
	_synapses = int(snap.get("synapses", 0))
	_backend = str(snap.get("backend", "?"))
	_act_left = float(snap.get("act_left", 0.0))
	_act_right = float(snap.get("act_right", 0.0))
	_act_median = float(snap.get("act_median", 0.0))
	_act_motor = float(snap.get("act_motor", 0.0))
	_brain_mix = float(snap.get("brain_weight", 0.9))
	if db.genome:
		_assist = clampf(db.genome.interface_mix, 0.0, 1.0)

	if title:
		title.text = "Vision → FlyWire"
	if stats:
		var be := "GPU" if _backend == "gpu" else "CPU"
		stats.text = (
			"%s · %s neu · spikes %d · FlyWire %.0f%%"
			% [be, _fmt_n(_neurons), _spikes, _brain_mix * 100.0]
		)
	if canvas:
		canvas.queue_redraw()


func _ch(arr: PackedFloat32Array, i: int) -> float:
	if arr == null or i < 0 or i >= arr.size():
		return 0.0
	return arr[i]


func _fmt_n(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 1000:
		return "%dk" % int(n / 1000)
	return str(n)


func paint_on(c: Control) -> void:
	var size := c.size
	if size.x < 8.0 or size.y < 8.0:
		return
	var font := ThemeDB.fallback_font
	var w := size.x
	var y := 2.0
	var pad := 8.0
	var bar_h := 10.0
	var gap := 3.0
	c.draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.08, 0.11, 0.98))

	y = _section(c, font, pad, y, w - pad * 2.0, "1. Yeux (front-end type mouche)")
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "ON gauche (nourriture)", _on_l, Color(0.4, 0.95, 0.5))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "OFF gauche (mur/loom)", _off_l, Color(0.95, 0.4, 0.35))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "ON droit", _on_r, Color(0.4, 0.95, 0.5))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "OFF droit", _off_r, Color(0.95, 0.4, 0.35))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "Expansion L / R / M", maxf(_exp_l, maxf(_exp_r, _exp_m)), Color(1.0, 0.75, 0.3))
	y += gap
	y = _signed_bar(c, font, pad, y, w - pad * 2.0, bar_h, "Flux HS (yaw)", _flow_yaw, Color(0.45, 0.75, 1.0))
	y += gap
	y = _signed_bar(c, font, pad, y, w - pad * 2.0, bar_h, "Flux VS (pitch)", _flow_pitch, Color(0.55, 0.85, 1.0))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "Contraste local", _contrast, Color(0.8, 0.8, 0.55))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "Figure partenaire", _mate, Color(0.85, 0.55, 1.0))
	y += gap + 2.0

	y = _section(c, font, pad, y, w - pad * 2.0, "2. Injection neuropiles")
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "ME gauche", _act_left, Color(0.35, 0.7, 1.0))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "ME droite", _act_right, Color(1.0, 0.55, 0.35))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "LOP (médian)", _act_median, Color(0.35, 0.9, 0.55))
	y += gap
	var pulse := 0.55 + 0.45 * absf(sin(_pulse))
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "Spikes", clampf(float(_spikes) / 50.0, 0, 1) * pulse, Color(0.95, 0.95, 1.0))
	y += gap
	y = _bar(c, font, pad, y, w - pad * 2.0, bar_h, "Carte moteur", _act_motor, Color(0.95, 0.8, 0.25))
	y += gap + 2.0

	y = _section(c, font, pad, y, w - pad * 2.0, "3. Moteur")
	var names := ["Avancer", "Monter / descendre", "Tourner", "Piquer", "Roulis"]
	var cols := [
		Color(0.45, 0.95, 0.55),
		Color(0.45, 0.75, 1.0),
		Color(1.0, 0.7, 0.35),
		Color(0.85, 0.55, 1.0),
		Color(0.7, 0.7, 0.75),
	]
	for i in mini(5, _motor.size()):
		y = _signed_bar(c, font, pad, y, w - pad * 2.0, bar_h, names[i], _motor[i], cols[i])
		y += gap


func _section(c: Control, font: Font, x: float, y: float, w: float, text: String) -> float:
	c.draw_string(font, Vector2(x, y + 11), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.9, 1.0))
	c.draw_line(Vector2(x, y + 14), Vector2(x + w, y + 14), Color(0.35, 0.4, 0.5, 0.6), 1.0)
	return y + 17.0


func _bar(c: Control, font: Font, x: float, y: float, w: float, h: float, label: String, value: float, col: Color) -> float:
	var v := clampf(value, 0.0, 1.5) / 1.5
	c.draw_string(font, Vector2(x, y + 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.75, 0.78, 0.85))
	var track := Rect2(x, y + 10, w, h)
	c.draw_rect(track, Color(0.12, 0.14, 0.18, 1.0))
	if v * w > 0.5:
		c.draw_rect(Rect2(track.position, Vector2(w * v, h)), col)
	c.draw_string(font, Vector2(x + w - 32, y + 8), "%d%%" % int(round(v * 100.0)), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.9, 0.92, 0.95))
	return y + 10.0 + h


func _signed_bar(c: Control, font: Font, x: float, y: float, w: float, h: float, label: String, value: float, col: Color) -> float:
	c.draw_string(font, Vector2(x, y + 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.75, 0.78, 0.85))
	var track := Rect2(x, y + 10, w, h)
	c.draw_rect(track, Color(0.12, 0.14, 0.18, 1.0))
	var mid := track.position.x + track.size.x * 0.5
	c.draw_line(Vector2(mid, track.position.y), Vector2(mid, track.position.y + h), Color(0.4, 0.45, 0.55, 0.9), 1.0)
	var v := clampf(value, -1.5, 1.5) / 1.5
	var half := track.size.x * 0.5
	if absf(v) > 0.01:
		var bw := half * absf(v)
		var bx := mid if v >= 0.0 else mid - bw
		c.draw_rect(Rect2(Vector2(bx, track.position.y), Vector2(bw, h)), col)
	c.draw_string(font, Vector2(x + w - 40, y + 8), "%+.2f" % clampf(value, -9.0, 9.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.9, 0.92, 0.95))
	return y + 10.0 + h
