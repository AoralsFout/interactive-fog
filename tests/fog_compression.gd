extends SceneTree
## 实际 GPU 回归：验证中心清空、外围密度超过基准、近似雾量转移、空区不凭空冒雾，
## 以及鼠标/空格的真实输入处理路径。用固定模拟步隔离运行帧率对断言的影响。

const STEP := 1.0 / 30.0
const CENTER := Vector3(0.0, 0.0, 1.0)
var _failures := 0
var _demo: Node3D
var _field: InteractiveFogField


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Fog compression test needs a real GPU; omit --headless.")
		quit(1)
		return
	_demo = load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(_demo)
	_demo.set_process(false)
	_demo.get_node("Player").set_physics_process(false)
	_demo.get_node("MouseBrush").hide()
	_demo.get_node("HUD").hide()
	_field = _demo.get_node("FogField") as InteractiveFogField
	_field.settings = FogSettings.new()
	_field.settings.resolution = 256
	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.turbulence_strength = 0.0
	_field.settings.density_variation = 0.0
	_field.settings.recovery_half_life = 20.0
	_field.simulation_enabled = false
	await _frames(8)
	await _reset()
	var before := _image()
	_field.disturb(CENTER, 1.6, Vector2.ZERO, 4.0, 0.0, 0.0, 1.0, 0.35)
	await _steps(1)
	var after := _image()
	var ring := _peak(after, 1.1, 2.1)
	_check(_density(after, CENTER) < 0.08, "impulse empties center")
	_check(ring.density > 1.6, "displaced fog piles above baseline: %.3f" % ring.density)
	var balance := _mass_balance(before, after)
	_check(balance < 0.15, "gain=1 approximately redistributes removed fog: relative error %.3f" % balance)
	await _steps(60)
	var relaxed := _peak(_image(), 1.1, 2.1)
	_check(relaxed.density < ring.density - 0.3, "compressed rim releases its extra density")
	_check(_density(_image(), CENTER) < 0.15, "center recovery remains independent of rim release")

	await _reset()
	_field.disturb(CENTER, 5.0, Vector2.ZERO, 100.0, 0.0, 0.0, 0.0)
	await _steps(1)
	_field.disturb(CENTER, 1.6, Vector2.ZERO, 4.0, 0.0, 0.0, 2.0, 0.35)
	await _steps(1)
	_check(_peak(_image(), 1.1, 2.1).density < 0.03, "empty source does not create a fake dense rim")
	_field.settings.max_density = 1.5
	await _reset()
	_field.disturb(CENTER, 1.6, Vector2.ZERO, 8.0, 0.0, 0.0, 3.0, 0.15)
	await _steps(1)
	_check(_maximum(_image()) <= 1.501, "compression respects editor density cap")
	_field.settings.max_density = 8.0

	# 持续笔刷沿用实际 FogInteractor 收集路径，保证按住左键时也能持续堆积。
	await _reset()
	var brush := _demo.get_node("MouseBrush") as Node3D
	brush.global_position = CENTER
	var interactor := brush.get_node("FogInteractor") as FogInteractor3D
	interactor.enabled = true
	interactor.radius = 1.4
	interactor.compression_gain = 1.5
	interactor.compression_width = 0.35
	await _steps(10)
	_check(_density(_image(), CENTER) < 0.12, "held brush clears center")
	_check(_peak(_image(), 1.0, 2.4).density > 1.3, "held brush pushes fog into a dense boundary")
	interactor.enabled = false

	# 直接调用场景的输入处理，避免只测公开 API 而漏掉鼠标/空格接线错误。
	await _reset()
	_demo.set("_valid_brush", true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	_demo._unhandled_input(click)
	await _steps(1)
	_check(_density(_image(), CENTER) < 0.12, "left click immediately pushes center fog out")
	_check(_peak(_image(), 1.0, 2.0).density > 1.6, "left click creates a high density rim")

	await _reset()
	var space := InputEventAction.new()
	space.action = &"fog_burst"
	space.pressed = true
	_demo._unhandled_input(space)
	await _steps(4)
	var early := _peak(_image(), 0.6, 3.6)
	await _steps(8)
	var late := _peak(_image(), 0.6, 3.8)
	_check(late.radius > early.radius + 0.4, "space shock front expands: %.2f -> %.2f m" % [early.radius, late.radius])
	_check(late.density > 1.5, "expanding shock front stays compressed: %.3f" % late.density)
	_check(_density(_image(), CENTER) < 0.08, "space shock leaves a hollow center")
	# 保留一张使用默认外观的实际渲染图，便于检查浓雾环不是只存在于数据视图。
	_field.settings.density = 2.6
	_field.settings.thickness = 1.5
	var rig := _demo.get_node("CameraRig") as FogDemoOrbitCamera
	rig.distance = 19.0
	rig.pitch_degrees = 65.0
	rig.target_offset = Vector3(0.0, 0.2, 1.0)
	await _frames(8)
	root.get_texture().get_image().save_png("res://artifacts/burst.png")
	_demo.queue_free()
	await _frames(4)
	print("FOG_COMPRESSION_RESULT failures=%d" % _failures)
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


func _image() -> Image:
	return _field.get_state_texture().get_image()


func _density(image: Image, position: Vector3) -> float:
	var uv := Vector2(position.x, position.z) / _field.settings.area_size + Vector2.ONE * 0.5
	var pixel := Vector2i(uv * Vector2(image.get_size())).clamp(Vector2i.ZERO, image.get_size() - Vector2i.ONE)
	return image.get_pixelv(pixel).r


func _peak(image: Image, minimum: float, maximum: float) -> Dictionary:
	var best := {"radius": 0.0, "density": 0.0}
	for index in range(33):
		var radius := lerpf(minimum, maximum, float(index) / 32.0)
		var total := 0.0
		for angle_index in range(16):
			var angle := angle_index * TAU / 16.0
			total += _density(image, CENTER + Vector3(cos(angle), 0.0, sin(angle)) * radius)
		var average := total / 16.0
		if average > best.density:
			best = {"radius": radius, "density": average}
	return best


func _mass_balance(before: Image, after: Image) -> float:
	var removed := 0.0
	var added := 0.0
	for y in range(before.get_height()):
		for x in range(before.get_width()):
			var difference := after.get_pixel(x, y).r - before.get_pixel(x, y).r
			removed += maxf(-difference, 0.0)
			added += maxf(difference, 0.0)
	return absf(removed - added) / maxf(removed, 0.0001)


func _maximum(image: Image) -> float:
	var value := 0.0
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			value = maxf(value, image.get_pixel(x, y).r)
	return value


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
