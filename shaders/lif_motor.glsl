#[compute]
#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Gather motor voltages (+ synaptic current) into agents × channels.
// map_motor packing: [forward | vertical | yaw_L | pitch | yaw_R]
// yaw channel = mean(yaw_L) - mean(yaw_R)
layout(set = 0, binding = 0, std430) restrict readonly buffer VBuf { float v[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer MotorMap { int map_ids[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer OutBuf { float outv[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer SpikeOut { uint spike_counts[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer SBuf { uint spiked[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer IBuf { int i_syn_fp[]; };

layout(set = 0, binding = 6, std430) restrict readonly buffer Params {
	uint neuron_count;
	uint agent_count;
	uint motor_count;
	uint channel_count;
};

const float FP = 1024.0;

float act_at(uint base, int ni) {
	if (ni < 0) {
		return 0.0;
	}
	uint u = uint(ni);
	float vv = v[base + u];
	float isyn = float(i_syn_fp[base + u]) / FP;
	return vv + 0.35 * isyn;
}

float tanh_approx(float mean) {
	float x = clamp(mean, -3.0, 3.0);
	float x2 = x * x;
	return x * (27.0 + x2) / (27.0 + 9.0 * x2);
}

float mean_range(uint base, uint start, uint stop) {
	float acc = 0.0;
	uint n = 0u;
	for (uint i = start; i < stop; i++) {
		acc += act_at(base, map_ids[i]);
		n++;
	}
	return (n > 0u) ? (acc / float(n)) : 0.0;
}

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

	uint chunk = max(1u, motor_count / max(channel_count, 1u));
	// Expected layout with 5 channels: fwd, vert, yaw_L, pitch, yaw_R
	float fwd = mean_range(base, 0u, min(motor_count, chunk));
	float vert = mean_range(base, chunk, min(motor_count, 2u * chunk));
	float yaw_l = mean_range(base, 2u * chunk, min(motor_count, 3u * chunk));
	float pitch = mean_range(base, 3u * chunk, min(motor_count, 4u * chunk));
	float yaw_r = mean_range(base, 4u * chunk, motor_count);
	float yaw = (yaw_l - yaw_r) * 2.2;
	float roll = (yaw_l + yaw_r) * 0.2;

	outv[a * channel_count + 0u] = tanh_approx(fwd * 1.5);
	if (channel_count > 1u) {
		outv[a * channel_count + 1u] = tanh_approx(vert * 1.25);
	}
	if (channel_count > 2u) {
		outv[a * channel_count + 2u] = tanh_approx(yaw);
	}
	if (channel_count > 3u) {
		outv[a * channel_count + 3u] = tanh_approx(pitch);
	}
	if (channel_count > 4u) {
		outv[a * channel_count + 4u] = tanh_approx(roll);
	}
}
