// Full-screen effect driven by the time scale: a light vignette always, more
// vignette and desaturation as time slows or freezes, a faint chromatic edge
// when fast-forwarding.
shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;
uniform float slow_amount = 0.0; // 0 = real time, 1 = frozen
uniform float fast_amount = 0.0; // 0 = real time, 1 = max fast forward

void fragment() {
	vec2 d = SCREEN_UV - 0.5;
	vec2 shift = d * 0.006 * fast_amount;
	vec3 col;
	col.r = texture(screen_texture, SCREEN_UV + shift).r;
	col.g = texture(screen_texture, SCREEN_UV).g;
	col.b = texture(screen_texture, SCREEN_UV - shift).b;

	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(lum), 0.4 * slow_amount);

	float vig = smoothstep(0.4, 0.85, length(d) * 1.2);
	col *= 1.0 - vig * (0.12 + 0.3 * slow_amount);
	COLOR = vec4(col, 1.0);
}
