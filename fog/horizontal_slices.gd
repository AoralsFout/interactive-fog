extends MultiMeshInstance3D
## Transparent horizontal planes share one draw and the field's optical profile.

const SHADER := preload("res://fog/shaders/horizontal_slices.gdshader")
@export_range(1, 12, 1) var slice_count := 6:
	set(value):
		slice_count = clampi(value, 1, 12)
		if multimesh != null and material != null:
			_update_layers()
@onready var field := get_parent() as InteractiveFogField
var material: ShaderMaterial


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
		var layers := MultiMesh.new()
		layers.transform_format = MultiMesh.TRANSFORM_3D
		layers.mesh = plane
		material = ShaderMaterial.new()
		material.shader = SHADER
		material_override = material
		multimesh = layers
		_update_layers()
	visible = active
	set_process(active)
	if active:
		_bind_textures()
		_sync_appearance()
		_process(0.0)


func _update_layers() -> void:
	multimesh.instance_count = slice_count
	for index in slice_count:
		multimesh.set_instance_transform(index, Transform3D.IDENTITY)
	material.set_shader_parameter("slice_count", slice_count)


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
	custom_aabb = AABB(Vector3(-size.x*0.5,0,-size.y*0.5), Vector3(size.x,field.settings.thickness,size.y))


func _process(_delta: float) -> void:
	material.set_shader_parameter("simulation_time", field.get_simulation_time())
	var env := get_world_3d().environment
	if env:
		var ambient := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy * env.volumetric_fog_ambient_inject
		material.set_shader_parameter("ambient_scatter", Vector3(ambient.r,ambient.g,ambient.b))
		material.set_shader_parameter("anisotropy", env.volumetric_fog_anisotropy)
