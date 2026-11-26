#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(binding=0) uniform sampler2D topology;
layout(rgba32f,binding=1) uniform writeonly image2D faces;
layout(binding=2) uniform sampler2D obstacle_map;
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy), n=imageSize(faces);
    if(any(greaterThanEqual(p,n))) return;
    vec4 t=texelFetch(topology,p,0);
    // The fine Jacobi stencil stores the neighbor mask and normalized weights.
    int m=int(t.x);
    vec4 open=vec4((m&1)!=0 || p.x==0, (m&2)!=0 || p.x==n.x-1,
                   (m&4)!=0 || p.y==0, (m&8)!=0 || p.y==n.y-1);
    vec2 uv=(vec2(p)+0.5)/vec2(n);
    imageStore(faces,p,textureLod(obstacle_map,uv,0).r<=0.0 ? vec4(0) : open*t.yyzz/t.w);
}
