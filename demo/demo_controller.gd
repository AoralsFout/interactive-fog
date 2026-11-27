extends Node3D
## 演示输入与面板胶水。雾算法完全位于 fog/，不依赖此控制器或这些 UI 节点。
signal brush_mode_changed(mode: int)
enum BrushMode { STIR, PART, BURST }

@export var brush_mode: BrushMode = BrushMode.STIR:
	set(value):
		var next := clampi(value, BrushMode.STIR, BrushMode.BURST)
		if brush_mode == next:
			return
		brush_mode = next
		_painting = false
		_terrain_clicks.clear()
		if is_instance_valid(_brush_interactor):
			_brush_interactor.enabled = false
		if is_node_ready():
			_sync_brush_mode()
@export_node_path("Node3D") var fog_field_path := NodePath("FogField")
@export_node_path("Camera3D") var camera_path := NodePath("CameraRig/Camera3D")
@export_node_path("Node3D") var brush_path := NodePath("MouseBrush")
@export_node_path("Node3D") var player_path := NodePath("Player")
@export_flags_3d_physics var terrain_brush_mask := 2
@export_group("鼠标推雾")
@export_range(0.2, 5.0, 0.1, "suffix:m") var brush_radius := 1.4:
	set(value):
		brush_radius = value
		if is_node_ready():
			_sync_brush_shape()
## 单击注入偏心卷流；拖动则由笔刷的实际世界速度持续施力。
@export_range(0.0, 8.0, 0.1) var brush_click_swirl := 2.0
@export_group("鼠标划开")
@export_range(0.15, 2.0, 0.05, "suffix:m") var part_radius := 0.65:
	set(value):
		part_radius = value
		if is_node_ready():
			_sync_brush_shape()
@export_range(0.0, 6.0, 0.1, "suffix:m/s") var part_speed := 3.0:
	set(value):
		part_speed = value
		if is_node_ready():
			_sync_brush_shape()
@export_range(0.1, 0.8, 0.05, "suffix:s") var part_duration := 0.3:
	set(value):
		part_duration = value
		if is_node_ready():
			_sync_brush_shape()
@export_group("鼠标爆开")
@export_range(0.5, 8.0, 0.1, "suffix:m") var burst_radius := 3.0:
	set(value):
		burst_radius = value
		if is_node_ready():
			_sync_brush_shape()
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
@onready var _player := get_node(player_path) as FogDemoPlayer
@onready var _hud := $HUD as FogDemoHUD

var _painting := false
var _valid_brush := false
var _terrain_clicks: Array[Vector2] = []
var _cursor_material: StandardMaterial3D
var _custom_fog_active := false
var _previous_native_fog := true
@onready var _environment: Environment = $WorldEnvironment.environment


func _ready() -> void:
	_cursor_material = _brush_ring.material_override.duplicate() as StandardMaterial3D
	_brush_ring.material_override = _cursor_material
	_hud.brush_mode_selected.connect(set_brush_mode)
	_hud.fog_quality_selected.connect(_set_fog_renderer)
	brush_mode_changed.connect(_hud.set_brush_mode)
	_player.jumped.connect(_gather_at_takeoff)
	_player.landed.connect(_spread_at_landing)
	if _field.height_map != null:
		var foot_interactor := _player.get_node("FogInteractor") as FogInteractor3D
		foot_interactor.vertical_reach = 0.1
	_sync_brush_mode()


func set_brush_mode(mode: int) -> void:
	brush_mode = mode


func _set_fog_renderer(index: int) -> void:
	var custom := index in [FogDemoHUD.FogQuality.THIN_LAYER, FogDemoHUD.FogQuality.HORIZONTAL_SLICES]
	if custom != _custom_fog_active:
		if custom:
			_previous_native_fog = _environment.volumetric_fog_enabled
		_environment.volumetric_fog_enabled = false if custom else _previous_native_fog
		_custom_fog_active = custom
	_field.get_node("HorizontalSlices").set_active(index == FogDemoHUD.FogQuality.HORIZONTAL_SLICES)


func _exit_tree() -> void:
	if _custom_fog_active:
		_environment.volumetric_fog_enabled = _previous_native_fog


func _sync_brush_mode() -> void:
	_brush_interactor.mode = FogInteractor3D.Mode.PART if brush_mode == BrushMode.PART else FogInteractor3D.Mode.STIR
	_sync_brush_shape()
	match brush_mode:
		BrushMode.STIR:
			_cursor_material.albedo_color = Color(0.44, 0.85, 0.78)
		BrushMode.PART:
			_cursor_material.albedo_color = Color(1.0, 0.68, 0.3)
		BrushMode.BURST:
			_cursor_material.albedo_color = Color(0.78, 0.66, 1.0)
	brush_mode_changed.emit(brush_mode)


func _sync_brush_shape() -> void:
	_brush_interactor.radius = part_radius if brush_mode == BrushMode.PART else brush_radius
	_brush_interactor.part_speed = part_speed
	_brush_interactor.part_duration = part_duration
	var radius := burst_radius if brush_mode == BrushMode.BURST else _brush_interactor.radius
	_brush_ring.scale = Vector3(radius, 1.0, radius)


func _gather_at_takeoff(foot_position: Vector3) -> void:
	if _touches_ground(foot_position):
		_field.gather(foot_position, 1.0)


func _spread_at_landing(foot_position: Vector3) -> void:
	if _touches_ground(foot_position):
		_field.burst(foot_position, 1.45, 0.32, 0.55, 0.0, 0.3)


func _touches_ground(foot_position: Vector3) -> bool:
	return _field.height_map == null or absf(foot_position.y - _field.get_ground_height(foot_position)) <= 0.35


func _process(_delta: float) -> void:
	if _field.height_map == null:
		_update_brush()


func _physics_process(_delta: float) -> void:
	if _field.height_map == null:
		return
	for mouse in _terrain_clicks:
		_update_brush_position(mouse)
		_apply_brush_click()
	_terrain_clicks.clear()
	_update_brush()


func _update_brush() -> void:
	_update_brush_position(get_viewport().get_mouse_position())
	# GUI 消耗按下事件；松开状态还通过 Input 检查，避免在面板上松开时留下粘连笔刷。
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_painting = false
	var hovered := get_viewport().gui_get_hovered_control()
	var over_panel := hovered != null and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE
	if not _valid_brush or over_panel:
		_painting = false
	_brush.visible = _valid_brush and not over_panel
	_brush_interactor.enabled = _valid_brush and _painting and not over_panel


func _update_brush_position(mouse: Vector2) -> void:
	var ray_origin := _camera.project_ray_origin(mouse)
	var ray_direction := _camera.project_ray_normal(mouse)
	var hit: Variant
	var normal := Vector3.UP
	if _field.height_map != null:
		var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_direction * _camera.far, terrain_brush_mask)
		var result := get_world_3d().direct_space_state.intersect_ray(query)
		hit = result.get("position")
		normal = result.get("normal", Vector3.UP)
	else:
		var ground_plane := Plane(Vector3.UP, _field.global_position.y)
		hit = ground_plane.intersects_ray(ray_origin, ray_direction)
	_valid_brush = hit != null
	if _valid_brush:
		var point: Vector3 = hit
		var local := point - _field.global_position
		_valid_brush = absf(local.x) < _field.settings.area_size.x * 0.5 and absf(local.z) < _field.settings.area_size.y * 0.5
		_brush.global_position = point + Vector3.UP * 0.045
		if _field.height_map != null:
			_brush.global_basis = Basis(Quaternion(Vector3.UP, normal))


func _apply_brush_click() -> void:
	_painting = _valid_brush and brush_mode != BrushMode.BURST
	if not _valid_brush:
		return
	var center := _brush.global_position
	match brush_mode:
		BrushMode.STIR:
			_field.disturb(center, brush_radius, Vector2.ZERO, brush_click_swirl)
		BrushMode.PART:
			_field.part(center, center, part_radius, part_speed, part_duration)
		BrushMode.BURST:
			_field.burst(center, burst_radius, burst_duration, burst_strength, burst_swirl, burst_rim_width)


func _input(event: InputEvent) -> void:
	# 空格专用于跳跃，避免输入同时激活有焦点的面板按钮。
	if event.is_action(&"jump"):
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			_painting = false
		elif _field.height_map != null:
			# Physics space queries belong to the following physics tick.
			_terrain_clicks.append(event.position)
		else:
			_update_brush_position(event.position)
			_apply_brush_click()
	elif event.is_action_pressed("fog_tool_toggle"):
		brush_mode = (brush_mode + 1) % BrushMode.size()
	elif event.is_action_pressed("fog_reset"):
		_field.reset_simulation()
	elif event.is_action_pressed("fog_pause"):
		_hud.toggle_pause()
	elif event.is_action_pressed("fog_debug"):
		_hud.toggle_debug()
