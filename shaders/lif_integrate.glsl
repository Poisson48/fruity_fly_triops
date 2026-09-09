#[compute]
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer VBuf { float v[]; };
layout(set = 0, binding = 1, std430) restrict buffer IBuf { int i_syn_fp[]; };
layout(set = 0, binding = 2, std430) restrict buffer RBuf { float refractory[]; };
layout(set = 0, binding = 3, std430) restrict buffer SBuf { uint spiked[]; };

layout(set = 0, binding = 4, std430) restrict readonly buffer Params {
	float dt;
	float inv_tau_m;
	float syn_decay;
	float v_rest;
	float v_thresh;
	float v_reset;
	float t_ref;
	uint neuron_count;
	uint agent_count;
	uint _pad;
};

const float FP = 1024.0;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	uint total = neuron_count * agent_count;
	if (idx >= total) {
		return;
	}

	float ref = refractory[idx];
	float isyn = float(i_syn_fp[idx]) / FP;
	isyn *= syn_decay;
	float vv = v[idx];
	spiked[idx] = 0u;

	if (ref > 0.0) {
		ref -= dt;
		vv = v_reset;
		if (ref < 0.0) {
			ref = 0.0;
		}
		refractory[idx] = ref;
		i_syn_fp[idx] = int(isyn * FP);
		v[idx] = vv;
		return;
	}

	vv += dt * inv_tau_m * ((v_rest - vv) + isyn);
	if (vv >= v_thresh) {
		vv = v_reset;
		refractory[idx] = t_ref;
		isyn *= 0.2;
		spiked[idx] = 1u;
	} else {
		refractory[idx] = 0.0;
	}
	i_syn_fp[idx] = int(isyn * FP);
	v[idx] = vv;
}
