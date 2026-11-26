#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(binding=0) uniform sampler2D fine_faces;
layout(rgba32f,binding=1) uniform writeonly image2D coarse_faces;
vec4 child(ivec2 p,ivec2 n) {
    if(any(lessThan(p,ivec2(0))) || any(greaterThanEqual(p,n))) return vec4(0);
    return texelFetch(fine_faces,p,0);
}
// A 2x2 aggregate may represent only one connected fluid component.
// In a four-node square with fewer than four edges there are no cycles.
vec4 aggregate(ivec2 base,ivec2 n) {
    vec4 a=child(base,n), b=child(base+ivec2(1,0),n);
    vec4 c=child(base+ivec2(0,1),n), d=child(base+ivec2(1,1),n);
    int cells=int(any(greaterThan(a,vec4(0))))+int(any(greaterThan(b,vec4(0))))
             +int(any(greaterThan(c,vec4(0))))+int(any(greaterThan(d,vec4(0))));
    int links=int(min(a.y,b.x)>0)+int(min(c.y,d.x)>0)+int(min(a.w,c.z)>0)+int(min(b.w,d.z)>0);
    if(cells==0 || links<cells-1) return vec4(0);
    bool last_x=base.x+1==n.x, last_y=base.y+1==n.y;
    // Average open face area, then scale 1/h² to the doubled cell size.
    return vec4(a.x+c.x,last_x?a.y+c.y:b.y+d.y,a.z+b.z,last_y?a.w+b.w:c.w+d.w)*0.125;
}
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy), n=imageSize(coarse_faces);
    if(any(greaterThanEqual(p,n))) return;
    ivec2 fine_size=textureSize(fine_faces,0);
    vec4 w=aggregate(2*p,fine_size);
    const ivec2 dir[4]=ivec2[](ivec2(-1,0),ivec2(1,0),ivec2(0,-1),ivec2(0,1));
    for(int i=0;i<4;i++) {
        ivec2 q=p+dir[i];
        if(w[i]>0 && all(greaterThanEqual(q,ivec2(0))) && all(lessThan(q,n)))
            w[i]=min(w[i],aggregate(2*q,fine_size)[i^1]);
    }
    imageStore(coarse_faces,p,w);
}
