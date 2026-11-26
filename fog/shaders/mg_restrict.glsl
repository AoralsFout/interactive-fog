#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(binding=0) uniform sampler2D faces;
layout(binding=1) uniform sampler2D rhs;
layout(binding=2) uniform sampler2D pressure;
layout(r32f,binding=3) uniform writeonly image2D coarse_rhs;
layout(r32f,binding=4) uniform writeonly image2D correction;
#include "mg_stencil.glslinc"
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy), n=textureSize(faces,0);
    if(any(greaterThanEqual(p,imageSize(coarse_rhs)))) return;
    float sum=0;
    for(int j=0;j<4;j++) {
        ivec2 q=2*p+ivec2(j%2,j/2);
        if(any(greaterThanEqual(q,n))) continue;
        vec4 w=texelFetch(faces,q,0);
        if(any(greaterThan(w,vec4(0))))
            sum+=texelFetch(rhs,q,0).r-laplacian(q,n,w,texelFetch(pressure,q,0).r);
    }
    imageStore(coarse_rhs,p,vec4(0.25*sum));
    imageStore(correction,p,vec4(0));
}
