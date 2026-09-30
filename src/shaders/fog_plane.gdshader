shader_type spatial;
// Bar haze (04 §2.2, 07 §2): additive, unshaded, ALU-only scrolling value noise. No depth/screen texture
// read, no shadows, no fog of its own — a stack of these quads stands in for volumetric fog, which the
// Mobile renderer does not have.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(0.55, 0.42, 0.32);
uniform float density : hint_range(0.0, 1.0) = 0.10;
uniform vec2 scroll = vec2(0.015, 0.008);
uniform float scale = 3.0;
instance uniform float phase = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 uv = UV * scale + scroll * (TIME + phase);
	float n = vnoise(uv) * 0.6 + vnoise(uv * 2.3 + 7.1) * 0.4;
	vec2 e = min(UV, 1.0 - UV) * 2.0;
	float edge = smoothstep(0.0, 0.5, min(e.x, e.y));
	ALBEDO = tint * n * edge * density;
}
