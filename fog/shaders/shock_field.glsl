#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

struct Shock { vec4 front; vec4 shape; };
layout(std430,set=0,binding=3) readonly buffer Shocks { Shock items[]; } shocks;
layout(rgba16f,set=0,binding=4) uniform writeonly image2D shock_velocity;
layout(push_constant,std430) uniform ActiveBounds { ivec2 origin; ivec2 extent; int members; float scale; ivec2 pad; } active_bounds;

// 对每个主时间步只构建一次可见性，子步复用此速度纹理。
float visible_from(vec2 center,vec2 target,float cell) {
    if(params.counts.x<0.5) { return 1.0; }
    vec2 ray=target-center;
    float distance=length(ray),travel=0.0;
    vec2 center_uv=(center-params.region.zw)/params.region.xy+0.5;
    if(solid_distance(center_uv)<=0.0) { return 0.0; }
    if(distance<cell) { return 1.0; }
    vec2 direction=ray/distance;
    for(int i=0;i<48;i++) {
        vec2 uv=(center+direction*travel-params.region.zw)/params.region.xy+0.5;
        float gap=solid_distance(uv);
        if(gap<cell*0.35) { return 0.0; }
        travel+=max(gap*0.8,cell*0.2);
        if(travel>=distance) { return 1.0; }
    }
    return 0.0;
}
vec2 impulse_at(vec2 uv,float cell) {
    vec2 p=(uv-0.5)*params.region.xy+params.region.zw;
    vec2 result=vec2(0);
    vec2 cut_velocity=vec2(0);
    float best_cut=0.0;
    for(int i=0;i<int(params.solver.y);i++) {
        if ((active_bounds.members & (1 << i)) == 0) { continue; }
        Shock s=shocks.items[i];
        if(s.shape.z>0.5) {
            vec2 segment=s.shape.xy-s.front.xy;
            float along=clamp(dot(p-s.front.xy,segment)/max(dot(segment,segment),0.000001),0.0,1.0);
            vec2 source=s.front.xy+segment*along;
            vec2 offset=p-source;
            float distance=length(offset),width=max(s.front.z,cell*2.0);
            float score=s.front.w*(1.0-smoothstep(0.0,width,distance));
            if(distance>=width || score<=best_cut) { continue; }
            float visibility=visible_from(source,p,cell);
            if(visibility<=0.0) { continue; }
            float profile=min(distance/(width*0.3),1.0)*(1.0-smoothstep(width*0.55,width,distance));
            cut_velocity=offset/max(distance,0.0001)*s.front.w*profile;
            best_cut=score;
            continue;
        }
        vec2 delta=p-s.front.xy;
        float r=length(delta),radius=max(s.front.z,cell);
        float width=max(s.shape.x,cell*2.0);
        if(r>=radius+width) { continue; }
        float taper=1.0-smoothstep(radius,radius+width,r);
        float speed=s.front.w*min(r/radius,1.0)*taper;
        result+=delta/max(r,0.0001)*speed*visible_from(s.front.xy,p,cell);
    }
    result=(result+cut_velocity)*active_bounds.scale;
    vec3 obstacle=textureLod(obstacle_map,uv,0).rgb;
    float guide=1.0-smoothstep(0.0,max(cell*2.0,0.25),obstacle.r);
    result-=obstacle.gb*min(dot(result,obstacle.gb),0.0)*guide;
    return result;
}
void main() {
    ivec2 local_id=ivec2(gl_GlobalInvocationID.xy);
    if(any(greaterThanEqual(local_id,active_bounds.extent))) { return; }
    ivec2 id=active_bounds.origin+local_id, size=imageSize(shock_velocity);
    vec2 h=1.0/vec2(size),uv=(vec2(id)+0.5)*h;
    float cell=min(params.region.x*h.x,params.region.y*h.y);
    vec2 v=vec2(impulse_at(uv+vec2(h.x*0.5,0),cell).x,
                impulse_at(uv+vec2(0,h.y*0.5),cell).y);
    if(solid_distance(uv)<=0.0 || solid_distance(uv+vec2(h.x,0))<=0.0) { v.x=0; }
    if(solid_distance(uv)<=0.0 || solid_distance(uv+vec2(0,h.y))<=0.0) { v.y=0; }
    imageStore(shock_velocity,id,vec4(v,velocity_at(uv)));
}
