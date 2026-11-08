shader_type fog;

uniform sampler2D state_texture : filter_linear, repeat_disable;
uniform sampler2D obstacle_texture : filter_linear, repeat_disable;
uniform sampler2D coordinate_texture : filter_linear, repeat_disable;
uniform sampler3D detail_texture : filter_linear, repeat_enable;
uniform bool use_simulation = false;
uniform vec2 area_size = vec2(24.0,20.0);
uniform vec3 world_origin = vec3(0.0);
uniform float thickness = 0.85;
uniform float density = 2.6;
uniform vec4 fog_albedo : source_color = vec4(0.78,0.87,0.94,1.0);
uniform vec4 fog_emission : source_color = vec4(0.04,0.055,0.07,1.0);
uniform float height_falloff = 1.8;
uniform float edge_fade = 1.25;
uniform float obstacle_fade = 0.18;
uniform float detail_scale = 1.4;
uniform float detail_amount = 0.35;
uniform float detail_sharpness = 0.75;
uniform float detail_warp = 0.65;
uniform float detail_reset_period = 12.0;
uniform float simulation_time = 0.0;

float volume_detail(vec2 material_position,float height) {
	vec3 q=vec3(material_position.x,height*1.7,material_position.y)*detail_scale*0.14;
	float bend=texture(detail_texture,q*0.61+vec3(0.21)).r-0.5;
	return texture(detail_texture,q+vec3(bend,0.0,-bend)*detail_warp*0.4).r;
}

void fog() {
	vec3 local=WORLD_POSITION-world_origin;
	vec2 uv=local.xz/area_size+vec2(0.5);
	vec2 border=(vec2(0.5)-abs(uv-vec2(0.5)))*area_size;
	float boundary=smoothstep(0.0,edge_fade,min(border.x,border.y));
	float amount=1.0,obstacle=1.0;
	vec4 coordinates=vec4(WORLD_POSITION.xz,WORLD_POSITION.xz);
	if(use_simulation) {
		amount=texture(state_texture,uv).r;
		coordinates=texture(coordinate_texture,uv);
		obstacle=smoothstep(0.0,obstacle_fade,texture(obstacle_texture,uv).r);
	}
	// 主要轮廓来自持久密度；三维纹理仅在随流搬运的材质坐标上补充厚度。
	float blend=1.0-abs(fract(simulation_time/detail_reset_period)*2.0-1.0);
	float noise=mix(volume_detail(coordinates.zw,local.y),volume_detail(coordinates.xy,local.y),blend);
	float detail=mix(1.0,mix(0.55,1.25,noise),detail_amount);
	float shaped=pow(max(amount,0.0),mix(1.0,1.65,detail_sharpness));
	float local_height=thickness*mix(0.4,0.75,noise);
	float height=clamp(local.y/max(local_height,0.001),0.0,1.0);
	float vertical=exp(-height*height_falloff)*(1.0-smoothstep(0.45,1.0,height));
	vertical*=step(0.0,local.y)*step(local.y,local_height);
	DENSITY=density*shaped*vertical*boundary*obstacle*detail;
	ALBEDO=fog_albedo.rgb;
	EMISSION=fog_emission.rgb;
}
