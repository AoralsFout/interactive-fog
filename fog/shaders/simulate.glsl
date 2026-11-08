#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

// 有限幅 MacCormack 搬运：主密度和两组材质坐标共享回溯位置。
layout(set=0,binding=3) uniform sampler2D previous_state;
layout(set=0,binding=4) uniform sampler2D predicted_state;
layout(set=0,binding=5) uniform sampler2D previous_coordinates;
layout(rgba16f,set=0,binding=6) uniform writeonly image2D next_state;
layout(rgba32f,set=0,binding=7) uniform writeonly image2D next_coordinates;
layout(rgba16f,set=0,binding=8) uniform writeonly image2D display_state;
layout(rgba32f,set=0,binding=9) uniform writeonly image2D display_coordinates;
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy),size=imageSize(next_state);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),p=(uv-0.5)*params.region.xy+params.region.zw;
    float dt=params.dynamics.x,time=params.dynamics.y,period=params.pattern.z;
    vec2 source=backtrace(uv,dt);
    float density=texelFetch(predicted_state,id,0).r;
    bool reset=params.counts.z>0.5;
    if(!reset && !outside(source) && solid_distance(uv)>0.0) {
        float reverse=density_sample(predicted_state,backtrace(uv,-dt));
        float corrected=density+0.5*(texelFetch(previous_state,id,0).r-reverse);
        ivec2 base=ivec2(floor(source*vec2(size)-0.5));
        float lower=1e10,upper=-1e10;
        for(int y=0;y<=1;y++) {
            for(int x=0;x<=1;x++) {
                float d=texelFetch(previous_state,clamp(base+ivec2(x,y),ivec2(0),size-1),0).r;
                lower=min(lower,d); upper=max(upper,d);
            }
        }
        density=clamp(corrected,lower,upper);
    }
    // 仅上风边界供给密度，场内不恢复为固定图案。
    vec2 inflow=vec2(params.flow.x>=0.0 ? uv.x : 1.0-uv.x,params.flow.y>=0.0 ? uv.y : 1.0-uv.y)*params.region.xy;
    float supply=max((1.0-smoothstep(0.0,1.2,inflow.x))*step(0.01,abs(params.flow.x)),
                     (1.0-smoothstep(0.0,1.2,inflow.y))*step(0.01,abs(params.flow.y)));
    if(supply>0.0) { density=mix(density,initial_density(p-params.flow.xy*time),supply*(1.0-exp(-params.dynamics.z*dt))); }
    float age_a=mod(time,period),age_b=mod(time+period*0.5,period);
    vec4 fresh=vec4(p-params.flow.xy*age_a,p-params.flow.xy*age_b);
    vec4 coordinates=(reset || outside(source)) ? fresh : textureLod(previous_coordinates,source,0);
    // 对应坐标刷新时，渲染权重为零；主密度不刷新。
    if(floor(time/period)>floor(max(time-dt,0.0)/period)) { coordinates.xy=p; }
    if(floor((time+period*0.5)/period)>floor((max(time-dt,0.0)+period*0.5)/period)) { coordinates.zw=p; }
    if(solid_distance(uv)<=0.0) { density=0; coordinates=fresh; }
    vec4 result=vec4(max(density,0.0),velocity_at(uv),0);
    imageStore(next_state,id,result); imageStore(display_state,id,result);
    imageStore(next_coordinates,id,coordinates); imageStore(display_coordinates,id,coordinates);
}
