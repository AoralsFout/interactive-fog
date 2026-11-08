shader_type canvas_item;

uniform sampler2D field_texture : filter_linear, repeat_disable;
uniform sampler2D obstacle_texture : filter_linear, repeat_disable;
// 0 密度，1 速度，2 有符号距离；三个视图共用同一份 GPU 状态。
uniform int mode = 0;

void fragment() {
	vec4 field = texture(field_texture, UV);
	vec4 obstacle = texture(obstacle_texture, UV);
	vec3 color = mix(vec3(0.02, 0.05, 0.07), vec3(0.58, 0.85, 0.88), min(field.r, 1.0));
	// 大于基准密度的压缩环用暖色显示，避免直接饱和成白色而看不出堆积强度。
	color = mix(color, vec3(1.0, 0.52, 0.12), 1.0 - exp(-max(field.r - 1.0, 0.0)));
	if (mode == 1) {
		color = vec3(field.g * 0.15 + 0.5, field.b * 0.15 + 0.5, length(field.gb) * 0.2);
	} else if (mode == 2) {
		color = vec3(0.12, 0.55, 0.6) * clamp(obstacle.r * 0.6, 0.0, 1.0);
		color += vec3(0.08) * step(0.88, fract(max(obstacle.r, 0.0) * 2.0));
	}
	if (obstacle.r <= 0.0) { color = vec3(0.27, 0.18, 0.15); }
	COLOR = vec4(color, 1.0);
}
