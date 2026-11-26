#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(binding=0) uniform sampler2D scene_depth;
layout(binding=1) uniform sampler2D density_map;
layout(binding=2) uniform sampler2D obstacle_map;
layout(binding=3) uniform sampler2D coordinate_map;
layout(binding=4) uniform sampler3D detail_map;
layout(rgba16f, binding=5) writeonly uniform image2D scatter;
layout(std140, binding=6) uniform Field {
	vec4 origin_height, area_density_falloff, fades_scale_amount, sharp_warp_time_phase;
	vec4 albedo, emission, ambient, sun_dir, sunlight;
	vec4 spot_pos, spotlight, cone, omni_pos, omnilight, attenuation;
} f;
layout(push_constant, std430) uniform Camera { mat4 inv_vp; vec4 eye; } cam;

vec2 uv_at(vec3 p) {
	return (p.xz - f.origin_height.xz) / f.area_density_falloff.xy + 0.5;
}

float noise_at(vec2 coord, float y) {
	vec3 q = vec3(coord.x, y*1.7, coord.y) * (0.14*f.fades_scale_amount.z);
	float bend = textureLod(detail_map, 0.61*q+0.21, 0).r - 0.5;
	return textureLod(detail_map, q + vec3(bend,0,-bend)*f.sharp_warp_time_phase.y*0.4, 0).r;
}

float extinction(vec3 p) {
	vec2 uv = uv_at(p);
	float y = p.y - f.origin_height.y;
	float amount = textureLod(density_map, uv, 0).r;
	vec4 coords = textureLod(coordinate_map, uv, 0);
	float blend = 1.0-abs(fract(f.sharp_warp_time_phase.z)*2.0-1.0);
	float noise = mix(noise_at(coords.zw,y), noise_at(coords.xy,y), blend);
	float height = f.origin_height.w * mix(mix(0.4,0.75,noise), 0.95, smoothstep(1,3,amount));
	float h = clamp(y/max(height,0.001), 0, 1);
	float vertical = exp(-h*f.area_density_falloff.w)*(1.0-smoothstep(0.45,1,h));
	vec2 border = (0.5-abs(uv-0.5))*f.area_density_falloff.xy;
	float mask = smoothstep(0, f.fades_scale_amount.y, textureLod(obstacle_map,uv,0).r)
		* smoothstep(0, max(f.fades_scale_amount.x,0.0001), min(border.x,border.y));
	float excess = max(amount-1.0,0);
	float shaped = pow(clamp(amount,0,1),mix(1.0,1.65,f.sharp_warp_time_phase.x)) + excess/(1+0.35*excess);
	return f.area_density_falloff.z * mask * shaped * vertical * mix(1.0,mix(0.55,1.25,noise),f.fades_scale_amount.w);
}

// A bounded footprint trace approximates shadows in the shallow layer. The
// simulation SDF has no occluder heights; the demo uses one representative height.
float visibility(vec3 p, vec3 to_light, float reach) {
	float t = 0.12;
	for (int i=0; i<7; ++i) {
		vec3 q = p + t*to_light;
		if (t>=reach || q.y-f.origin_height.y>2.15) break;
		float distance_to_solid = textureLod(obstacle_map,uv_at(q),0).r;
		if (distance_to_solid<0.04) return smoothstep(-0.08,0.04,distance_to_solid);
		t += max(0.08, distance_to_solid);
	}
	return 1;
}

float phase(vec3 dir, vec3 ray) {
	float g = clamp(f.sharp_warp_time_phase.w,-0.95,0.95);
	return (1-g*g) / (12.56637 * pow(1+g*g-2*g*dot(dir,ray),1.5));
}

vec3 local_light(vec3 p, vec3 ray, vec4 pos, vec4 energy, float falloff, bool is_spot) {
	vec3 delta = pos.xyz-p;
	float d = max(length(delta),0.001);
	vec3 dir = delta/d;
	float fade = max(1-pow(d/pos.w,4),0);
	float weight = fade*fade * pow(max(d,1),-falloff);
	if (is_spot) {
		float rim = clamp((1-dot(-dir,f.cone.xyz))/(1-f.cone.w),0,1);
		weight *= 1-pow(rim,1/max(0.001,f.attenuation.z));
	}
	if (weight <= 0) return vec3(0);
	if (energy.w>0) weight *= visibility(p,dir,d);
	return energy.rgb * (3.14159*weight*phase(dir,ray));
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px,imageSize(scatter)))) return;
	ivec2 size = textureSize(scene_depth,0);
	ivec2 full = min(px*2+1,size-1);
	vec2 ndc = (vec2(full)+0.5)/vec2(size)*2-1;
	vec4 end_h = cam.inv_vp*vec4(ndc,texelFetch(scene_depth,full,0).r,1);
	vec3 end_pos = end_h.xyz/end_h.w;
	vec3 ray = normalize(end_pos-cam.eye.xyz);
	vec3 safe_ray = mix(vec3(1e-7),ray,greaterThan(abs(ray),vec3(1e-7)));
	vec3 base = f.origin_height.xyz;
	vec3 ext = vec3(f.area_density_falloff.x,0,f.area_density_falloff.y)*0.5;
	vec3 a = (base-ext-cam.eye.xyz)/safe_ray;
	vec3 b = (base+ext+vec3(0,f.origin_height.w,0)-cam.eye.xyz)/safe_ray;
	vec3 lo = min(a,b), hi = max(a,b);
	float enter = max(0,max(lo.x,max(lo.y,lo.z)));
	float leave = min(length(end_pos-cam.eye.xyz),min(hi.x,min(hi.y,hi.z)));
	vec4 result = vec4(0);
	if (leave>enter) {
		int steps = int(clamp(ceil((leave-enter)/0.25),4,16));
		float ds = (leave-enter)/steps;
		float tau = 0;
		for (int i=0; i<steps; ++i) tau += extinction(cam.eye.xyz+ray*(enter+(i+0.5)*ds))*ds;
		float alpha = 1-exp(-tau);
		vec3 p = cam.eye.xyz+ray*mix(enter,leave,0.65);
		vec3 light = f.ambient.rgb + f.sunlight.rgb * phase(f.sun_dir.xyz,ray) *
			(f.sun_dir.w>0 ? visibility(p,f.sun_dir.xyz,50) : 1);
		light += local_light(p,ray,f.spot_pos,f.spotlight,f.attenuation.x,true);
		light += local_light(p,ray,f.omni_pos,f.omnilight,f.attenuation.y,false);
		result = vec4((light*f.albedo.rgb+f.emission.rgb)*alpha, alpha);
	}
	imageStore(scatter,px,result);
}
