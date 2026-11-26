#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(binding=0) uniform sampler2D faces;
layout(binding=1) uniform sampler2D rhs;
layout(binding=2) uniform sampler2D pressure;
layout(r32f,binding=3) uniform writeonly image2D result;
#include "mg_stencil.glslinc"
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy), n=imageSize(result);
    if(any(greaterThanEqual(p,n))) return;
    vec4 w=texelFetch(faces,p,0);
    float diag=dot(w,vec4(1)), old=texelFetch(pressure,p,0).r;
    float r=texelFetch(rhs,p,0).r-laplacian(p,n,w,old);
    imageStore(result,p,vec4(diag>0 ? old-0.72*r/diag : 0.0));
}
