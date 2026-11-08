#[compute]
#version 450
layout(local_size_x=8,local_size_y=8,local_size_z=1) in;
layout(set=0,binding=3) uniform sampler2D previous_state;
layout(set=0,binding=4) uniform sampler2D previous_coordinates;
layout(r32f,set=0,binding=5) uniform writeonly image2D next_state;
layout(rgba32f,set=0,binding=6) uniform writeonly image2D next_coordinates;
layout(push_constant,std430) uniform Offset { ivec4 value; } offset;

// 两份状态的区域外保持一致，后续 CFL 子步只需更新作用范围。
void main() {
    ivec2 id=ivec2(gl_GlobalInvocationID.xy)+offset.value.xy;
    if(any(greaterThanEqual(id,imageSize(next_state)))) { return; }
    imageStore(next_state,id,texelFetch(previous_state,id,0));
    imageStore(next_coordinates,id,texelFetch(previous_coordinates,id,0));
}
