#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(rgba16f,set=0,binding=3) uniform writeonly image2D next_velocity;
struct Stamp { vec4 brush; vec4 force; };
layout(std430,set=0,binding=4) readonly buffer Stamps { Stamp items[]; } stamps;
layout(set=0,binding=5) uniform sampler2D diagnostics;
vec2 acceleration(vec2 uv) {
    vec2 p=(uv-0.5)*params.region.xy+params.region.zw;
    float t=params.dynamics.y;
    vec2 q=(p-params.flow.xy*t*0.3)*params.flow.w;
    vec2 force=vec2(sin(q.x+t*0.13)*cos(q.y-t*0.17),-cos(q.x+t*0.13)*sin(q.y-t*0.17))*params.flow.z;
    for(int i=0;i<int(params.counts.y);i++) {
        Stamp s=stamps.items[i]; vec2 offset=p-s.brush.xy;
        float weight=1.0-smoothstep(0.0,1.0,length(offset)/max(s.brush.z,0.05));
        force+=(s.force.xy+vec2(-offset.y,offset.x)/max(s.brush.z,0.05)*s.brush.w)*weight;
    }
    vec2 h=1.0/vec2(textureSize(velocity_map,0));
    vec2 grad=vec2(
        abs(textureLod(diagnostics,uv+vec2(h.x,0),0).g)-abs(textureLod(diagnostics,uv-vec2(h.x,0),0).g),
        abs(textureLod(diagnostics,uv+vec2(0,h.y),0).g)-abs(textureLod(diagnostics,uv-vec2(0,h.y),0).g));
    vec2 n=grad/max(length(grad),0.0001);
    force+=vec2(n.y,-n.x)*textureLod(diagnostics,uv,0).g*min(cell_size().x,cell_size().y)*params.solver.x;
    return force;
}
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(next_velocity);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 h=1.0/vec2(size),uv=(vec2(id)+0.5)*h;
    vec2 xface=uv+vec2(h.x*0.5,0),zface=uv+vec2(0,h.y*0.5);
    vec2 v=params.flow.xy;
    if(params.counts.z<0.5) {
        v=vec2(velocity_at(backtrace(xface,params.dynamics.x)).x,velocity_at(backtrace(zface,params.dynamics.x)).y);
        v=params.flow.xy+(v-params.flow.xy)*exp(-(params.dynamics.w+params.behavior.x)*params.dynamics.x);
    }
    v+=vec2(acceleration(xface).x,acceleration(zface).y)*params.dynamics.x;
    v*=min(1.0,params.behavior.y/max(length(v),0.0001));
    if(solid_distance(uv)<=0.0 || solid_distance(uv+vec2(h.x,0))<=0.0) { v.x=0; }
    if(solid_distance(uv)<=0.0 || solid_distance(uv+vec2(0,h.y))<=0.0) { v.y=0; }
    imageStore(next_velocity,id,vec4(v,0,0));
}
