#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(rgba16f,set=0,binding=3) uniform writeonly image2D diagnostics;
layout(set=0,binding=4) uniform sampler2D previous_diagnostics;
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(diagnostics);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),h=1.0/vec2(size),cell=cell_size();
    if(solid_distance(uv)<=0.0) { imageStore(diagnostics,id,vec4(0)); return; }
    vec2 v=texelFetch(velocity_map,id,0).rg;
    float left=id.x>0 ? texelFetch(velocity_map,id-ivec2(1,0),0).r : params.flow.x;
    float top=id.y>0 ? texelFetch(velocity_map,id-ivec2(0,1),0).g : params.flow.y;
    float div=(v.x-left)/cell.x+(v.y-top)/cell.y;
    float curl=(velocity_at(uv+vec2(h.x,0)).y-velocity_at(uv-vec2(h.x,0)).y)/(2.0*cell.x)
              -(velocity_at(uv+vec2(0,h.y)).x-velocity_at(uv-vec2(0,h.y)).x)/(2.0*cell.y);
    imageStore(diagnostics,id,vec4(div,curl,texelFetch(previous_diagnostics,id,0).r,0));
}
