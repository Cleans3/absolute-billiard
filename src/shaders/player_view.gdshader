shader_type canvas_item;
// One full-screen pass for every player_view_* stat (03 §3.8). EffectManager stats -> uniforms only.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float light_level : hint_range(0.0, 1.0) = 1.0;
uniform float fog_density : hint_range(0.0, 1.0) = 0.0;
uniform float shake_amp : hint_range(0.0, 2.0) = 0.0;
uniform vec3 fog_color : source_color = vec3(0.55, 0.55, 0.6);

void fragment() {
	vec2 uv = SCREEN_UV;
	uv += shake_amp * 0.01 * vec2(sin(TIME * 47.0 + uv.y * 9.0), cos(TIME * 53.0 + uv.x * 7.0));
	vec3 c = texture(screen_tex, uv).rgb;
	float vignette = smoothstep(0.85, 0.15, distance(SCREEN_UV, vec2(0.5)));
	c *= light_level * mix(1.0, vignette, 1.0 - light_level);
	c = mix(c, fog_color * light_level, fog_density);
	COLOR = vec4(c, 1.0);
}
