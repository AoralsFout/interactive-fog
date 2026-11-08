@tool
class_name FogCut
extends RefCounted
## 一段短时拨雾路径；几何覆盖整个线段，快速拖动时也不留下采样断点。

var start: Vector2
var end: Vector2
var radius: float
var speed: float
var duration: float
var elapsed := 0.0


func _init(from: Vector3, to: Vector3, width: float, strength: float, lifetime: float) -> void:
	start = Vector2(from.x, from.z)
	end = Vector2(to.x, to.z)
	radius = maxf(width, 0.1)
	speed = clampf(strength, 0.0, 6.0)
	duration = clampf(lifetime, 0.1, 0.8)


func advance(step: float) -> PackedFloat32Array:
	var active := minf(step, duration - elapsed)
	var middle := elapsed + active * 0.5
	elapsed = minf(elapsed + step, duration)
	var fade := 1.0 - smoothstep(0.45, 1.0, middle / duration)
	# shape.z=1 标记线段拨开；强度含最后一个不完整时间步的比例。
	return PackedFloat32Array([
		start.x, start.y, radius, speed * fade * active / step,
		end.x, end.y, 1.0, 0.0,
	])


func is_finished() -> bool:
	return elapsed >= duration
