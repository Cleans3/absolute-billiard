shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled;
// Materialise / dematerialise glow (docs/plan/10 §3.6): an additive overlay (`GeometryInstance3D.material_overlay`) that rides ON TOP of
// whatever material the mesh already has, so every ball type (gimmicks and the cue ball included) and the saucer use the one shader.
// `Materialise.set_progress` drives `progress` 0 (gone) -> 1 (solid) per instance and fades the mesh itself with the instance
// `transparency`; here: a hologram shell (fresnel + scan lines) while the thing is not yet there, and a bright band that climbs it.

instance uniform float progress : hint_range(0.0, 1.0) = 1.0;
uniform vec4 tint : source_color = vec4(0.45, 0.95, 1.0, 1.0);
uniform float scan_lines = 18.0;

varying float v_h;

void vertex() {
	v_h = clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);  // object-space normal: 0 underside .. 1 top, whatever the mesh or its scale
}

void fragment() {
	float front = progress * 1.5 - 0.25;  // the band starts below the object and ends above it
	float band = exp(-pow((v_h - front) * 6.0, 2.0));
	float lines = 0.5 + 0.5 * step(0.5, fract(v_h * scan_lines - TIME * 2.0));
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
	float shell = (1.0 - progress) * (fres * 1.2 + lines * 0.25);
	ALBEDO = tint.rgb * (band * 1.6 + shell);
	ALPHA = 1.0;
}
