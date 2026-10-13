shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_schlick_ggx;

// The picture of a hazard on the table (adhoc-1014a G): one thin sheet over the cloth, no collider, no texture file.
//   mode 0  Vacation: water on one side of the shoreline, sand on the other (table-local z)
//   mode 1  Sunken Ship: the cloth is wet round the low corner and a current of chevrons runs toward its pocket
//   mode 2  the pool the sunk corner's leg stands in (a cylinder: the sides are glassy, the top ripples)
// Everything is in table-local metres (the sheet's mesh is built in them), so nothing here knows where the table stands.

uniform int mode = 0;
uniform float shore_z = 0.0;
uniform float water_sign = 1.0;       // which side of the shoreline is water (sign of z - shore_z)
uniform vec2 corner = vec2(0.0);      // the sunk pocket's centre, table-local xz
uniform vec4 holes[6];                // x, z, radius of every pocket hole: the sheet is cut open over them
uniform int hole_count = 6;

varying vec3 lp;
varying vec3 ln;

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

void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}

void fragment() {
	vec2 p = lp.xz;
	for (int i = 0; i < 6; i++) {
		if (i < hole_count && distance(p, holes[i].xy) < holes[i].z) {
			discard;
		}
	}
	vec3 col = vec3(0.0);
	float alpha = 0.0;
	float rough = 0.5;
	float spec = 0.5;
	vec3 emit = vec3(0.0);
	if (mode == 1) {
		vec2 d = normalize(corner);
		vec2 perp = vec2(-d.y, d.x);
		float u = dot(p, d);
		float w = dot(p, perp);
		float near = distance(p, corner);
		float pool = smoothstep(1.7, 0.1, near);
		// chevrons marching to the corner: lanes across the current, one V per period
		float period = 0.95;
		float lane = 0.7;
		float a = fract((u - TIME * 0.7) / period);
		float wc = fract(w / lane + 0.5) - 0.5;
		float v = a - 0.5 + abs(wc) * 0.9;
		float chev = smoothstep(0.05, 0.02, abs(v)) * smoothstep(0.34, 0.27, abs(wc));  // separate arrowheads, not one zigzag
		float reach = smoothstep(3.4, 0.3, near);  // the current is faint across the table and strong at the low corner
		col = mix(vec3(0.04, 0.32, 0.5), vec3(0.6, 0.95, 1.0), chev);
		alpha = clamp(pool * 0.45 + chev * (0.1 + 0.4 * reach), 0.0, 0.75);
		rough = 0.15;
		spec = 0.8;
		emit = col * chev * 0.25;
	} else {
		bool water = mode == 2 || (p.y - shore_z) * water_sign > 0.0;
		float shore = abs(p.y - shore_z);
		if (water) {
			vec2 q = mode == 2 ? lp.xz + vec2(3.0) : p;
			float w1 = vnoise(q * 6.0 + vec2(TIME * 0.35, TIME * 0.2));
			float w2 = vnoise(q * 14.0 - vec2(TIME * 0.5, -TIME * 0.3));
			float wave = w1 * 0.6 + w2 * 0.4;
			col = mix(vec3(0.01, 0.16, 0.42), vec3(0.08, 0.52, 0.78), wave);
			col += pow(smoothstep(0.8, 0.96, w2), 2.0) * 0.35;
			alpha = 0.7 + wave * 0.1;
			if (mode == 2 && abs(ln.y) < 0.5) {
				alpha *= 0.55;
			}
			if (mode == 0) {
				float foam = smoothstep(0.05, 0.0, shore) * (0.65 + 0.35 * sin(TIME * 2.0 + p.x * 9.0));
				col = mix(col, vec3(1.0), foam);
				alpha = mix(alpha, 0.9, foam);
			}
			rough = 0.1;
			spec = 0.9;
			emit = col * 0.12;
		} else {
			float grain = hash21(floor(p * 420.0));
			float dunes = sin(p.x * 9.0 + sin(p.y * 7.0) * 1.5) * 0.5 + 0.5;
			col = mix(vec3(0.5, 0.39, 0.2), vec3(0.72, 0.58, 0.33), dunes * 0.45 + grain * 0.55);
			col *= mix(0.62, 1.0, smoothstep(0.0, 0.14, shore));  // wet sand at the water's edge
			alpha = 0.97;
			rough = 0.96;
			spec = 0.08;
		}
	}
	ALBEDO = col;
	ALPHA = alpha;
	ROUGHNESS = rough;
	SPECULAR = spec;
	EMISSION = emit;
}
