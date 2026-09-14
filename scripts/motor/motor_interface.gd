class_name MotorInterface
extends RefCounted
## Maps brain output channels → Triops motor commands.
## Correspondences are configurable — never hard-code "if neuron X then move".

## Default channel layout for TestBrain (and stubs):
## 0 forward thrust   [-1, 1]
## 1 vertical thrust  [-1, 1]
## 2 yaw rate         [-1, 1]
## 3 pitch rate       [-1, 1]
## 4 roll rate        [-1, 1]
const CHANNEL_FORWARD := 0
const CHANNEL_VERTICAL := 1
const CHANNEL_YAW := 2
const CHANNEL_PITCH := 3
const CHANNEL_ROLL := 4
const CHANNEL_COUNT := 5

## Optional remapping: brain_output_index → motor channel.
## Empty = identity mapping for the first CHANNEL_COUNT outputs.
var channel_map: PackedInt32Array = PackedInt32Array()

## Scales applied after mapping (yaw soft-saturated in decode).
var thrust_scale: float = 1.0
var vertical_scale: float = 0.65
var yaw_scale: float = 0.7
var pitch_scale: float = 1.0
var roll_scale: float = 0.4


class MotorCommand:
	extends RefCounted
	var forward: float = 0.0
	var vertical: float = 0.0
	var yaw: float = 0.0
	var pitch: float = 0.0
	var roll: float = 0.0


func decode(brain_outputs: PackedFloat32Array) -> MotorCommand:
	var cmd := MotorCommand.new()
	cmd.forward = _read(brain_outputs, CHANNEL_FORWARD) * thrust_scale
	cmd.vertical = _read(brain_outputs, CHANNEL_VERTICAL) * vertical_scale
	# Soft sat — saturated SEZ still steers, but body YAW_LOCK_CAP stops orbits.
	cmd.yaw = tanh(_read(brain_outputs, CHANNEL_YAW) * yaw_scale)
	cmd.pitch = tanh(_read(brain_outputs, CHANNEL_PITCH) * pitch_scale)
	cmd.roll = _read(brain_outputs, CHANNEL_ROLL) * roll_scale
	return cmd


func configure_for_mode(config: SimulationConfig) -> void:
	if config != null and config.is_free_flight():
		thrust_scale = 1.15
		vertical_scale = 1.1
		yaw_scale = 1.25
		pitch_scale = 1.15
		roll_scale = 0.18
	else:
		thrust_scale = 1.0
		vertical_scale = 0.65
		yaw_scale = 0.7
		pitch_scale = 1.0
		roll_scale = 0.4


func _read(outputs: PackedFloat32Array, motor_channel: int) -> float:
	var src := motor_channel
	if channel_map.size() > motor_channel:
		src = channel_map[motor_channel]
	if src < 0 or src >= outputs.size():
		return 0.0
	return clampf(outputs[src], -1.0, 1.0)
