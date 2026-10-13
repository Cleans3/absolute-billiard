shader_type spatial;
render_mode cull_disabled;
// Wet pulsing flesh for the monster under the floor (docs/plan/09 §3.8): one material, no texture reads, no screen-texture. Colour runs from
// `base_color` at `depth_top` to `deep_color` at `depth_bottom` (object-space y), ribs and veins are sums of sines, the surface breathes
// along its normal. `clock` is seconds, driven by the script so a preview is repeatable.

uniform vec4 base_color : source_color = vec4(0.62, 0.16, 0.18, 1.0);
uniform vec4 deep_color : source_color = vec4(0.16, 0.015, 0.05, 1.0);
uniform vec4 vein_color : source_color = vec4(0.30, 0.03, 0.11, 1.0);
uniform vec4 glow_color : source_color = vec4(0.9, 0.12, 0.14, 1.0);
uniform float depth_top = 0.0;
uniform float depth_bottom = -7.5;
uniform float pulse_amp = 0.035;
uniform float pulse_hz = 0.7;
uniform float wet = 0.85;
uniform float clock = 0.0;

varying vec3 obj_pos;
varying float depth01;

void vertex() {
	obj_pos = VERTEX;
	depth01 = clamp((VERTEX.y - depth_top) / (depth_bottom - depth_top), 0.0, 1.0);
	float wave = sin(clock * pulse_hz * 6.2831853 + VERTEX.y * 1.7 + atan(VERTEX.z, VERTEX.x) * 2.0);
	VERTEX += NORMAL * wave * pulse_amp;
}

void fragment() {
	float ang = atan(obj_pos.z, obj_pos.x);
	float ribs = 0.5 + 0.5 * sin(obj_pos.y * 5.5 + sin(ang * 3.0 + clock * 0.4) * 0.8);
	float v1 = sin(ang * 7.0 + obj_pos.y * 2.3 + sin(obj_pos.y * 5.0) * 1.5);
	float v2 = sin(ang * 11.0 - obj_pos.y * 3.1 + 1.7);
	float veins = smoothstep(0.82, 0.97, max(v1, v2) * 0.5 + 0.5);
	vec3 col = mix(base_color.rgb, deep_color.rgb, pow(depth01, 0.8));
	col = mix(col, col * 1.35, ribs * 0.35);
	col = mix(col, vein_color.rgb, veins * 0.6);
	ALBEDO = col;
	ROUGHNESS = mix(0.55, 0.15, wet * (0.6 + 0.4 * ribs));
	SPECULAR = 0.6;
	RIM = 0.3;
	RIM_TINT = 0.5;
	EMISSION = glow_color.rgb * (0.05 + 0.25 * depth01) * (0.7 + 0.3 * sin(clock * pulse_hz * 6.2831853));
}
