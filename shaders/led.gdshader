shader_type spatial;
render_mode unshaded, cull_disabled;

// LED advertising ribbon / big electronic screen.
//
// Draws a SubViewport texture unlit so the panel reads as a real emissive LED
// surface rather than a lit piece of plastic. `scroll_speed` turns a board into
// a moving advertising ribbon; the scoreboard leaves it at zero. Presentation
// only - this shader has no collision and touches no gameplay state.

uniform sampler2D panel_tex : source_color, filter_linear_mipmap;
uniform float scroll_speed = 0.0;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform float brightness = 1.3;
uniform bool flip_vertical = false;

void fragment() {
	float v = flip_vertical ? 1.0 - UV.y : UV.y;
	vec2 uv = vec2(fract(UV.x * uv_scale.x + TIME * scroll_speed), v * uv_scale.y);
	vec3 c = texture(panel_tex, uv).rgb;
	ALBEDO = c * brightness;
}
