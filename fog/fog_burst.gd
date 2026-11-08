@tool
class_name FogBurst
extends RefCounted
## 扩张的径向搬运场与少量残留旋流。雾量通过单元面通量重分配。

const MAX_SPEED := 8.0
var world_position: Vector3
var radius: float
var duration: float
var strength: float
var swirl: float
var rim_width: float
var elapsed := 0.0
var _initial_radius: float
var _front_radius := 0.0
var _front_speed := 0.0


func _init(position: Vector3, size: float, lifetime: float, gain: float, spin: float,
		width := 0.45) -> void:
	world_position = position
	radius = maxf(size, 0.3)
	strength = clampf(gain, 0.0, 2.0)
	swirl = spin
	rim_width = clampf(width, 0.08, radius * 0.6)
	_initial_radius = clampf(radius * 0.15, 0.2, 0.45)
	# 半径的 smoothstep 导数最大为 1.5；限制峰值速度，避免极短冲击需要无界子步。
	duration = maxf(maxf(lifetime, 0.2), 1.5 * (radius - _initial_radius) * strength / MAX_SPEED)


func _radius_at(time: float) -> float:
	var p := clampf(time / duration, 0.0, 1.0)
	return lerpf(_initial_radius, radius, p * p * (3.0 - 2.0 * p))


func advance(step: float) -> PackedFloat32Array:
	var before := _radius_at(elapsed)
	var active := minf(step, duration - elapsed)
	elapsed = minf(elapsed + step, duration)
	var after := _radius_at(elapsed)
	_front_radius = (before + after) * 0.5
	_front_speed = (after - before) / step * strength
	var spin_rate := swirl * active / maxf(step * duration, 0.0001)
	# 旋流经过正常压力求解并留下尾流；径向扩散在独立守恒搬运阶段执行。
	return PackedFloat32Array([
		world_position.x, world_position.z, _front_radius + rim_width, spin_rate,
		0.0, 0.0, 0.0, 0.0,
	])


func pack_expansion() -> PackedFloat32Array:
	return PackedFloat32Array([
		world_position.x, world_position.z, _front_radius, _front_speed,
		rim_width, 0.0, 0.0, 0.0,
	])


func is_finished() -> bool:
	return elapsed >= duration
