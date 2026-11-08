#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(set=0,binding=3) uniform sampler2D previous_state;
layout(rgba16f,set=0,binding=4) uniform writeonly image2D predicted_state;
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(predicted_state);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),p=(uv-0.5)*params.region.xy+params.region.zw;
    float density=0;
    if(solid_distance(uv)>0.0) {
        vec2 source=backtrace(uv,params.dynamics.x);
        density=(params.counts.z>0.5 || outside(source)) ? initial_density(p-params.flow.xy*params.dynamics.y)
                                                               : density_sample(previous_state,source);
    }
    imageStore(predicted_state,id,vec4(density,0,0,0));
}
