@tool
class_name FogSimulationGPU
extends RefCounted
## 主 RenderingDevice 上的二维 MAC 流体与高分辨率密度搬运。
## 所有 GPU RID 归此模块所有；运行时不回读、不 submit/sync。

const MAX_OBSTACLES := 32
const MAX_STAMPS := 16
const STAMP_FLOAT_COUNT := 8
const PARAMETER_BYTES := 7 * 16
const SHADERS := {
	"obstacles": preload("res://fog/shaders/build_obstacles.glsl"),
	"velocity": preload("res://fog/shaders/velocity.glsl"),
	"divergence": preload("res://fog/shaders/divergence.glsl"),
	"pressure": preload("res://fog/shaders/pressure.glsl"),
	"project": preload("res://fog/shaders/project_velocity.glsl"),
	"predict": preload("res://fog/shaders/density_predict.glsl"),
	"transport": preload("res://fog/shaders/simulate.glsl"),
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
		obstacles: PackedFloat32Array, rebuild: bool, iterations: int) -> void:
	RenderingServer.call_on_render_thread(_advance.bind(
		parameters.to_byte_array(), stamps.to_byte_array(), obstacles.to_byte_array(), rebuild, iterations))


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
		var shader := _own(_rd.shader_create_from_spirv(shader_file.get_spirv()))
		if not shader.is_valid():
			push_error("交互雾：GPU shader 创建失败：" + stage)
			_release()
			return
		_shaders[stage] = shader
		_pipelines[stage] = _own(_rd.compute_pipeline_create(shader))
	_parameters = _own(_rd.storage_buffer_create(PARAMETER_BYTES))
	_stamps = _own(_rd.storage_buffer_create(MAX_STAMPS * STAMP_FLOAT_COUNT * 4))
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
	_predicted = _texture(_density_resolution)
	_display = _texture(_density_resolution)
	_display_coordinates = _texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	for index in range(2):
		_states.append(_texture(_density_resolution))
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


func _dispatch(list: int, stage: String, uniform_set: RID, size: int) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[stage])
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size) / 8.0), ceili(float(size) / 8.0), 1)
	_rd.compute_list_add_barrier(list)


func _advance(parameters: PackedByteArray, stamps: PackedByteArray,
		obstacles: PackedByteArray, rebuild: bool, iterations: int) -> void:
	if not _ready_on_gpu:
		return
	_rd.buffer_update(_parameters, 0, parameters.size(), parameters)
	if not stamps.is_empty():
		_rd.buffer_update(_stamps, 0, stamps.size(), stamps)
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
	_rd.compute_list_end()
	_read = 1 - _read


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
