# Interactive Fog / 可交互贴地雾

Godot 4.7 的独立 3D demo：二维 GPU 雾场负责密度与水平速度，原生 `FogVolume` 负责体积外观、受光和几何体阴影。默认使用 Forward+ / D3D12，无外部资源或插件依赖；仓库内附带的编辑器插件只绘制辅助线。

## 运行

使用 Godot 4.7 或更新版本打开 `project.godot`，等待 Compute Shader 导入，按 **F6** 运行 `demo/main.tscn`，或按 **F5** 运行项目。标准版和 .NET 版均可，本项目使用 GDScript。

| 输入 | 效果 |
| --- | --- |
| WASD / 方向键 | 相机相对移动角色，留下推雾尾迹 |
| Shift | 加速移动 |
| 鼠标左键按下 / 按住 / 拖动 | 按下立即推开中心雾，按住持续挤压，外围堆积成浓雾环；划动方向决定推力方向 |
| Space | 在鼠标位置产生扩张冲击波，把中心雾推向外圈，再逐渐散开 |
| 鼠标右键拖动 | 环绕相机 |
| 滚轮 | 相机缩放 |
| R / P / Tab | 重置 / 暂停流动 / 显示场数据 |

左侧滑块调整本次运行的密度、恢复半衰期、风速和高度。Field 面板可切换密度、速度、有符号距离三种视图。FPS 是整个运行画面的瞬时帧率，不是雾系统的独立耗时或性能承诺。

## 在编辑器中调整

打开 `demo/main.tscn`，在 3D 工具栏启用**使用场景环境 / 使用场景灯光**，即可看到场景自身的灯光与雾。请使用 Forward+；Mobile 和 Compatibility 不支持此处的原生体积雾。

1. 选择 **FogField**，展开 Inspector 中的 **Settings** 资源。外观参数在下一帧同步；流动参数在下一模拟步生效，无需重新运行。
2. **Preview In Editor** 控制编辑器中是否播放流动。关闭后仍可改变外观、移动障碍、调整区域；已有尾迹冻结。**Simulation Enabled** 同样控制运行时模拟。
3. **重置雾场** 按钮重建初始疏密分布、清除尾迹，不重建场景节点。修改 Resolution 会重新分配 GPU 纹理并自动重置。
4. **Obstacles** 下的柱子与墙可以直接平移、绕 Y 轴旋转或调整尺寸。标准预制体开启 `Sync Prefab Geometry` 时，`Box Size` / `Radius` / `Height` 会同步网格和物理碰撞体。
5. 选择 **Lighting/WarmSpot**、**Lighting/CoolOmni** 或方向光，直接调整原生 Light3D 属性。`Light Volumetric Fog Energy` 控制灯光影响雾的强度；`Shadow Enabled` 也影响雾中的几何阴影。
6. 选择 **WorldEnvironment → Environment → Volumetric Fog**，调整可见距离、时间重投影和环境注入。选择 **CameraRig** 调整预览角度、距离和目标偏移。
7. 选择主场景根节点 **InteractiveFogDemo**，在 **鼠标推雾 / 空格冲击波** 分组中调整点击推力、冲击持续时间、目标半径、清除量、堆积倍率和环宽。按住左键的持续推力仍由 **MouseBrush/FogInteractor** 提供；它的环宽和倍率由根节点统一同步。
8. **FogField → Settings → 挤压与爆开** 提供密度上限、浓雾环释放半衰期、厚实程度和增高比例。普通雾的密度基准为 1；压缩后允许超过 1，数据视图里这些高密度区域显示为暖色。浓雾环自身仍按灯光与阴影渲染，不是发光圆环。

选中雾场时显示青色边界框，选中障碍足迹时显示橙色轮廓，选中交互器时显示蓝色作用半径。这些是编辑器 Gizmo，不参与运行时渲染。如果看不到，请检查编辑器 Gizmos 菜单和项目的 `Interactive Fog Gizmos` 插件是否启用。

长期预设请在编辑器中保存 `FogSettings` 为 `.tres`。默认预设启用了 `resource_local_to_scene`，多个雾场实例在实例化后拥有独立的参数。运行游戏后改的是游戏进程中的资源；如需持久保存，请在停止运行后修改本地场景，或自行把参数保存为新预设。

## 主要参数

| 参数 | 默认值 | 调整含义 |
| --- | --- | --- |
| Area Size | 24 × 20 m | 世界 XZ 覆盖范围；原点是雾层底部中心 |
| Resolution | 128 × 128 | 状态与障碍纹理尺寸，越高越能保留细小尾迹 |
| Simulation Hz | 30 Hz | 独立于渲染帧率的更新频率 |
| Wind Velocity | (0.7, 0.18) m/s | 世界 X、Z 方向背景风速 |
| Wind Response / Velocity Damping | 0.8 / 0.25 | 回到背景风速的速度 / 额外速度阻尼 |
| Recovery Half Life | 3.2 s | 无流动时，当前密度与目标密度的差缩小一半所需时间 |
| Turbulence Strength / Scale | 0.65 / 0.65 | 程序化旋流加速度 / 空间频率 |
| Max Speed | 5 m/s | 速度限幅，同时约束搬运稳定性 |
| Obstacle Influence | 0.65 m | 障碍表面附近的导流范围 |
| Density Variation / Pattern Scale | 0.7 / 0.55 | **写入模拟场**的大尺度疏密强度与空间频率，轮廓会被流场搬运 |
| Thickness / Density | 1.5 m / 2.6 | 平静雾层厚度 / 光学密度倍率 |
| Max Density | 8 | 模拟密度上限，允许中心移出的雾堆到外围 |
| Compression Half Life | 1.6 s | 浓雾环超额密度的释放半衰期，独立于空洞恢复 |
| Compression Visibility / Height Boost | 0.9 / 0.8 | 压缩区的厚实程度 / 相对平静雾层的最大增高比例 |
| Albedo / Emission | 见 Inspector | 散射颜色 / 暗部补色；Emission 不照亮场景物体 |
| Height Falloff | 1.8 | 越大越贴地 |
| Edge Fade / Obstacle Fade | 1.25 / 0.18 m | 区域边缘 / 障碍周围的软化宽度 |
| Detail Scale / Amount / Speed | 1.4 / 0.8 / 0.32 | **仅渲染层**的细碎噪声，提供翻滚轮廓与雾顶起伏 |

参数脚本中的 `##` 注释会作为 Inspector 提示显示，补充单位和行为说明。`FogInteractor3D` 的半径、清除速率、方向推力、径向推力、旋转推力、静止时是否作用和高度范围，也都可在 Inspector 编辑。

## 复用方式与文件结构

所有场景节点都在 `.tscn` 中声明。脚本只创建必要的网格/碰撞资源副本、材质副本和 GPU 资源，不用代码拼装运行场景。

```text
fog/
  scenes/fog_field.tscn          可独立实例化的雾场及 FogVolume
  presets/default_fog.tres      默认参数资源
  fog_settings.gd               带 changed 通知的可调参数
  fog_field.gd                  场景接口、参数同步、交互收集、固定步调度
  fog_simulation_gpu.gd         渲染线程、GPU 资源生命周期、Compute 调度
  fog_obstacle.gd               二维障碍足迹与标准预制体几何同步
  fog_interactor.gd             持续交互器的数据组件
  fog_burst.gd                  按模拟时间扩张的冲击状态，不生成场景节点
  shaders/build_obstacles.glsl  构建距离与法线纹理，几何变化时才运行
  shaders/prepare_interactions.glsl  在 GPU 上估算中心本步移出的雾量
  shaders/simulate.glsl         搬运、导流、交互、阻尼、密度恢复
  shaders/ground_fog.gdshader   高度轮廓、噪声和原生体积受光
demo/
  main.tscn                    地面、障碍、角色、灯光、相机、UI 的场景装配
  player.tscn / player.gd       物理移动角色，交互器作为子节点
  obstacles/*.tscn             可调柱子与墙预制体
  hud.tscn / hud.gd            独立调参面板与 GPU 数据视图
  demo_controller.gd           鼠标地面拾取、笔刷与快捷键
  orbit_camera.gd              编辑器和运行时共用的相机参数
addons/fog_gizmos/              仅编辑器使用的辅助轮廓
tests/                         真实 GPU 与编辑器行为验收
artifacts/                     验收截图与临时保存检查，不进入资源导入流程
```

把 `fog/scenes/fog_field.tscn` 实例化到其他场景，启用该场景环境的体积雾，将环境的全局体积密度设为 0，即可只显示此处的局部贴地雾。雾场保持旋转为零、缩放为一；用 `Area Size` 调整范围，平移节点调整位置和底部高度。

在物体下添加带 `fog_obstacle.gd` 的 Node3D 即可提供足迹。自定义模型关闭 `Sync Prefab Geometry`，独立设置足迹尺寸。障碍无需物理碰撞体才能影响雾，角色碰撞则仍需物理形状。足迹是二维的，不会根据模型高度自动投影。

在移动物体下添加带 `fog_interactor.gd` 的 Node3D 即可持续推雾。所有注册组件由雾场收集，销毁节点后自动移出组。多个雾场分别记录交互器上一位置，互不消耗状态。

一次性冲击可直接调用：

```gdscript
# 世界坐标、作用半径、水平速度增量、清除量、径向速度增量、旋转速度增量。
$FogField.disturb(Vector3(0, 0, 2), 2.5, Vector2(1, 0), 3.0, 4.0, 1.0)

# 在 0.4 秒内扩张到 3 米，外围窄环堆积雾量。末两项为堆积倍率、环的半宽。
$FogField.burst(Vector3(0, 0, 2), 3.0, 0.4, 8.0, 5.0, 0.5, 1.8, 0.45)
```

`disturb()` 还可追加 `compression_gain`、`compression_width`。倍率 1 近似等量重分配，0 关闭堆积，大于 1 会夸张爆开效果。实际环宽至少覆盖一个模拟格；密度受 `Max Density` 限制。空格波前随模拟推进，暂停时冻结，重置时清除。

## 模拟与开销

状态 RGBA16F 保存密度、两个水平速度分量和相对目标的压缩量。两张状态纹理交替读写，另有固定展示纹理与障碍纹理；高级材质通过 `Texture2DRD` 直接采样主 RenderingDevice 的资源。CPU 只打包少量交互参数，常规运行不读取 GPU 结果，也不调用 `sync()`。

存在交互时，预处理 Compute 为每个作用点使用 12×12 个采样点估算本步移出的雾量，再交给主模拟按窄环面积重分配。采样在 GPU 上每个作用点执行一次，不在每个雾格重复积分，不需要额外状态纹理；只新增很小的缓冲。没有交互时跳过该步骤。多个重叠作用、移动边界、密度上限和恢复项仍会引入守恒误差，属于表现性挤压。

压缩量还会让浓雾环减少噪声空隙并增高。`Thickness` 保持控制平静高度，FogVolume 与编辑器辅助线会按 `Thickness × (1 + Compression Height Boost)` 自动预留最大空间。设增高比例为 0 可只保留密度堆积；增高会扩大局部雾着色覆盖范围。

每步先反向追踪读取上一状态，再施加风、旋流、交互与边界导流，最后进行指数恢复。障碍距离场包含到最近固体的距离与朝自由空间的法线：速度的入射分量在边缘被削弱，切向分量保留。回溯路径还分段检查固体，避免从墙另一侧直接采样。粗于网格的障碍最可靠；小于一个格的薄物体请增加足迹 padding 或提高分辨率。

四张 128² RGBA16F 纹理的数据约为 **0.5 MiB**；256² 约为 **2 MiB**。这些数字不包含体积雾 froxel、阴影、纹理包装、噪声和引擎额外资源。默认最多 32 个障碍足迹、单步 16 个交互作用，超限会明确提示并忽略后续项。若扩容，需同时评估 shader 循环与缓冲大小。

优先从以下方面调成本：

1. 状态保持 128² / 30 Hz；交互精度不足才提高。
2. 项目设置 `Rendering → Environment → Volumetric Fog` 默认使用 Volume Size 96、Volume Depth 64。减小会降低渲染开销，但也会降低细节与稳定性。
3. 缩短 Environment 的体积雾 Length，减少参与体积雾和阴影的动态灯。此 demo 为了展示受光，提供了三盏参与雾的灯。
4. 快速冲击存在拖影时，降低时间重投影 Amount；关闭它会更及时，但噪点和采样抖动可能更明显。

极低帧率时每个画面最多更新一个模拟步，会主动放慢模拟，避免卡顿后堆积大量补帧任务。单步搬运最多检查八段，位移超出预算时截短，优先避免跨墙。

这是二维表现模拟，没有压力投影、严格质量守恒、雾自身的多次散射或雾自身投影。密度恢复有意补充雾；细碎着色噪声不参与物理搬运。适用于平地、浅厚度雾，不能直接覆盖洞穴多层地形或真实三维翻腾烟气。需要更强的挤压与堆积时，可以在当前速度场后加入压力求解而保留场景接口。

## 验证

将下面的 `godot` 换为本机 Godot 控制台可执行文件。图形测试需要真实渲染设备，不能使用 `--headless`。

```powershell
godot --headless --editor --path . --import --quit
godot --path . --script res://tests/gpu_smoke.gd
godot --path . --fixed-fps 60 --script res://tests/fog_compression.gd
godot --editor --path . -- --fog-editor-smoke
```

GPU 验收检查打散后持久密度降低、恢复、障碍内部清空、边界导流、移动障碍、暂停时遮罩刷新、厚度热更新、分辨率重建、资源替换后 UI 重新连接，以及实际体积雾对最终画面的影响。保存 `artifacts/preview.png` 和 `artifacts/interaction.png`。

挤压回归通过真实 GPU 检查中心清空、外围密度大于基准、近似雾量重分配、空区不凭空生出浓雾环、密度上限、独立消散、持续笔刷及鼠标/空格的输入处理，并检查波前半径随时间增大。保存近距离观察图 `artifacts/burst.png`；截图只改变测试相机，不修改主场景相机参数。

编辑器验收在实际 `@tool` 环境中检查预览播放/暂停、参数同步、预制体几何更新、重置按钮及场景保存。瞬态材质通过 RenderingServer 绑定，不覆盖 `.tscn` 中的 material 属性，避免将 GPU 纹理资源保存到场景。

本次在 Windows / Godot 4.7.2 / D3D12 Forward+ / RTX 3050 Ti Laptop 上完成了 23 项 GPU 相关检查、10 项编辑器检查，以及无头导入和启动检查，最终输出无报错。尚未进行独立 GPU 耗时基准或其他显卡、后端的兼容性测试。

设计所用的官方接口说明：[体积雾](https://docs.godotengine.org/en/latest/tutorials/3d/volumetric_fog.html)、[Fog Shader](https://docs.godotengine.org/en/latest/tutorials/shaders/shader_reference/fog_shader.html)、[Texture2DRD](https://docs.godotengine.org/en/latest/classes/class_texture2drd.html)、[渲染线程调度](https://docs.godotengine.org/en/latest/classes/class_renderingserver.html#class-renderingserver-method-call-on-render-thread)。
