#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(binding=0) uniform sampler2D fine_faces;
layout(binding=1) uniform sampler2D coarse_faces;
layout(binding=2) uniform sampler2D coarse_pressure;
layout(binding=3) uniform sampler2D pressure;
layout(r32f,binding=4) uniform writeonly image2D result;
bool inside(ivec2 p,ivec2 n) {return all(greaterThanEqual(p,ivec2(0))) && all(lessThan(p,n));}
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy), n=imageSize(result);
    if(any(greaterThanEqual(p,n))) return;
    ivec2 c=p/2, size=textureSize(coarse_faces,0);
    ivec2 side=p%2, dx=ivec2(side.x*2-1,0), dy=ivec2(0,side.y*2-1);
    vec4 w=texelFetch(coarse_faces,c,0);
    float error=0.0;
    if(any(greaterThan(w,vec4(0))) && any(greaterThan(texelFetch(fine_faces,p,0),vec4(0)))) {
        // Cell-centered bilinear weights (9,3,3,1); trace open faces for every tap.
        float sum=9.0*texelFetch(coarse_pressure,c,0).r, mass=9.0;
        // Outside the domain the prescribed correction is zero. At solid
        // faces the normal derivative is zero, so renormalize remaining taps.
        bool exterior_x=!inside(c+dx,size) && w[side.x]>0;
        bool exterior_y=!inside(c+dy,size) && w[2+side.y]>0;
        if(exterior_x) mass+=3.0;
        if(exterior_y) mass+=3.0;
        if(exterior_x || exterior_y) mass+=1.0;
        bool diagonal=false;
        if(w[side.x]>0 && inside(c+dx,size)) {
            sum+=3.0*texelFetch(coarse_pressure,c+dx,0).r; mass+=3.0;
            diagonal=texelFetch(coarse_faces,c+dx,0)[2+side.y]>0;
        }
        if(w[2+side.y]>0 && inside(c+dy,size)) {
            sum+=3.0*texelFetch(coarse_pressure,c+dy,0).r; mass+=3.0;
            diagonal=diagonal || texelFetch(coarse_faces,c+dy,0)[side.x]>0;
        }
        if(diagonal && inside(c+dx+dy,size)) {sum+=texelFetch(coarse_pressure,c+dx+dy,0).r; mass+=1.0;}
        // Damped coarse correction for partial aggregates at cut boundaries.
        error=0.65*sum/mass;
    }
    imageStore(result,p,vec4(texelFetch(pressure,p,0).r+error));
}
