shader_type spatial;
render_mode unshaded, cull_back;
// The wall mirror's glass (06 P26, adhoc-1012a): the room is a cube capture (6 faces in a texture array, face axes = Mirror.FACES)
// box-projected onto the room's walls per pixel from the live eye; avatars come from the per-frame window pass on top.
// The avatar image runs right-to-left as seen from the room, hence the flipped U.

const vec3 F[6] = { vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 1, 0), vec3(0, -1, 0), vec3(0, 0, 1), vec3(0, 0, -1) };
const vec3 U[6] = { vec3(0, 1, 0), vec3(0, 1, 0), vec3(0, 0, 1), vec3(0, 0, -1), vec3(0, 1, 0), vec3(0, 1, 0) };

uniform sampler2DArray room : source_color, filter_linear_mipmap, repeat_disable;  // mipmapped: the faces are minified from a distance
uniform sampler2D avatars : source_color, filter_linear, repeat_disable;
uniform bool has_room = false;
uniform vec3 cap_pos;      // where the faces were captured from (world)
uniform vec3 box_min;      // the room's interior (world)
uniform vec3 box_max;
uniform vec3 tint : source_color = vec3(0.90, 0.96, 1.0);
uniform float gain = 1.0;
uniform float blood : hint_range(0.0, 1.0) = 0.0;  // Mirror.set_blood: 0 clean, 1 splattered, smeared and dripping

varying vec3 world_pos;
varying vec3 world_n;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec3 room_at(vec3 d) {
	vec3 a = abs(d);
	int i = a.x >= a.y && a.x >= a.z ? (d.x > 0.0 ? 0 : 1) : (a.y >= a.z ? (d.y > 0.0 ? 2 : 3) : (d.z > 0.0 ? 4 : 5));
	vec3 r = cross(U[i], -F[i]);  // the capture camera's right
	vec2 p = vec2(dot(d, r), dot(d, U[i])) / dot(d, F[i]);
	return texture(room, vec3(0.5 + 0.5 * p.x, 0.5 - 0.5 * p.y, float(i))).rgb;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + 11.7;
		a *= 0.5;
	}
	return s;
}

// Blood on the glass: splatter that spreads with the amount, one hand smear, and drips running down from the top edge (UV.y grows
// downward). Returns the coverage 0..1; `tone` is the wetness for the shade.
float blood_cover(vec2 uv, float amount, out float tone) {
	vec2 q = vec2(uv.x * 4.5, uv.y * 3.0);  // the glass is 3:2: square blobs
	float n = fbm(q * 3.0);
	float t = mix(0.86, 0.50, amount);
	float splat = smoothstep(t, t + 0.04, n) * step(0.001, amount);
	// the smear: a diagonal swipe with streaky edges
	vec2 sp = uv - vec2(0.60, 0.46);
	float along = dot(sp, normalize(vec2(0.8, -0.6)));
	float across = dot(sp, normalize(vec2(0.6, 0.8)));
	float streak = vnoise(vec2(across * 90.0, along * 5.0));
	float smear = (1.0 - smoothstep(0.10, 0.16, abs(across))) * (1.0 - smoothstep(0.35, 0.55, abs(along)));
	smear *= smoothstep(0.30, 0.70, streak + amount * 0.5) * smoothstep(0.15, 0.55, amount);
	// the drips: 36 columns, each with its own length, width and wobble; the longer the amount, the further they have run
	float col = floor(uv.x * 36.0);
	float h = hash21(vec2(col, 7.0));
	float cx = (col + 0.5 + (h - 0.5) * 0.5) / 36.0;
	float len = (0.2 + 0.8 * hash21(vec2(col, 11.0))) * amount * 1.1;
	float w = mix(0.004, 0.011, hash21(vec2(col, 3.0))) * (1.0 - 0.45 * clamp(uv.y / max(len, 0.01), 0.0, 1.0));
	float dx = abs(uv.x - cx - sin(uv.y * 38.0 + h * 6.28) * 0.0025);
	float drip = (1.0 - smoothstep(w, w + 0.004, dx)) * (1.0 - smoothstep(len - 0.03, len, uv.y)) * step(h, 0.5 + 0.45 * amount);
	float bead = (1.0 - smoothstep(w * 1.4, w * 1.4 + 0.004, dx)) * (1.0 - smoothstep(0.0, 0.02, abs(uv.y - len + 0.012))) * step(h, 0.5 + 0.45 * amount);  // the bead at a drip's end
	float top = smoothstep(0.30 * amount, 0.0, uv.y + (fbm(uv * 9.0) - 0.4) * 0.25) * step(0.001, amount);  // it starts at the frame
	tone = vnoise(uv * 55.0);
	return clamp(max(max(max(splat, smear), max(drip, bead)), top), 0.0, 1.0);
}

void fragment() {
	vec3 c = vec3(0.0);
	if (has_room) {
		vec3 rd = reflect(normalize(world_pos - CAMERA_POSITION_WORLD), world_n);
		vec3 tf = max((box_max - world_pos) / rd, (box_min - world_pos) / rd);
		float t = min(min(tf.x, tf.y), tf.z);
		c = room_at(world_pos + rd * t - cap_pos);
	}
	vec4 av = texture(avatars, vec2(1.0 - UV.x, UV.y));
	c = mix(c, av.rgb, av.a) * tint * gain;
	vec2 e = abs(UV - 0.5) * 2.0;
	float edge = smoothstep(0.78, 1.0, max(e.x, e.y));  // the silvering darkens toward the frame
	c *= 1.0 - 0.35 * edge;
	if (blood > 0.0) {
		float tone;
		float cover = blood_cover(UV, blood, tone);
		vec3 wet = mix(vec3(0.20, 0.0, 0.015), vec3(0.52, 0.02, 0.03), tone) + 0.18 * pow(tone, 5.0);
		c = mix(c, wet, cover * 0.94);
	}
	ALBEDO = c;
}
