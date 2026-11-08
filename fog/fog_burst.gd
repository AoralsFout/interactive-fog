@tool
class_name FogBurst
extends RefCounted
## 一次扩张冲击的状态，不创建任何场景节点。
## 按模拟时间推进，波前逐步扩大；暂停雾场时也会暂停冲击。

var world_position: Vector3
var radius: float
var duration: float
var clear_amount: float
var radial_speed: float
var swirl_speed: float
var compression_gain: float
var compression_width: float
var elapsed := 0.0


func _init(position: Vector3, target_radius: float, lifetime: float, clearing: float,
		push_speed: float, rotation_speed: float, gain: float, width: float) -> void:
	world_position = position
	radius = maxf(target_radius, 0.1)
	duration = maxf(lifetime, 0.05)
	clear_amount = maxf(clearing, 0.0)
	radial_speed = push_speed
	swirl_speed = rotation_speed
	compression_gain = maxf(gain, 0.0)
	compression_width = maxf(width, 0.05)


func advance(step: float) -> PackedFloat32Array:
	# 最后一小步按剩余时长缩放，避免不同模拟频率产生不同总冲量。
	var active_step := minf(step, duration - elapsed)
	elapsed = minf(elapsed + step, duration)
	var progress := elapsed / duration
	var expansion := 1.0 - (1.0 - progress) * (1.0 - progress)
	var front_radius := radius * lerpf(0.2, 1.0, expansion)
	var rate_scale := active_step / (step * duration)
	return PackedFloat32Array([
		world_position.x, world_position.z, front_radius, clear_amount * rate_scale,
		0.0, 0.0, radial_speed * rate_scale, swirl_speed * rate_scale,
		compression_gain, compression_width, 0.0, 0.0,
	])


func is_finished() -> bool:
	return elapsed >= duration
