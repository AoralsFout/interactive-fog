shader_type canvas_item;

uniform sampler2D field_texture : filter_linear, repeat_disable;
uniform sampler2D obstacle_texture : filter_linear, repeat_disable;
// 0 密度，1 速度颜色，2 有符号距离，3 密度底色 + 速度箭头。
// 所有视图直接采样同一份 GPU 状态，不为画箭头回读速度数据。
uniform int mode = 3;
uniform vec2 map_pixel_size = vec2(360.0, 300.0);
uniform vec2 area_size = vec2(24.0, 20.0);
uniform float arrow_spacing : hint_range(16.0, 64.0, 1.0) = 26.0;
uniform float arrow_reference_speed : hint_range(0.1, 10.0, 0.1) = 2.0;
uniform float arrow_min_speed : hint_range(0.0, 0.5, 0.01) = 0.04;
uniform float arrow_line_width : hint_range(0.5, 3.0, 0.1) = 1.2;
uniform vec4 arrow_color : source_color = vec4(0.96, 0.98, 0.95, 1.0);

float segment_distance(vec2 point, vec2 start, vec2 end) {
	vec2 segment = end - start;
	float t = clamp(dot(point - start, segment) / max(dot(segment, segment), 0.0001), 0.0, 1.0);
	return length(point - start - segment * t);
}

float arrow_distance(vec2 point, float arrow_length) {
	vec2 tip = vec2(arrow_length * 0.5, 0.0);
	float head = min(arrow_length * 0.4, 6.0);
	float shaft = segment_distance(point, vec2(-arrow_length * 0.5, 0.0), tip);
	float upper = segment_distance(point, tip, tip - vec2(head, head * 0.65));
	float lower = segment_distance(point, tip, tip - vec2(head, -head * 0.65));
	return min(shaft, min(upper, lower));
}

vec3 velocity_arrow(vec3 base_color, vec2 uv) {
	vec2 pixels = max(map_pixel_size, vec2(1.0));
	// 从连续 UV 求像素覆盖，避免跨格流向变化时 SDF 的跳变被误当成抗锯齿宽度。
	float antialias = max(length(fwidth(uv * pixels)) * 0.7071, 0.5);
	vec2 grid = max(floor(pixels / max(arrow_spacing, 1.0)), vec2(1.0));
	vec2 cell = floor(uv * grid);
	vec2 center_uv = (cell + 0.5) / grid;
	vec2 velocity = texture(field_texture, center_uv).gb;
	float speed = length(velocity);
	if (speed <= arrow_min_speed || texture(obstacle_texture, center_uv).r <= 0.0) {
		return base_color;
	}
	// 把世界米/秒转换到图上的方向；即使面板尺寸或区域长宽比改变，箭头仍正确。
	// +X 在右，+Z 在下，与密度纹理的 UV 方向保持一致，不额外翻转 Z。
	vec2 display_velocity = velocity * pixels / max(area_size, vec2(0.001));
	vec2 direction = display_velocity / max(length(display_velocity), 0.0001);
	vec2 offset = (uv - center_uv) * pixels;
	vec2 local = vec2(dot(offset, direction), dot(offset, vec2(-direction.y, direction.x)));
	vec2 pitch = pixels / grid;
	// 长度与速度线性对应，达到参考速度后限幅，避免跨格重叠。
	float arrow_length = min(pitch.x, pitch.y) * 0.8 * min(speed / max(arrow_reference_speed, 0.001), 1.0);
	float distance = arrow_distance(local, arrow_length);
	float half_width = arrow_line_width * 0.5;
	float outline = 1.0 - smoothstep(half_width + 1.0, half_width + 1.0 + antialias, distance);
	float ink = 1.0 - smoothstep(half_width, half_width + antialias, distance);
	// 深色描边让浅色箭头在青色基底与橙色高密度区上都能辨认。
	vec3 color = mix(base_color, vec3(0.015, 0.025, 0.03), outline * 0.9);
	return mix(color, arrow_color.rgb, ink * arrow_color.a);
}

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
	} else if (mode == 3) {
		color = velocity_arrow(color, UV);
	}
	if (obstacle.r <= 0.0) { color = vec3(0.27, 0.18, 0.15); }
	COLOR = vec4(color, 1.0);
}
