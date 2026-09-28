shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Subtle stadium-crowd sway.
//
// Every spectator is one MultiMesh instance, and INSTANCE_ID gives each of them
// its own phase. That means the whole stand breathes in a single draw call with
// no per-frame CPU work at all, which is what keeps it mobile friendly.
uniform float sway_amplitude : hint_range(0.0, 0.4) = 0.04;
uniform float sway_speed : hint_range(0.0, 6.0) = 1.3;

void vertex() {
	// NORMAL is deliberately left alone. The sway is a few centimetres on a tiny
	// seated silhouette, so its normal barely changes and the lighting does not
	// need recalculating - which is also what keeps this free on mobile.
	float phase = float(INSTANCE_ID) * 1.7;
	VERTEX.y += sin(TIME * sway_speed + phase) * sway_amplitude;
}

void fragment() {
	// The MultiMesh instance colour carries the shirt colour, so one draw call
	// can hold a whole mixed crowd.
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.95;
	SPECULAR = 0.0;
}
