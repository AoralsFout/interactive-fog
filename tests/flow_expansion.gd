extends "res://tests/flow_transport.gd"
## 冲击路径真实 GPU 验收：径向扩张、密度通量、共同材质轨迹、障碍遮挡和输入接线。


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	_field = load("res://fog/scenes/fog_field.tscn").instantiate() as InteractiveFogField
	_field.settings = FogSettings.new()
	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.turbulence_strength = 0.0
	_field.settings.density_variation = 0.0
	_field.simulation_enabled = false
	root.add_child(_field)
	await _frames(8)
	var ready := _field.get_state_texture() != null and _field.get_state_texture().get_width() == _field.settings.get_density_resolution()
	_check(ready, "expansion GPU pipeline initializes with the real density texture")
	if not ready:
		_field.queue_free()
		await _frames(3)
		quit(1)
		return
	_field.set_process(false)
	await _reset()
	var before := _state()
	var mass_before := _mass(before)
	_field.burst(Vector3.ZERO, 3.0, 0.65, 1.0, 0.0)
	await _steps(6)
	var early := _ring(_state(), 0.3, 4.0)
	await _steps(14)
	var after := _state()
	var late := _ring(after, 0.3, 4.0)
	var mass_error := absf(_mass(after) / mass_before - 1.0)
	_check(_sample(after, Vector2.ZERO).r < 0.15, "expansion transports fog out of center: %.4f" % _sample(after, Vector2.ZERO).r)
	_check(late.density > 1.5, "conservative transport builds a dense wave front: %.3f" % late.density)
	_check(late.radius > early.radius + 1.0, "wave front expands: %.2f -> %.2f m" % [early.radius, late.radius])
	_check(mass_error < 0.0005, "expansion redistributes existing fog: relative mass error %.6f" % mass_error)
	_check(_bounded(after), "expansion keeps density finite, positive and below safety cap")
	var marker := _find_material(Vector2(0.6, 0.0))
	_check(marker.x > 2.0 and absf(marker.y) < 0.2, "material coordinates move with radial density transport: %s" % marker)
	_save_density(before, "expansion-before")
	_save_density(after, "expansion-after")
	# 清空区里再次释放小冲击，不能凭空补出基准浓度圆环。
	var empty_before := _disk_mass(after, 1.6)
	_field.burst(Vector3.ZERO, 1.0, 0.4, 1.0, 0.0, 0.25)
	await _steps(12)
	var nested := _state()
	_check(absf(_disk_mass(nested, 1.6) - empty_before) / maxf(empty_before, 0.001) < 0.03,
		"nested wave in a depleted region does not create fog")
	_check(_ring(nested, 0.5, 1.4).density < 0.8, "depleted source produces only a weak nested rim")

	await _reset()
	_field.burst(Vector3.ZERO, 3.0, 0.65, 1.0, 0.0)
	for index in range(40):
		_field._advance_simulation(1.0 / 60.0)
		await _frames(1)
	var frequency_error := _difference(after, _state())
	_check(frequency_error < 0.04, "30/60Hz expansion agrees: MAE %.6f" % frequency_error)
	_field.burst(Vector3.ZERO, 3.0)
	await _steps(3)
	var frozen := _state()
	var time := _field.get_simulation_time()
	await _frames(12)
	_check(_difference(frozen, _state()) < 0.0001 and is_equal_approx(time, _field.get_simulation_time()), "pause freezes an active expansion")
	await _reset()
	await _steps(6)
	_check(_difference(before, _state()) < 0.0002, "reset cancels active expansion and clears transient state")

	var wall := FogObstacle3D.new()
	wall.sync_prefab_geometry = false
	wall.shape = FogObstacle3D.Shape.BOX
	wall.box_size = Vector2(0.4, 10.0)
	wall.position.x = 1.5
	root.add_child(wall)
	await _reset()
	var behind := _sample(_state(), Vector2(2.2, 0.0)).r
	_field.burst(Vector3.ZERO, 3.0, 0.65, 1.0, 0.0)
	await _steps(20)
	_check(absf(_sample(_state(), Vector2(2.2, 0.0)).r - behind) < 0.005,
		"solid wall occludes the radial impulse behind it")
	_check(_sample(_state(), Vector2(1.5, 0.0)).r < 0.001, "wave cannot transport density through solid cells")
	_save_density(_state(), "expansion-wall")
	wall.queue_free()
	await _frames(2)
	await _reset()
	for index in range(FogSimulationGPU.MAX_BURSTS):
		_field.burst(Vector3((index - 1.5) * 0.4, 0, 0), 2.5)
	_field.burst(Vector3.ZERO, 2.5)
	_check(_field.get("_active_bursts").size() == FogSimulationGPU.MAX_BURSTS, "overlap limit prevents shock buffer overflow")
	await _steps(25)
	_check(_bounded(_state()), "overlapping waves remain stable and bounded")
	await _reset()
	var edge_before := _mass(_state())
	_field.burst(Vector3(-10.5, 0, 0), 3.0, 0.65, 1.0, 0.0)
	await _steps(20)
	_check(_mass(_state()) < edge_before and absf(_sample(_state(), Vector2(10.5, 0.0)).r - 1.0) < 0.001,
		"open boundary lets fog leave without wrapping or creating a remote wave")
	_field.queue_free()
	await _frames(4)
	await _input_path()
	print("FLOW_EXPANSION_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _ring(image: Image, minimum: float, maximum: float) -> Dictionary:
	var best := {"radius": 0.0, "density": 0.0}
	for index in range(65):
		var radius := lerpf(minimum, maximum, float(index) / 64.0)
		var sum := 0.0
		for angle_index in range(32):
			var angle := float(angle_index) * TAU / 32.0
			sum += _sample(image, Vector2(cos(angle), sin(angle)) * radius).r
		var average := sum / 32.0
		if average > best.density:
			best = {"radius": radius, "density": average}
	return best


func _disk_mass(image: Image, radius: float) -> float:
	var total := 0.0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var p := ((Vector2(x, y) + Vector2.ONE * 0.5) / Vector2(image.get_size()) - Vector2.ONE * 0.5) * _field.settings.area_size
			if p.length() < radius:
				total += image.get_pixel(x, y).r
	return total


func _bounded(image: Image) -> bool:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var d := image.get_pixel(x, y).r
			if not is_finite(d) or d < 0.0 or d > _field.settings.max_compressed_density + 0.01:
				return false
	return true


func _input_path() -> void:
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	_field = demo.get_node("FogField") as InteractiveFogField
	await _frames(8)
	_field.set_process(false)
	var initial := _state()
	demo.get_node("MouseBrush").position = Vector3(0.0, 0.05, 1.0)
	demo.set("_valid_brush", true)
	var event := InputEventAction.new()
	event.action = &"fog_burst"
	event.pressed = true
	demo._unhandled_input(event)
	await _steps(8)
	_check(_difference(initial, _state()) > 0.002, "Space input drives the actual radial transport path")
	demo.queue_free()
	await _frames(4)
