#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(set=0,binding=3) uniform sampler2D diagnostics;
layout(set=0,binding=4) uniform sampler2D previous_pressure;
layout(r32f,set=0,binding=5) uniform writeonly image2D next_pressure;
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(next_pressure);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),h=1.0/vec2(size),cell=cell_size();
    if(solid_distance(uv)<=0.0) { imageStore(next_pressure,id,vec4(0)); return; }
    float total=0,weights=0;
    for(int axis=0;axis<2;axis++) {
        for(int side=-1;side<=1;side+=2) {
            ivec2 offset=axis==0 ? ivec2(side,0) : ivec2(0,side);
            vec2 neighbor=uv+vec2(offset)*h;
            if(solid_distance(neighbor)<=0.0) { continue; }
            float w=1.0/(cell[axis]*cell[axis]);
            float p=outside(neighbor) ? 0.0 : texelFetch(previous_pressure,id+offset,0).r;
            total+=w*p; weights+=w;
        }
    }
    imageStore(next_pressure,id,vec4((total-texelFetch(diagnostics,id,0).r)/max(weights,0.0001)));
}
