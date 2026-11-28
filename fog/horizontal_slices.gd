extends MultiMeshInstance3D
## Flat planes or terrain-following tiles share the field's optical profile.

const SHADER := preload("res://fog/shaders/horizontal_slices.gdshader")
const TILE_CELLS := 24
const MAX_GRID_CELLS := 160
@export_range(1, 12, 1) var slice_count := 6:
	set(value):
		slice_count = clampi(value, 1, 12)
		if material != null:
			_update_layers()
@onready var field := get_parent() as InteractiveFogField
var material: ShaderMaterial
var _flat_layers: MultiMesh
var _terrain_tiles: Array[MultiMeshInstance3D] = []
var _tile_heights := PackedVector2Array()
var _terrain_texture: Texture2D
var _terrain_bounds := Rect2()
var _field_bounds := Rect2()


func _ready() -> void:
	set_process(false)
	process_priority = 10
	field.appearance_changed.connect(_sync_appearance)
	field.textures_changed.connect(_bind_textures)


func set_active(active: bool) -> void:
	if active == visible:
		return
	if active and material == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2.ONE
		material = ShaderMaterial.new()
		material.shader = SHADER
		material_override = material
		_flat_layers = _make_layers(plane)
		_update_layers()
	visible = active
	set_process(active)
	if active:
		_bind_textures()
		_sync_appearance()
		_process(0.0)


func _update_layers() -> void:
	material.set_shader_parameter("slice_count", slice_count)
	_set_layer_count(_flat_layers)
	for tile in _terrain_tiles:
		_set_layer_count(tile.multimesh)


func _set_layer_count(layers: MultiMesh) -> void:
	layers.instance_count = slice_count
	for index in slice_count:
		layers.set_instance_transform(index, Transform3D.IDENTITY)


func _make_layers(mesh: Mesh) -> MultiMesh:
	var layers := MultiMesh.new()
	layers.transform_format = MultiMesh.TRANSFORM_3D
	layers.mesh = mesh
	_set_layer_count(layers)
	return layers


func _bind_textures() -> void:
	if not visible:
		return
	var volume := field.get_node(field.volume_path) as FogVolume
	material.set_shader_parameter("detail_texture", volume.material.get_shader_parameter("detail_texture"))
	material.set_shader_parameter("use_simulation", field.get_state_texture() != null)
	material.set_shader_parameter("state_texture", field.get_state_texture())
	material.set_shader_parameter("coordinate_texture", field.get_coordinate_texture())
	material.set_shader_parameter("obstacle_texture", field.get_obstacle_texture())


func _sync_appearance() -> void:
	if not visible:
		return
	field.apply_render_parameters(material)
	var size := field.settings.area_size
	var terrain := field.get_render_height_map()
	if terrain == null:
		_clear_tiles()
		multimesh = _flat_layers
		custom_aabb = AABB(Vector3(-size.x*0.5,0,-size.y*0.5), Vector3(size.x,field.settings.thickness,size.y))
		return

	multimesh = null
	var center := Vector2(field.global_position.x, field.global_position.z)
	var area := Rect2(center - size * 0.5, size)
	var texture := terrain.get_height_texture()
	if texture != _terrain_texture or terrain.world_bounds != _terrain_bounds or area != _field_bounds:
		_clear_tiles()
		_terrain_texture = texture
		_terrain_bounds = terrain.world_bounds
		_field_bounds = area
		_build_tiles(terrain, center)
	for index in _terrain_tiles.size():
		var heights := _tile_heights[index]
		var bottom := heights.x - field.global_position.y
		_terrain_tiles[index].custom_aabb = AABB(Vector3(-0.5,bottom,-0.5),
			Vector3(1.0,heights.y-heights.x+field.settings.thickness,1.0))


func _clear_tiles() -> void:
	for tile in _terrain_tiles:
		tile.hide()
		tile.queue_free()
	_terrain_tiles.clear()
	_tile_heights.clear()
	_terrain_texture = null


func _build_tiles(terrain: FogHeightMap, center: Vector2) -> void:
	var cells := terrain.get_samples().get_size() - Vector2i.ONE
	var spacing := _terrain_bounds.size / Vector2(cells)
	var first := Vector2i(((_field_bounds.position - _terrain_bounds.position) / spacing).floor()).clamp(Vector2i.ZERO, cells - Vector2i.ONE)
	var last := Vector2i(((_field_bounds.end - _terrain_bounds.position) / spacing).ceil()).clamp(Vector2i.ONE, cells)
	var stride := maxi(1, ceili(float(maxi(last.x - first.x, last.y - first.y)) / MAX_GRID_CELLS))
	var tile_step := Vector2i.ONE * TILE_CELLS * stride
	for z in range(first.y, last.y, tile_step.y):
		for x in range(first.x, last.x, tile_step.x):
			var start := Vector2i(x, z)
			var cell_count := (start + tile_step).min(last) - start
			var tile_area := Rect2(_terrain_bounds.position + Vector2(start) * spacing, Vector2(cell_count) * spacing)
			var tile_center := tile_area.get_center() - center
			var tile := MultiMeshInstance3D.new()
			tile.position = Vector3(tile_center.x, 0.0, tile_center.y)
			tile.scale = Vector3(tile_area.size.x, 1.0, tile_area.size.y)
			tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			tile.material_override = material
			tile.multimesh = _make_layers(_tile_mesh(cell_count, stride))
			add_child(tile)
			_terrain_tiles.append(tile)
			_tile_heights.append(terrain.get_height_limits(tile_area.intersection(_terrain_bounds)))


func _tile_mesh(cells: Vector2i, stride: int) -> ArrayMesh:
	var grid := Vector2i((Vector2(cells) / stride).ceil()) + Vector2i.ONE
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for z in range(grid.y):
		for x in range(grid.x):
			var uv := Vector2((Vector2i(x, z) * stride).min(cells)) / Vector2(cells) - Vector2.ONE * 0.5
			vertices.append(Vector3(uv.x, 0.0, uv.y))
			normals.append(Vector3.UP)
			if x > 0 and z > 0:
				var end := z * grid.x + x
				var start := end - grid.x - 1
				# The diagonal must match the triangles used by the terrain and height sampler.
				indices.append_array([start, start + 1, end, start, end, end - 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _process(_delta: float) -> void:
	material.set_shader_parameter("simulation_time", field.get_simulation_time())
	var env := get_world_3d().environment
	if env:
		var ambient := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy * env.volumetric_fog_ambient_inject
		material.set_shader_parameter("ambient_scatter", Vector3(ambient.r,ambient.g,ambient.b))
		material.set_shader_parameter("anisotropy", env.volumetric_fog_anisotropy)
