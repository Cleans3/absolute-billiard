shader_type spatial;
render_mode unshaded, cull_back;
// The wall mirror's glass (06 P26, adhoc-1012a): the room is a cube capture (6 faces in a texture array, face axes = Mirror.FACES)
// box-projected onto the room's walls per pixel from the live eye; avatars come from the per-frame window pass on top.
// The avatar image runs right-to-left as seen from the room, hence the flipped U.

const vec3 F[6] = { vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 1, 0), vec3(0, -1, 0), vec3(0, 0, 1), vec3(0, 0, -1) };
const vec3 U[6] = { vec3(0, 1, 0), vec3(0, 1, 0), vec3(0, 0, 1), vec3(0, 0, -1), vec3(0, 1, 0), vec3(0, 1, 0) };

uniform sampler2DArray room : source_color, filter_linear, repeat_disable;
uniform sampler2D avatars : source_color, filter_linear, repeat_disable;
uniform bool has_room = false;
uniform vec3 cap_pos;      // where the faces were captured from (world)
uniform vec3 box_min;      // the room's interior (world)
uniform vec3 box_max;
uniform vec3 tint : source_color = vec3(0.90, 0.96, 1.0);
uniform float gain = 1.0;

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
	ALBEDO = c * (1.0 - 0.35 * edge);
}
