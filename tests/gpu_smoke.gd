extends SceneTree
## 真正的渲染设备集成检查（不能以 --headless 运行）。
## 回读只出现在此验证脚本，运行时雾场不会回读 GPU。
## 验证清除/恢复、障碍变化、热调参、分辨率重建、场景销毁，并保存实际视口截图。

var _failures := 0
var _demo: Node3D
var _field: InteractiveFogField


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("gpu_smoke 需要图形设备；请不要传 --headless。")
		quit(1)
		return
	_demo = load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(_demo)
	_field = _demo.get_node("FogField") as InteractiveFogField
	_demo.set_process(false)
	_demo.get_node("Player").set_physics_process(false)
	_demo.get_node("MouseBrush").hide()
	await _frames(12)
	# 真实键盘事件使用 device=0，InputMap 中的 -1 表示任意设备。
	# 同时验证物理键码，防止项目配置能加载但按键无法匹配。
	var keys := {
		"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"sprint": KEY_SHIFT, "fog_burst": KEY_SPACE, "fog_reset": KEY_R,
		"fog_pause": KEY_P, "fog_debug": KEY_TAB,
	}
	for action in keys:
		var event := InputEventKey.new()
		event.device = 0
		event.physical_keycode = keys[action]
		event.pressed = true
		_check(InputMap.event_is_action(event, action), "physical keyboard action: " + action)
	_check(_field.get_state_texture() != null, "GPU texture initialized")
	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.turbulence_strength = 0.0
	_field.settings.density_variation = 0.0
	_field.settings.recovery_half_life = 0.6
	_field.reset_simulation()
	await _simulated(0.15)
	var baseline := _density_at(Vector2.ZERO)
	_check(baseline > 0.98, "undisturbed density is full: %.3f" % baseline)
	_field.disturb(Vector3.ZERO, 1.8, Vector2.ZERO, 4.0, 0.0, 0.0)
	await _simulated(0.10)
	var cleared := _density_at(Vector2.ZERO)
	_check(cleared < 0.25, "burst clears persistent density: %.3f" % cleared)
	await _simulated(1.2)
	var recovered := _density_at(Vector2.ZERO)
	_check(recovered > 0.7 and recovered > cleared + 0.4, "density recovers: %.3f" % recovered)

	var wall := _demo.get_node("Obstacles/WallWest") as FogObstacle3D
	var old_position := wall.position
	wall.position = Vector3.ZERO
	await _simulated(0.12)
	_check(_obstacle_distance_at(Vector2.ZERO) < 0.0, "moved wall updates obstacle map")
	_check(_density_at(Vector2.ZERO) < 0.01, "solid interior has no fog")
	# 法线方向的速度必须被边界导流削弱，而远处的背景风仍保留。
	wall.rotation = Vector3.ZERO
	wall.box_size = Vector2(0.65, 4.0)
	_field.settings.wind_velocity = Vector2(2.0, 0.0)
	_field.reset_simulation()
	await _simulated(0.15)
	var near_velocity := _sample(_field.get_state_texture(), Vector2(-0.55, 0.0)).g
	var far_velocity := _sample(_field.get_state_texture(), Vector2(-2.0, 0.0)).g
	_check(near_velocity < 0.6 and far_velocity > 1.5, "obstacle guides wind: near %.3f, far %.3f" % [near_velocity, far_velocity])
	# 即使暂停流动，编辑几何仍刷新遮罩；测试编辑器常用的静态调参路径。
	_field.simulation_enabled = false
	wall.position = old_position
	wall.rotation.y = deg_to_rad(-18.0)
	wall.box_size = Vector2(4.2, 0.65)
	await _frames(5)
	_check(_obstacle_distance_at(Vector2.ZERO) > 0.0, "paused field refreshes moved obstacles")
	_field.settings.thickness = 1.8
	await _frames(3)
	var expected_height := 1.8 * (1.0 + _field.settings.compression_height_boost)
	_check(is_equal_approx((_field.get_node("FogVolume") as FogVolume).size.y, expected_height), "height updates existing scene node and reserves compressed rim space")
	_field.settings.resolution = 64
	await _frames(6)
	_check(_field.get_state_texture().get_width() == 64, "live resolution rebuild")
	_field.settings = FogSettings.new()
	await _frames(6)
	var hud := _demo.get_node("HUD") as FogDemoHUD
	_field.settings.density = 1.45
	await _frames(2)
	_check(is_equal_approx((hud.get_node("%DensitySlider") as HSlider).value, 1.45), "HUD follows replacement settings resource")
	(hud.get_node("%DensitySlider") as HSlider).value = 1.2
	_check(is_equal_approx(_field.settings.density, 1.2), "live slider writes settings")

	# 对同一静态场景做开关雾对比，确认状态纹理最终影响了实际画面。
	hud.hide()
	_field.settings = FogSettings.new()
	_field.simulation_enabled = true
	_field.reset_simulation()
	await _simulated(0.3)
	_field.simulation_enabled = false
	await _frames(4)
	var fog_on := root.get_texture().get_image()
	_field.settings.density = 0.0
	await _frames(4)
	var density_zero := root.get_texture().get_image()
	_check(_image_difference(fog_on, density_zero) > 0.002, "live density parameter changes rendered image")
	_field.settings.density = FogSettings.new().density
	await _frames(4)
	var environment := (_demo.get_node("WorldEnvironment") as WorldEnvironment).environment
	environment.volumetric_fog_enabled = false
	await _frames(4)
	var fog_off := root.get_texture().get_image()
	var difference := _image_difference(fog_on, fog_off)
	_check(difference > 0.002, "volumetric fog affects rendered image: %.5f" % difference)
	environment.volumetric_fog_enabled = true
	hud.show()
	await _frames(5)
	root.get_texture().get_image().save_png("res://artifacts/preview.png")
	(hud.get_node("%DebugButton") as Button).button_pressed = true
	_field.disturb(Vector3(0, 0, 1), 2.6, Vector2(1.0, 0.0), 4.0, 4.0, 1.5)
	_field.simulation_enabled = true
	await _simulated(0.25)
	_field.simulation_enabled = false
	await _frames(3)
	root.get_texture().get_image().save_png("res://artifacts/interaction.png")
	_demo.queue_free()
	await _frames(5)
	print("GPU_SMOKE_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _frames(count: int) -> void:
	for index in range(count):
		await process_frame
		await RenderingServer.frame_post_draw


func _simulated(seconds: float) -> void:
	var start := _field.get_simulation_time()
	var deadline := Time.get_ticks_msec() + 10000
	while _field.get_simulation_time() - start < seconds:
		await _frames(1)
		if Time.get_ticks_msec() > deadline:
			_check(false, "simulation step timed out")
			break
	await _frames(2)


func _density_at(world_xz: Vector2) -> float:
	return _sample(_field.get_state_texture(), world_xz).r


func _obstacle_distance_at(world_xz: Vector2) -> float:
	return _sample(_field.get_obstacle_texture(), world_xz).r


func _sample(texture: Texture2D, world_xz: Vector2) -> Color:
	var image := texture.get_image()
	if image == null or image.is_empty():
		_check(false, "GPU image readback")
		return Color(0, 0, 0, 0)
	var uv := (world_xz - Vector2(_field.global_position.x, _field.global_position.z)) / _field.settings.area_size + Vector2.ONE * 0.5
	var pixel := Vector2i(uv * Vector2(image.get_size())).clamp(Vector2i.ZERO, image.get_size() - Vector2i.ONE)
	return image.get_pixelv(pixel)


func _image_difference(a: Image, b: Image) -> float:
	var total := 0.0
	var samples := 0
	for y in range(0, a.get_height(), 8):
		for x in range(0, a.get_width(), 8):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			samples += 1
	return total / samples


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
