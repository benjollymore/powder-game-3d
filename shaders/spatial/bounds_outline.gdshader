// Dashed outline of the simulation bounds, drawn on a quad just above the ground.
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec4 color : source_color = vec4(0.28, 0.32, 0.4, 0.55);
uniform float band = 0.012;   // line thickness in UV units
uniform float dash = 0.035;   // dash period in UV units

void fragment() {
	vec2 uv = UV - 0.5;
	vec2 a = abs(uv);
	float edge = max(a.x, a.y);
	float in_band = step(0.5 - band, edge);
	// Walk along whichever axis the border runs on for the dash pattern.
	float along = (a.x > a.y) ? uv.y : uv.x;
	float dashed = step(0.5, fract(along / dash));
	ALBEDO = color.rgb;
	ALPHA = color.a * in_band * dashed;
}
