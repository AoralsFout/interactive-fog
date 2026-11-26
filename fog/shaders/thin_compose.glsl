#[compute]
#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(binding=0) uniform sampler2D scene_depth;
layout(binding=1) uniform sampler2D scatter;
layout(rgba16f, binding=2) uniform image2D color;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy), size = imageSize(color);
	if (any(greaterThanEqual(px,size))) return;
	float depth = texelFetch(scene_depth,px,0).r;
	// Match the full-resolution depth used by each half-resolution ray.
	vec2 grid = (vec2(px)-1)*0.5, fraction = fract(grid);
	ivec2 base = ivec2(floor(grid)), last = textureSize(scatter,0)-1;
	float total = 0, best_delta = 1e10;
	vec4 fog = vec4(0), closest = vec4(0);
	for (int y=0; y<2; ++y) for (int x=0; x<2; ++x) {
		ivec2 sample_px = clamp(base+ivec2(x,y),ivec2(0),last);
		float other = texelFetch(scene_depth,min(sample_px*2+1,size-1),0).r;
		float diff = abs(other-depth)/max(depth,1e-6);
		vec4 value = texelFetch(scatter,sample_px,0);
		if (diff < best_delta) { best_delta=diff; closest=value; }
		vec2 w = mix(1-fraction,fraction,vec2(x,y));
		float weight = w.x*w.y * (1-smoothstep(0.002,0.015,diff));
		fog += weight*value;
		total += weight;
	}
	fog = total>0.0001 ? fog/total : closest;
	if (fog.a>0) {
		vec4 src = imageLoad(color,px);
		imageStore(color,px,vec4(src.rgb*(1-fog.a)+fog.rgb,src.a));
	}
}
