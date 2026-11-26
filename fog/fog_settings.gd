@tool
class_name FogSettings
extends Resource
## 交互雾的美术与模拟参数。Resource 可另存为 .tres，方便不同场景共享一套预设。
## 每个 setter 发出 changed：编辑器修改后，雾场会在下一帧同步，无需重新运行。

@export_group("模拟区域")
## 覆盖的世界空间 XZ 尺寸，单位米。通过此参数调整区域，不要缩放 FogField 节点。
@export var area_size := Vector2(24.0, 20.0):
	set(value):
		area_size = value.max(Vector2(1.0, 1.0))
		emit_changed()
## 正方形模拟纹理边长。修改此项会重新分配 GPU 资源，并重置已有尾迹。
@export_enum("64:64", "128:128", "256:256", "512:512") var resolution: int = 256:
	set(value):
		resolution = clampi(value, 32, 512)
		emit_changed()
## 固定模拟频率；与画面帧率分离。低频率适合缓慢流动的贴地雾。
@export_range(10.0, 60.0, 1.0, "suffix:Hz") var simulation_hz := 30.0:
	set(value):
		simulation_hz = clampf(value, 10.0, 60.0)
		emit_changed()

@export_group("流动与边界供给")
## X 对应世界 X，Y 对应世界 Z，单位米/秒。
@export var wind_velocity := Vector2(0.7, 0.18):
	set(value):
		wind_velocity = value
		emit_changed()
## 雾回到背景风速的速度。调低可使交互产生的尾流持续更久。
@export_range(0.0, 8.0, 0.05) var wind_response := 0.12:
	set(value):
		wind_response = maxf(value, 0.0)
		emit_changed()
## 额外速度的阻尼；采用指数衰减，不随帧率改变。
@export_range(0.0, 5.0, 0.05) var velocity_damping := 0.08:
	set(value):
		velocity_damping = maxf(value, 0.0)
		emit_changed()
## 上风边界补充新雾的半衰期；不改变场内已形成的密度和尾流。
@export_range(0.2, 20.0, 0.1, "suffix:s") var inflow_half_life := 1.5:
	set(value):
		inflow_half_life = maxf(value, 0.2)
		emit_changed()
## 程序化旋流的加速度，包含大尺度流动与较弱的小涡旋，不进行三维流体求解。
@export_range(0.0, 5.0, 0.05) var turbulence_strength := 0.25:
	set(value):
		turbulence_strength = maxf(value, 0.0)
		emit_changed()
## 旋流的空间频率，越小越宽大。
@export_range(0.1, 4.0, 0.05) var turbulence_scale := 1.2:
	set(value):
		turbulence_scale = maxf(value, 0.1)
		emit_changed()
## 速度上限也限制一次回溯的距离，避免大冲击产生跨墙采样。
@export_range(0.5, 15.0, 0.1, "suffix:m/s") var max_speed := 5.0:
	set(value):
		max_speed = maxf(value, 0.5)
		emit_changed()
## 初始化及入流处的疏密变化，包含可交互的细丝。已有密度不会按此图案重新生成。
## 修改后按“重置雾场”重新初始化；0 为均匀密度。
@export_range(0.0, 1.0, 0.01) var density_variation := 1.0:
	set(value):
		density_variation = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.1, 2.0, 0.05) var density_pattern_scale := 0.55:
	set(value):
		density_pattern_scale = maxf(value, 0.1)
		emit_changed()

@export_group("流体求解")
enum PressureSolver { JACOBI, MULTIGRID }
## Jacobi 档保留已有预设的迭代次数。
@export var pressure_solver: PressureSolver = PressureSolver.JACOBI:
	set(value):
		pressure_solver = value
		emit_changed()
@export_range(1, 4, 1) var multigrid_cycles := 2:
	set(value):
		multigrid_cycles = clampi(value, 1, 4)
		emit_changed()
## 压力迭代次数；增加会更好地约束局部散度，也增加 GPU 开销。
@export_range(12, 100, 2) var pressure_iterations := 64:
	set(value):
		pressure_iterations = clampi(value, 12, 100)
		emit_changed()
## 补偿网格搬运损失的涡量；不生成独立于流场的装饰旋涡。
@export_range(0.0, 5.0, 0.05) var vorticity_strength := 1.5:
	set(value):
		vorticity_strength = clampf(value, 0.0, 5.0)
		emit_changed()

@export_group("径向冲击")
## 冲击波的密度安全上限；达到上限会损失部分雾量，避免极端重叠冲击无限堆积。
@export_range(2.0, 32.0, 0.1) var max_compressed_density := 16.0:
	set(value):
		max_compressed_density = clampf(value, 2.0, 32.0)
		emit_changed()
@export_group("雾的外观")
## 雾体最大高度。主密度决定局部高度，三维噪声只补充纵向层次。
@export_range(0.2, 4.0, 0.05, "suffix:m") var thickness := 0.85:
	set(value):
		thickness = maxf(value, 0.2)
		emit_changed()
@export_range(0.0, 5.0, 0.01) var density := 2.6:
	set(value):
		density = maxf(value, 0.0)
		emit_changed()
## 雾的散射颜色，会参与 Godot 原生体积光照计算。
@export var albedo := Color(0.78, 0.87, 0.94):
	set(value):
		albedo = value
		emit_changed()
## 极少的自发光用于保留暗部层次；它不会照亮场景物体。
@export var emission := Color(0.04, 0.055, 0.07):
	set(value):
		emission = value
		emit_changed()
## 越高越贴地；顶部始终平滑淡出，避免出现盒子截面。
@export_range(0.2, 6.0, 0.05) var height_falloff := 1.8:
	set(value):
		height_falloff = maxf(value, 0.2)
		emit_changed()
@export_range(0.05, 3.0, 0.05, "suffix:m") var edge_fade := 1.25:
	set(value):
		edge_fade = maxf(value, 0.05)
		emit_changed()
## 障碍周围的柔和空隙；小于一个模拟格时会自动采用一个格的宽度。
@export_range(0.02, 1.0, 0.02, "suffix:m") var obstacle_fade := 0.18:
	set(value):
		obstacle_fade = maxf(value, 0.02)
		emit_changed()
## 细节的空间频率；增大可缩小雾丝与局部卷边，不改变模拟网格。
@export_range(0.1, 5.0, 0.05) var detail_scale := 1.4:
	set(value):
		detail_scale = maxf(value, 0.1)
		emit_changed()
## 细节对密度和高度的影响；接近 1 时透明空隙更清楚，0 为平滑雾层。
@export_range(0.0, 1.0, 0.01) var detail_amount := 0.35:
	set(value):
		detail_amount = clampf(value, 0.0, 1.0)
		emit_changed()
## 辅助噪声坐标的刷新周期。两组错开淡入淡出，主密度历史不参与刷新。
@export_range(4.0, 40.0, 1.0, "suffix:s") var detail_reset_period := 12.0:
	set(value):
		detail_reset_period = clampf(value, 4.0, 40.0)
		emit_changed()
## 密度边缘的清晰度。过高会暴露体积雾采样网格，可适当降低或提高 Volume Size。
@export_range(0.0, 1.0, 0.01) var detail_sharpness := 0.75:
	set(value):
		detail_sharpness = clampf(value, 0.0, 1.0)
		emit_changed()
## 随流搬运坐标上的三维噪声域扭曲；不直接使用瞬时速度偏移纹理。
@export_range(0.0, 1.0, 0.01) var detail_warp := 0.65:
	set(value):
		detail_warp = clampf(value, 0.0, 1.0)
		emit_changed()


## 渲染包围体使用的最大高度；各场景组件通过此接口共用一致的空间范围。
func get_volume_height() -> float:
	return thickness

## 密度和材质坐标比速度场更细，但所有搬运共享同一投影后的速度。
func get_density_resolution() -> int:
	return resolution * 2
