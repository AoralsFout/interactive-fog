#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8) in;
layout(rgba32f,set=0,binding=3) uniform writeonly image2D topology;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy), size = imageSize(topology);
    if (any(greaterThanEqual(id, size))) { return; }
    vec2 h = 1.0 / vec2(size), uv = (vec2(id) + 0.5) * h;
    vec2 cell = params.region.xy * h, weight = 1.0 / (cell * cell);
    const ivec2 offsets[4] = ivec2[](ivec2(-1,0), ivec2(1,0), ivec2(0,-1), ivec2(0,1));
    int mask = 0;
    float denominator = 0.0;
    if (solid_distance(uv) > 0.0) {
        for (int i = 0; i < 4; ++i) {
            vec2 adjacent = uv + vec2(offsets[i]) * h;
            if (solid_distance(adjacent) <= 0.0) { continue; }
            // Open faces add weight, with a prescribed pressure of zero outside the domain.
            denominator += weight[i / 2];
            if (!outside(adjacent)) { mask |= 1 << i; }
        }
    }
    float inverse_weight = 1.0 / max(denominator, 0.0001);
    imageStore(topology, id, vec4(float(mask), weight * inverse_weight, inverse_weight));
}
