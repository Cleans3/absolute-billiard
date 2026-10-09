shader_type canvas_item;
// The Skins screen's bar turntable (polish 2 C2): `sheet` is src/tools/render_bar_previews.gd's panorama, a full turn of the
// room in cylindrical projection folded into `rows` stacked rows. The picture shows `view` of a turn and `phase`
// (0..1) slides it round, so the room spins with no frame blending and no 3D on the phone.

uniform sampler2D sheet : filter_linear, repeat_disable;
uniform int rows = 2;
uniform float view = 0.3;
uniform float phase = 0.0;
uniform vec2 sheet_px = vec2(1024.0, 752.0);

void fragment() {
	float a = fract(phase + (UV.x - 0.5) * view);
	float n = float(rows);
	float row = floor(a * n);
	float x = a * n - row;
	vec2 half_texel = 0.5 / vec2(sheet_px.x, sheet_px.y / n);
	vec2 uv = vec2(clamp(x, half_texel.x, 1.0 - half_texel.x), (row + clamp(UV.y, half_texel.y, 1.0 - half_texel.y)) / n);
	COLOR = texture(sheet, uv);
}
