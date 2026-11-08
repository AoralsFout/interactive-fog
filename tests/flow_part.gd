extends "res://tests/flow_transport.gd"
## 拨开路径、连续缺口、共同搬运、自然回填与两种左键模式接线的真实 GPU 验收。


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	_field = load("res://fog/scenes/fog_field.tscn").instantiate() as InteractiveFogField
	_field.settings = FogSettings.new()
	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.turbulence_strength = 0.0
	_field.settings.density_variation = 0.0
	_field.simulation_enabled = false
	root.add_child(_field)
	await _frames(8)
	_field.set_process(false)
	await _reset()
	var before := _state()
	_field.part(Vector3(-3, 0, 0), Vector3(3, 0, 0))
	await _steps(12)
	var after := _state()
	var gap := 0.0
	for x in [-2.5, -1.25, 0.0, 1.25, 2.5]:
		gap = maxf(gap, _sample(after, Vector2(x, 0.0)).r)
	_check(gap < 0.2, "fast swept segment leaves a continuous opening: maximum center density %.4f" % gap)
	var side := 0.0
	for index in range(31):
		var distance := lerpf(0.3, 0.85, float(index) / 30.0)
		side = maxf(side, maxf(_sample(after, Vector2(0.0, distance)).r, _sample(after, Vector2(0.0, -distance)).r))
	_check(side > 1.4, "displaced fog accumulates beside the opening: %.3f" % side)
	var mass_error := absf(_mass(after) / _mass(before) - 1.0)
	_check(mass_error < 0.0005, "parting redistributes density instead of erasing it: mass error %.6f" % mass_error)
	var marker := _find_material(Vector2(0.0, 0.2))
	_check(marker.y > 0.4 and absf(marker.x) < 0.15, "material detail moves to the same side: %s" % marker)
	_save_density(after, "part-open")
	await _steps(30)
	_check(_sample(_state(), Vector2.ZERO).r < 0.2, "opening retains history after the parting force expires")
	var wall := FogObstacle3D.new()
	wall.sync_prefab_geometry = false
	wall.shape = FogObstacle3D.Shape.BOX
	wall.box_size = Vector2(10.0, 0.2)
	wall.position.z = 0.3
	root.add_child(wall)
	await _reset()
	_field.part(Vector3(-3, 0, 0), Vector3(3, 0, 0))
	await _steps(12)
	_check(absf(_sample(_state(), Vector2(0, 0.55)).r - 1.0) < 0.005, "wall shields fog behind the parting stroke")
	_check(_sample(_state(), Vector2(0, 0.3)).r < 0.001, "parting cannot transport density through solid cells")
	wall.queue_free()
	await _frames(2)
	await _reset()
	_field.part(Vector3(-3, 0, 0), Vector3(3, 0, 0))
	await _steps(12)
	_field.settings.wind_velocity = Vector2(0.0, 0.7)
	_field.settings.wind_response = 8.0
	await _steps(45)
	_check(_sample(_state(), Vector2.ZERO).r > 0.4, "surrounding flow refills the original gap naturally")

	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.wind_response = 0.12
	await _reset()
	var interactor := FogInteractor3D.new()
	interactor.mode = FogInteractor3D.Mode.PART
	interactor.radius = 0.65
	interactor.position = Vector3(-3, 0, 0)
	root.add_child(interactor)
	await _steps(1)
	for index in range(16):
		interactor.position.x += 0.2
		await _steps(1)
	await _steps(12)
	_check(_sample(_state(), Vector2(-1.5, 0.0)).r < 0.3, "moving PART interactor builds a persistent stroke")
	interactor.enabled = false
	interactor.position.x = 5.0
	await _steps(1)
	interactor.enabled = true
	await _steps(1)
	interactor.position.x = 5.2
	await _steps(12)
	_check(_sample(_state(), Vector2(2.5, 0.0)).r > 0.95, "disabled stroke gap is not bridged on re-enable")
	interactor.queue_free()
	await _frames(2)
	await _reset()
	_field.part(Vector3(-2, 0, 0), Vector3(2, 0, 0))
	_field.burst(Vector3.ZERO, 2.5)
	await _steps(25)
	_check(_finite(_state()), "parting and expansion can overlap without invalid density")
	await _reset()
	_field.part(Vector3(-2, 0, 0), Vector3(2, 0, 0))
	await _steps(3)
	var frozen := _state()
	await _frames(12)
	_check(_difference(frozen, _state()) < 0.0001, "paused parting does not advance by wall clock")
	await _reset()
	await _steps(12)
	_check(_difference(before, _state()) < 0.0002, "reset removes pending parting segments")
	_field.queue_free()
	await _frames(4)
	await _ui()
	print("FLOW_PART_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _finite(image: Image) -> bool:
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var d := image.get_pixel(x, y).r
			if not is_finite(d) or d < 0.0 or d > _field.settings.max_compressed_density + 0.01:
				return false
	return true


func _ui() -> void:
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	_field = demo.get_node("FogField") as InteractiveFogField
	_field.settings.wind_velocity = Vector2.ZERO
	_field.settings.turbulence_strength = 0.0
	_field.settings.density_variation = 0.0
	root.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	await _frames(8)
	_field.set_process(false)
	var hud := demo.get_node("HUD") as FogDemoHUD
	_check(demo.get("brush_mode") == 0 and (hud.get_node("%StirButton") as Button).button_pressed, "stirring remains the default left tool")
	(hud.get_node("%PartButton") as Button).pressed.emit()
	_check(demo.get("brush_mode") == 1 and (hud.get_node("%PartButton") as Button).button_pressed, "visible tool button selects parting")
	var keyboard := InputEventKey.new()
	keyboard.physical_keycode = KEY_M
	keyboard.pressed = true
	_check(InputMap.event_is_action(keyboard, "fog_tool_toggle"), "physical M key maps to tool switching")
	var toggle := InputEventAction.new()
	toggle.action = &"fog_tool_toggle"
	toggle.pressed = true
	demo._unhandled_input(toggle)
	_check(demo.get("brush_mode") == 0 and (hud.get_node("%StirButton") as Button).button_pressed, "shortcut and selected button stay synchronized")
	demo.set("_painting", true)
	demo.set_brush_mode(1)
	_check(not demo.get("_painting") and not (demo.get_node("MouseBrush/FogInteractor") as FogInteractor3D).enabled, "switching tools ends the current stroke")
	demo.get_node("MouseBrush").position = Vector3(0, 0.05, 1)
	demo.set("_valid_brush", true)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	demo._unhandled_input(click)
	await _steps(12)
	_check(_sample(_state(), Vector2(0, 1)).r < 0.2, "left press in PART mode reaches the real parting transport")
	demo.queue_free()
	await _frames(4)
