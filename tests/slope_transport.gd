extends "res://tests/flow_transport.gd"
## Real GPU cases for mass, material motion, terrain replacement and interaction.


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	_field = load("res://fog/scenes/fog_field.tscn").instantiate() as InteractiveFogField
	_field.settings = FogSettings.new()
	var settings := _field.settings
	settings.area_size = Vector2(8.0, 6.0)
	settings.resolution = 64
	settings.pressure_iterations = 12
	settings.wind_velocity = Vector2.ZERO
	settings.turbulence_strength = 0.0
	settings.vorticity_strength = 0.0
	settings.density_variation = 0.0
	settings.downslope_strength = 0.65
	settings.max_downslope_speed = 0.35
	_field.height_map = _terrain(func(x: float) -> float: return 0.5 - 0.05 * x)
	_field.simulation_enabled = false
	root.add_child(_field)
	await _frames(8)
	_field.set_process(false)
	await _reset()
	if _field.get_state_texture().get_width() != settings.get_density_resolution():
		_check(false, "density GPU texture initialized")
		quit(1)
		return
	var initial := _state()
	await _steps(55)
	var drift := _state()
	var ridge_to_foot := _mean_x(drift) - _mean_x(initial)
	var error := absf(_mass(drift) / _mass(initial) - 1.0)
	_check(ridge_to_foot > 0.24, "still air: density centroid moves %.3f m downhill" % ridge_to_foot)
	_check(error < 0.0005, "closed slope conserves fog mass: relative error %.6f" % error)
	var along := _find_material(Vector2.ZERO)
	_check(along.x > 0.24 and absf(along.y) < 0.08, "material marker follows the slope: %s" % along)

	settings.wind_velocity = Vector2(-0.75, 0.0)
	await _reset()
	await _steps(36)
	var uphill := _find_material(Vector2.ZERO)
	_check(uphill.x < -0.42 and _sample(_state(), Vector2.ZERO).g < -0.3,
		"strong opposing wind carries fog uphill: %s" % uphill)
	settings.wind_velocity = Vector2.ZERO

	_field.height_map = _terrain(func(_x: float) -> float: return 0.45)
	await _reset()
	await _steps(12)
	_check(_difference(initial, _state()) < 0.0001, "level height map adds no drift")
	_field.height_map = _terrain(func(x: float) -> float: return 0.25 + 0.08 * absf(x - 0.25))
	await _reset()
	await _steps(75)
	var valley := _state()
	var center := Vector2(0.25, 0.0)
	var middle_density := _sample(valley, center).r
	await _steps(180)
	var pooled := _state()
	var final_density := _sample(pooled, center).r
	var early_rate := (middle_density - 1.0) / 75.0
	var late_rate := (final_density - middle_density) / 180.0
	_check(middle_density > 1.6 and late_rate < early_rate * 0.75 and final_density < settings.max_compressed_density,
		"valley accumulation slows as density rises: %.2f then %.2f" % [middle_density, final_density])
	_check(absf(_mass(pooled) / _mass(initial) - 1.0) < 0.0005, "valley accumulation redistributes mass")
	settings.downslope_strength = 0.0
	await _steps(8)
	_check(_difference(pooled, _state()) < 0.0001, "turning slope off freezes drift and retains its result")

	settings.downslope_strength = 0.65
	_field.height_map = _terrain(func(x: float) -> float: return 0.5 - 0.05 * x)
	var wall := FogObstacle3D.new()
	wall.sync_prefab_geometry = false
	wall.shape = FogObstacle3D.Shape.BOX
	wall.box_size = Vector2(0.5, 8.0)
	root.add_child(wall)
	await _reset()
	var upwind_mass := _west_mass(_state())
	await _steps(50)
	_check(absf(_west_mass(_state()) / upwind_mass - 1.0) < 0.0005
		and _sample(_state(), Vector2.ZERO).r == 0.0, "closed wall carries zero downslope flux")
	wall.queue_free()
	await _frames(2)
	await _reset()
	_field.burst(Vector3.ZERO, 1.4, 0.55)
	await _steps(18)
	_check(_sample(_state(), Vector2.ZERO).r < 0.3, "burst and slope operate on the same density state")

	_field.queue_free()
	await _frames(4)
	print("SLOPE_TRANSPORT_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _terrain(profile: Callable) -> FogHeightMap:
	var terrain := FogHeightMap.new()
	terrain.world_bounds = Rect2(-5.0, -4.0, 10.0, 8.0)
	terrain.height_range = Vector2(0.0, 10.0)
	var image := Image.create_empty(41, 2, false, Image.FORMAT_RF)
	for x in range(41):
		var value: float = profile.call(-5.0 + x * 0.25)
		for z in range(2):
			image.set_pixel(x, z, Color(value, 0.0, 0.0))
	terrain.source = ImageTexture.create_from_image(image)
	return terrain


func _mean_x(image: Image) -> float:
	var moment := 0.0
	for z in range(image.get_height()):
		for x in range(image.get_width()):
			var world_x := ((x + 0.5) / image.get_width() - 0.5) * _field.settings.area_size.x
			moment += image.get_pixel(x, z).r * world_x
	return moment / _mass(image)


func _west_mass(image: Image) -> float:
	var total := 0.0
	for z in range(image.get_height()):
		for x in range(image.get_width() / 2):
			total += image.get_pixel(x, z).r
	return total
