class_name FogDemoHUD
extends CanvasLayer
## 调参面板独立场景。% 唯一节点引用只在此 HUD 的 owner 范围内解析。
## 这些滑块修改本次运行的资源；长期预设请在编辑器的 FogSettings 中保存。

@export_node_path("Node3D") var fog_field_path := NodePath("../FogField")

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
	_sync_controls()
	_bind_debug_textures()


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
	%RecoverySlider.set_value_no_signal(settings.recovery_half_life)
	%WindSlider.set_value_no_signal(settings.wind_velocity.length())
	%HeightSlider.set_value_no_signal(settings.thickness)
	%DensityValue.text = "%.2f" % settings.density
	%RecoveryValue.text = "%.1f s" % settings.recovery_half_life
	%WindValue.text = "%.2f m/s" % settings.wind_velocity.length()
	%HeightValue.text = "%.2f m" % settings.thickness


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
	_field.settings.recovery_half_life = value


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
	_debug_material.set_shader_parameter("mode", index)
