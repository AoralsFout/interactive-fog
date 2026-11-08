shader_type spatial;

uniform vec4 ground_color : source_color = vec4(0.055, 0.08, 0.105, 1.0);
uniform vec4 grid_color : source_color = vec4(0.095, 0.15, 0.18, 1.0);
uniform float grid_size = 1.0;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// 导数抗锯齿的地面刻度，便于观察尾流的真实移动速度。
	vec2 grid = world_position.xz / grid_size;
	vec2 derivative = max(fwidth(grid), vec2(0.0001));
	vec2 line = abs(fract(grid - 0.5) - 0.5) / derivative;
	float strength = 1.0 - min(min(line.x, line.y), 1.0);
	ALBEDO = mix(ground_color.rgb, grid_color.rgb, strength * 0.55);
	ROUGHNESS = 0.82;
	METALLIC = 0.15;
}
