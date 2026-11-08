@tool
class_name FogInteractor3D
extends Node3D
## 放在角色、移动物体或鼠标笔刷下面即可推雾。节点原点是作用中心。
## 强度均按秒定义，模拟频率改变不会改变打散速度。

@export var enabled := true
@export_range(0.1, 8.0, 0.05, "suffix:m") var radius := 1.0
## 每秒清除的密度比例系数；中心最强，边缘平滑衰减。
@export_range(0.0, 20.0, 0.1) var clearing_rate := 5.0
## 物体移动速度转成推雾加速度的倍率。
@export_range(0.0, 15.0, 0.1) var directional_strength := 3.5
## 向四周推动的加速度，适合脚步、风扇和冲击。
@export_range(-15.0, 15.0, 0.1) var radial_strength := 2.0
## 切向加速度，正负代表不同旋转方向。
@export_range(-15.0, 15.0, 0.1) var swirl_strength := 1.0
## 关闭后，仅在移动时生效，避免静止角色持续吹走周围雾。
@export var emit_when_stationary := false
@export_range(0.0, 1.0, 0.01, "suffix:m/s") var minimum_speed := 0.08
## 原点离雾层超过此范围时不再影响地面雾。负值代表不检查高度。
@export_range(-1.0, 10.0, 0.1, "suffix:m") var vertical_reach := 1.5


func _enter_tree() -> void:
	add_to_group(&"interactive_fog_interactors")


func pack_gpu_stamp(horizontal_velocity: Vector2) -> PackedFloat32Array:
	return PackedFloat32Array([
		global_position.x, global_position.z, radius, clearing_rate,
		horizontal_velocity.x * directional_strength,
		horizontal_velocity.y * directional_strength,
		radial_strength, swirl_strength,
	])
