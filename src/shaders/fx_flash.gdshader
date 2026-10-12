shader_type canvas_item;
render_mode blend_add;
// Screen colour flash (docs/plan/10 §3): an additive tint that is strongest at the screen edge so the table stays readable.
// No screen_texture read, so it is a plain fill, not a second post pass (07 §2).

uniform vec4 flash_color : source_color = vec4(1.0);
uniform float amount : hint_range(0.0, 2.0) = 0.0;

void fragment() {
	float edge = smoothstep(0.15, 1.3, length(UV * 2.0 - 1.0));
	COLOR = vec4(flash_color.rgb * amount * mix(0.3, 1.0, edge), 1.0);
}
