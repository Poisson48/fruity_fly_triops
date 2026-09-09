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

## Scales applied after mapping.
var thrust_scale: float = 1.0
var vertical_scale: float = 1.35
var yaw_scale: float = 1.0
var pitch_scale: float = 1.3
var roll_scale: float = 0.85


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
	cmd.yaw = _read(brain_outputs, CHANNEL_YAW) * yaw_scale
	cmd.pitch = _read(brain_outputs, CHANNEL_PITCH) * pitch_scale
	cmd.roll = _read(brain_outputs, CHANNEL_ROLL) * roll_scale
	return cmd


func _read(outputs: PackedFloat32Array, motor_channel: int) -> float:
	var src := motor_channel
	if channel_map.size() > motor_channel:
		src = channel_map[motor_channel]
	if src < 0 or src >= outputs.size():
		return 0.0
	return clampf(outputs[src], -1.0, 1.0)
