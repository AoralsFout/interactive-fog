@tool
class_name InteractiveFogField
extends Node3D
## 对场景公开的雾场接口：管理参数、收集交互、驱动 GPU、同步 FogVolume。
## 本节点的原点是雾层底部中心；雾层固定沿世界 XZ 平面铺开。
## 场景节点均由 .tscn 提供；本脚本只创建瞬态 GPU 资源和运行时材质副本。

signal textures_changed
signal settings_replaced

@export var settings: FogSettings:
	set(value):
		if settings != null and settings.changed.is_connected(_on_settings_changed):
			settings.changed.disconnect(_on_settings_changed)
		settings = value
		if settings != null:
			settings.changed.connect(_on_settings_changed)
		_on_settings_changed()
		if is_inside_tree():
			settings_replaced.emit()
## 编辑器中持续播放模拟。关闭后仍可修改外观，保留当前预览状态。
@export var preview_in_editor := true
@export var simulation_enabled := true
@export_node_path("FogVolume") var volume_path := NodePath("FogVolume")
@export_tool_button("重置雾场", "Reload") var reset_button: Callable = reset_simulation

var _simulation: FogSimulationGPU
var _volume: FogVolume
var _render_material: ShaderMaterial
var _appearance_dirty := true
var _needs_reset := true
var _resolution := 0
var _accumulator := 0.0
var _simulation_time := 0.0
var _previous_obstacles := PackedFloat32Array()
var _previous_domain := Vector4(INF, INF, INF, INF)
var _interactor_positions: Dictionary = {}
var _pending_impulses: Array[PackedFloat32Array] = []
var _active_bursts: Array[FogBurst] = []
var _warned_obstacle_limit := false
var _warned_stamp_limit := false
var _last_global_position := Vector3(INF, INF, INF)


func _ready() -> void:
	if settings == null:
		settings = FogSettings.new()
	_volume = get_node_or_null(volume_path) as FogVolume
	if _volume == null or not _volume.material is ShaderMaterial:
		push_error("交互雾：volume_path 必须指向带 ShaderMaterial 的 FogVolume。")
		set_process(false)
		return
	# 通过 RenderingServer 指派瞬态材质，不覆盖 .tscn 的 material 属性。
	# 这样编辑器保存场景时，不会把 Texture2DRD 等 GPU 临时资源写入场景文件。
	_render_material = _volume.material.duplicate() as ShaderMaterial
	RenderingServer.fog_volume_set_material(_volume.get_base(), _render_material.get_rid())
	_on_settings_changed()
	update_configuration_warnings()


func _exit_tree() -> void:
	# 恢复场景原材质后再释放 GPU 资源，兼容编辑器关闭场景和脚本热重载。
	if is_instance_valid(_volume) and _volume.material != null:
		RenderingServer.fog_volume_set_material(_volume.get_base(), _volume.material.get_rid())
	if _simulation != null:
		_simulation.shutdown()
		_simulation = null


func _process(delta: float) -> void:
	if settings == null or _render_material == null:
		return
	if _resolution != settings.resolution and _supports_gpu():
		_rebuild_simulation()
	if global_position != _last_global_position:
		_appearance_dirty = true
		_last_global_position = global_position
	if _appearance_dirty:
		_apply_appearance()
		_appearance_dirty = false
	if _simulation == null:
		return
	var playing := simulation_enabled and (not Engine.is_editor_hint() or preview_in_editor)
	if not playing and not _needs_reset:
		# 暂停期间仍跟踪交互器，恢复时不会把静止期间的位移误当成巨大速度。
		_interactor_positions.clear()
		var domain := Vector4(settings.area_size.x, settings.area_size.y, global_position.x, global_position.z)
		if _collect_obstacles() != _previous_obstacles or domain != _previous_domain:
			# 暂停只冻结流动，移动障碍或调整区域仍应立刻更新静态遮罩。
			_advance_simulation(0.0)
		return
	var step := 1.0 / settings.simulation_hz
	_accumulator += minf(delta, 0.1)
	if _needs_reset or _accumulator >= step:
		# 每个画面最多提交一次，避免窗口卡住后排队大量 GPU 作业。
		# 模拟在极低帧率下会减速，这是比追帧爆发更适合此类视觉效果的退化方式。
		_accumulator = fmod(_accumulator, step)
		_advance_simulation(step)


func _supports_gpu() -> bool:
	return DisplayServer.get_name() != "headless" and RenderingServer.get_current_rendering_method() == "forward_plus"


func _rebuild_simulation() -> void:
	if _simulation != null:
		_simulation.shutdown()
	_simulation = FogSimulationGPU.new()
	_resolution = settings.resolution
	_simulation.start(_resolution)
	_render_material.set_shader_parameter("state_texture", _simulation.state_texture)
	_render_material.set_shader_parameter("obstacle_texture", _simulation.obstacle_texture)
	_render_material.set_shader_parameter("use_simulation", true)
	_appearance_dirty = true
	reset_simulation()
	textures_changed.emit()


func reset_simulation() -> void:
	_needs_reset = true
	_simulation_time = 0.0
	_previous_obstacles.clear()
	_previous_domain = Vector4(INF, INF, INF, INF)
	_interactor_positions.clear()
	_pending_impulses.clear()
	_active_bursts.clear()


## 一次性冲击接口。velocity 是速度增量，clear_amount 是密度的指数衰减量。
## 与持续的 FogInteractor3D 区别：此接口不需要调用者每帧重发。
func disturb(world_position: Vector3, radius: float, velocity := Vector2.ZERO,
		clear_amount := 3.0, radial_speed := 2.5, swirl_speed := 0.5,
		compression_gain := 1.0, compression_width := 0.35) -> void:
	if _pending_impulses.size() + _active_bursts.size() >= FogSimulationGPU.MAX_STAMPS:
		return
	_pending_impulses.append(PackedFloat32Array([
		world_position.x, world_position.z, maxf(radius, 0.05), maxf(clear_amount, 0.0),
		velocity.x, velocity.y, radial_speed, swirl_speed,
		clampf(compression_gain, 0.0, 3.0), maxf(compression_width, 0.05), 0.0, 0.0,
	]))


## 在 duration 秒内扩张到目标半径，边清空内部边把雾量堆向移动的波前。
## 直接作用于模拟密度，不是叠加发光特效。各强度是整个冲击的总量，与模拟频率无关。
func burst(world_position: Vector3, radius: float, duration := 0.4,
		clear_amount := 8.0, radial_speed := 5.0, swirl_speed := 0.5,
		compression_gain := 1.8, compression_width := 0.45) -> void:
	if _pending_impulses.size() + _active_bursts.size() >= FogSimulationGPU.MAX_STAMPS:
		return
	_active_bursts.append(FogBurst.new(world_position, radius, duration, clear_amount,
		radial_speed, swirl_speed, clampf(compression_gain, 0.0, 3.0), compression_width))


func get_state_texture() -> Texture2D:
	return _simulation.state_texture if _simulation != null else null


func get_obstacle_texture() -> Texture2D:
	return _simulation.obstacle_texture if _simulation != null else null


func get_simulation_time() -> float:
	return _simulation_time


func _advance_simulation(step: float) -> void:
	var obstacles := _collect_obstacles()
	var stamps := _collect_stamps(step) if step > 0.0 else PackedFloat32Array()
	var domain := Vector4(settings.area_size.x, settings.area_size.y, global_position.x, global_position.z)
	var rebuild := _needs_reset or obstacles != _previous_obstacles or domain != _previous_domain
	_previous_obstacles = obstacles
	_previous_domain = domain
	_simulation_time += step
	# 七个 vec4，字节布局与三个 .glsl 文件中的 Parameters 完全一致。
	var parameters := PackedFloat32Array([
		domain.x, domain.y, domain.z, domain.w,
		settings.wind_velocity.x, settings.wind_velocity.y, settings.turbulence_strength, settings.turbulence_scale,
		step, _simulation_time, log(2.0) / settings.recovery_half_life, settings.velocity_damping,
		settings.wind_response, settings.max_speed, settings.obstacle_influence, 0.0,
		float(obstacles.size()) / 8.0, float(stamps.size()) / FogSimulationGPU.STAMP_FLOAT_COUNT,
		1.0 if _needs_reset else 0.0, float(_resolution),
		settings.density_variation, settings.density_pattern_scale, 0.0, 0.0,
		settings.max_density, log(2.0) / settings.compression_half_life, 0.0, 0.0,
	])
	_simulation.advance(parameters, stamps, obstacles, rebuild)
	_render_material.set_shader_parameter("simulation_time", _simulation_time)
	_needs_reset = false


func _collect_obstacles() -> PackedFloat32Array:
	var data := PackedFloat32Array()
	for node in get_tree().get_nodes_in_group(&"interactive_fog_obstacles"):
		var obstacle := node as FogObstacle3D
		if obstacle == null or not obstacle.enabled:
			continue
		if data.size() >= FogSimulationGPU.MAX_OBSTACLES * 8:
			if not _warned_obstacle_limit:
				push_warning("交互雾：最多支持 32 个障碍足迹，超出部分已忽略。")
				_warned_obstacle_limit = true
			break
		data.append_array(obstacle.pack_gpu_data())
	return data


func _collect_stamps(step: float) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	# 一次性冲击转换为每秒速率，GPU 乘 dt 后得到与频率无关的冲量。
	# 仅把清除量和力转换为速率，第三个 vec4 的倍率、米制环宽保持原单位。
	for impulse in _pending_impulses:
		var rate := impulse.duplicate()
		for i in range(3, 8):
			rate[i] /= step
		data.append_array(rate)
	_pending_impulses.clear()
	var ongoing_bursts: Array[FogBurst] = []
	for wave in _active_bursts:
		data.append_array(wave.advance(step))
		if not wave.is_finished():
			ongoing_bursts.append(wave)
	_active_bursts = ongoing_bursts
	var live_positions: Dictionary = {}
	for node in get_tree().get_nodes_in_group(&"interactive_fog_interactors"):
		var interactor := node as FogInteractor3D
		if interactor == null:
			continue
		var id := interactor.get_instance_id()
		var position_now := interactor.global_position
		var previous: Vector3 = _interactor_positions.get(id, position_now)
		live_positions[id] = position_now
		# 各雾场分别保存采样位置，多雾场可共享同一交互器而不会互相消耗状态。
		var velocity := Vector2(position_now.x - previous.x, position_now.z - previous.z) / step
		if not interactor.enabled:
			continue
		if interactor.vertical_reach >= 0.0 and absf(position_now.y - global_position.y) > settings.get_volume_height() + interactor.vertical_reach:
			continue
		if not interactor.emit_when_stationary and velocity.length() < interactor.minimum_speed:
			continue
		if data.size() >= FogSimulationGPU.MAX_STAMPS * FogSimulationGPU.STAMP_FLOAT_COUNT:
			if not _warned_stamp_limit:
				push_warning("交互雾：单步最多支持 16 个交互作用，超出部分已忽略。")
				_warned_stamp_limit = true
			continue
		data.append_array(interactor.pack_gpu_stamp(velocity.limit_length(settings.max_speed * 2.0)))
	_interactor_positions = live_positions
	return data


func _apply_appearance() -> void:
	var volume_height := settings.get_volume_height()
	_volume.position = Vector3(0.0, volume_height * 0.5, 0.0)
	_volume.size = Vector3(settings.area_size.x, volume_height, settings.area_size.y)
	var values := {
		"area_size": settings.area_size, "world_origin": global_position,
		"thickness": settings.thickness, "density": settings.density,
		"fog_albedo": settings.albedo, "fog_emission": settings.emission,
		"height_falloff": settings.height_falloff, "edge_fade": settings.edge_fade,
		"obstacle_fade": maxf(settings.obstacle_fade, settings.area_size[settings.area_size.max_axis_index()] / settings.resolution),
		"detail_scale": settings.detail_scale, "detail_amount": settings.detail_amount,
		"detail_speed": settings.detail_speed, "wind_velocity": settings.wind_velocity,
		"compression_visibility": settings.compression_visibility,
		"compression_height_boost": settings.compression_height_boost,
	}
	for key in values:
		_render_material.set_shader_parameter(key, values[key])


func _on_settings_changed() -> void:
	_appearance_dirty = true
	if is_inside_tree():
		update_configuration_warnings()
		update_gizmos()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if settings == null:
		warnings.append("请指定 FogSettings 资源；可在 Inspector 中新建或加载预设。")
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		warnings.append("此 demo 的 FogVolume 渲染需要 Forward+。")
	if is_inside_tree() and not global_basis.is_equal_approx(Basis.IDENTITY):
		warnings.append("雾场沿世界 XZ 平面铺开：请保持自身及父节点旋转为零、缩放为一，使用 area_size 调整尺寸。")
	return warnings
