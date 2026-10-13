shader_type spatial;
render_mode unshaded, cull_back;
// The wall TV's picture (StreamTv, 06 P33 U5): the left half is the first tripod's feed, the right half the ceiling camera's; on tier 2
// (`wide`) one feed, the ceiling camera's, fills the whole glass. A feed shows once it has drawn (`lit`), so a TV that is off, resized
// or just built is black, never a stale or uninitialised frame. The pictures are 8-bit sRGB viewport textures (like the mirror's), so
// they are read as source_color. Nothing is added to the picture: no static, scanlines or tint.

uniform sampler2D feed_a : source_color, filter_linear, repeat_disable;
uniform sampler2D feed_b : source_color, filter_linear, repeat_disable;
uniform vec2 lit = vec2(0.0);       // 1 once the feed has drawn: x = left half, y = right half (or the wide one)
uniform bool wide = false;
uniform float gain = 1.15;          // the room's filmic tonemap tones the unshaded picture down once more

void fragment() {
	vec3 c;
	float on;
	if (wide) {
		c = texture(feed_b, UV).rgb;
		on = lit.y;
	} else if (UV.x < 0.5) {
		c = texture(feed_a, vec2(UV.x * 2.0, UV.y)).rgb;
		on = lit.x;
	} else {
		c = texture(feed_b, vec2((UV.x - 0.5) * 2.0, UV.y)).rgb;
		on = lit.y;
	}
	ALBEDO = c * gain * on;
}
