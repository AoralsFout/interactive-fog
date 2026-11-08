@tool
class_name FogSimulationGPU
extends RefCounted
## GPU 资源与调度的唯一拥有者。此类不访问场景树、不读取 Inspector 属性。
## 主线程把一帧所需的数值打包后提交；所有 RenderingDevice 调用均在渲染线程执行。
## 使用主 RenderingDevice + Texture2DRD，结果直接交给体积雾，没有逐帧 GPU→CPU 回读。

const MAX_OBSTACLES := 32
const MAX_STAMPS := 16
const PARAMETER_BYTES := 6 * 16
const SIMULATION_SHADER: RDShaderFile = preload("res://fog/shaders/simulate.glsl")
const OBSTACLE_SHADER: RDShaderFile = preload("res://fog/shaders/build_obstacles.glsl")

var state_texture := Texture2DRD.new()
var obstacle_texture := Texture2DRD.new()

# 以下变量仅在渲染线程读写。shutdown 后仍被已排队的 Callable 持有，避免悬空回调。
var _rd: RenderingDevice
var _resolution := 128
var _state_rids: Array[RID] = []
var _display_rid := RID()
var _obstacle_rid := RID()
var _parameters_rid := RID()
var _stamps_rid := RID()
var _obstacles_rid := RID()
var _sampler_rid := RID()
var _simulation_shader_rid := RID()
var _obstacle_shader_rid := RID()
var _simulation_pipeline := RID()
var _obstacle_pipeline := RID()
var _simulation_sets: Array[RID] = []
var _obstacle_set := RID()
var _read_index := 0
var _ready_on_gpu := false


func start(resolution: int) -> void:
	RenderingServer.call_on_render_thread(_initialize.bind(resolution))


func advance(parameters: PackedFloat32Array, stamps: PackedFloat32Array,
		obstacles: PackedFloat32Array, rebuild_obstacles: bool) -> void:
	# duplicate 是线程边界：调用者下一帧可继续复用自己的数组。
	RenderingServer.call_on_render_thread(_advance.bind(
		parameters.to_byte_array(), stamps.to_byte_array(),
		obstacles.to_byte_array(), rebuild_obstacles))


func shutdown() -> void:
	RenderingServer.call_on_render_thread(_release)


func _initialize(resolution: int) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	_resolution = resolution
	_simulation_shader_rid = _rd.shader_create_from_spirv(SIMULATION_SHADER.get_spirv())
	_obstacle_shader_rid = _rd.shader_create_from_spirv(OBSTACLE_SHADER.get_spirv())
	if not _simulation_shader_rid.is_valid() or not _obstacle_shader_rid.is_valid():
		push_error("交互雾：Compute Shader 创建失败，请检查着色器编译输出。")
		_release()
		return
	_simulation_pipeline = _rd.compute_pipeline_create(_simulation_shader_rid)
	_obstacle_pipeline = _rd.compute_pipeline_create(_obstacle_shader_rid)
	_state_rids = [_create_texture(), _create_texture()]
	_display_rid = _create_texture()
	_obstacle_rid = _create_texture()
	_parameters_rid = _rd.storage_buffer_create(PARAMETER_BYTES)
	_stamps_rid = _rd.storage_buffer_create(MAX_STAMPS * 32)
	_obstacles_rid = _rd.storage_buffer_create(MAX_OBSTACLES * 32)
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_rid = _rd.sampler_create(sampler)

	for read_index in range(2):
		var uniforms: Array[RDUniform] = [
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler_rid, _state_rids[read_index]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_state_rids[1 - read_index]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [_display_rid]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_sampler_rid, _obstacle_rid]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_parameters_rid]),
			_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_stamps_rid]),
		]
		_simulation_sets.append(_rd.uniform_set_create(uniforms, _simulation_shader_rid, 0))
	var obstacle_uniforms: Array[RDUniform] = [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [_obstacle_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [_parameters_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, [_obstacles_rid]),
	]
	_obstacle_set = _rd.uniform_set_create(obstacle_uniforms, _obstacle_shader_rid, 0)
	state_texture.texture_rd_rid = _display_rid
	obstacle_texture.texture_rd_rid = _obstacle_rid
	_ready_on_gpu = true


func _create_texture() -> RID:
	var format := RDTextureFormat.new()
	format.width = _resolution
	format.height = _resolution
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return _rd.texture_create(format, RDTextureView.new())


func _uniform(type: RenderingDevice.UniformType, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


func _advance(parameters: PackedByteArray, stamps: PackedByteArray,
		obstacles: PackedByteArray, rebuild_obstacles: bool) -> void:
	if not _ready_on_gpu:
		return
	_rd.buffer_update(_parameters_rid, 0, parameters.size(), parameters)
	if not stamps.is_empty():
		_rd.buffer_update(_stamps_rid, 0, stamps.size(), stamps)
	if rebuild_obstacles and not obstacles.is_empty():
		_rd.buffer_update(_obstacles_rid, 0, obstacles.size(), obstacles)
	var groups := ceili(float(_resolution) / 8.0)
	var compute_list := _rd.compute_list_begin()
	if rebuild_obstacles:
		_rd.compute_list_bind_compute_pipeline(compute_list, _obstacle_pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, _obstacle_set, 0)
		_rd.compute_list_dispatch(compute_list, groups, groups, 1)
		# mask 写入必须在模拟读取之前完成；RD 负责其余跨渲染阶段的资源屏障。
		_rd.compute_list_add_barrier(compute_list)
	_rd.compute_list_bind_compute_pipeline(compute_list, _simulation_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, _simulation_sets[_read_index], 0)
	_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	_rd.compute_list_end()
	_read_index = 1 - _read_index
	# 主设备由 Godot 提交。这里不能 submit()/sync()，否则会破坏引擎调度或造成等待。


func _release() -> void:
	if _rd == null:
		return
	_ready_on_gpu = false
	# 先解除高级纹理包装，再释放底层 RID；防止编辑器重新加载脚本时留下失效引用。
	state_texture.texture_rd_rid = RID()
	obstacle_texture.texture_rd_rid = RID()
	var resources: Array[RID] = []
	resources.append_array(_simulation_sets)
	resources.append(_obstacle_set)
	resources.append_array([_simulation_pipeline, _obstacle_pipeline])
	resources.append_array(_state_rids)
	resources.append_array([
		_display_rid, _obstacle_rid, _sampler_rid, _parameters_rid,
		_stamps_rid, _obstacles_rid, _simulation_shader_rid, _obstacle_shader_rid,
	])
	for rid in resources:
		if rid.is_valid():
			_rd.free_rid(rid)
	_simulation_sets.clear()
	_state_rids.clear()
	_rd = null
