@tool
class_name FogSimulationGPU
extends RefCounted
## 主 RenderingDevice 上的二维 MAC 流体与高分辨率密度搬运。
## 所有 GPU RID 归此模块所有；运行时不回读、不 submit/sync。

const MAX_OBSTACLES := 32
const MAX_STAMPS := 16
const STAMP_FLOAT_COUNT := 8
const MAX_BURSTS := 4
const MAX_CUT_SEGMENTS := 16
const SHOCK_FLOAT_COUNT := 8
const MAX_SHOCK_SUBSTEPS := 64
const PARAMETER_BYTES := 7 * 16
const SHADERS := {
	"obstacles": preload("res://fog/shaders/build_obstacles.glsl"),
	"velocity": preload("res://fog/shaders/velocity.glsl"),
	"divergence": preload("res://fog/shaders/divergence.glsl"),
	"pressure": preload("res://fog/shaders/pressure.glsl"),
	"project": preload("res://fog/shaders/project_velocity.glsl"),
	"predict": preload("res://fog/shaders/density_predict.glsl"),
	"transport": preload("res://fog/shaders/simulate.glsl"),
	"shock_field": preload("res://fog/shaders/shock_field.glsl"),
	"shock_seed": preload("res://fog/shaders/shock_seed.glsl"),
	"shock_transport": preload("res://fog/shaders/shock_transport.glsl"),
}

var state_texture := Texture2DRD.new()
var obstacle_texture := Texture2DRD.new()
var coordinate_texture := Texture2DRD.new()
var diagnostics_texture := Texture2DRD.new()

var _rd: RenderingDevice
var _resolution := 256
var _density_resolution := 512
var _resources: Array[RID] = []
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _sets: Dictionary = {}
var _states: Array[RID] = []
var _coordinates: Array[RID] = []
var _pressures: Array[RID] = []
var _parameters := RID()
var _stamps := RID()
var _shocks := RID()
var _shock_velocity := RID()
var _obstacles := RID()
var _sampler := RID()
var _mask := RID()
var _velocity := RID()
var _working_velocity := RID()
var _before_projection := RID()
var _after_projection := RID()
var _predicted := RID()
var _display := RID()
var _display_coordinates := RID()
var _read := 0
var _pressure_read := 0
var _ready_on_gpu := false


func start(resolution: int, density_resolution: int) -> void:
	RenderingServer.call_on_render_thread(_initialize.bind(resolution, density_resolution))


func advance(parameters: PackedFloat32Array, stamps: PackedFloat32Array,
		obstacles: PackedFloat32Array, rebuild: bool, iterations: int, shocks: PackedFloat32Array) -> void:
	RenderingServer.call_on_render_thread(_advance.bind(
		parameters.to_byte_array(), stamps.to_byte_array(), obstacles.to_byte_array(), rebuild, iterations, shocks.to_byte_array()))


func shutdown() -> void:
	RenderingServer.call_on_render_thread(_release)


func _own(rid: RID) -> RID:
	_resources.append(rid)
	return rid


func _texture(size: int, format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT) -> RID:
	var description := RDTextureFormat.new()
	description.width = size
	description.height = size
	description.format = format
	description.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var rid := _own(_rd.texture_create(description, RDTextureView.new()))
	_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid


func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for rid in ids:
		uniform.add_id(rid)
	return uniform


func _sample(binding: int, rid: RID) -> RDUniform:
	return _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, binding, [_sampler, rid])


func _image(binding: int, rid: RID) -> RDUniform:
	return _uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, binding, [rid])


func _buffer(binding: int, rid: RID) -> RDUniform:
	return _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, binding, [rid])


func _common(velocity: RID) -> Array[RDUniform]:
	return [_buffer(0, _parameters), _sample(1, _mask), _sample(2, velocity)]


func _make_set(stage: String, uniforms: Array[RDUniform]) -> RID:
	return _own(_rd.uniform_set_create(uniforms, _shaders[stage], 0))


func _initialize(resolution: int, density_resolution: int) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	_resolution = resolution
	_density_resolution = density_resolution
	for stage in SHADERS:
		var shader_file: RDShaderFile = SHADERS[stage]
		var spirv := shader_file.get_spirv()
		var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not compile_error.is_empty():
			push_error("交互雾：" + stage + " 编译失败：" + compile_error)
			_release()
			return
		var shader := _own(_rd.shader_create_from_spirv(spirv))
		if not shader.is_valid():
			push_error("交互雾：GPU shader 创建失败：" + stage)
			_release()
			return
		_shaders[stage] = shader
		_pipelines[stage] = _own(_rd.compute_pipeline_create(shader))
	_parameters = _own(_rd.storage_buffer_create(PARAMETER_BYTES))
	_stamps = _own(_rd.storage_buffer_create(MAX_STAMPS * STAMP_FLOAT_COUNT * 4))
	_shocks = _own(_rd.storage_buffer_create((MAX_BURSTS + MAX_CUT_SEGMENTS) * SHOCK_FLOAT_COUNT * 4))
	_obstacles = _own(_rd.storage_buffer_create(MAX_OBSTACLES * 32))
	var sampler := RDSamplerState.new()
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _own(_rd.sampler_create(sampler))
	_mask = _texture(_density_resolution)
	_velocity = _texture(_resolution)
	_working_velocity = _texture(_resolution)
	_before_projection = _texture(_resolution)
	_after_projection = _texture(_resolution)
	# 密度内部使用单通道 32 位，避免冲击的多个守恒子步反复量化到半精度。
	_predicted = _texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	_shock_velocity = _texture(_density_resolution)
	_display = _texture(_density_resolution)
	_display_coordinates = _texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	for index in range(2):
		_states.append(_texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT))
		_coordinates.append(_texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT))
		_pressures.append(_texture(_resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT))

	_sets["obstacles"] = _make_set("obstacles", [_image(0, _mask), _buffer(1, _parameters), _buffer(2, _obstacles)])
	var uniforms := _common(_velocity)
	uniforms.append_array([_image(3, _working_velocity), _buffer(4, _stamps), _sample(5, _after_projection)])
	_sets["velocity"] = _make_set("velocity", uniforms)
	uniforms = _common(_working_velocity)
	uniforms.append_array([_image(3, _before_projection), _sample(4, _after_projection)])
	_sets["divergence"] = _make_set("divergence", uniforms)
	uniforms = _common(_velocity)
	uniforms.append_array([_image(3, _after_projection), _sample(4, _before_projection)])
	_sets["diagnostics"] = _make_set("divergence", uniforms)
	uniforms = _common(_velocity)
	uniforms.append_array([_buffer(3, _shocks), _image(4, _shock_velocity)])
	_sets["shock_field"] = _make_set("shock_field", uniforms)
	for index in range(2):
		uniforms = _common(_working_velocity)
		uniforms.append_array([_sample(3, _before_projection), _sample(4, _pressures[index]), _image(5, _pressures[1 - index])])
		_sets["pressure%d" % index] = _make_set("pressure", uniforms)
		uniforms = _common(_working_velocity)
		uniforms.append_array([_sample(3, _pressures[index]), _image(4, _velocity)])
		_sets["project%d" % index] = _make_set("project", uniforms)
		uniforms = _common(_velocity)
		uniforms.append_array([_sample(3, _states[index]), _image(4, _predicted)])
		_sets["predict%d" % index] = _make_set("predict", uniforms)
		uniforms = _common(_velocity)
		uniforms.append_array([
			_sample(3, _states[index]), _sample(4, _predicted), _sample(5, _coordinates[index]),
			_image(6, _states[1 - index]), _image(7, _coordinates[1 - index]),
			_image(8, _display), _image(9, _display_coordinates)])
		_sets["transport%d" % index] = _make_set("transport", uniforms)
		uniforms = _common(_shock_velocity)
		uniforms.append_array([
			_sample(3, _states[index]), _sample(4, _coordinates[index]),
			_image(5, _states[1 - index]), _image(6, _coordinates[1 - index]),
			_image(7, _display), _image(8, _display_coordinates)])
		_sets["shock_transport%d" % index] = _make_set("shock_transport", uniforms)
		_sets["shock_seed%d" % index] = _make_set("shock_seed", [
			_sample(3, _states[index]), _sample(4, _coordinates[index]),
			_image(5, _states[1 - index]), _image(6, _coordinates[1 - index])])
	for rid in _resources:
		if not rid.is_valid():
			push_error("交互雾：流体资源或 uniform set 创建失败。")
			_release()
			return
	state_texture.texture_rd_rid = _display
	obstacle_texture.texture_rd_rid = _mask
	coordinate_texture.texture_rd_rid = _display_coordinates
	diagnostics_texture.texture_rd_rid = _after_projection
	_ready_on_gpu = true


func _dispatch(list: int, stage: String, uniform_set: RID, size: int, push := PackedByteArray(), extent := Vector2i.ZERO) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	if not push.is_empty():
		_rd.compute_list_set_push_constant(list, push, push.size())
	if extent == Vector2i.ZERO:
		extent = Vector2i(size, size)
	_rd.compute_list_dispatch(list, ceili(float(extent.x) / 8.0), ceili(float(extent.y) / 8.0), 1)
	_rd.compute_list_add_barrier(list)


func _advance(parameters: PackedByteArray, stamps: PackedByteArray,
		obstacles: PackedByteArray, rebuild: bool, iterations: int, shocks: PackedByteArray) -> void:
	if not _ready_on_gpu:
		return
	var peak := 0.0
	var cut_peak := 0.0
	var bounds_min := Vector2(INF, INF)
	var bounds_max := Vector2(-INF, -INF)
	for offset in range(0, shocks.size(), SHOCK_FLOAT_COUNT * 4):
		var start := Vector2(shocks.decode_float(offset), shocks.decode_float(offset + 4))
		var radius := shocks.decode_float(offset + 8)
		if shocks.decode_float(offset + 24) > 0.5:
			cut_peak = maxf(cut_peak, absf(shocks.decode_float(offset + 12)))
			var end := Vector2(shocks.decode_float(offset + 16), shocks.decode_float(offset + 20))
			bounds_min = bounds_min.min(start.min(end) - Vector2.ONE * radius)
			bounds_max = bounds_max.max(start.max(end) + Vector2.ONE * radius)
		else:
			peak += absf(shocks.decode_float(offset + 12))
			var support := radius + shocks.decode_float(offset + 16)
			bounds_min = bounds_min.min(start - Vector2.ONE * support)
			bounds_max = bounds_max.max(start + Vector2.ONE * support)
	# 划开段取局部最强作用，不相加；连续路径重叠不会叠出过大速度。
	peak += cut_peak
	var dt := parameters.decode_float(32)
	var cell := minf(parameters.decode_float(0), parameters.decode_float(4)) / _density_resolution
	# 两个 MAC 面分量可能在不同位置取到峰值，用逐轴上界约束 CFL。
	var desired_steps := maxi(1, ceili(dt * peak * 2.0 / (cell * 0.4)))
	var substeps := mini(desired_steps, MAX_SHOCK_SUBSTEPS)
	# 保持 CFL 安全；极端重叠或很小区域时削弱冲击，而不是提交无界 GPU 子步。
	parameters.encode_float(104, minf(1.0, float(substeps) / desired_steps))
	_rd.buffer_update(_parameters, 0, parameters.size(), parameters)
	if not stamps.is_empty():
		_rd.buffer_update(_stamps, 0, stamps.size(), stamps)
	if not shocks.is_empty():
		_rd.buffer_update(_shocks, 0, shocks.size(), shocks)
	if rebuild and not obstacles.is_empty():
		_rd.buffer_update(_obstacles, 0, obstacles.size(), obstacles)
	if parameters.decode_float(72) > 0.5:
		for pressure in _pressures:
			_rd.texture_clear(pressure, Color(0, 0, 0, 0), 0, 1, 0, 1)
		for diagnostic in [_before_projection, _after_projection]:
			_rd.texture_clear(diagnostic, Color(0, 0, 0, 0), 0, 1, 0, 1)
	var list := _rd.compute_list_begin()
	if rebuild:
		_dispatch(list, "obstacles", _sets["obstacles"], _density_resolution)
	_dispatch(list, "velocity", _sets["velocity"], _resolution)
	_dispatch(list, "divergence", _sets["divergence"], _resolution)
	for index in range(iterations):
		_dispatch(list, "pressure", _sets["pressure%d" % _pressure_read], _resolution)
		_pressure_read = 1 - _pressure_read
	_dispatch(list, "project", _sets["project%d" % _pressure_read], _resolution)
	_dispatch(list, "divergence", _sets["diagnostics"], _resolution)
	_dispatch(list, "predict", _sets["predict%d" % _read], _density_resolution)
	_dispatch(list, "transport", _sets["transport%d" % _read], _density_resolution)
	_read = 1 - _read
	if peak > 0.000001 and dt > 0.0:
		var margin := maxf(parameters.decode_float(0), parameters.decode_float(4)) / _density_resolution * 2.0
		var bounds := PackedFloat32Array([bounds_min.x - margin, bounds_min.y - margin, bounds_max.x + margin, bounds_max.y + margin]).to_byte_array()
		_dispatch(list, "shock_field", _sets["shock_field"], _density_resolution, bounds)
		var region := Vector2(parameters.decode_float(0), parameters.decode_float(4))
		var center := Vector2(parameters.decode_float(8), parameters.decode_float(12))
		var low := ((bounds_min - Vector2.ONE * margin - center) / region + Vector2.ONE * 0.5) * _density_resolution
		var high := ((bounds_max + Vector2.ONE * margin - center) / region + Vector2.ONE * 0.5) * _density_resolution
		var origin := Vector2i(low.floor()).clamp(Vector2i.ZERO, Vector2i.ONE * (_density_resolution - 1))
		var extent := Vector2i(high.ceil()).clamp(origin + Vector2i.ONE, Vector2i.ONE * _density_resolution) - origin
		_dispatch(list, "shock_seed", _sets["shock_seed%d" % _read], _density_resolution, PackedInt32Array([0, 0, 0, 0]).to_byte_array())
		var push := PackedByteArray()
		push.resize(32)
		push.encode_float(0, dt / substeps)
		push.encode_s32(8, origin.x)
		push.encode_s32(12, origin.y)
		push.encode_s32(16, extent.x)
		push.encode_s32(20, extent.y)
		for index in range(substeps):
			push.encode_s32(4, 1 if index == substeps - 1 else 0)
			_dispatch(list, "shock_transport", _sets["shock_transport%d" % _read], _density_resolution, push, extent)
			_read = 1 - _read
	_rd.compute_list_end()


func _release() -> void:
	if _rd == null:
		return
	_ready_on_gpu = false
	for wrapper in [state_texture, obstacle_texture, coordinate_texture, diagnostics_texture]:
		wrapper.texture_rd_rid = RID()
	_resources.reverse()
	for rid in _resources:
		if rid.is_valid():
			_rd.free_rid(rid)
	_resources.clear()
	_states.clear()
	_coordinates.clear()
	_pressures.clear()
	_sets.clear()
	_shaders.clear()
	_pipelines.clear()
	_rd = null
