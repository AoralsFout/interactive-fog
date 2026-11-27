#[compute]
#version 450
#include "fluid_common.glslinc"
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;

layout(set=0,binding=3) uniform sampler2D height_map;
layout(set=0,binding=4) uniform sampler2D previous_state;
layout(set=0,binding=5) uniform sampler2D previous_coordinates;
layout(r32f,set=0,binding=6) uniform writeonly image2D next_state;
layout(rgba32f,set=0,binding=7) uniform writeonly image2D next_coordinates;
layout(rgba16f,set=0,binding=8) uniform image2D display_state;
layout(push_constant,std430) uniform Slope {
    vec4 bounds;
    float dt;
    float speed_limit;
    float publish;
} slope;

const float DENSITY_CONTRAST = 1.0;
const ivec2 OFFSETS[4] = ivec2[](ivec2(1,0),ivec2(-1,0),ivec2(0,1),ivec2(0,-1));

float terrain_height(vec2 uv) {
    vec2 world = (uv-0.5)*params.region.xy+params.region.zw;
    vec2 texels = vec2(textureSize(height_map,0));
    vec2 grid = (world-slope.bounds.xy)/slope.bounds.zw*(texels-1.0);
    return textureLod(height_map,(grid+0.5)/texels,0).r;
}

// Positive transfer leaves the current cell. Both cells compute the same
// amount, using the same donor, receiver and per-face capacity.
vec2 face_transfer(float drop,float current,float neighbor,float spacing) {
    if(abs(drop)<=0.00001) { return vec2(0.0); }
    float direction = sign(drop);
    float donor = drop>0.0 ? current : neighbor;
    float receiver = drop>0.0 ? neighbor : current;
    float room = max(0.0,DENSITY_CONTRAST+donor-receiver);
    float speed = min(slope.speed_limit,params.behavior.z*abs(drop)/spacing);
    speed *= min(1.0,room/DENSITY_CONTRAST);
    float amount = speed*slope.dt/spacing*donor;
    // Each cell can receive from four neighbors. Keep the limit conservative
    // by reducing incoming flux rather than clipping density after the step.
    amount = min(amount,0.25*min(room,max(0.0,params.solver.w-receiver)));
    float applied_speed = amount*spacing/(slope.dt*max(donor,0.000001));
    return direction*vec2(amount,applied_speed);
}

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy), size = imageSize(next_state);
    if(any(greaterThanEqual(id,size))) { return; }
    vec2 uv = (vec2(id)+0.5)/vec2(size), cell = params.region.xy/vec2(size);
    float density = texelFetch(previous_state,id,0).r;
    vec4 coordinates = texelFetch(previous_coordinates,id,0);
    vec4 incoming_coordinates = vec4(0.0);
    vec2 drift = vec2(0.0);
    float change = 0.0;
    if(texelFetch(obstacle_map,id,0).r>0.0) {
        float height = terrain_height(uv);
        for(int index=0; index<4; ++index) {
            ivec2 offset = OFFSETS[index], neighbor = id+offset;
            if(any(lessThan(neighbor,ivec2(0))) || any(greaterThanEqual(neighbor,size))) { continue; }
            if(texelFetch(obstacle_map,neighbor,0).r<=0.0) { continue; }
            vec2 sample_uv = (vec2(neighbor)+0.5)/vec2(size);
            float neighbor_density = texelFetch(previous_state,neighbor,0).r;
            vec2 flow = face_transfer(height-terrain_height(sample_uv),density,neighbor_density,
                offset.x==0 ? cell.y : cell.x);
            change -= flow.x;
            drift += vec2(offset)*flow.y*0.5;
            if(flow.x<0.0) {
                // Blend material markers by the newly arrived fog amount.
                incoming_coordinates -= flow.x*(texelFetch(previous_coordinates,neighbor,0)-coordinates);
            }
        }
    }
    density += change;
    if(density>0.000001) { coordinates += incoming_coordinates/density; }
    imageStore(next_state,id,vec4(density));
    imageStore(next_coordinates,id,coordinates);
    if(slope.publish>0.5) {
        vec4 state = imageLoad(display_state,id);
        state.r = density;
        state.gb += drift;
        imageStore(display_state,id,state);
    }
}
