#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Sparse CSR synapse: one thread per neuron×agent; only spiked sources fire edges.
layout(set = 0, binding = 0, std430) restrict buffer IBuf { int i_syn_fp[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer SBuf { uint spiked[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer OffBuf { int offsets[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer TgtBuf { int tgt[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer WBuf { float weight[]; };

layout(set = 0, binding = 5, std430) restrict readonly buffer Params {
	float syn_scale;
	uint neuron_count;
	uint agent_count;
	uint max_edges;
};

const float FP = 1024.0;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	uint total = neuron_count * agent_count;
	if (idx >= total) {
		return;
	}
	if (spiked[idx] == 0u) {
		return;
	}
	uint agent = idx / neuron_count;
	uint neuron = idx % neuron_count;
	int a = offsets[neuron];
	int b = offsets[neuron + 1u];
	int limit = min(b, a + int(max_edges));
	uint base = agent * neuron_count;
	for (int e = a; e < limit; e++) {
		int t = tgt[e];
		if (t < 0) {
			continue;
		}
		int add_fp = int(weight[e] * syn_scale * FP);
		atomicAdd(i_syn_fp[base + uint(t)], add_fp);
	}
}
