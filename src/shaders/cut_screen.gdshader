shader_type canvas_item;
// The in-room cutscenes' screen pass (docs/plan/09 §3.8): a colour wash (the failure's red, the win's green), a blur (the gas) and a fade to
// black. Its own shader, not player_view's, so the drink effects never pay for the screen's mip chain. Uniforms only; hidden when idle.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform vec3 tint : source_color = vec3(1.0, 0.0, 0.0);
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float blur : hint_range(0.0, 1.0) = 0.0;
uniform float dark : hint_range(0.0, 1.0) = 0.0;
uniform float wobble : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	uv += wobble * 0.012 * vec2(sin(TIME * 2.3 + uv.y * 6.0), cos(TIME * 1.9 + uv.x * 5.0));  // the gas makes the room swim
	vec3 c = textureLod(screen_tex, uv, blur * 5.0).rgb;  // the screen's mip chain is the blur: no extra pass
	c = mix(c, c * tint * 1.6 + tint * 0.05, amount);
	float vignette = smoothstep(0.9, 0.2, distance(SCREEN_UV, vec2(0.5)));
	c *= mix(1.0, vignette, dark * 0.6) * (1.0 - dark);
	COLOR = vec4(c, 1.0);
}
