#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D topology;
layout(set=0,binding=1) uniform sampler2D divergence;
layout(set=0,binding=2) uniform sampler2D previous_pressure;
layout(r32f,set=0,binding=3) uniform writeonly image2D next_pressure;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy), size = imageSize(next_pressure);
    if (any(greaterThanEqual(id, size))) { return; }
    vec4 geometry = texelFetch(topology, id, 0);
    int mask = int(geometry.x);
    float x = 0.0, y = 0.0;
    if ((mask & 1) != 0) { x += texelFetch(previous_pressure, id - ivec2(1,0), 0).r; }
    if ((mask & 2) != 0) { x += texelFetch(previous_pressure, id + ivec2(1,0), 0).r; }
    if ((mask & 4) != 0) { y += texelFetch(previous_pressure, id - ivec2(0,1), 0).r; }
    if ((mask & 8) != 0) { y += texelFetch(previous_pressure, id + ivec2(0,1), 0).r; }
    float rhs = texelFetch(divergence, id, 0).r;
    imageStore(next_pressure, id, vec4(dot(vec2(x,y), geometry.yz) - rhs * geometry.w));
}
