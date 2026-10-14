shader_type canvas_item;
render_mode blend_mul;
// cut_screen.gdshader without the screen read (adhoc-1014b C6): the wash and the fade to black are both a per-channel multiply of what is
// already on screen, so the GPU multiplies it in the blend unit and the renderer builds no copy of the screen (nor its mip chain). The
// failure's red wash runs on this at every tier; the win's gas blur and swim need the copy, so tier 2 drops them and runs on this too.
// Left out against the mip shader: the wash's additive lift of tint * 0.05 * amount (4 / 255 on black at amount 0.3, 8 at the win's peak of
// 0.67), and the blur / wobble; everything else matches it to 3 decimals (checked on a colour field).
uniform vec3 tint : source_color = vec3(1.0, 0.0, 0.0);
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float dark : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float vignette = smoothstep(0.9, 0.2, distance(SCREEN_UV, vec2(0.5)));
	vec3 f = mix(vec3(1.0), tint * 1.6, amount) * mix(1.0, vignette, dark * 0.6) * (1.0 - dark);
	COLOR = vec4(f, 1.0);
}
