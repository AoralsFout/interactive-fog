extends CompositorEffect
## Render-thread implementation. The scene adapter sends an immutable parameter snapshot.

const INTEGRATE := preload("res://fog/shaders/thin_integrate.glsl")
const COMPOSE := preload("res://fog/shaders/thin_compose.glsl")
const CONTEXT := &"interactive_thin_fog"
var rd: RenderingDevice
var shaders: Array[RID] = []
var pipelines: Array[RID] = []
var linear: RID
var repeat_linear: RID
var params: RID
var field_data := PackedByteArray()
var state: Texture2DRD
var obstacle: Texture2DRD
var coordinates: Texture2DRD
var noise: Texture3D
var height_map: Texture2D
var terrain_tiles: Texture2D


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true


func set_field(data: PackedByteArray, density: Texture2DRD, mask: Texture2DRD,
		coords: Texture2DRD, detail: Texture3D, terrain: Texture2D, tiles: Texture2D) -> void:
	field_data = data
	state = density
	obstacle = mask
	coordinates = coords
	noise = detail
	height_map = terrain
	terrain_tiles = tiles


func _setup() -> void:
	rd = RenderingServer.get_rendering_device()
	for source: RDShaderFile in [INTEGRATE, COMPOSE]:
		var shader := rd.shader_create_from_spirv(source.get_spirv())
		shaders.append(shader)
		pipelines.append(rd.compute_pipeline_create(shader))
	var sampler := RDSamplerState.new()
	sampler.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear = rd.sampler_create(sampler)
	sampler.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	repeat_linear = rd.sampler_create(sampler)
	params = rd.uniform_buffer_create(field_data.size())


func _binding(slot: int, type: RenderingDevice.UniformType, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.binding = slot
	uniform.uniform_type = type
	for id in ids:
		uniform.add_id(id)
	return uniform


func _render_callback(_stage: int, render_data: RenderData) -> void:
	if state == null or noise == null or not state.texture_rd_rid.is_valid():
		return
	var detail := RenderingServer.texture_get_rd_texture(noise.get_rid())
	if not detail.is_valid():
		return
	# Bind existing resources in flat mode. The flat shader branch never samples them.
	var height_rid := state.texture_rd_rid
	var tiles_rid := height_rid
	if height_map != null:
		height_rid = RenderingServer.texture_get_rd_texture(height_map.get_rid())
		tiles_rid = RenderingServer.texture_get_rd_texture(terrain_tiles.get_rid())
		if not height_rid.is_valid() or not tiles_rid.is_valid():
			return
	if rd == null:
		_setup()
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene := render_data.get_render_scene_data()
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var half_size := (size + Vector2i.ONE) / 2
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if not buffers.has_texture(CONTEXT, &"scatter"):
		buffers.create_texture(CONTEXT, &"scatter", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				usage, RenderingDevice.TEXTURE_SAMPLES_1, half_size, 1, 1, true, false)
	var scatter := buffers.get_texture(CONTEXT, &"scatter")
	var depth := buffers.get_depth_layer(0)
	var color := buffers.get_color_layer(0)
	var cam := scene.get_cam_transform()
	var inv_vp := Projection(cam) * scene.get_cam_projection().inverse()
	var constants := PackedVector4Array([inv_vp.x, inv_vp.y, inv_vp.z, inv_vp.w,
			Vector4(cam.origin.x, cam.origin.y, cam.origin.z, 0)]).to_byte_array()
	var sampled := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	var storage := RenderingDevice.UNIFORM_TYPE_IMAGE
	var integrate_set := UniformSetCacheRD.get_cache(shaders[0], 0, [
		_binding(0, sampled, [linear, depth]), _binding(1, sampled, [linear, state.texture_rd_rid]),
		_binding(2, sampled, [linear, obstacle.texture_rd_rid]), _binding(3, sampled, [linear, coordinates.texture_rd_rid]),
		_binding(4, sampled, [repeat_linear, detail]), _binding(5, storage, [scatter]),
		_binding(6, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, [params]),
		_binding(7, sampled, [linear, height_rid]), _binding(8, sampled, [linear, tiles_rid]),
	])
	var compose_set := UniformSetCacheRD.get_cache(shaders[1], 0, [
		_binding(0, sampled, [linear, depth]), _binding(1, sampled, [linear, scatter]), _binding(2, storage, [color]),
	])
	rd.buffer_update(params, 0, field_data.size(), field_data)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipelines[0])
	rd.compute_list_bind_uniform_set(list, integrate_set, 0)
	rd.compute_list_set_push_constant(list, constants, constants.size())
	rd.compute_list_dispatch(list, (half_size.x + 7) / 8, (half_size.y + 7) / 8, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, pipelines[1])
	rd.compute_list_bind_uniform_set(list, compose_set, 0)
	rd.compute_list_dispatch(list, (size.x + 7) / 8, (size.y + 7) / 8, 1)
	rd.compute_list_end()


func release() -> void:
	if rd:
		for id in shaders + [params, linear, repeat_linear]:
			rd.free_rid(id)
	state = null
	obstacle = null
	coordinates = null
	noise = null
	height_map = null
	terrain_tiles = null
