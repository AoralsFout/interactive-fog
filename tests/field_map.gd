extends SceneTree
## 用固定的密度/速度纹理验证真正绘制出的箭头，而不是只检查 Shader 参数。
## 图片回读只用于测试；HUD 绘图本身不回读模拟纹理、不创建逐箭头节点。

var _failures := 0
var _fixture: Node
var _viewport: SubViewport
var _map: TextureRect
var _material: ShaderMaterial


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Field map rendering test needs a real GPU; omit --headless.")
		quit(1)
		return
	_fixture = load("res://tests/fixtures/field_map.tscn").instantiate()
	root.add_child(_fixture)
	_viewport = _fixture.get_node("Viewport") as SubViewport
	_map = _fixture.get_node("Viewport/Map") as TextureRect
	_material = _map.material as ShaderMaterial
	_set_field(0.2, Vector2.RIGHT)
	_set_obstacle(10.0)
	await _frames(3)
	var right := _image()
	_check(_head_bias(right, 0) > 0, "+X velocity points right")
	_set_field(0.2, Vector2.LEFT)
	await _frames(2)
	_check(_head_bias(_image(), 0) < 0, "-X velocity points left")
	_set_field(0.2, Vector2.DOWN)
	await _frames(2)
	_check(_head_bias(_image(), 1) > 0, "+Z velocity points down on map")
	_set_field(0.2, Vector2.UP)
	await _frames(2)
	_check(_head_bias(_image(), 1) < 0, "-Z velocity points up on map")
	_set_field(0.2, Vector2.RIGHT * 0.5)
	await _frames(2)
	var slow_length := _ink_bounds(_image()).size.x
	_set_field(0.2, Vector2.RIGHT * 1.5)
	await _frames(2)
	var fast_length := _ink_bounds(_image()).size.x
	_check(fast_length > slow_length + 6, "arrow length shows velocity magnitude: %d -> %d px" % [slow_length, fast_length])
	_set_field(0.2, Vector2.ZERO)
	await _frames(2)
	_check(_ink_count(_image()) == 0, "zero velocity has no direction arrow")
	_set_field(0.2, Vector2.RIGHT)
	_set_obstacle(-1.0)
	await _frames(2)
	_check(_ink_count(_image()) == 0, "solid obstacle cells hide arrows")
	_set_obstacle(10.0)
	_set_field(0.2, Vector2.RIGHT)
	await _frames(2)
	var low_density := _image().get_pixel(1, 1)
	_set_field(1.0, Vector2.RIGHT)
	await _frames(2)
	var high_density := _image().get_pixel(1, 1)
	_check(high_density.g > low_density.g + 0.2, "background color still represents density")
	_material.set_shader_parameter("mode", 0)
	await _frames(2)
	_check(_image().get_pixel(1, 1).is_equal_approx(high_density), "combined map preserves density-only background")
	_fixture.queue_free()
	await _frames(3)

	# 再走真实 HUD 的绑定、长宽比、下拉菜单和 Inspector setter 路径。
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	demo.get_node("MouseBrush").hide()
	var field := demo.get_node("FogField") as InteractiveFogField
	field.settings = FogSettings.new()
	await _frames(8)
	var hud := demo.get_node("HUD") as FogDemoHUD
	var selector := hud.get_node("%DebugMode") as OptionButton
	var debug_map := hud.get_node("%DebugMap") as TextureRect
	var material := debug_map.material as ShaderMaterial
	(hud.get_node("%DebugButton") as Button).button_pressed = true
	await _frames(3)
	_check(selector.get_item_id(selector.selected) == 3, "field view opens with density and arrows")
	_check(is_equal_approx(material.get_shader_parameter("mode"), 3), "default selector binds combined shader mode")
	_check(is_equal_approx(debug_map.size.x / debug_map.size.y, 1.2), "map keeps world area aspect ratio")
	hud.arrow_spacing = 32.0
	hud.arrow_reference_speed = 1.5
	await _frames(2)
	_check(is_equal_approx(material.get_shader_parameter("arrow_spacing"), 32.0), "Inspector-style spacing change reaches shader")
	_check((hud.get_node("%ArrowLegend") as Label).text.contains("1.5 m/s"), "legend tracks reference speed")
	selector.select(1)
	selector.item_selected.emit(1)
	_check(material.get_shader_parameter("mode") == 0, "density-only mode still uses original mode id")
	_check(not (hud.get_node("%ArrowLegend") as Label).visible, "arrow legend hides in density-only mode")
	selector.select(0)
	selector.item_selected.emit(0)
	field.settings = FogSettings.new()
	field.settings.area_size = Vector2(30.0, 15.0)
	await _frames(6)
	_check(is_equal_approx(debug_map.size.x / debug_map.size.y, 2.0), "replacement settings resize map without distortion")
	_check(material.get_shader_parameter("field_texture") == field.get_state_texture(), "field texture rebinds after resource replacement")
	field.settings.area_size = Vector2(24.0, 20.0)
	hud.arrow_spacing = 26.0
	hud.arrow_reference_speed = 2.0
	field.reset_simulation()
	await _frames(4)
	field.burst(Vector3(0, 0, 1), 3.0)
	await _frames(18)
	field.simulation_enabled = false
	await _frames(2)
	root.get_texture().get_image().save_png("res://artifacts/field_map.png")
	demo.queue_free()
	await _frames(4)
	print("FIELD_MAP_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _frames(count: int) -> void:
	for index in range(count):
		await process_frame
		await RenderingServer.frame_post_draw


func _set_field(density: float, velocity: Vector2) -> void:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	image.fill(Color(density, velocity.x, velocity.y, 0.0))
	var texture := ImageTexture.create_from_image(image)
	_map.texture = texture
	_material.set_shader_parameter("field_texture", texture)


func _set_obstacle(distance: float) -> void:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	image.fill(Color(distance, 0, 0, 0))
	_material.set_shader_parameter("obstacle_texture", ImageTexture.create_from_image(image))


func _image() -> Image:
	return _viewport.get_texture().get_image()


func _is_arrow(color: Color) -> bool:
	return color.r > 0.82 and color.g > 0.82 and color.b > 0.82


func _head_bias(image: Image, axis: int) -> int:
	var bias := 0
	# 第一格是 30×30 像素；头部有两个斜翼，其所在半格比尾部有更多浅色像素。
	for y in range(30):
		for x in range(30):
			if not _is_arrow(image.get_pixel(x, y)):
				continue
			var coordinate := x if axis == 0 else y
			bias += 1 if coordinate >= 15 else -1
	return bias


func _ink_count(image: Image) -> int:
	var count := 0
	for y in range(30):
		for x in range(30):
			if _is_arrow(image.get_pixel(x, y)):
				count += 1
	return count


func _ink_bounds(image: Image) -> Rect2i:
	var minimum := Vector2i(30, 30)
	var maximum := Vector2i(-1, -1)
	for y in range(30):
		for x in range(30):
			if _is_arrow(image.get_pixel(x, y)):
				minimum = minimum.min(Vector2i(x, y))
				maximum = maximum.max(Vector2i(x, y))
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
