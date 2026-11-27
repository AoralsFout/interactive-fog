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
const MAX_SLOPE_SUBSTEPS := 8
const PARAMETER_BYTES := 7 * 16
const SHADERS := {
	"obstacles": preload("res://fog/shaders/build_obstacles.glsl"),
	"velocity": preload("res://fog/shaders/velocity.glsl"),
	"divergence": preload("res://fog/shaders/divergence.glsl"),
	"topology": preload("res://fog/shaders/pressure_topology.glsl"),
	"pressure": preload("res://fog/shaders/pressure.glsl"),
	"mg_finest": preload("res://fog/shaders/mg_finest.glsl"),
	"mg_coarsen": preload("res://fog/shaders/mg_coarsen.glsl"),
	"mg_smooth": preload("res://fog/shaders/mg_smooth.glsl"),
	"mg_restrict": preload("res://fog/shaders/mg_restrict.glsl"),
	"mg_prolong": preload("res://fog/shaders/mg_prolong.glsl"),
	"project": preload("res://fog/shaders/project_velocity.glsl"),
	"predict": preload("res://fog/shaders/density_predict.glsl"),
	"transport": preload("res://fog/shaders/simulate.glsl"),
	"slope_transport": preload("res://fog/shaders/slope_transport.glsl"),
	"shock_field": preload("res://fog/shaders/shock_field.glsl"),
	"shock_seed": preload("res://fog/shaders/shock_seed.glsl"),
	"shock_transport": preload("res://fog/shaders/shock_transport.glsl"),
}

# Each region owns a disjoint padded rectangle and a conservative local CFL bound.
class ShockRegion:
	var rect: Rect2i
	var members: int
	var burst_speed := 0.0
	var cut_speed := 0.0


class PressureLevel:
	var size: int
	var faces: RID
	var rhs: RID
	var pressure: Array[RID]
	var geometry_set: RID
	var smooth: Array[RID]
	var restrict_sets: Array[RID]
	var prolong: Array[RID]


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
var _backtrace_uv := RID()
var _read := 0
var _pressure_read := 0
var _pressure_sets: Array[RID] = []
var _slope_texture: Texture2D
var _slope_sets: Array[RID] = []
var _topology: RID
var _levels: Array[PressureLevel] = []
var _mg_geometry_dirty := true
var _ready_on_gpu := false


func start(resolution: int, density_resolution: int) -> void:
	RenderingServer.call_on_render_thread(_initialize.bind(resolution, density_resolution))


func advance(parameters: PackedFloat32Array, stamps: PackedFloat32Array,
		obstacles: PackedFloat32Array, rebuild: bool, iterations: int, shocks: PackedFloat32Array,
		multigrid_cycles := 0, slope_texture: Texture2D = null, slope_bounds := Rect2()) -> void:
	RenderingServer.call_on_render_thread(_advance.bind(
		parameters.to_byte_array(), stamps.to_byte_array(), obstacles.to_byte_array() if rebuild else PackedByteArray(),
		rebuild, iterations, shocks.to_byte_array(), multigrid_cycles, slope_texture, slope_bounds))


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
	_backtrace_uv = _texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32G32_SFLOAT)
	for index in range(2):
		_states.append(_texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT))
		_coordinates.append(_texture(_density_resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT))
		_pressures.append(_texture(_resolution, RenderingDevice.DATA_FORMAT_R32_SFLOAT))

	_topology = _texture(_resolution, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	var topology_uniforms := _common(_velocity)
	topology_uniforms.append(_image(3, _topology))
	_sets["topology"] = _make_set("topology", topology_uniforms)
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
		_pressure_sets.append(_make_set("pressure", [_sample(0, _topology), _sample(1, _before_projection),
			_sample(2, _pressures[index]), _image(3, _pressures[1 - index])]))
		uniforms = _common(_working_velocity)
		uniforms.append_array([_sample(3, _pressures[index]), _image(4, _velocity)])
		_sets["project%d" % index] = _make_set("project", uniforms)
		uniforms = _common(_velocity)
		uniforms.append_array([_sample(3, _states[index]), _image(4, _predicted), _image(5, _backtrace_uv)])
		_sets["predict%d" % index] = _make_set("predict", uniforms)
		uniforms = _common(_velocity)
		uniforms.append_array([
			_sample(3, _states[index]), _sample(4, _predicted), _sample(5, _coordinates[index]),
			_image(6, _states[1 - index]), _image(7, _coordinates[1 - index]),
			_image(8, _display), _sample(9, _backtrace_uv)])
		_sets["transport%d" % index] = _make_set("transport", uniforms)
		uniforms = _common(_shock_velocity)
		uniforms.append_array([
			_sample(3, _states[index]), _sample(4, _coordinates[index]),
			_image(5, _states[1 - index]), _image(6, _coordinates[1 - index]),
			_image(7, _display)])
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
	coordinate_texture.texture_rd_rid = _coordinates[_read]
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


func _init_multigrid() -> void:
	var size := _resolution
	var fine: PressureLevel
	while true:
		var level := PressureLevel.new()
		level.size = size
		level.faces = _texture(size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
		if fine == null:
			level.pressure = _pressures
			level.rhs = _before_projection
			level.geometry_set = _make_set("mg_finest", [_sample(0,_topology), _image(1,level.faces), _sample(2,_mask)])
		else:
			level.rhs = _texture(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
			for i in 2:
				level.pressure.append(_texture(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT))
			level.geometry_set = _make_set("mg_coarsen", [_sample(0,fine.faces), _image(1,level.faces)])
			for i in 2:
				fine.restrict_sets.append(_make_set("mg_restrict", [_sample(0,fine.faces), _sample(1,fine.rhs),
					_sample(2,fine.pressure[i]), _image(3,level.rhs), _image(4,level.pressure[0])]))
				for coarse_read in 2:
					fine.prolong.append(_make_set("mg_prolong", [_sample(0,fine.faces), _sample(1,level.faces),
						_sample(2,level.pressure[coarse_read]), _sample(3,fine.pressure[i]), _image(4,fine.pressure[1-i])]))
		for i in 2:
			level.smooth.append(_make_set("mg_smooth", [_sample(0,level.faces), _sample(1,level.rhs),
				_sample(2,level.pressure[i]), _image(3,level.pressure[1-i])]))
		_levels.append(level)
		if size <= 8:
			break
		fine = level
		size = (size+1)/2


func _smooth(list: int, level: PressureLevel, read: int, iterations: int) -> int:
	for i in iterations:
		_dispatch(list, "mg_smooth", level.smooth[read], level.size)
		read = 1-read
	return read


func _v_cycle(list: int, depth: int, read: int) -> int:
	var level := _levels[depth]
	if depth+1 == _levels.size():
		return _smooth(list, level, read, 16)
	read = _smooth(list, level, read, 2)
	_dispatch(list, "mg_restrict", level.restrict_sets[read], _levels[depth+1].size)
	var coarse_read := _v_cycle(list, depth+1, 0)
	_dispatch(list, "mg_prolong", level.prolong[2*read+coarse_read], level.size)
	# Smooth fine-scale jumps left by the masked interpolation at solid faces.
	return _smooth(list, level, 1-read, 4)


func _advance(parameters: PackedByteArray, stamps: PackedByteArray,
		obstacles: PackedByteArray, rebuild: bool, iterations: int, shocks: PackedByteArray,
		multigrid_cycles: int, slope_texture: Texture2D, slope_bounds: Rect2) -> void:
	if not _ready_on_gpu:
		return
	var dt := parameters.decode_float(32)
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
	if multigrid_cycles > 0 and _levels.is_empty():
		_init_multigrid()
	var transport_slope := slope_texture != null and _bind_slope_texture(slope_texture)
	var area := Vector2(parameters.decode_float(0), parameters.decode_float(4))
	var list := _rd.compute_list_begin()
	if rebuild:
		_dispatch(list, "obstacles", _sets["obstacles"], _density_resolution)
		_dispatch(list, "topology", _sets["topology"], _resolution)
		_mg_geometry_dirty = true
	_dispatch(list, "velocity", _sets["velocity"], _resolution)
	_dispatch(list, "divergence", _sets["divergence"], _resolution)
	if multigrid_cycles > 0:
		if _mg_geometry_dirty:
			for i in _levels.size():
				var level := _levels[i]
				_dispatch(list, "mg_finest" if i == 0 else "mg_coarsen", level.geometry_set, level.size)
			_mg_geometry_dirty = false
		for cycle in multigrid_cycles:
			_pressure_read = _v_cycle(list, 0, _pressure_read)
	else:
		var groups := ceili(_resolution / 8.0)
		_rd.compute_list_bind_compute_pipeline(list, _pipelines["pressure"])
		for index in range(iterations):
			_rd.compute_list_bind_uniform_set(list, _pressure_sets[_pressure_read], 0)
			_rd.compute_list_dispatch(list, groups, groups, 1)
			_rd.compute_list_add_barrier(list)
			_pressure_read = 1 - _pressure_read
	_dispatch(list, "project", _sets["project%d" % _pressure_read], _resolution)
	_dispatch(list, "divergence", _sets["diagnostics"], _resolution)
	_dispatch(list, "predict", _sets["predict%d" % _read], _density_resolution)
	_dispatch(list, "transport", _sets["transport%d" % _read], _density_resolution)
	_read = 1 - _read
	if not shocks.is_empty() and dt > 0.0:
		var center := Vector2(parameters.decode_float(8), parameters.decode_float(12))
		var cell := minf(area.x, area.y) / _density_resolution
		for region in _shock_regions(shocks, area, center, cell):
			_transport_region(list, region, dt, cell)
	if transport_slope:
		_transport_slope(list, dt, area / _density_resolution, parameters.decode_float(60), slope_bounds)
	_rd.compute_list_end()
	coordinate_texture.texture_rd_rid = _coordinates[_read]


func _bind_slope_texture(texture: Texture2D) -> bool:
	if texture == _slope_texture and _slope_sets.size() == 2:
		return true
	_release_slope_sets()
	var height_rid := RenderingServer.texture_get_rd_texture(texture.get_rid())
	if not height_rid.is_valid():
		return false
	for index in range(2):
		var uniforms := _common(_velocity)
		uniforms.append_array([
			_sample(3, height_rid), _sample(4, _states[index]), _sample(5, _coordinates[index]),
			_image(6, _states[1 - index]), _image(7, _coordinates[1 - index]), _image(8, _display)])
		var uniform_set := _rd.uniform_set_create(uniforms, _shaders["slope_transport"], 0)
		if not uniform_set.is_valid():
			_release_slope_sets()
			return false
		_slope_sets.append(uniform_set)
	_slope_texture = texture
	return true


func _release_slope_sets() -> void:
	for uniform_set in _slope_sets:
		if _rd.uniform_set_is_valid(uniform_set):
			_rd.free_rid(uniform_set)
	_slope_sets.clear()
	_slope_texture = null


func _transport_slope(list: int, dt: float, cell: Vector2, max_speed: float, bounds: Rect2) -> void:
	# Bound the sum of outgoing Courant numbers even when all four faces drain.
	var desired := maxi(1, ceili(2.0 * dt * max_speed * (1.0 / cell.x + 1.0 / cell.y) / 0.8))
	var steps := mini(desired, MAX_SLOPE_SUBSTEPS)
	var push := PackedFloat32Array([
		bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y,
		dt / steps, max_speed * float(steps) / desired, 0.0]).to_byte_array()
	for index in range(steps):
		push.encode_float(24, float(index == steps - 1))
		_dispatch(list, "slope_transport", _slope_sets[_read], _density_resolution, push)
		_read = 1 - _read


func _shock_regions(shocks: PackedByteArray, area: Vector2, center: Vector2, cell: float) -> Array[ShockRegion]:
	var regions: Array[ShockRegion] = []
	var domain := Rect2i(0, 0, _density_resolution, _density_resolution)
	for i in range(shocks.size() / (SHOCK_FLOAT_COUNT * 4)):
		var offset := i * SHOCK_FLOAT_COUNT * 4
		var speed := absf(shocks.decode_float(offset + 12))
		if speed <= 0.000001:
			continue
		var point := Vector2(shocks.decode_float(offset), shocks.decode_float(offset + 4))
		var endpoint := point
		var radius := shocks.decode_float(offset + 8)
		var region := ShockRegion.new()
		if shocks.decode_float(offset + 24) > 0.5:
			endpoint = Vector2(shocks.decode_float(offset + 16), shocks.decode_float(offset + 20))
			radius = maxf(radius, 2.0 * cell)
			region.cut_speed = speed
		else:
			radius = maxf(radius, cell) + maxf(shocks.decode_float(offset + 16), 2.0 * cell)
			region.burst_speed = speed
		var low := ((point.min(endpoint) - Vector2.ONE * radius - center) / area + Vector2.ONE * 0.5) * _density_resolution
		var high := ((point.max(endpoint) + Vector2.ONE * radius - center) / area + Vector2.ONE * 0.5) * _density_resolution
		var origin := Vector2i(low.floor())
		# Three cells cover MAC face interpolation and the two-cell flux stencil.
		region.rect = Rect2i(origin, Vector2i(high.ceil()) - origin).grow(3).intersection(domain)
		if not region.rect.has_area():
			continue
		region.members = 1 << i
		# A union can bridge previously disjoint regions. Restart after every merge.
		var j := 0
		while j < regions.size():
			var other := regions[j]
			if not region.rect.intersects(other.rect):
				j += 1
				continue
			region.rect = region.rect.merge(other.rect)
			region.members |= other.members
			region.burst_speed += other.burst_speed
			region.cut_speed = maxf(region.cut_speed, other.cut_speed)
			regions.remove_at(j)
			j = 0
		regions.append(region)
	return regions


func _transport_region(list: int, region: ShockRegion, dt: float, cell: float) -> void:
	var desired := maxi(1, ceili(dt * (region.burst_speed + region.cut_speed) * 2.0 / (cell * 0.4)))
	var steps := mini(desired, MAX_SHOCK_SUBSTEPS)
	var rect := region.rect
	var field_push := PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y,
		region.members, 0, 0, 0]).to_byte_array()
	field_push.encode_float(20, float(steps) / desired)
	_dispatch(list, "shock_field", _sets["shock_field"], _density_resolution, field_push, rect.size)
	var push := PackedInt32Array([0, 0, rect.position.x, rect.position.y, rect.size.x, rect.size.y, 0, 0]).to_byte_array()
	push.encode_float(0, dt / steps)
	var read_index := _read
	for i in range(steps):
		push.encode_s32(4, int(i == steps - 1))
		_dispatch(list, "shock_transport", _sets["shock_transport%d" % read_index], _density_resolution, push, rect.size)
		read_index = 1 - read_index
	# The canonical texture already holds all other regions. Copy back only an odd result.
	if read_index != _read:
		var copy_push := PackedInt32Array([rect.position.x, rect.position.y, rect.size.x, rect.size.y]).to_byte_array()
		_dispatch(list, "shock_seed", _sets["shock_seed%d" % read_index], _density_resolution, copy_push, rect.size)


func _release() -> void:
	if _rd == null:
		return
	_ready_on_gpu = false
	for wrapper in [state_texture, obstacle_texture, coordinate_texture, diagnostics_texture]:
		wrapper.texture_rd_rid = RID()
	_release_slope_sets()
	_resources.reverse()
	for rid in _resources:
		if rid.is_valid():
			_rd.free_rid(rid)
	_resources.clear()
	_states.clear()
	_coordinates.clear()
	_pressures.clear()
	_pressure_sets.clear()
	_levels.clear()
	_mg_geometry_dirty = true
	_sets.clear()
	_shaders.clear()
	_pipelines.clear()
	_rd = null
