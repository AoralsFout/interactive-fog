#[compute]
#version 450

// 每个格点保存：R = 到最近固体的有符号距离（米），GB = 朝向自由空间的法线。
// 把几何距离场预先画成纹理，模拟中就不必反复遍历所有障碍物。
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D obstacle_map;
layout(std430, set = 0, binding = 1) readonly buffer Parameters {
    vec4 region;       // 宽、深、世界原点 X、Z
    vec4 flow;         // 风 X、Z、旋流强度、旋流频率
    vec4 dynamics;     // dt、累计时间、边界补雾系数、速度阻尼
    vec4 behavior;     // 风速恢复、最大速度、导流距离、保留
    vec4 counts;       // 障碍数量、交互数量、重置标记、分辨率
    vec4 pattern;      // 基础密度变化强度、空间频率、保留、保留
    vec4 solver;       // 涡量约束等求解参数，保持布局一致
} params;
struct Obstacle { vec4 geometry; vec4 transform; };
layout(std430, set = 0, binding = 2) readonly buffer Obstacles { Obstacle items[]; } obstacles;

float shape_distance(vec2 p, Obstacle o) {
    vec2 offset = p - o.geometry.xy;
    // transform.xy 是局部 X 轴在世界 XZ 平面上的单位向量。
    vec2 local = vec2(dot(offset, o.transform.xy), dot(offset, vec2(-o.transform.y, o.transform.x)));
    if (o.transform.z > 0.5) {
        return length(local) - o.geometry.z - o.transform.w;
    }
    vec2 q = abs(local) - o.geometry.zw;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - o.transform.w;
}

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(obstacle_map);
    if (any(greaterThanEqual(pixel, size))) { return; }
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
    vec2 p = (uv - 0.5) * params.region.xy + params.region.zw;

    // 域边界开放，障碍才是固体；上风边界在搬运阶段补雾。
    float distance = 1000.0;
    vec2 normal = vec2(0.0);
    int nearest = -1;
    for (int i = 0; i < int(params.counts.x); i++) {
        float d = shape_distance(p, obstacles.items[i]);
        if (d < distance) { distance = d; nearest = i; }
    }
    if (nearest >= 0) {
        // 仅对最近的形状求梯度，避免为每个形状做四次额外距离计算。
        const float e = 0.01;
        Obstacle o = obstacles.items[nearest];
        vec2 gradient = vec2(
            shape_distance(p + vec2(e, 0.0), o) - shape_distance(p - vec2(e, 0.0), o),
            shape_distance(p + vec2(0.0, e), o) - shape_distance(p - vec2(0.0, e), o));
        normal = gradient / max(length(gradient), 0.0001);
    }
    imageStore(obstacle_map, pixel, vec4(distance, normal, distance <= 0.0 ? 1.0 : 0.0));
}
