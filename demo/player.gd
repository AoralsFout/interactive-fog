class_name FogDemoPlayer
extends CharacterBody3D
## 简单的相机相对移动。雾交互由子节点 FogInteractor3D 负责，移动逻辑无需依赖 GPU。

@export_range(0.5, 12.0, 0.1, "suffix:m/s") var move_speed := 4.0
@export_range(1.0, 40.0, 0.5) var acceleration := 14.0
@export_range(1.0, 3.0, 0.1) var sprint_multiplier := 1.7
@export_node_path("Camera3D") var camera_path: NodePath
## 演示平台边界；不限制复用此角色到其他场景，可在 Inspector 关闭。
@export var limit_to_demo_area := true
@export var movement_bounds := Vector2(11.0, 9.0)

@onready var _camera := get_node_or_null(camera_path) as Camera3D


func _physics_process(delta: float) -> void:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := Vector3(input.x, 0.0, input.y)
	if _camera != null:
		var right := _camera.global_basis.x
		var back := _camera.global_basis.z
		right.y = 0.0
		back.y = 0.0
		direction = right.normalized() * input.x + back.normalized() * input.y
	var speed := move_speed * (sprint_multiplier if Input.is_action_pressed("sprint") else 1.0)
	velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * delta)
	velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * delta)
	if not is_on_floor():
		velocity.y -= 20.0 * delta
	else:
		velocity.y = 0.0
	move_and_slide()
	if limit_to_demo_area:
		global_position.x = clampf(global_position.x, -movement_bounds.x, movement_bounds.x)
		global_position.z = clampf(global_position.z, -movement_bounds.y, movement_bounds.y)
