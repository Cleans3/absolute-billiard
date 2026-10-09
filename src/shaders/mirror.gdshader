shader_type spatial;
render_mode unshaded, cull_back;
// The wall mirror's glass (06 P26): the SubViewport that looks through the glass from the far side of the wall.
// Its image runs right-to-left as seen from the room, hence the flipped U.

uniform sampler2D view : source_color, filter_linear, repeat_disable;
uniform vec3 tint : source_color = vec3(0.90, 0.96, 1.0);
uniform float gain = 1.5;

void fragment() {
	vec3 c = texture(view, vec2(1.0 - UV.x, UV.y)).rgb * tint * gain;
	vec2 e = abs(UV - 0.5) * 2.0;
	float edge = smoothstep(0.78, 1.0, max(e.x, e.y));  // the silvering darkens toward the frame
	ALBEDO = c * (1.0 - 0.35 * edge);
}
