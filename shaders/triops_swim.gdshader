shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// Triops swim (not fish): rigid carapace, metachronal phyllopod beat, soft abdomen.
// INSTANCE_CUSTOM: r=phase, g=swim_amp 0..1, b=turn -1..1, a=idle_breathe

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform float z_min = -0.95;
uniform float z_max = 0.95;
uniform float y_mid = 0.0;
// Body length param: 0=head(+Z), 1=furca tip(-Z)
uniform float legs_start = 0.08;
uniform float legs_end = 0.52;
uniform float abdomen_start = 0.48;
uniform float leg_rows = 10.0;
uniform float leg_kick = 0.055;
uniform float leg_stroke = 0.038;
uniform float abdomen_flex = 0.028;
uniform float furca_trail = 0.035;


void vertex() {
	float span = max(z_max - z_min, 0.001);
	float along = clamp((z_max - VERTEX.z) / span, 0.0, 1.0);

	float phase = INSTANCE_CUSTOM.r;
	float swim = clamp(INSTANCE_CUSTOM.g, 0.0, 1.0);
	float turn = clamp(INSTANCE_CUSTOM.b, -1.0, 1.0);
	float breathe = INSTANCE_CUSTOM.a;
	float amp = mix(0.22, 1.0, swim);

	vec3 p = VERTEX;

	// --- Phyllopods: underside under the shield, front→back metachronal wave ---
	float under = smoothstep(y_mid + 0.02, y_mid - 0.12, p.y);
	float leg_band = smoothstep(legs_start, legs_start + 0.08, along)
		* (1.0 - smoothstep(legs_end - 0.06, legs_end, along));
	float side = smoothstep(0.02, 0.12, abs(p.x)); // stronger outboard
	float leg_w = under * leg_band * side;
	// Phase lags toward the rear (and slightly outer legs).
	float meta = phase * 2.15 - along * leg_rows * 0.85 - abs(p.x) * 3.0;
	float beat = sin(meta);
	float recover = cos(meta);
	// Kick (dorsoventral) + power stroke (along body).
	p.y += beat * leg_kick * amp * leg_w;
	p.z += recover * leg_stroke * amp * leg_w;
	// Tiny lateral spread on the out-stroke.
	p.x += sign(p.x + 0.0001) * max(beat, 0.0) * 0.012 * amp * leg_w;

	// --- Abdomen: gentle vertical flex only (no fishy lateral S-curve) ---
	float abd = smoothstep(abdomen_start, abdomen_start + 0.2, along);
	float sag = sin(phase * 0.9 + along * 2.8) * abdomen_flex * amp * abd;
	p.y += sag;
	// Mild yaw lean when turning — whole rear, not a traveling wave.
	p.x += turn * 0.05 * abd * amp;

	// --- Furca: soft trailing filaments ---
	float furca = smoothstep(0.78, 0.9, along);
	p.x += sin(phase * 1.1 + along * 4.0) * furca_trail * 0.55 * amp * furca * sign(p.x + 0.0001);
	p.y += cos(phase * 1.3 + along * 3.5) * furca_trail * 0.4 * amp * furca;

	// Idle carapace breathe (very subtle).
	float shield = 1.0 - smoothstep(0.35, 0.55, along);
	p.y += breathe * 0.008 * shield * (1.0 - under);

	VERTEX = p;
}


void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * COLOR.rgb * albedo_tint.rgb;
	ALPHA = tex.a * COLOR.a * albedo_tint.a;
}
