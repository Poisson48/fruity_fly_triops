class_name SensoryPacket
extends RefCounted
## Sensor snapshot for one Triops — fly-inspired visual front-end.
##
## left/right/median_eye keep 3 summary channels for genome adapter (9 flat):
##   0 OFF/loom  1 ON/food  2 mate/figure
## Richer fields drive retinotopic FlyWire injection (ME / LOP).

var left_eye: PackedFloat32Array = PackedFloat32Array()
var right_eye: PackedFloat32Array = PackedFloat32Array()
var median_eye: PackedFloat32Array = PackedFloat32Array()

## Retinotopic mosaics (compound ≈ ommatidia → medulla).
var left_on: PackedFloat32Array = PackedFloat32Array()
var left_off: PackedFloat32Array = PackedFloat32Array()
var left_mate: PackedFloat32Array = PackedFloat32Array()
var right_on: PackedFloat32Array = PackedFloat32Array()
var right_off: PackedFloat32Array = PackedFloat32Array()
var right_mate: PackedFloat32Array = PackedFloat32Array()
var median_on: PackedFloat32Array = PackedFloat32Array()
var median_off: PackedFloat32Array = PackedFloat32Array()
var median_mate: PackedFloat32Array = PackedFloat32Array()

## Column optic-flow (HS / VS proxies), length = azimuth count.
var left_flow_h: PackedFloat32Array = PackedFloat32Array()
var left_flow_v: PackedFloat32Array = PackedFloat32Array()
var right_flow_h: PackedFloat32Array = PackedFloat32Array()
var right_flow_v: PackedFloat32Array = PackedFloat32Array()
var median_flow_h: PackedFloat32Array = PackedFloat32Array()
var median_flow_v: PackedFloat32Array = PackedFloat32Array()

## Global fly-like scalars (lobula-plate style).
var expand_l: float = 0.0
var expand_r: float = 0.0
var expand_m: float = 0.0
var contrast_l: float = 0.0
var contrast_r: float = 0.0
var contrast_m: float = 0.0
var flow_yaw: float = 0.0 ## + = world flow suggesting turn right
var flow_pitch: float = 0.0

var energy: float = 1.0
var food_motivation: float = 1.0
var mate_motivation: float = 1.0
var floor_loom: float = 0.0
var ceiling_loom: float = 0.0
var depth_norm: float = 0.0
var food_up: float = 0.0
var food_down: float = 0.0
var mate_up: float = 0.0
var mate_down: float = 0.0
## Body-frame bearing: + = turn left toward target (matches motor yaw sign).
var food_bearing_yaw: float = 0.0
var mate_bearing_yaw: float = 0.0
var food_bearing_strength: float = 0.0


func as_flat() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.append_array(left_eye)
	out.append_array(right_eye)
	out.append_array(median_eye)
	return out


func channel_count() -> int:
	return left_eye.size() + right_eye.size() + median_eye.size()


## Hunger ↑ ON/food; surplus ↑ mate figure.
func apply_energy_motivation(energy_in: float) -> void:
	energy = energy_in
	var hunger := clampf(1.0 - energy_in / 1.1, 0.0, 1.0)
	food_motivation = lerpf(0.95, 2.8, hunger)
	var satiety := clampf((energy_in - 0.4) / 1.0, 0.0, 1.0)
	mate_motivation = lerpf(0.2, 2.5, satiety)
	_scale_eye_channel(1, food_motivation)
	_scale_eye_channel(2, mate_motivation)
	_scale_field(left_on, food_motivation)
	_scale_field(right_on, food_motivation)
	_scale_field(median_on, food_motivation)
	_scale_field(left_mate, mate_motivation)
	_scale_field(right_mate, mate_motivation)
	_scale_field(median_mate, mate_motivation)
	food_up = minf(food_up * food_motivation, 3.5)
	food_down = minf(food_down * food_motivation, 3.5)
	mate_up = minf(mate_up * mate_motivation, 3.5)
	mate_down = minf(mate_down * mate_motivation, 3.5)


func _scale_eye_channel(channel_idx: int, scale: float) -> void:
	for eye in [left_eye, right_eye, median_eye]:
		if channel_idx < eye.size():
			eye[channel_idx] = minf(eye[channel_idx] * scale, 3.5)


func _scale_field(field: PackedFloat32Array, scale: float) -> void:
	for i in field.size():
		field[i] = minf(field[i] * scale, 3.5)
