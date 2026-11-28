#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(binding=0) uniform sampler2D scene_depth;
layout(binding=1) uniform sampler2D density_map;
layout(binding=2) uniform sampler2D obstacle_map;
layout(binding=3) uniform sampler2D coordinate_map;
layout(binding=4) uniform sampler3D detail_map;
layout(rgba16f, binding=5) writeonly uniform image2D scatter;
struct ShadowCaster {
	vec4 world_to_local_x, world_to_local_y, world_to_local_z;
	vec4 half_extents_shape;
};
layout(std140, binding=6) uniform Field {
	vec4 origin_height, area_density_falloff, fades_scale_amount, sharp_warp_time_phase;
	vec4 albedo, emission, ambient, sun_dir, sunlight;
	vec4 spot_pos, spotlight, cone, omni_pos, omnilight, attenuation;
	vec4 terrain_rect, terrain_limits;
	ShadowCaster casters[32]; // FogSimulationGPU.MAX_OBSTACLES
} f;
layout(binding=7) uniform sampler2D terrain_height;
layout(binding=8) uniform sampler2D terrain_tiles;
layout(push_constant, std430) uniform Camera { mat4 inv_vp; vec4 eye; } cam;

vec2 uv_at(vec3 p) {
	return (p.xz - f.origin_height.xz) / f.area_density_falloff.xy + 0.5;
}

bool has_terrain() { return f.terrain_limits.z > 0.5; }

float ground_height(vec2 world_xz) {
	// Match the terrain mesh's 00–11 diagonal, including on the map boundary.
	ivec2 last = textureSize(terrain_height,0)-1;
	vec2 grid = clamp((world_xz-f.terrain_rect.xy)/f.terrain_rect.zw,0.0,1.0)*vec2(last);
	ivec2 cell = min(ivec2(grid),last-1);
	vec2 t = grid-vec2(cell);
	float h00 = texelFetch(terrain_height,cell,0).r;
	float h11 = texelFetch(terrain_height,cell+1,0).r;
	if (t.x>=t.y) {
		float h10 = texelFetch(terrain_height,cell+ivec2(1,0),0).r;
		return h00+(h10-h00)*t.x+(h11-h10)*t.y;
	}
	float h01 = texelFetch(terrain_height,cell+ivec2(0,1),0).r;
	return h00+(h11-h01)*t.x+(h01-h00)*t.y;
}

struct TileRay {
	ivec2 cell, direction;
	vec2 next, spacing;
};

TileRay begin_tiles(vec3 origin, vec3 ray, float enter) {
	ivec2 size = textureSize(terrain_tiles,0);
	vec2 cell_size = f.terrain_rect.zw/vec2(size);
	vec2 p = (origin.xz+ray.xz*enter-f.terrain_rect.xy)/cell_size;
	ivec2 direction = ivec2(sign(ray.xz));
	ivec2 cell = clamp(ivec2(floor(p+vec2(direction)*1e-5)),ivec2(0),size-1);
	vec2 edge = f.terrain_rect.xy+vec2(cell+max(direction,ivec2(0)))*cell_size;
	bvec2 moving = greaterThan(abs(ray.xz),vec2(1e-7));
	vec2 safe_ray = mix(vec2(1.0),ray.xz,moving);
	return TileRay(cell,direction,mix(vec2(1e20),(edge-origin.xz)/safe_ray,moving),
		mix(vec2(0.0),abs(cell_size/safe_ray),moving));
}

bool advance_tile(inout TileRay tiles, float exit_t, float leave) {
	if (exit_t>=leave) return false;
	ivec2 crossed = ivec2(lessThanEqual(tiles.next,vec2(exit_t+1e-5)));
	tiles.cell += crossed*tiles.direction;
	tiles.next += vec2(crossed)*tiles.spacing;
	return all(greaterThanEqual(tiles.cell,ivec2(0))) && all(lessThan(tiles.cell,textureSize(terrain_tiles,0)));
}

bool clip_slab(float position, float direction, vec2 limits, inout float enter, inout float leave) {
	if (abs(direction)<1e-7) return position>=limits.x && position<=limits.y && leave>enter;
	vec2 t = (limits-position)/direction;
	enter = max(enter,min(t.x,t.y));
	leave = min(leave,max(t.x,t.y));
	return leave>enter;
}

float noise_at(vec2 coord, float y) {
	vec3 q = vec3(coord.x, y*1.7, coord.y) * (0.14*f.fades_scale_amount.z);
	float bend = textureLod(detail_map, 0.61*q+0.21, 0).r - 0.5;
	return textureLod(detail_map, q + vec3(bend,0,-bend)*f.sharp_warp_time_phase.y*0.4, 0).r;
}

float extinction(vec3 p) {
	vec2 uv = uv_at(p);
	float y = p.y - (has_terrain() ? ground_height(p.xz) : f.origin_height.y);
	if (has_terrain() && (y<0.0 || y>f.origin_height.w)) return 0.0;
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

const int LIGHT_SEGMENTS = 4;
const float MIN_TRANSMITTANCE = 0.005;

void terrain_integral(vec3 origin, vec3 ray, float enter, float leave, out vec2 segments[LIGHT_SEGMENTS]) {
	TileRay tiles = begin_tiles(origin,ray,enter);
	float ray_start = enter;
	float segments_per_meter = float(LIGHT_SEGMENTS)/(leave-enter);
	for (int i=0; i<LIGHT_SEGMENTS; ++i) segments[i] = vec2(0);
	// At most 32 + 32 tile columns and rows are crossed by one ray.
	for (int tile=0; tile<64; ++tile) {
		float edge = min(leave,min(tiles.next.x,tiles.next.y));
		vec2 bounds = texelFetch(terrain_tiles,tiles.cell,0).rg;
		float first = enter, last = edge;
		if (clip_slab(origin.y,ray.y,bounds+vec2(0.0,f.origin_height.w),first,last)) {
			float spacing = clamp(f.origin_height.w*0.16,0.035,0.18);
			int steps = int(clamp(ceil((last-first)/spacing),1.0,24.0));
			float ds = (last-first)/float(steps);
			for (int i=0; i<steps; ++i) {
				float t = first+(float(i)+0.5)*ds;
				float amount = extinction(origin+ray*t)*ds;
				int segment = min(int((t-ray_start)*segments_per_meter),LIGHT_SEGMENTS-1);
				segments[segment] += vec2(amount,amount*t);
			}
		}
		if (!advance_tile(tiles,edge,leave)) break;
		enter = max(enter,edge);
	}
}

bool terrain_blocks_light(vec3 p, vec3 dir, float reach) {
	float enter = 0.045, leave = reach;
	if (!clip_slab(p.x,dir.x,f.terrain_rect.x+vec2(0.0,f.terrain_rect.z),enter,leave) ||
		!clip_slab(p.z,dir.z,f.terrain_rect.y+vec2(0.0,f.terrain_rect.w),enter,leave)) return false;
	TileRay tiles = begin_tiles(p,dir,enter);
	for (int tile=0; tile<64; ++tile) {
		float edge = min(leave,min(tiles.next.x,tiles.next.y));
		float ceiling = texelFetch(terrain_tiles,tiles.cell,0).g;
		float first = enter, last = edge;
		if (clip_slab(p.y,dir.y,vec2(-1e10,ceiling),first,last)) {
			int steps = int(clamp(ceil((last-first)/0.14),1.0,24.0));
			for (int i=0; i<=steps; ++i) {
				vec3 q = p+dir*mix(first,last,float(i)/float(steps));
				if (q.y+0.015<ground_height(q.xz)) return true;
			}
		}
		if (!advance_tile(tiles,edge,leave)) break;
		enter = max(enter,edge);
	}
	return false;
}

const float SHADOW_BIAS = 0.12;

float caster_visibility(ShadowCaster caster, vec3 p, vec3 to_light, float reach) {
	vec3 extent = caster.half_extents_shape.xyz;
	vec4 position = vec4(p,1.0), direction = vec4(to_light,0.0);
	// Transform the ray into mesh space without renormalizing. The interval
	// parameters still measure world-space distance from the fog sample.
	float enter = SHADOW_BIAS, leave = reach;
	if (!clip_slab(dot(caster.world_to_local_y,position),dot(caster.world_to_local_y,direction),
			vec2(-extent.y,extent.y),enter,leave)) return 1.0;
	vec2 base = vec2(dot(caster.world_to_local_x,position),dot(caster.world_to_local_z,position));
	vec2 ray = vec2(dot(caster.world_to_local_x,direction),dot(caster.world_to_local_z,direction));
	float coverage = 1.0;
	if (caster.half_extents_shape.w>0.5) {
		float a = dot(ray,ray);
		float b = dot(base,ray);
		float c = dot(base,base)-extent.x*extent.x;
		if (a<1e-14) {
			if (c>=0.0) return 1.0;
		} else {
			float discriminant = b*b-a*c;
			if (discriminant<=0.0) return 1.0;
			float root = sqrt(discriminant);
			enter = max(enter,(-b-root)/a);
			leave = min(leave,(-b+root)/a);
			if (leave<=enter) return 1.0;
		}
		float closest = a<1e-14 ? enter : clamp(-b/a,enter,leave);
		coverage = smoothstep(0.0,min(0.12,extent.x),extent.x-length(base+ray*closest));
	} else {
		if (!clip_slab(base.x,ray.x,vec2(-extent.x,extent.x),enter,leave) ||
				!clip_slab(base.y,ray.y,vec2(-extent.z,extent.z),enter,leave)) return 1.0;
		vec2 inset = extent.xz-abs(base+ray*(0.5*(enter+leave)));
		coverage = smoothstep(0.0,min(0.12,min(extent.x,extent.z)),min(inset.x,inset.y));
	}
	// The far intersection faces the light. A thin chord fades out at the silhouette.
	float depth = leave-SHADOW_BIAS;
	return mix(1.0,exp(-1.35*depth),coverage*smoothstep(0.0,0.30,leave-enter));
}

float visibility(vec3 p, vec3 to_light, float reach) {
	if (has_terrain() && terrain_blocks_light(p,to_light,reach)) return 0.0;
	float visible = 1.0;
	for (int i=0; i<int(f.terrain_limits.w); ++i) {
		visible = min(visible,caster_visibility(f.casters[i],p,to_light,reach));
	}
	return visible;
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
	if (energy.w>0) weight *= mix(1.0,visibility(p,dir,d),energy.w);
	return energy.rgb * (3.14159*weight*phase(dir,ray));
}

vec3 direct_light(vec3 p, vec3 ray, vec3 sun) {
	vec3 light = sun * (f.sunlight.w>0 ? mix(1.0,visibility(p,f.sun_dir.xyz,50),f.sunlight.w) : 1.0);
	light += local_light(p,ray,f.spot_pos,f.spotlight,f.attenuation.x,true);
	light += local_light(p,ray,f.omni_pos,f.omnilight,f.attenuation.y,false);
	return light;
}

struct Scattering {
	vec3 direct;
	float transmittance;
};

void scatter_segment(vec2 integral, vec3 origin, vec3 ray, vec3 sun, inout Scattering fog) {
	if (integral.x <= 0.0) return;
	// Shade at the extinction-weighted center of this part of the ray.
	vec3 p = origin+ray*(integral.y/integral.x);
	float transmission = exp(-integral.x);
	fog.direct += fog.transmittance*(1.0-transmission)*direct_light(p,ray,sun);
	fog.transmittance *= transmission;
}

Scattering integrate_flat(vec3 origin, vec3 ray, float enter, float leave, vec3 sun, ivec2 px) {
	float distance_in_fog = leave-enter;
	// Preserve the original sampling on paths up to 4 m and lift the cap on longer paths.
	int steps = int(clamp(ceil(distance_in_fog/0.25),4.0,48.0));
	float ds = distance_in_fog/float(steps);
	float offset = 0.5;
	if (distance_in_fog>4.0) {
		// A stable per-pixel offset breaks up bands from neighboring rays marching in lockstep.
		uint seed = uint(px.x)+65537u*uint(px.y);
		uint state = seed*747796405u+2891336453u;
		uint bits = ((state >> ((state >> 28u)+4u)) ^ state)*277803737u;
		float noise = float((bits >> 22u) ^ bits)*(1.0/4294967296.0);
		offset += (noise-0.5)*0.88*smoothstep(4.0,6.0,distance_in_fog);
	}
	Scattering fog = Scattering(vec3(0),1.0);
	for (int segment=0; segment<LIGHT_SEGMENTS; ++segment) {
		int first = segment*steps/LIGHT_SEGMENTS;
		int end = (segment+1)*steps/LIGHT_SEGMENTS;
		vec2 integral = vec2(0);
		for (int i=first; i<end; ++i) {
			float t = enter+(float(i)+offset)*ds;
			float amount = extinction(origin+ray*t)*ds;
			integral += vec2(amount,amount*t);
		}
		scatter_segment(integral,origin,ray,sun,fog);
		if (fog.transmittance<MIN_TRANSMITTANCE) break;
	}
	return fog;
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
	vec3 low = base-ext, high = base+ext+vec3(0,f.origin_height.w,0);
	if (has_terrain()) { low.y=f.terrain_limits.x; high.y=f.terrain_limits.y; }
	vec3 a = (low-cam.eye.xyz)/safe_ray;
	vec3 b = (high-cam.eye.xyz)/safe_ray;
	vec3 lo = min(a,b), hi = max(a,b);
	float enter = max(0,max(lo.x,max(lo.y,lo.z)));
	float leave = min(length(end_pos-cam.eye.xyz),min(hi.x,min(hi.y,hi.z)));
	vec4 result = vec4(0);
	if (leave>enter && f.area_density_falloff.z>0.0) {
		vec3 sun = f.sunlight.rgb*phase(f.sun_dir.xyz,ray);
		Scattering fog = Scattering(vec3(0),1.0);
		if (has_terrain()) {
			vec2 segments[LIGHT_SEGMENTS];
			terrain_integral(cam.eye.xyz,ray,enter,leave,segments);
			for (int i=0; i<LIGHT_SEGMENTS; ++i) {
				scatter_segment(segments[i],cam.eye.xyz,ray,sun,fog);
				if (fog.transmittance<MIN_TRANSMITTANCE) break;
			}
		} else {
			fog = integrate_flat(cam.eye.xyz,ray,enter,leave,sun,px);
		}
		float alpha = 1.0-fog.transmittance;
		vec3 color = (fog.direct+f.ambient.rgb*alpha)*f.albedo.rgb+f.emission.rgb*alpha;
		result = vec4(color,alpha);
	}
	imageStore(scatter,px,result);
}
