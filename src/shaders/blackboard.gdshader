shader_type spatial;
render_mode unshaded;
// The Blackboard's slate (docs 08 §2.8): chalk dust smudged on a dark board, two chalk dividers, a column rule and the hype
// bar, all drawn analytically in board metres so the quad is one draw call with no texture. The text is Label3D on top.
// Only `hype` ever changes at run time.

uniform vec4 slate : source_color = vec4(0.055, 0.085, 0.075, 1.0);
uniform vec4 chalk : source_color = vec4(0.93, 0.92, 0.85, 1.0);
uniform vec4 bar_fill : source_color = vec4(0.24, 0.88, 1.0, 1.0);
uniform vec2 board_size = vec2(2.34, 1.26);
uniform float hype : hint_range(0.0, 1.0) = 0.0;

const vec2 BAR_MIN = vec2(-1.1, -0.15);  // hype bar rectangle, metres from the board centre (+y up)
const vec2 BAR_MAX = vec2(-0.1, -0.10);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// signed distance to a segment, minus half its thickness
float seg(vec2 p, vec2 a, vec2 b, float t) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - t;
}

float box(vec2 p, vec2 lo, vec2 hi) {
	vec2 c = (lo + hi) * 0.5;
	vec2 d = abs(p - c) - (hi - lo) * 0.5;
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

void fragment() {
	vec2 m = (UV - 0.5) * board_size;
	m.y = -m.y;
	float aa = fwidth(m.x) * 1.5;
	float near = 1.0 - smoothstep(0.002, 0.006, fwidth(m.x));  // chalk grain is only visible up close; it would shimmer at range
	// the board: slate with eraser smears
	float smear = vnoise(m * vec2(2.2, 4.0)) * 0.6 + vnoise(m * 9.0) * 0.4;
	vec3 col = slate.rgb + (smear - 0.5) * 0.05;
	// chalk strokes: dividers (a little wobbly, like a hand drew them) and the column rule
	float wob = 0.004 * sin(m.x * 13.0) + 0.002 * sin(m.x * 41.0);
	float d = seg(m, vec2(-1.1, 0.33 + wob), vec2(1.1, 0.33 + wob), 0.005);
	d = min(d, seg(m, vec2(-1.1, -0.31 - wob), vec2(1.1, -0.31 - wob), 0.005));
	d = min(d, seg(m, vec2(0.0 + wob, 0.29), vec2(0.0 + wob, -0.27), 0.004));
	// the hype bar: a chalk outline with a cyan fill as long as hype
	float outline = abs(box(m, BAR_MIN - 0.01, BAR_MAX + 0.01)) - 0.003;
	d = min(d, outline);
	float fill_x = BAR_MIN.x + (BAR_MAX.x - BAR_MIN.x) * hype;
	float fill = box(m, BAR_MIN, vec2(fill_x, BAR_MAX.y));
	float grain = mix(1.0, 0.55 + 0.45 * hash(floor(m * 450.0)), near);
	float cover = (1.0 - smoothstep(-aa, aa, d)) * grain;
	float filled = (1.0 - smoothstep(-aa, aa, fill)) * step(0.001, hype) * grain;
	col = mix(col, bar_fill.rgb, filled * 0.9);
	col = mix(col, chalk.rgb, cover * 0.85);
	ALBEDO = col;
}
