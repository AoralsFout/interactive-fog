class_name FogDemoHUD
extends CanvasLayer
## 调参面板独立场景。% 唯一节点引用只在此 HUD 的 owner 范围内解析。
## 这些滑块修改本次运行的资源；长期预设请在编辑器的 FogSettings 中保存。

@export_node_path("Node3D") var fog_field_path := NodePath("../FogField")
@export_group("场图")
## 地图宽度；高度按雾场的 XZ 长宽比自动计算，避免把方向或障碍形状拉歪。
@export_range(240.0, 640.0, 10.0, "suffix:px") var field_map_width := 360.0:
	set(value):
		field_map_width = clampf(value, 240.0, 640.0)
		_sync_field_map_style()
## 箭头采样间隔，单位为面板像素；越小越密集，不影响模拟本身。
@export_range(4.0, 64.0, 1.0, "suffix:px") var arrow_spacing := 26.0:
	set(value):
		arrow_spacing = clampf(value, 4.0, 64.0)
		_sync_field_map_style()
## 满长度箭头代表的速度。超过此值时保持满长度，图例会显示这个限幅值。
@export_range(0.1, 10.0, 0.1, "suffix:m/s") var arrow_reference_speed := 2.0:
	set(value):
		arrow_reference_speed = maxf(value, 0.1)
		_sync_field_map_style()
## 低于此速度不绘制箭头，避免在停滞区域出现方向随机的小点。
@export_range(0.0, 0.5, 0.01, "suffix:m/s") var arrow_min_speed := 0.04:
	set(value):
		arrow_min_speed = maxf(value, 0.0)
		_sync_field_map_style()
@export_range(0.0, 3.0, 0.1, "suffix:px") var arrow_line_width := 1.2:
	set(value):
		arrow_line_width = clampf(value, 0.0, 3.0)
		_sync_field_map_style()
@export var arrow_color := Color(0.96, 0.98, 0.95):
	set(value):
		arrow_color = value
		_sync_field_map_style()

@onready var _field := get_node(fog_field_path) as InteractiveFogField
@onready var _debug_map: TextureRect = %DebugMap
@onready var _debug_material := _debug_map.material as ShaderMaterial
var _status_elapsed := 0.0
var _connected_settings: FogSettings


func _ready() -> void:
	_field.textures_changed.connect(_bind_debug_textures)
	_field.settings_replaced.connect(_connect_settings)
	_connect_settings()
	%DensitySlider.value_changed.connect(_set_density)
	%RecoverySlider.value_changed.connect(_set_recovery)
	%WindSlider.value_changed.connect(_set_wind)
	%HeightSlider.value_changed.connect(_set_height)
	%ResetButton.pressed.connect(_field.reset_simulation)
	%PauseButton.toggled.connect(_set_paused)
	%DebugButton.toggled.connect(_set_debug_visible)
	%DebugMode.item_selected.connect(_set_debug_mode)
	_debug_map.resized.connect(_sync_field_map_style)
	_sync_controls()
	_bind_debug_textures()
	_set_debug_mode(%DebugMode.selected)


func _process(delta: float) -> void:
	_status_elapsed += delta
	if _status_elapsed >= 0.25:
		_status_elapsed = 0.0
		%StatusLabel.text = "%d × %d  /  %d Hz  /  %d FPS" % [
			_field.settings.resolution, _field.settings.resolution,
			_field.settings.simulation_hz, Engine.get_frames_per_second()]


func toggle_pause() -> void:
	%PauseButton.button_pressed = not %PauseButton.button_pressed


func toggle_debug() -> void:
	%DebugButton.button_pressed = not %DebugButton.button_pressed


func _bind_debug_textures() -> void:
	_debug_material.set_shader_parameter("field_texture", _field.get_state_texture())
	_debug_material.set_shader_parameter("obstacle_texture", _field.get_obstacle_texture())
	# TextureRect 没有 texture 时不会绘制，即使它的材质内部使用了其他 sampler。
	_debug_map.texture = _field.get_state_texture()


func _sync_controls() -> void:
	var settings := _field.settings
	if settings == null:
		return
	%DensitySlider.set_value_no_signal(settings.density)
	%RecoverySlider.set_value_no_signal(settings.inflow_half_life)
	%WindSlider.set_value_no_signal(settings.wind_velocity.length())
	%HeightSlider.set_value_no_signal(settings.thickness)
	%DensityValue.text = "%.2f" % settings.density
	%RecoveryValue.text = "%.1f s" % settings.inflow_half_life
	%WindValue.text = "%.2f m/s" % settings.wind_velocity.length()
	%HeightValue.text = "%.2f m" % settings.thickness
	_sync_field_map_style()


func _connect_settings() -> void:
	if _connected_settings != null and _connected_settings.changed.is_connected(_sync_controls):
		_connected_settings.changed.disconnect(_sync_controls)
	_connected_settings = _field.settings
	if _connected_settings != null:
		_connected_settings.changed.connect(_sync_controls)
		_sync_controls()


func _set_density(value: float) -> void:
	_field.settings.density = value


func _set_recovery(value: float) -> void:
	_field.settings.inflow_half_life = value


func _set_wind(value: float) -> void:
	var direction := _field.settings.wind_velocity.normalized()
	if direction.is_zero_approx():
		direction = Vector2.RIGHT
	_field.settings.wind_velocity = direction * value


func _set_height(value: float) -> void:
	_field.settings.thickness = value


func _set_paused(paused: bool) -> void:
	_field.simulation_enabled = not paused
	%PauseButton.text = "Resume" if paused else "Pause"


func _set_debug_visible(enabled: bool) -> void:
	%DebugPanel.visible = enabled


func _set_debug_mode(index: int) -> void:
	# 选择框排序与 Shader 的模式编号分别维护；用 item id 保持旧模式兼容。
	_debug_material.set_shader_parameter("mode", %DebugMode.get_item_id(index))
	_sync_field_map_style()


func _sync_field_map_style() -> void:
	# Inspector setter 也会在反序列化期间调用，此时 @onready 节点还没有解析。
	if not is_node_ready() or _field.settings == null:
		return
	var area := _field.settings.area_size
	var aspect := area.x / area.y
	%MapAspect.ratio = aspect
	%MapAspect.custom_minimum_size = Vector2(field_map_width, field_map_width / aspect)
	%DebugPanel.offset_left = %DebugPanel.offset_right - field_map_width - 40.0
	var values := {
		"map_pixel_size": _debug_map.size.max(Vector2.ONE), "area_size": area,
		"arrow_spacing": arrow_spacing, "arrow_reference_speed": arrow_reference_speed,
		"arrow_min_speed": arrow_min_speed, "arrow_line_width": arrow_line_width,
		"arrow_color": arrow_color,
	}
	for key in values:
		_debug_material.set_shader_parameter(key, values[key])
	%Axes.text = "World X →    World Z ↓    %.0f × %.0f m" % [area.x, area.y]
	var mode: int = %DebugMode.get_item_id(%DebugMode.selected)
	%ArrowLegend.visible = mode == 3
	%ArrowLegend.text = "Arrows: velocity · full length ≥ %.1f m/s" % arrow_reference_speed
	match mode:
		0, 3:
			%FieldLegend.text = "Density: 0 dark · 1 cyan · >1 amber"
		1:
			%FieldLegend.text = "Velocity: red +X · green +Z · blue speed"
		2:
			%FieldLegend.text = "Distance: bands every 0.5 m"
