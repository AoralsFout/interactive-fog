#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

// 这里 velocity_map 绑定冲击 MAC 场；BA 保存常规流体速度用于最终场图。
layout(set=0,binding=3) uniform sampler2D previous_state;
layout(set=0,binding=4) uniform sampler2D previous_coordinates;
layout(r32f,set=0,binding=5) uniform writeonly image2D next_state;
layout(rgba32f,set=0,binding=6) uniform writeonly image2D next_coordinates;
layout(rgba16f,set=0,binding=7) uniform writeonly image2D display_state;
layout(rgba32f,set=0,binding=8) uniform writeonly image2D display_coordinates;
layout(push_constant,std430) uniform Substep { float dt; int final_step; ivec2 origin; ivec2 extent; ivec2 padding; } substep;

float scalar(ivec2 id) {
    ivec2 size=textureSize(previous_state,0);
    // 开放边界不凭空补充冲击雾量；普通入流由原有主时间步负责。
    if(any(lessThan(id,ivec2(0))) || any(greaterThanEqual(id,size))) { return 0.0; }
    return max(texelFetch(previous_state,id,0).r,0.0);
}
float minmod(float a,float b,float c) {
    if(a>0.0 && b>0.0 && c>0.0) { return min(a,min(b,c)); }
    if(a<0.0 && b<0.0 && c<0.0) { return max(a,max(b,c)); }
    return 0.0;
}
float slope(ivec2 id,ivec2 axis) {
    float center=scalar(id),left=scalar(id-axis),right=scalar(id+axis);
    return minmod(2.0*(center-left),0.5*(right-left),2.0*(right-center));
}
float flux(ivec2 left,ivec2 axis,float speed,float spacing) {
    if(abs(speed)<0.000001) { return 0.0; }
    ivec2 upwind=speed>=0.0 ? left : left+axis;
    float sign=speed>=0.0 ? 1.0 : -1.0;
    float reconstructed=scalar(upwind)+sign*0.5*(1.0-abs(speed)*substep.dt/spacing)*slope(upwind,axis);
    return speed*max(reconstructed,0.0);
}
void main() {
    ivec2 local_id=ivec2(gl_GlobalInvocationID.xy);
    if(any(greaterThanEqual(local_id,substep.extent))) { return; }
    ivec2 id=local_id+substep.origin,size=imageSize(next_state);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv=(vec2(id)+0.5)/vec2(size),cell=params.region.xy/vec2(size);
    vec4 state=texelFetch(previous_state,id,0);
    vec4 coordinates=texelFetch(previous_coordinates,id,0);
    vec4 velocity_data=texelFetch(velocity_map,id,0);
    float left=id.x>0 ? texelFetch(velocity_map,id-ivec2(1,0),0).r : velocity_data.r;
    float top=id.y>0 ? texelFetch(velocity_map,id-ivec2(0,1),0).g : velocity_data.g;
    float flux_activity=abs(velocity_data.r)+abs(velocity_data.g)+abs(left)+abs(top);
    if(flux_activity>0.000001 && solid_distance(uv)>0.0) {
        float delta_x=flux(id,ivec2(1,0),velocity_data.r,cell.x)-flux(id-ivec2(1,0),ivec2(1,0),left,cell.x);
        float delta_z=flux(id,ivec2(0,1),velocity_data.g,cell.y)-flux(id-ivec2(0,1),ivec2(0,1),top,cell.y);
        state.r=clamp(state.r-substep.dt*(delta_x/cell.x+delta_z/cell.y),0.0,params.solver.w);
        // 坐标是随流的材质标记，而密度额外遵循压缩/膨胀的连续方程。
        coordinates=textureLod(previous_coordinates,clamp(backtrace(uv,substep.dt),vec2(0),vec2(1)),0);
    }
    if(solid_distance(uv)<=0.0) { state.r=0.0; }
    state.gb=velocity_data.ba+velocity_at(uv);
    state.a=0.0;
    imageStore(next_state,id,state);
    imageStore(next_coordinates,id,coordinates);
    if(substep.final_step!=0) {
        imageStore(display_state,id,state);
        imageStore(display_coordinates,id,coordinates);
    }
}
