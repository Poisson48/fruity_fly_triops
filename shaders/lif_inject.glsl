#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer IBuf { int i_syn_fp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer DriveBuf { int drive_fp[]; };

layout(set = 0, binding = 2, std430) restrict readonly buffer Params {
	uint neuron_count;
	uint agent_count;
};

void main() {
	uint idx = gl_GlobalInvocationID.x;
	uint total = neuron_count * agent_count;
	if (idx >= total) {
		return;
	}
	int d = drive_fp[idx];
	if (d != 0) {
		atomicAdd(i_syn_fp[idx], d);
	}
}
