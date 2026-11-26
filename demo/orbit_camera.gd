@tool
class_name FogDemoOrbitCamera
extends Node3D
## 编辑器内直接调整相机角度、距离；运行时右键拖动环绕、滚轮缩放。

@export_range(-180.0, 180.0, 0.1, "degrees") var yaw_degrees := 16.0:
	set(value):
		yaw_degrees = value
		set_process(true)
@export_range(12.0, 85.0, 0.1, "degrees") var pitch_degrees := 52.0:
	set(value):
		pitch_degrees = value
		set_process(true)
@export_range(4.0, 60.0, 0.1, "suffix:m") var distance := 29.0:
	set(value):
		distance = value
		set_process(true)
@export var target_offset := Vector3(0.0, 0.2, 0.0):
	set(value):
		target_offset = value
		set_process(true)
@export_range(0.05, 1.0, 0.01) var mouse_sensitivity := 0.22
@export_range(0.1, 5.0, 0.1) var zoom_step := 1.5


func _ready() -> void:
	set_notify_transform(true)
	set_process(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		set_process(true)


func _process(_delta: float) -> void:
	var camera := get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		return
	set_process(false)
	var yaw := deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	camera.position = target_offset + offset
	camera.look_at(to_global(target_offset), Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		yaw_degrees = wrapf(yaw_degrees - event.relative.x * mouse_sensitivity, -180.0, 180.0)
		pitch_degrees = clampf(pitch_degrees + event.relative.y * mouse_sensitivity, 12.0, 85.0)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(4.0, distance - zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(60.0, distance + zoom_step)
