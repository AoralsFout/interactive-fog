#[compute]
#version 450

// 二维半拉格朗日搬运：从当前格点沿速度反向追踪，读取上一状态。
// 状态 RGBA = 密度（允许超过 1）、水平速度 X、水平速度 Z、相对目标的压缩量。
// 不求解压力、不模拟竖直速度；恢复项有意补充密度，服务于可控的游戏表现。
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D previous_state;
layout(rgba16f, set = 0, binding = 1) uniform writeonly image2D next_state;
layout(rgba16f, set = 0, binding = 2) uniform writeonly image2D display_state;
layout(set = 0, binding = 3) uniform sampler2D obstacle_map;
layout(std430, set = 0, binding = 4) readonly buffer Parameters {
    vec4 region;
    vec4 flow;
    vec4 dynamics;
    vec4 behavior;
    vec4 counts;
    vec4 pattern;
    vec4 compression;  // 密度上限、超额密度释放速率、保留、保留
} params;
struct Stamp { vec4 brush; vec4 force; vec4 compression; };
layout(std430, set = 0, binding = 5) readonly buffer Stamps { Stamp items[]; } stamps;
layout(std430, set = 0, binding = 6) readonly buffer Redistribution { vec4 items[]; } redistribution;

float hash21(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

float value_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(cell), hash21(cell + vec2(1.0, 0.0)), u.x),
               mix(hash21(cell + vec2(0.0, 1.0)), hash21(cell + vec2(1.0)), u.x), u.y);
}

vec2 guide_velocity(vec2 velocity, vec3 obstacle) {
    float influence = 1.0 - smoothstep(0.0, params.behavior.z, obstacle.x);
    // 去掉朝固体内部的分量，切向分量保留，因此流动会沿障碍表面滑动。
    return velocity - obstacle.yz * min(dot(velocity, obstacle.yz), 0.0) * influence;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(next_state);
    if (any(greaterThanEqual(pixel, size))) { return; }
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
    vec2 p = (uv - 0.5) * params.region.xy + params.region.zw;
    vec3 obstacle = textureLod(obstacle_map, uv, 0.0).rgb;
    vec4 result = vec4(0.0);
    if (obstacle.x > 0.0) {
        float dt = params.dynamics.x;
        vec2 pattern_p = (p - params.flow.xy * params.dynamics.y * 0.25) * params.pattern.y;
        float target_density = mix(1.0, 0.25 + 0.75 * value_noise(pattern_p), params.pattern.x);
        bool reset = params.counts.z > 0.5;
        vec2 velocity = reset ? params.flow.xy : textureLod(previous_state, uv, 0.0).gb;
        velocity = guide_velocity(velocity, obstacle);

        // 限制单步搬运距离，并沿线检测固体，阻止从薄墙另一侧直接取样。
        // 长位移分成最多八段，每段不超过半个格；超出预算时截短而非跨墙。
        vec2 displacement = velocity * dt;
        float cell = min(params.region.x / float(size.x), params.region.y / float(size.y));
        float travel = length(displacement);
        displacement *= min(1.0, cell * 4.0 / max(travel, 0.0001));
        int segments = clamp(int(ceil(length(displacement) / (cell * 0.5))), 1, 8);
        vec2 source_uv = uv;
        for (int i = 1; i <= segments; i++) {
            vec2 candidate = uv - displacement / params.region.xy * (float(i) / float(segments));
            if (any(lessThan(candidate, vec2(0.0))) || any(greaterThan(candidate, vec2(1.0)))) { break; }
            if (textureLod(obstacle_map, candidate, 0.0).r <= cell * 0.1) { break; }
            source_uv = candidate;
        }

        vec4 old = reset ? vec4(target_density, params.flow.xy, 1.0) : textureLod(previous_state, source_uv, 0.0);
        float density = old.r;
        velocity = old.gb;
        // 低频、随时间缓变的旋流；细节由渲染噪声补充，不提高模拟分辨率。
        float t = params.dynamics.y;
        vec2 q = p * params.flow.w;
        vec2 curl = vec2(sin(q.y + t * 0.37) * cos(q.x * 0.71 - t * 0.21),
                         -sin(q.x - t * 0.29) * cos(q.y * 0.83 + t * 0.17));
        velocity = params.flow.xy + (velocity - params.flow.xy) * exp(-params.dynamics.w * dt);
        velocity += (params.flow.xy - velocity) * (1.0 - exp(-params.behavior.x * dt));
        velocity += curl * params.flow.z * dt;

        float compressed_density = 0.0;
        for (int i = 0; i < int(params.counts.y); i++) {
            Stamp stamp = stamps.items[i];
            vec2 offset = p - stamp.brush.xy;
            float radius = max(stamp.brush.z, cell * 1.5);
            float distance = length(offset);
            // 至少保留一个格宽，低分辨率下也不会出现细环在格点之间跳变。
            float width = max(cell, min(stamp.compression.y, radius * 0.6));
            if (distance > radius + width) { continue; }
            // 大部分圆盘保持完整推开力度，只在接近波前时淡出，形成清晰的中空区域。
            float weight = 1.0 - smoothstep(radius * 0.8, radius, distance);
            float ring = 1.0 - smoothstep(0.0, width, abs(distance - radius));
            vec2 radial = offset / max(distance, 0.01);
            vec2 force = stamp.force.xy + radial * stamp.force.z + vec2(-radial.y, radial.x) * stamp.force.w;
            velocity += force * max(weight, ring) * dt;
            density *= exp(-stamp.brush.w * weight * dt);
            // 此对称平滑环的面积积分约为 2πRW。宽度越窄，同样的雾量就堆得越高。
            // 额外密度最后统一加入，避免同一步里的其他清除作用立刻擦掉新形成的环。
            float area = 6.2831853 * radius * width;
            compressed_density += redistribution.items[i].x * stamp.compression.x * ring / max(area, 0.001);
        }
        density += compressed_density;
        velocity = guide_velocity(velocity, obstacle);
        velocity *= min(1.0, params.behavior.y / max(length(velocity), 0.0001));
        // 高密度环可以迅速散开；中心空洞则仍按原有恢复时间回填，二者独立可调。
        float recovery = density > target_density ? params.compression.y : params.dynamics.z;
        density = mix(density, target_density, 1.0 - exp(-recovery * dt));
        density = clamp(density, 0.0, params.compression.x);
        result = vec4(density, velocity, max(density - target_density, 0.0));
    }
    imageStore(next_state, pixel, result);
    // 固定的展示纹理使 Fog Shader 和 HUD 不需要随 ping-pong 更换绑定。
    imageStore(display_state, pixel, result);
}
