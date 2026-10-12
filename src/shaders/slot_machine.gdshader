// The bar slot machine: one material for the cabinet, the bulbs and the three drums (docs/plan/02 §3.9).
// Vertex colour = tint, COLOR.a = chasing-bulb mask, UV2 = (bulb phase 0..1 round its loop, steady glow). The cabinet is not in
// the room's lightmap, so a flat fill keeps its dark side readable (same trick as humanoid.gdshader).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform float chase_speed = 0.6;  // loops per second the bulbs run round
uniform float flash = 0.0;        // 0..1 strobe of every bulb (wins)
uniform float glow = 1.0;
uniform float fill = 0.28;
uniform vec3 flash_tint = vec3(1.0, 0.85, 0.35);
instance uniform float blur = 0.0;  // per drum: 1 while it spins, the symbols smear to their average

varying float v_phase;
varying float v_steady;

void vertex() {
	v_phase = UV2.x;
	v_steady = UV2.y;
}

void fragment() {
	vec3 sym = texture(atlas, UV).rgb;
	vec3 avg = vec3(0.62, 0.52, 0.42);
	ALBEDO = COLOR.rgb * mix(sym, avg, blur * 0.85);
	ROUGHNESS = 0.55;
	float pulse = 0.5 + 0.5 * sin(TIME * chase_speed * 6.28318 * 4.0 - v_phase * 6.28318 * 4.0);
	float strobe = flash * step(0.5, fract(TIME * 7.0 + v_phase));
	vec3 e = ALBEDO * fill;
	e += ALBEDO * v_steady * glow * 1.4;
	e += COLOR.rgb * COLOR.a * glow * (0.15 + 1.6 * pulse);
	e += mix(COLOR.rgb, flash_tint, 0.5) * COLOR.a * strobe * 2.5;
	EMISSION = e;
}
