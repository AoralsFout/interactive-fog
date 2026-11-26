extends SceneTree
## 同一真实 GPU 流场的轨迹、细密度搬运、压力、历史、障碍与坐标刷新验收。

const STEP := 1.0 / 30.0
const OUTPUT := "res://artifacts/flow-transport/"
var _output := OUTPUT
var _field: InteractiveFogField
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	var use_multigrid := "--multigrid" in OS.get_cmdline_user_args()
	if use_multigrid:
		_output = "res://.godot/multigrid-transport/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output))
	_field = load("res://fog/scenes/fog_field.tscn").instantiate() as InteractiveFogField
	_field.settings = FogSettings.new()
	_field.settings.resolution = 256
	_field.settings.wind_velocity = Vector2(1.0, 0.0)
	_field.settings.turbulence_strength = 0.0
	_field.settings.wind_response = 0.0
	_field.settings.velocity_damping = 0.0
	_field.settings.vorticity_strength = 0.0
	_field.settings.pressure_iterations = 64
	if use_multigrid:
		_field.settings.pressure_solver = FogSettings.PressureSolver.MULTIGRID
	_field.settings.detail_reset_period = 4.0
	_field.simulation_enabled = false
	root.add_child(_field)
	await _frames(8)
	# 固定步测试独占调度，防止暂停路径每画面清掉交互器的位置历史。
	_field.set_process(false)
	await _reset()
	var original := _state()
	await _steps(30)
	var translated := _state()
	var transport_error := _translation_error(original, translated, Vector2(1, 0))
	_check(transport_error < 0.06, "fine density follows known 1m wind displacement: MAE %.5f" % transport_error)
	var coordinates := _field.get_coordinate_texture().get_image()
	var center := _sample(coordinates, Vector2.ZERO)
	_check(absf(center.r + 1.0) < 0.12, "3D noise material coordinates share displacement: %.3f" % center.r)
	_check(_range_valid(translated), "limited transport keeps density finite and within initial bounds")
	_save_density(original, "wind-before")
	_save_density(translated, "wind-after")
	# 跨越辅助坐标刷新，主密度仍跟随同一平移，不回到初始纹理。
	await _steps(95)
	var long_error := _translation_error(original, _state(), Vector2(125.0 / 30.0, 0))
	_check(long_error < 0.09, "density history survives auxiliary coordinate reset: MAE %.5f" % long_error)

	_field.settings.wind_velocity = Vector2.ZERO
	await _reset()
	var still := _state()
	await _steps(30)
	_check(_difference(still, _state()) < 0.0003, "zero flow does not animate or regenerate fine density")
	_field.disturb(Vector3.ZERO, 1.4, Vector2(3.0, 0.0), 2.0)
	await _steps(1)
	var diagnostics := _field.get_diagnostics_texture().get_image()
	var residual := _projection_ratio(diagnostics)
	_check(residual < 0.85, "pressure projection reduces divergence: ratio %.4f" % residual)
	await _steps(29)
	var stirred := _state()
	var moved := _find_material(Vector2.ZERO)
	_check(moved.length() > 0.15, "local drag carries a material marker: %s" % moved)
	_check(_difference(still, stirred) > 0.002, "local input persistently deforms the actual fine density")
	_check(absf(_mass(stirred) / _mass(still) - 1.0) < 0.06, "drag redistributes fog instead of erasing it")
	_save_density(stirred, "drag-after")
	_field.settings.wind_response = 8.0
	_field.settings.velocity_damping = 5.0
	await _steps(90)
	_check(_difference(still, _state()) > 0.002, "settled flow retains the displaced density history")
	var frozen := _state()
	var frozen_time := _field.get_simulation_time()
	await _frames(12)
	_check(_difference(frozen, _state()) < 0.0001 and is_equal_approx(frozen_time, _field.get_simulation_time()), "pause freezes density and material history")
	await _steps(900)
	_check(_range_valid(_state()) and _difference(still, _state()) > 0.002, "30 seconds of settled flow preserves finite, displaced density across repeated texture refresh")

	var obstacle := FogObstacle3D.new()
	obstacle.sync_prefab_geometry = false
	obstacle.radius = 0.6
	obstacle.shape = FogObstacle3D.Shape.CIRCLE
	root.add_child(obstacle)
	await _steps(1)
	_check(_sample(_state(), Vector2.ZERO).r < 0.001, "new solid masks density without resetting the field")
	obstacle.position.x = 3.0
	await _steps(1)
	_check(_sample(_field.get_obstacle_texture().get_image(), Vector2.ZERO).r > 0.0, "moving obstacle refreshes open fluid cells")
	obstacle.queue_free()
	await _frames(2)
	_field.settings.vorticity_strength = 1.5
	await _reset()
	var reset_before := _state()
	_field.disturb(Vector3.ZERO, 1.4, Vector2(2.0, 0.0), 3.0)
	await _steps(30)
	await _reset()
	var reset_velocity := _sample(_state(), Vector2(0.3, 0.0))
	_check(_difference(reset_before, _state()) < 0.0002 and Vector2(reset_velocity.g, reset_velocity.b).length() < 0.001,
		"reset clears old vorticity, density and material history deterministically")
	var brush := FogInteractor3D.new()
	brush.position = Vector3(-1.5, 0.0, 1.0)
	root.add_child(brush)
	await _reset()
	var before_brush := _state()
	for index in range(60):
		brush.position.x += 0.05
		await _steps(1)
	var brush_marker := _find_material(Vector2(-1.0, 1.0))
	_check(brush_marker.distance_to(Vector2(-1.0, 1.0)) > 0.15 and _difference(before_brush, _state()) > 0.002,
		"moving interactor transports fine density and its material marker: %s" % brush_marker)
	brush.queue_free()
	_field.queue_free()
	await _frames(5)
	print("FLOW_TRANSPORT_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _reset() -> void:
	_field.reset_simulation()
	await _steps(1)


func _steps(count: int) -> void:
	for index in range(count):
		_field._advance_simulation(STEP)
		await _frames(1)


func _frames(count: int) -> void:
	for index in range(count):
		await process_frame
		await RenderingServer.frame_post_draw


func _state() -> Image:
	return _field.get_state_texture().get_image()


func _sample(image: Image, p: Vector2) -> Color:
	var uv := p / _field.settings.area_size + Vector2.ONE * 0.5
	var pixel := uv * Vector2(image.get_size()) - Vector2.ONE * 0.5
	var base := Vector2i(pixel.floor())
	var weight := pixel - Vector2(base)
	var limit := image.get_size() - Vector2i.ONE
	return image.get_pixelv(base.clamp(Vector2i.ZERO, limit)).lerp(
		image.get_pixelv((base + Vector2i.RIGHT).clamp(Vector2i.ZERO, limit)), weight.x).lerp(
		image.get_pixelv((base + Vector2i.DOWN).clamp(Vector2i.ZERO, limit)).lerp(
		image.get_pixelv((base + Vector2i.ONE).clamp(Vector2i.ZERO, limit)), weight.x), weight.y)


func _translation_error(before: Image, after: Image, displacement: Vector2) -> float:
	var total := 0.0
	var count := 0
	for y in range(24, after.get_height() - 24, 3):
		for x in range(70, after.get_width() - 24, 3):
			var p := ((Vector2(x, y) + Vector2.ONE * 0.5) / Vector2(after.get_size()) - Vector2.ONE * 0.5) * _field.settings.area_size
			total += absf(after.get_pixel(x, y).r - _sample(before, p - displacement).r)
			count += 1
	return total / count


func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			total += absf(a.get_pixel(x, y).r - b.get_pixel(x, y).r)
	return total / (a.get_width() * a.get_height())


func _range_valid(image: Image) -> bool:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var d := image.get_pixel(x, y).r
			if not is_finite(d) or d < -0.001 or d > 1.001:
				return false
	return true


func _mass(image: Image) -> float:
	var total := 0.0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			total += image.get_pixel(x, y).r
	return total


func _projection_ratio(image: Image) -> float:
	var before := 0.0
	var after := 0.0
	for y in range(3, image.get_height() - 3):
		for x in range(3, image.get_width() - 3):
			var value := image.get_pixel(x, y)
			before += absf(value.b)
			after += absf(value.r)
	return after / maxf(before, 0.00001)


func _find_material(target: Vector2) -> Vector2:
	var image := _field.get_coordinate_texture().get_image()
	var best := INF
	var position := Vector2.ZERO
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var c := image.get_pixel(x, y)
			var distance := Vector2(c.r, c.g).distance_squared_to(target)
			if distance < best:
				best = distance
				position = ((Vector2(x, y) + Vector2.ONE * 0.5) / Vector2(image.get_size()) - Vector2.ONE * 0.5) * _field.settings.area_size
	return position


func _save_density(state: Image, name: String) -> void:
	var image := Image.create(state.get_width(), state.get_height(), false, Image.FORMAT_RGB8)
	for y in range(state.get_height()):
		for x in range(state.get_width()):
			var d := state.get_pixel(x, y).r
			image.set_pixel(x, y, Color(d * 0.65, d * 0.9, d))
	image.save_png(_output + name + ".png")


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
