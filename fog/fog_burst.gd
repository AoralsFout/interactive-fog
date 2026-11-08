@tool
class_name FogBurst
extends RefCounted
## 在有限时间内注入偏心旋涡和方向冲量。密度始终由速度搬运。

var world_position: Vector3
var radius: float
var duration: float
var strength: float
var swirl: float
var elapsed := 0.0


func _init(position: Vector3, size: float, lifetime: float, speed: float, spin: float) -> void:
	world_position = position
	radius = maxf(size, 0.1)
	duration = maxf(lifetime, 0.05)
	strength = speed
	swirl = spin


func advance(step: float) -> PackedFloat32Array:
	var active := minf(step, duration - elapsed)
	elapsed = minf(elapsed + step, duration)
	var rate := active / maxf(step * duration, 0.0001)
	var offset := Vector2(cos(elapsed * 1.3), sin(elapsed * 1.3)) * radius * 0.3
	# 一个偏心旋涡叠加方向冲量；压力投影会自然形成回流，形状不指定为圆环。
	return PackedFloat32Array([
		world_position.x + offset.x, world_position.z + offset.y, radius,
		swirl * rate, strength * rate, strength * 0.28 * rate, 0.0, 0.0,
	])


func is_finished() -> bool:
	return elapsed >= duration
