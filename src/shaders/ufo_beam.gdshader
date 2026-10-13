shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;
// The set-up saucer's tractor beam (docs/plan/10 §3.6): an open cone, narrow at the saucer (object y = -0.5) and wide at the ball (y = +0.5),
// additive, so it needs no sorting and no light. Stripes turn round the cone and run up it; `strength` fades the whole beam.

uniform vec4 tint : source_color = vec4(0.45, 0.95, 1.0, 1.0);
uniform float strength = 1.0;

varying float v_h;
varying float v_a;

void vertex() {
	v_h = VERTEX.y + 0.5;
	v_a = atan(VERTEX.z, VERTEX.x);
}

void fragment() {
	float stripes = 0.65 + 0.35 * sin(v_a * 6.0 + v_h * 14.0 - TIME * 9.0);
	float soft = pow(1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0), 1.5);
	ALBEDO = tint.rgb * (0.35 + 1.1 * soft) * stripes * mix(1.0, 0.4, v_h) * strength;
	ALPHA = 1.0;
}
