@tool
class_name FogInteractor3D
extends Node3D
## 向同一流体速度场施力；不直接擦密度，不生成预设浓雾环。

@export var enabled := true
enum Mode { STIR, PART }
@export var mode: Mode = Mode.STIR
@export_range(0.1, 8.0, 0.05, "suffix:m") var radius := 0.85
## 移动速度转为局部流体加速度的倍率。
@export_range(0.0, 15.0, 0.1) var directional_strength := 6.0
## 随移动速度增强的切向力，允许旋转尾流。
@export_range(-15.0, 15.0, 0.1) var swirl_strength := 0.7
## 划开模式沿路径两侧拨雾的峰值速度，不直接删除密度。
@export_range(0.0, 6.0, 0.1) var part_speed := 3.0
## 路径离开后保留短时拨开作用，保证快速拖动也能形成连续缺口。
@export_range(0.1, 0.8, 0.05, "suffix:s") var part_duration := 0.3
@export var emit_when_stationary := false
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var minimum_speed := 0.03
@export_range(-1.0, 10.0, 0.1, "suffix:m") var vertical_reach := 1.5


func _enter_tree() -> void:
	add_to_group(&"interactive_fog_interactors")


## 两个 vec4：中心/半径/切向加速度，方向加速度/保留。
func pack_gpu_stamp(horizontal_velocity: Vector2) -> PackedFloat32Array:
	return PackedFloat32Array([
		global_position.x, global_position.z, radius, swirl_strength * horizontal_velocity.length(),
		horizontal_velocity.x * directional_strength,
		horizontal_velocity.y * directional_strength, 0.0, 0.0,
	])
