#[compute]
#version 450

// 每个作用点仅运行一个 invocation，在 GPU 上估算本步从圆心移走的雾量。
// 后续模拟把这部分量放到外围窄环；比给每个雾格重复做圆盘积分便宜得多。
// 这是低成本的表现性重分配，不是压力求解或严格守恒的流体求解器。
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D previous_state;
layout(set = 0, binding = 1) uniform sampler2D obstacle_map;
layout(std430, set = 0, binding = 2) readonly buffer Parameters {
    vec4 region;
    vec4 flow;
    vec4 dynamics;
    vec4 behavior;
    vec4 counts;
    vec4 pattern;
    vec4 compression;
} params;
struct Stamp { vec4 brush; vec4 force; vec4 compression; };
layout(std430, set = 0, binding = 3) readonly buffer Stamps { Stamp items[]; } stamps;
layout(std430, set = 0, binding = 4) writeonly buffer Redistribution { vec4 items[]; } redistribution;

void main() {
    int index = int(gl_GlobalInvocationID.x);
    if (index >= int(params.counts.y)) { return; }
    Stamp stamp = stamps.items[index];
    float removed_mass = 0.0;
    // 首次重置时上一状态尚未初始化；没有源雾量时也不会凭空生成浓雾环。
    if (params.counts.z < 0.5 && params.dynamics.x > 0.0 && stamp.compression.x > 0.0) {
        const int SAMPLES = 12;
        float cell = min(params.region.x, params.region.y) / params.counts.w;
        float radius = max(stamp.brush.z, cell * 1.5);
        float sample_area = pow(2.0 * radius / float(SAMPLES), 2.0);
        for (int y = 0; y < SAMPLES; y++) {
            for (int x = 0; x < SAMPLES; x++) {
                vec2 offset = ((vec2(x, y) + 0.5) / float(SAMPLES) * 2.0 - 1.0) * radius;
                float distance = length(offset);
                if (distance >= radius) { continue; }
                vec2 uv = (stamp.brush.xy + offset - params.region.zw) / params.region.xy + 0.5;
                if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) { continue; }
                if (textureLod(obstacle_map, uv, 0.0).r <= 0.0) { continue; }
                float density = textureLod(previous_state, uv, 0.0).r;
                float weight = 1.0 - smoothstep(radius * 0.8, radius, distance);
                float removed = density * (1.0 - exp(-stamp.brush.w * weight * params.dynamics.x));
                removed_mass += removed * sample_area;
            }
        }
    }
    redistribution.items[index] = vec4(removed_mass, 0.0, 0.0, 0.0);
}
