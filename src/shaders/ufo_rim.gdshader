shader_type spatial;
render_mode unshaded, blend_mix, fog_disabled;
// The saucer's rim lights (docs/plan/10 §3.6): sixteen lamps chasing round the ring, unshaded. ALPHA is left at its default
// (1 - the instance `transparency`), so `Materialise.set_progress` dissolves the ring with the rest of the craft.

uniform vec4 lamp : source_color = vec4(1.0, 0.85, 0.35, 1.0);
uniform vec4 idle : source_color = vec4(0.06, 0.12, 0.14, 1.0);
uniform float lamps = 16.0;

varying vec3 v_p;

void vertex() {
	v_p = VERTEX;
}

void fragment() {
	float a = atan(v_p.z, v_p.x) / TAU + 0.5;
	float k = fract(a * lamps - TIME * 1.5);
	float on = smoothstep(0.0, 0.12, k) * (1.0 - smoothstep(0.3, 0.45, k));
	ALBEDO = mix(idle.rgb, lamp.rgb * 2.5, on);
}
