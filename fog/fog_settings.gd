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
@export_enum("64:64", "128:128", "256:256", "512:512") var resolution: int = 128:
	set(value):
		resolution = clampi(value, 32, 512)
		emit_changed()
## 固定模拟频率；与画面帧率分离。低频率适合缓慢流动的贴地雾。
@export_range(10.0, 60.0, 1.0, "suffix:Hz") var simulation_hz := 30.0:
	set(value):
		simulation_hz = clampf(value, 10.0, 60.0)
		emit_changed()

@export_group("流动与恢复")
## X 对应世界 X，Y 对应世界 Z，单位米/秒。
@export var wind_velocity := Vector2(0.7, 0.18):
	set(value):
		wind_velocity = value
		emit_changed()
## 雾回到背景风速的速度。调低可使交互产生的尾流持续更久。
@export_range(0.0, 8.0, 0.05) var wind_response := 0.8:
	set(value):
		wind_response = maxf(value, 0.0)
		emit_changed()
## 额外速度的阻尼；采用指数衰减，不随帧率改变。
@export_range(0.0, 5.0, 0.05) var velocity_damping := 0.25:
	set(value):
		velocity_damping = maxf(value, 0.0)
		emit_changed()
## 密度差恢复一半所需时间。实际还会受到周边雾的流动回填影响。
@export_range(0.2, 20.0, 0.1, "suffix:s") var recovery_half_life := 3.2:
	set(value):
		recovery_half_life = maxf(value, 0.2)
		emit_changed()
## 程序化旋流的加速度。它提供低成本扰动，不进行三维流体求解。
@export_range(0.0, 5.0, 0.05) var turbulence_strength := 0.65:
	set(value):
		turbulence_strength = maxf(value, 0.0)
		emit_changed()
## 旋流的空间频率，越小越宽大。
@export_range(0.1, 4.0, 0.05) var turbulence_scale := 0.65:
	set(value):
		turbulence_scale = maxf(value, 0.1)
		emit_changed()
## 速度上限也限制一次回溯的距离，避免大冲击产生跨墙采样。
@export_range(0.5, 15.0, 0.1, "suffix:m/s") var max_speed := 5.0:
	set(value):
		max_speed = maxf(value, 0.5)
		emit_changed()
## 障碍边缘开始导流的距离，单位米。
@export_range(0.05, 2.0, 0.05, "suffix:m") var obstacle_influence := 0.65:
	set(value):
		obstacle_influence = maxf(value, 0.05)
		emit_changed()
## 大尺度疏密也写进模拟状态，因此这些轮廓会随速度场绕障碍搬运。
## 设为 0 得到均匀基底；细碎的外观噪声仍由下方 detail_amount 控制。
@export_range(0.0, 1.0, 0.01) var density_variation := 0.7:
	set(value):
		density_variation = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.1, 2.0, 0.05) var density_pattern_scale := 0.55:
	set(value):
		density_pattern_scale = maxf(value, 0.1)
		emit_changed()

@export_group("挤压与爆开")
## 初始基准密度不超过 1；推雾后的外围允许堆积到此上限。
@export_range(1.0, 16.0, 0.1) var max_density := 8.0:
	set(value):
		max_density = clampf(value, 1.0, 16.0)
		emit_changed()
## 浓雾环的超额密度释放一半所需时间，不影响中心空洞的恢复速度。
@export_range(0.1, 10.0, 0.1, "suffix:s") var compression_half_life := 1.6:
	set(value):
		compression_half_life = maxf(value, 0.1)
		emit_changed()
## 压缩区填满高度轮廓与噪声空隙的程度，使浓雾环更厚实。0 表示沿用普通雾轮廓。
@export_range(0.0, 1.0, 0.01) var compression_visibility := 0.9:
	set(value):
		compression_visibility = clampf(value, 0.0, 1.0)
		emit_changed()
## 浓雾环相对平静雾层最多增高的比例，0.8 表示最多增加 80% 高度。
## 只增高真正压缩的区域，不改变普通雾的厚度；FogVolume 会自动预留这个空间。
@export_range(0.0, 1.5, 0.05) var compression_height_boost := 0.8:
	set(value):
		compression_height_boost = clampf(value, 0.0, 1.5)
		emit_changed()

@export_group("雾的外观")
## 平静雾层的高度。浓雾环可按 compression_height_boost 增高；太薄容易采样闪烁。
@export_range(0.2, 4.0, 0.05, "suffix:m") var thickness := 1.5:
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
@export_range(0.1, 5.0, 0.05) var detail_scale := 1.4:
	set(value):
		detail_scale = maxf(value, 0.1)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var detail_amount := 0.8:
	set(value):
		detail_amount = clampf(value, 0.0, 1.0)
		emit_changed()
## 噪声纹理本身的漂移比例，大尺度运动仍由模拟风场控制。
@export_range(0.0, 2.0, 0.01) var detail_speed := 0.32:
	set(value):
		detail_speed = maxf(value, 0.0)
		emit_changed()


## 渲染包围体使用的最大高度；各场景组件通过此接口共用一致的空间范围。
func get_volume_height() -> float:
	return thickness * (1.0 + compression_height_boost)
