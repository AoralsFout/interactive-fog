# Interactive Fog / 可交互贴地雾

Godot 4.7 / Forward+ 的浅层交互雾。二维流体负责水平运动，主要可见细节存在持久密度中；三维噪声补充纵向层次，并通过随流搬运的材质坐标采样。

鼠标和角色向同一速度场施力。密度与纹理一起被推移、拉长和卷起，停止输入后继续演化。场内不再自动恢复固定图案，也不直接擦出空洞或填入预设浓雾环。

## 运行

打开 `project.godot`，等待 Compute Shader 导入，F5 运行。使用 Forward+，默认 Windows / D3D12；Mobile 和 Compatibility 不支持此处的 FogVolume。

| 输入 | 行为 |
| --- | --- |
| WASD / 方向键、Shift | 角色移动、加速，推动雾并留下尾流 |
| 左键拖动 | 搅动：推动和卷动；划开：沿路径把雾拨向两侧 |
| 左键单击 | 搅动时注入小旋涡；划开时拨出局部缺口 |
| M / 面板工具按钮 | 切换“搅动”和“划开”；默认搅动 |
| Space | 从鼠标位置径向推开雾，在移动波前堆积并留下卷曲尾流 |
| 右键拖动、滚轮 | 环绕相机、缩放 |
| R / P / Tab | 重置 / 暂停 / 二维场图 |

左侧可调光学密度、**上风边界补雾半衰期**、风速与层高。补雾只在入流边缘发生；场内稀疏区由周围流动填充，不按固定图案重新生成。

## 结构

```mermaid
flowchart TD
    Input[鼠标、角色、风和旋涡力] --> Velocity[二维 MAC 速度自搬运与受力]
    Velocity --> Pressure[障碍约束、压力迭代、速度投影]
    Pressure --> Density[高分辨率持久密度搬运]
    Pressure --> Coordinates[两组材质坐标搬运]
    Density --> Volume[FogVolume 三维密度与原生光照]
    Coordinates --> Noise[三维噪声辅助层]
    Noise --> Volume
```

速度采用交错 MAC 存储，压力与散度使用配对的前后差分。固体边界禁止穿入，区域边界开放。压力采用有限次 Jacobi 迭代与上一时间步的压力作为初值，因此仅近似满足不可压缩约束。

密度使用 RK2 回溯、双三次重建及带局部极值限制的 MacCormack 校正，减少细丝反复搬运后的扩散。初始化图案包含大尺度疏密和窄密度脊；之后细节作为真实状态随速度搬运。仍存在采样与数值耗散，不能保证无限细的结构长期保持。

三维纹理不再以背景风乘时间自行漂移，也不再用瞬时速度偏移伪装搬运。两组二维材质坐标使用相同的速度和回溯路径，驱动三维噪声。它们错开周期刷新，并在刷新时将对应噪声权重降至零，以限制长期拉伸；**主密度不参与刷新**。这层噪声只补充厚度与次要纹理，不承担主要交互历史。

涡量约束用于补偿速度搬运损失。它不能制造速度网格无法分辨的微涡。默认 24 × 20 m 区域中，速度格约 9.4 × 7.8 cm，密度格约 4.7 × 3.9 cm；实际可分辨的涡旋需要跨越多个速度格。

方法参考：[GPU Gems 38：GPU 流体](https://developer.nvidia.com/gpugems/gpugems/part-vi-beyond-triangles/chapter-38-fast-fluid-dynamics-simulation-gpu)、[GPU Gems 3 / 30：高阶搬运](https://developer.nvidia.com/gpugems/gpugems3/part-v-physics-simulation/chapter-30-real-time-simulation-and-rendering-3d-fluids)。

### 径向扩散

扩散是投影后的一条短时搬运路径。波前半径按平滑曲线增长，内部径向速度逐渐稀释中心，速度在外圈下降形成压缩。密度通过单元面上的有限体积通量重新分配，不直接清除圆盘或往预设圆环加雾。三维噪声坐标使用同一冲击速度回溯，所以细节会一同移动。

冲击速度预先构建为高分辨率 MAC 场；障碍距离场用于从源点进行保守的球面步进遮挡检查，固体面通量为零，近障碍速度沿表面导流。它不求解绕障碍传播的声波或完整三维爆炸。

冲击密度使用 MC 限制斜率重建与通量差更新，子步按 CFL 0.4 自动细分。内部密度和预测纹理为单通道 R32F，避免多子步反复量化；对渲染与场图的展示接口仍为 RGBA16F。正常流动仍走原有的高阶 MacCormack 搬运。冲击还向常规流场注入少量旋流，使波前在冲击结束后继续变形。

最多同时处理 4 个冲击，每主时间步最多 64 个冲击子步。极小区域、高分辨率或极端重叠触及子步上限时，会按 CFL 约束削弱冲击速度。密度安全上限默认为 16，达到上限时会损失部分雾量；常规参数下的单次均匀雾扩散验收，二维密度积分误差约 0.003%。原理参考：[Clawpack 的有限体积与通量方法](https://www.clawpack.org/v5.3.x/wp_algorithms.html)。

### 沿路径划开

划开使用覆盖完整拖动线段的短时速度场，把雾拨向路径两侧。它与径向扩散共用有限体积搬运，密度和三维纹理坐标一起移动，不删除雾量。作用结束后保留疏密历史，由原有风和流动继续搬运、自然补位。切换工具、进入面板或松开左键会结束当前笔划，不跨越下一次输入连接路径。

默认半径 0.65 m、峰值速度 3 m/s、作用时间 0.3 s，主场景根节点可调整。最多保留 16 段轨迹，重叠路径取局部最强作用，避免移动缓慢时累加出过大速度。障碍检查只在作用范围内进行；两份状态先同步一次，后续 CFL 子步仅更新范围内的单元，保留区域外状态与原有流动。

## 参数与编辑器

在 `demo/main.tscn` 选中 **FogField → Settings**。开启编辑器的“使用场景环境 / 使用场景灯光”可预览。所有外观参数即时同步；流动参数在下一步生效。

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| Area Size | 24 × 20 m | 世界 XZ 覆盖范围，原点为雾层底部中心 |
| Resolution | 256² | 速度、压力、诊断纹理尺寸 |
| 密度与材质坐标 | Resolution 的两倍边长，默认 512² | 跟随速度分辨率一起重建 |
| Simulation Hz | 30 Hz | 固定模拟频率 |
| Pressure Iterations | 64 | 压力精度与 GPU 成本 |
| Wind Velocity | (0.7, 0.18) m/s | 背景风 |
| Wind Response / Velocity Damping | 0.12 / 0.08 | 回到背景风的响应与速度衰减 |
| Turbulence Strength / Scale | 0.25 / 1.2 | 进入求解器的旋流加速度与频率 |
| Vorticity Strength | 1.5 | 已分辨涡旋的耗散补偿 |
| Inflow Half Life | 1.5 s | 上风边缘的密度供给时间 |
| Density Variation / Pattern Scale | 1 / 0.55 | 初始化与新入流的密度结构；修改后按“重置雾场”重建初始状态 |
| Thickness / Density | 0.85 m / 2.6 | 最大高度与光学密度 |
| Detail Amount / Scale | 0.35 / 1.4 | 辅助三维纹理强度与空间频率 |
| Detail Reset Period | 12 s | 辅助坐标刷新周期，不清除主密度历史 |
| Detail Sharpness / Warp | 0.75 / 0.65 | 密度外观对比与随流坐标上的噪声域扭曲 |
| Max Compressed Density | 16 | 冲击路径的密度安全上限 |

`Preview In Editor` 控制编辑器播放，`Simulation Enabled` 控制流动。暂停会冻结密度、材质坐标及噪声动画；移动障碍仍更新遮罩与固体区域。修改分辨率、区域或场位置会重置状态；普通外观调整保留历史。

柱子与墙保留可编辑的二维足迹、可见几何同步及 Gizmo。自定义模型关闭 `Sync Prefab Geometry` 后独立配置足迹。原生 Light3D 的颜色、体积雾能量和阴影继续影响雾。

主场景保留已有的 0.85 m 层高、白色散射颜色与相机参数。旧的逐格恢复、清除强度和规则圆环挤压参数已移除；旧预设需要按新参数重新保存。

主场景根节点的“空格径向扩散”提供范围、强度倍率、持续时间、残留旋流和波前宽度。默认 3 m / 0.65 s / 强度 1 / 宽度 0.45 m。过短持续时间会按 8 m/s 的峰值冲击速度自动延长。浓雾波前可在原有 FogVolume 范围内增高，不改变普通雾层的高度。

## 复用与接口

实例化 `fog/scenes/fog_field.tscn`，在目标 Environment 开启体积雾并设全局体积密度为 0。雾场与父级保持零旋转、单位缩放，用 Area Size 调整范围。

移动物体下挂 `FogInteractor3D`，设置半径、方向推力和随移动增强的切向力。多个雾场独立记录物体上一位置。障碍使用 `FogObstacle3D`，足迹为二维，不能自动投影复杂多层地形。

```gdscript
# 注入一次速度冲量：位置、半径、XZ 速度增量、旋转速度增量。
$FogField.disturb(Vector3(0, 0, 2), 1.2, Vector2(2, 0), 1.5)

# 径向扩散：位置、范围、持续时间、强度倍率、残留旋流、波前宽度。
$FogField.burst(Vector3(0, 0, 2), 3.0, 0.65, 1.0, 1.5, 0.45)

# 线段拨开：起点、终点、作用半径、峰值速度、持续时间。
$FogField.part(Vector3(-2, 0, 1), Vector3(2, 0, 1), 0.65, 3.0, 0.3)
```

`get_state_texture()` 返回固定展示纹理：R 密度、GB 单元中心速度、A 保留。冲击期间 GB 包含常规流动与冲击速度，场图直接采样它显示密度与速度箭头，无运行时 GPU 回读。`get_coordinate_texture()` 返回两组持久坐标；`get_diagnostics_texture()` 的 R/G/B 分别为常规速度的投影后散度、涡量、投影前散度，不包含有意保留散度的冲击分量。

## 文件

- `fog/fog_simulation_gpu.gd`：GPU 资源与计算阶段的唯一拥有者。
- `fog/fog_field.gd`：场景接口、固定步、参数和交互收集。
- `fog/shaders/fluid_common.glslinc`：共享布局、MAC 采样、回溯与密度重建。
- `velocity / divergence / pressure / project_velocity.glsl`：速度与压力求解。
- `density_predict / simulate.glsl`：密度预测校正与材质坐标搬运。
- `shock_field / shock_seed / shock_transport.glsl`：扩散与划开速度场、区域外状态同步、局部有限体积搬运。
- `build_obstacles.glsl`：几何变化时重建距离与法线。
- `ground_fog.gdshader`：从共享状态重建三维外观。
- `demo/`：角色、相机、灯光、笔刷和场图。
- `tests/`：实际 GPU 轨迹、渲染、编辑器与预算检查。

场景节点由 .tscn 声明；运行时只创建必要的材质、网格副本和 GPU 资源。瞬态材质通过 RenderingServer 绑定，不将 Texture2DRD 保存回场景。

## 验证

图形检查需要真实 GPU，不能加 `--headless`。将 godot 换成本机控制台可执行文件：

```powershell
godot --headless --editor --path . --import --quit
godot --path . --fixed-fps 60 --script res://tests/flow_transport.gd
godot --path . --fixed-fps 60 --script res://tests/flow_expansion.gd
godot --path . --fixed-fps 60 --script res://tests/flow_part.gd
godot --path . --script res://tests/gpu_smoke.gd
godot --path . --fixed-fps 60 --script res://tests/field_map.gd
godot --path . --fixed-fps 60 --script res://tests/fog_detail.gd
godot --editor --path . -- --fog-editor-smoke

# 真实 1080p 离屏场景，预热 2 秒模拟时间、持续采样 5 秒墙钟时间。
godot --path . --script res://tests/flow_budget.gd
godot --path . --script res://tests/flow_budget.gd -- --close
godot --path . --script res://tests/flow_budget.gd -- --flow-only
godot --path . --script res://tests/flow_budget.gd -- --close --burst
godot --path . --script res://tests/flow_budget.gd -- --close --part

# 固定步动态捕捉，105 帧 / 15 FPS / 7 秒。
godot --path . --fixed-fps 60 --script res://tests/flow_capture.gd
ffmpeg -framerate 15 -i artifacts/flow-transport/frames/%03d.png -c:v libx264 -crf 18 -pix_fmt yuv420p artifacts/flow-transport/interaction.mp4

# 真实 Space 输入的扩散与随后尾流：120 帧 / 15 FPS / 8 秒。
godot --path . --fixed-fps 60 --script res://tests/expansion_capture.gd
ffmpeg -framerate 15 -i artifacts/expansion/frames/%03d.png -c:v libx264 -crf 18 -pix_fmt yuv420p artifacts/expansion/expansion.mp4

# M 切换后实际左键划开，再松手自然演化：120 帧 / 15 FPS / 8 秒。
godot --path . --fixed-fps 60 --script res://tests/part_capture.gd
ffmpeg -framerate 15 -i artifacts/part/frames/%03d.png -c:v libx264 -crf 18 -pix_fmt yuv420p artifacts/part/part.mp4
```

轨迹验收比较已知 1 m 风位移的密度与材质坐标，检查局部标记的位移、松手后的历史、密度范围、近似雾量保持、压力残差、暂停、障碍更新、重复坐标刷新和重置确定性。它不把“参数造成像素差”当成交互正确的证据。

扩散验收另行检查中心稀释、波前半径增长、浓度超过基准、总雾量误差、材质标记共同位移、空区二次冲击、30/60 Hz 一致性、暂停重置、隔墙遮挡、重叠上限、开放边界及实际 Space 输入。

划开验收检查快速线段的连续缺口、两侧堆积、密度积分、材质标记位移、松手历史、墙体遮挡和自然回填，以及交互器、暂停重置、模式按钮、M 键和左键接线。新增 19 项与已有 93 项检查均通过；均匀雾测试的密度积分误差约 0.0005%。预览位于 `artifacts/part/`。

`artifacts/flow-transport/` 保存密度前后图、动态预览、1080p 截图和预算 JSON。PNG 序列与日志不提交。`artifacts/fog-detail/` 保存静态远近景检查与改动前参考；新的外观判断应同时看动态预览。

本轮验证环境为 Windows / Godot 4.7.2 / D3D12 Forward+ / RTX 3050 Ti Laptop。预算报告记录整帧墙钟间隔和单视口 GPU 渲染时间；后者不单独代表流体计算耗时。关闭体积雾的对照保留流体与其余场景，用于粗略区分成本。

共享流场重构提交 `16e85bc` 的 288 / 192 体积采样下，1080p 近景两次连续复测的 P95 为 15.365 / 14.963 ms，最慢帧为 16.659 / 16.569 ms。每次先预热 2 秒模拟时间，再持续采样约 5 秒，笔刷沿固定轨迹持续推雾。对应报告为 `budget-full-close-repeat1.json`、`budget-full-close-repeat2.json`。该提交的轨迹、渲染、场图、GPU 集成及编辑器验收共 75 项检查通过；新增扩散结果见 `budget-full-close-burst.json` 及扩散验收输出。

径向扩散版本共通过 93 项检查，其中新增 18 项扩散回归。最终配置在相同机器上的 1080p 近景持续拖动、每 1.5 秒释放一次扩散，预热 2 秒后测量约 5 秒：整帧中位数 10.684 ms，P95 14.302 ms，最慢帧 15.154 ms。报告包含该场景和采样条件，不能据此保证所有窗口、设备或四重同时冲击都达到相同帧率。动态预览为 `artifacts/expansion/expansion.mp4`。

划开模式在同机 1080p 近景持续拖动、最多 8 段同时作用的预算测试中，中位数 10.627 ms、P95 12.368 ms、最慢帧 13.335 ms。条件为预热 2 秒模拟时间后采样约 5 秒；见 `budget-full-close-part.json`，不涵盖任意长线段或多交互器同时划开的最坏情况。

## 成本与限制

默认 256² 速度 / 512² 密度的模拟纹理约 23.5 MiB，另有噪声、体积雾 froxel、阴影及引擎资源。所有计算留在主 RenderingDevice；CPU 只提交少量参数，无每帧 readback、submit 或 sync。最多 32 个障碍、单步 16 个常规作用、同时 4 个径向冲击及 16 段划开路径。

项目体积雾为 Volume Size 288 / Depth 192、关闭空间滤波，时间重投影为 0.75。连续复测时 320 的近景 P95 曾达到 17.3 ms，因此只小幅降低体积横向采样，保留速度和密度精度。这些选项明显影响细节、闪烁和拖影。近景细丝受最终 froxel 分辨率限制；加密二维场无法单独突破渲染采样上限。需要省性能时先降低 Volume Size / Depth 或减少参与雾的动态灯，再按目标涡尺度调整速度分辨率。

本模型是二维水平流动加三维外观，不求解上下穿插、真实三维翻卷或浅水自由表面。压力迭代、极值限制、开放边界和源项都可能引入守恒误差。快速移动障碍当前更新遮罩，连续推雾应同时配置交互器。极低帧率下每画面最多推进一步，会主动放慢模拟，避免作业堆积。

本机离屏预算检查不能代替其他显卡、后端或真实窗口的验收；尚未验证这些环境。
