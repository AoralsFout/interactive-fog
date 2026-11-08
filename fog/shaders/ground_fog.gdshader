shader_type fog;

uniform sampler2D state_texture : filter_linear, repeat_disable;
uniform sampler2D obstacle_texture : filter_linear, repeat_disable;
uniform sampler3D detail_texture : filter_linear, repeat_enable;
uniform bool use_simulation = false;
uniform vec2 area_size = vec2(24.0, 20.0);
uniform vec3 world_origin = vec3(0.0);
uniform float thickness = 1.5;
uniform float density = 2.6;
uniform vec4 fog_albedo : source_color = vec4(0.78, 0.87, 0.94, 1.0);
uniform vec4 fog_emission : source_color = vec4(0.04, 0.055, 0.07, 1.0);
uniform float height_falloff = 1.8;
uniform float edge_fade = 1.25;
uniform float obstacle_fade = 0.18;
uniform float detail_scale = 1.4;
uniform float detail_amount = 0.8;
uniform float detail_speed = 0.32;
uniform vec2 wind_velocity = vec2(0.7, 0.18);
uniform float simulation_time = 0.0;

void fog() {
	vec3 local = WORLD_POSITION - world_origin;
	vec2 uv = local.xz / area_size + vec2(0.5);
	// FogVolume 按包围盒覆盖 froxel，仍须主动把边缘及高度外的密度裁掉。
	vec2 border = (vec2(0.5) - abs(uv - vec2(0.5))) * area_size;
	float boundary = smoothstep(0.0, edge_fade, min(border.x, border.y));
	float field_density = 1.0;
	float obstacle_mask = 1.0;
	if (use_simulation) {
		field_density = texture(state_texture, uv).r;
		obstacle_mask = smoothstep(0.0, obstacle_fade, texture(obstacle_texture, uv).r);
	}
	// 两个频段共享一张小型、预生成的三维噪声纹理，避免逐 froxel 计算昂贵噪声。
	vec3 drift = vec3(wind_velocity.x, 0.09, wind_velocity.y) * simulation_time * detail_speed;
	vec3 noise_uv = (WORLD_POSITION - drift) * detail_scale * 0.075;
	// 主轮廓沿高度保持连贯，避免薄雾中多层独立噪声积分后互相平均，变成均匀薄纱。
	float broad = texture(detail_texture, vec3(noise_uv.x, 0.37, noise_uv.z)).r;
	float fine = texture(detail_texture, noise_uv * 2.07 + vec3(0.17)).r;
	float cloud = smoothstep(0.32, 0.68, broad * 0.75 + fine * 0.25);
	float detail = mix(1.0, cloud, detail_amount);
	// 用同一噪声轻微改变雾顶高度，使贴地雾具有可见的高低起伏，而非平整的半透明盒子。
	float local_thickness = thickness * mix(1.0, mix(0.22, 1.0, cloud), detail_amount);
	float height = clamp(local.y / local_thickness, 0.0, 1.0);
	float vertical = exp(-height * height_falloff) * (1.0 - smoothstep(0.4, 1.0, height));
	vertical *= step(0.0, local.y) * step(local.y, local_thickness);
	DENSITY = density * field_density * vertical * boundary * obstacle_mask * detail;
	ALBEDO = fog_albedo.rgb;
	EMISSION = fog_emission.rgb;
}
