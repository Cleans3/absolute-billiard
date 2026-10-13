shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
// A dark open box seen from inside (docs/plan/10 §3.6): the pit under the table's bed (clean-up) and the trapdoor shaft. Unlit, so it
// reads as depth: a warm dark at the lip fading to pure black `depth` metres down (object y = 0 at the lip). No texture, no light.

uniform vec4 top_color : source_color = vec4(0.11, 0.08, 0.06, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float depth = 1.0;

varying float v_k;

void vertex() {
	v_k = clamp(-VERTEX.y / max(depth, 0.001), 0.0, 1.0);
}

void fragment() {
	ALBEDO = mix(top_color.rgb, bottom_color.rgb, smoothstep(0.0, 1.0, v_k));
}
