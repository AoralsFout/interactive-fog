extends Node3D
## 演示输入与面板胶水。雾算法完全位于 fog/，不依赖此控制器或这些 UI 节点。
signal brush_mode_changed(mode: int)
enum BrushMode { STIR, PART }

@export var brush_mode: BrushMode = BrushMode.STIR:
	set(value):
		var next := clampi(value, BrushMode.STIR, BrushMode.PART)
		if brush_mode == next:
			return
		brush_mode = next
		_painting = false
		if is_instance_valid(_brush_interactor):
			_brush_interactor.enabled = false
		if is_node_ready():
			_sync_brush_mode()
@export_node_path("Node3D") var fog_field_path := NodePath("FogField")
@export_node_path("Camera3D") var camera_path := NodePath("CameraRig/Camera3D")
@export_node_path("Node3D") var brush_path := NodePath("MouseBrush")
@export_node_path("Node3D") var player_path := NodePath("Player")
@export_group("鼠标推雾")
@export_range(0.2, 5.0, 0.1, "suffix:m") var brush_radius := 1.4
## 单击注入偏心卷流；拖动则由笔刷的实际世界速度持续施力。
@export_range(0.0, 8.0, 0.1) var brush_click_swirl := 2.0
@export_group("鼠标划开")
@export_range(0.15, 2.0, 0.05, "suffix:m") var part_radius := 0.65
@export_range(0.0, 6.0, 0.1, "suffix:m/s") var part_speed := 3.0
@export_range(0.1, 0.8, 0.05, "suffix:s") var part_duration := 0.3
@export_group("空格径向扩散")
@export_range(0.5, 8.0, 0.1, "suffix:m") var burst_radius := 3.0
@export_range(0.0, 2.0, 0.05) var burst_strength := 1.0
## 时间过短时会按冲击速度上限自动延长，保持搬运稳定。
@export_range(0.2, 2.0, 0.05, "suffix:s") var burst_duration := 0.65
@export_range(0.0, 8.0, 0.1) var burst_swirl := 1.5
@export_range(0.08, 1.5, 0.05, "suffix:m") var burst_rim_width := 0.45

@onready var _field := get_node(fog_field_path) as InteractiveFogField
@onready var _camera := get_node(camera_path) as Camera3D
@onready var _brush := get_node(brush_path) as Node3D
@onready var _brush_interactor := _brush.get_node("FogInteractor") as FogInteractor3D
@onready var _brush_ring := _brush.get_node("Ring") as MeshInstance3D
@onready var _player := get_node(player_path) as Node3D
@onready var _hud := $HUD as FogDemoHUD

var _painting := false
var _valid_brush := false
var _cursor_material: StandardMaterial3D


func _ready() -> void:
	_cursor_material = _brush_ring.material_override.duplicate() as StandardMaterial3D
	_brush_ring.material_override = _cursor_material
	_hud.brush_mode_selected.connect(set_brush_mode)
	brush_mode_changed.connect(_hud.set_brush_mode)
	_sync_brush_mode()


func set_brush_mode(mode: int) -> void:
	brush_mode = mode


func _sync_brush_mode() -> void:
	_brush_interactor.mode = FogInteractor3D.Mode.PART if brush_mode == BrushMode.PART else FogInteractor3D.Mode.STIR
	_sync_brush_shape()
	_cursor_material.albedo_color = Color(1.0, 0.68, 0.3) if brush_mode == BrushMode.PART else Color(0.44, 0.85, 0.78)
	brush_mode_changed.emit(brush_mode)


func _sync_brush_shape() -> void:
	var radius := part_radius if brush_mode == BrushMode.PART else brush_radius
	_brush_interactor.radius = radius
	_brush_interactor.part_speed = part_speed
	_brush_interactor.part_duration = part_duration
	_brush_ring.scale = Vector3(radius, 1.0, radius)


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
	if not _valid_brush or over_panel:
		_painting = false
	_brush.visible = _valid_brush and not over_panel
	_brush_interactor.enabled = _valid_brush and _painting and not over_panel
	_sync_brush_shape()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_painting = event.pressed
		if event.pressed and _valid_brush:
			if brush_mode == BrushMode.PART:
				_field.part(_brush.global_position, _brush.global_position, part_radius, part_speed, part_duration)
			else:
				_field.disturb(_brush.global_position, brush_radius, Vector2.ZERO, brush_click_swirl)
	elif event.is_action_pressed("fog_tool_toggle"):
		brush_mode = BrushMode.STIR if brush_mode == BrushMode.PART else BrushMode.PART
	elif event.is_action_pressed("fog_burst"):
		var position_for_burst := _brush.global_position if _valid_brush else _player.global_position
		_field.burst(position_for_burst, burst_radius, burst_duration, burst_strength, burst_swirl, burst_rim_width)
	elif event.is_action_pressed("fog_reset"):
		_field.reset_simulation()
	elif event.is_action_pressed("fog_pause"):
		_hud.toggle_pause()
	elif event.is_action_pressed("fog_debug"):
		_hud.toggle_debug()
