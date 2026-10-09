shader_type spatial;
// Every Humanoid's one shared material (08 §2.7): the skins' colours live in the vertices. Same look as the plain
// StandardMaterial3D it replaces (sRGB vertex colour x 0.5 sRGB albedo = 0.214 linear, rough, low specular; the bar's
// key lights are tuned for dark wood, so bright cloth would clip), plus a fill: a share of the albedo as emission, so
// the side of a body the lamps miss reads as dim colour instead of black (06 P26, the look-down body, the mirror).
// Skinning is applied by the engine before `vertex()`.

uniform float albedo_scale = 0.214;
uniform float fill = 0.9;
uniform float floor_glow = 0.03;   // a flat linear glow under everything, so near-black trousers and shoes are not a hole

varying vec3 tint;

void vertex() {
	tint = COLOR.rgb;
}

vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), vec3(lessThan(c, vec3(0.04045))));
}

void fragment() {
	vec3 c = srgb_to_linear(tint) * albedo_scale;
	ALBEDO = c;
	EMISSION = c * fill + vec3(floor_glow);
	ROUGHNESS = 0.85;
	SPECULAR = 0.2;
}
