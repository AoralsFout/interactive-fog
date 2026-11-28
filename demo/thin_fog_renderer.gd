extends Node
## Demo adapter for a single field, camera and the three lights in main.tscn.

const Effect = preload("res://fog/thin_fog_effect.gd")
@onready var field: InteractiveFogField = $"../FogField"
@onready var world: WorldEnvironment = $"../WorldEnvironment"
@onready var camera: Camera3D = $"../CameraRig/Camera3D"
@onready var sun: DirectionalLight3D = $"../DirectionalLight3D"
@onready var warm: SpotLight3D = $"../Lighting/WarmSpot"
@onready var cool: OmniLight3D = $"../Lighting/CoolOmni"
@onready var volume: FogVolume = field.get_node(field.volume_path)
var effect: Effect
var compositor: Compositor
var previous_compositor: Compositor


func _ready() -> void:
	process_priority = 10
	set_process(false)
	$"../HUD".thin_fog_selected.connect(_switch)


func _switch(active: bool) -> void:
	if active == is_processing():
		return
	if active:
		if effect == null:
			effect = Effect.new()
		previous_compositor = camera.compositor
		compositor = previous_compositor.duplicate() if previous_compositor else Compositor.new()
		var effects := compositor.compositor_effects
		effects.append(effect)
		compositor.compositor_effects = effects
		camera.compositor = compositor
	else:
		camera.compositor = previous_compositor
		compositor = null
	set_process(active)


func _exit_tree() -> void:
	if is_processing():
		_switch(false)
	if effect:
		RenderingServer.call_on_render_thread(effect.release)


func _process(_delta: float) -> void:
	if field.get_state_texture() == null:
		return
	var s := field.settings
	var env := world.environment
	var origin := field.global_position
	var terrain := field.get_render_height_map()
	var bounds := terrain.world_bounds if terrain != null else Rect2()
	var height_texture := terrain.get_height_texture() if terrain != null else null
	var tile_texture := terrain.get_tile_height_texture() if terrain != null else null
	var density := s.density if field.height_map == null or terrain != null else 0.0
	var half_height := volume.size.y * 0.5
	var ambient := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy * env.volumetric_fog_ambient_inject
	var albedo := s.albedo.srgb_to_linear()
	var emission := s.emission.srgb_to_linear()
	var vectors: Array[Vector4] = [
		Vector4(origin.x, origin.y, origin.z, s.thickness),
		Vector4(s.area_size.x, s.area_size.y, density, s.height_falloff),
		Vector4(s.edge_fade, maxf(s.obstacle_fade, s.area_size[s.area_size.max_axis_index()] / s.resolution), s.detail_scale, s.detail_amount),
		Vector4(s.detail_sharpness, s.detail_warp, field.get_simulation_time() / s.detail_reset_period, env.volumetric_fog_anisotropy),
		Vector4(albedo.r, albedo.g, albedo.b, 0),
		Vector4(emission.r, emission.g, emission.b, 0),
		Vector4(ambient.r, ambient.g, ambient.b, 0),
		_vec(sun.global_basis.z.normalized(), float(sun.shadow_enabled)), _light(sun),
		_vec(warm.global_position, warm.spot_range), _light(warm),
		_vec(-warm.global_basis.z.normalized(), cos(deg_to_rad(warm.spot_angle))),
		_vec(cool.global_position, cool.omni_range), _light(cool),
		Vector4(warm.spot_attenuation, cool.omni_attenuation, warm.spot_angle_attenuation, 0),
		Vector4(bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y),
		Vector4(volume.global_position.y - half_height, volume.global_position.y + half_height, float(terrain != null), 0.0),
	]
	var params := PackedVector4Array(vectors).to_byte_array()
	var detail: Texture3D = volume.material.get_shader_parameter("detail_texture")
	RenderingServer.call_on_render_thread(effect.set_field.bind(params, field.get_state_texture(),
			field.get_obstacle_texture(), field.get_coordinate_texture(), detail, height_texture, tile_texture))


func _vec(v: Vector3, w: float) -> Vector4:
	return Vector4(v.x, v.y, v.z, w)


func _light(node: Light3D) -> Vector4:
	var color := node.light_color.srgb_to_linear() * node.light_energy * node.light_volumetric_fog_energy
	if not node.is_visible_in_tree():
		color = Color.BLACK
	return Vector4(color.r, color.g, color.b, float(node.shadow_enabled))
