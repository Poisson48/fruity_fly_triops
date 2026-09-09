#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Gather motor voltages into a tiny buffer (agents × channels).
layout(set = 0, binding = 0, std430) restrict readonly buffer VBuf { float v[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer MotorMap { int map_ids[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer OutBuf { float outv[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer SpikeOut { uint spike_counts[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer SBuf { uint spiked[]; };

layout(set = 0, binding = 5, std430) restrict readonly buffer Params {
	uint neuron_count;
	uint agent_count;
	uint motor_count;
	uint channel_count;
};

void main() {
	uint a = gl_GlobalInvocationID.x;
	if (a >= agent_count) {
		return;
	}
	uint base = a * neuron_count;
	uint spikes = 0u;
	uint n_sample = min(neuron_count, 512u);
	for (uint i = 0u; i < n_sample; i++) {
		if (spiked[base + i] != 0u) {
			spikes++;
		}
	}
	spike_counts[a] = spikes;

	uint chunk = max(1u, motor_count / channel_count);
	for (uint c = 0u; c < channel_count; c++) {
		uint start = c * chunk;
		uint stop = (c == channel_count - 1u) ? motor_count : min(motor_count, start + chunk);
		float acc = 0.0;
		uint n = 0u;
		for (uint i = start; i < stop; i++) {
			int ni = map_ids[i];
			if (ni >= 0) {
				acc += v[base + uint(ni)];
				n++;
			}
		}
		float mean = (n > 0u) ? (acc / float(n)) : 0.0;
		// tanh approx for |x|<3
		float x = clamp(mean, -3.0, 3.0);
		float x2 = x * x;
		outv[a * channel_count + c] = x * (27.0 + x2) / (27.0 + 9.0 * x2);
	}
}
