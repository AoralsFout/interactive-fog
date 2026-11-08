extends Node3D
## 演示输入与面板胶水。雾算法完全位于 fog/，不依赖此控制器或这些 UI 节点。

@export_node_path("Node3D") var fog_field_path := NodePath("FogField")
@export_node_path("Camera3D") var camera_path := NodePath("CameraRig/Camera3D")
@export_node_path("Node3D") var brush_path := NodePath("MouseBrush")
@export_node_path("Node3D") var player_path := NodePath("Player")
@export_range(0.2, 5.0, 0.1, "suffix:m") var brush_radius := 1.4
@export_range(0.5, 8.0, 0.1, "suffix:m") var burst_radius := 3.0
@export_range(0.0, 12.0, 0.1) var burst_speed := 5.0

@onready var _field := get_node(fog_field_path) as InteractiveFogField
@onready var _camera := get_node(camera_path) as Camera3D
@onready var _brush := get_node(brush_path) as Node3D
@onready var _brush_interactor := _brush.get_node("FogInteractor") as FogInteractor3D
@onready var _brush_ring := _brush.get_node("Ring") as MeshInstance3D
@onready var _player := get_node(player_path) as Node3D
@onready var _hud := $HUD as FogDemoHUD

var _painting := false
var _valid_brush := false


func _process(_delta: float) -> void:
	_update_brush()


func _update_brush() -> void:
	var mouse := get_viewport().get_mouse_position()
	var ray_origin := _camera.project_ray_origin(mouse)
	var ray_direction := _camera.project_ray_normal(mouse)
	var ground_plane := Plane(Vector3.UP, _field.global_position.y)
	var hit: Variant = ground_plane.intersects_ray(ray_origin, ray_direction)
	_valid_brush = hit != null
	if _valid_brush:
		var point: Vector3 = hit
		var local := point - _field.global_position
		_valid_brush = absf(local.x) < _field.settings.area_size.x * 0.5 and absf(local.z) < _field.settings.area_size.y * 0.5
		_brush.global_position = point + Vector3.UP * 0.045
	# GUI 消耗按下事件；松开状态还通过 Input 检查，避免在面板上松开时留下粘连笔刷。
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_painting = false
	var hovered := get_viewport().gui_get_hovered_control()
	var over_panel := hovered != null and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE
	_brush.visible = _valid_brush and not over_panel
	_brush_interactor.enabled = _valid_brush and _painting and not over_panel
	_brush_interactor.radius = brush_radius
	_brush_ring.scale = Vector3(brush_radius, 1.0, brush_radius)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_painting = event.pressed
	elif event.is_action_pressed("fog_burst"):
		var position_for_burst := _brush.global_position if _valid_brush else _player.global_position
		_field.disturb(position_for_burst, burst_radius, Vector2.ZERO, 4.5, burst_speed, 1.5)
	elif event.is_action_pressed("fog_reset"):
		_field.reset_simulation()
	elif event.is_action_pressed("fog_pause"):
		_hud.toggle_pause()
	elif event.is_action_pressed("fog_debug"):
		_hud.toggle_debug()
