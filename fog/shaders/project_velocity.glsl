#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(set=0,binding=3) uniform sampler2D pressure;
layout(rgba16f,set=0,binding=4) uniform writeonly image2D next_velocity;
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(next_velocity);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),h=1.0/vec2(size),cell=cell_size();
    vec2 v=texelFetch(velocity_map,id,0).rg;
    float p=texelFetch(pressure,id,0).r;
    for(int axis=0;axis<2;axis++) {
        ivec2 offset=axis==0 ? ivec2(1,0) : ivec2(0,1);
        vec2 neighbor=uv+vec2(offset)*h;
        if(solid_distance(uv)<=0.0 || solid_distance(neighbor)<=0.0) { v[axis]=0; continue; }
        float other=outside(neighbor) ? 0.0 : texelFetch(pressure,id+offset,0).r;
        v[axis]-=(other-p)/cell[axis];
    }
    v*=min(1.0,params.behavior.y/max(length(v),0.0001));
    imageStore(next_velocity,id,vec4(v,0,0));
}
