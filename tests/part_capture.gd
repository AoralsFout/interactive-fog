extends SceneTree
## 记录面板/M 切换后的真实划开交互；显示缺口与松手后的流动。

const OUTPUT := "res://artifacts/part/"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT + "frames/"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	viewport.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	# PNG 写盘影响墙钟帧率；固定步录制不显示该读数，性能由预算脚本独立测量。
	demo.get_node("HUD").get_node("%StatusLabel").visible = false
	var field := demo.get_node("FogField") as InteractiveFogField
	field.simulation_enabled = false
	var rig := demo.get_node("CameraRig") as FogDemoOrbitCamera
	rig.distance = 15.0
	rig.pitch_degrees = 55.0
	rig.target_offset = Vector3(-0.5, 0.2, 1.0)
	var brush := demo.get_node("MouseBrush") as Node3D
	var interactor := brush.get_node("FogInteractor") as FogInteractor3D
	interactor.enabled = false
	for index in range(24):
		await process_frame
		await RenderingServer.frame_post_draw
	field.set_process(false)
	for index in range(240):
		if index == 20:
			var key := InputEventAction.new()
			key.action = &"fog_tool_toggle"
			key.pressed = true
			demo._unhandled_input(key)
		var t := clampf(float(index - 30) / 90.0, 0.0, 1.0)
		brush.position = Vector3(-2.5 + t * 5.0, 0.05, 1.0 + sin(t * PI))
		if index == 30:
			demo.set("_valid_brush", true)
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			demo._unhandled_input(click)
		interactor.enabled = index >= 30 and index < 120
		field._advance_simulation(1.0 / 30.0)
		await process_frame
		await RenderingServer.frame_post_draw
		if index % 2 == 0:
			viewport.get_texture().get_image().save_png(OUTPUT + "frames/%03d.png" % (index / 2))
		if index == 95:
			viewport.get_texture().get_image().save_png(OUTPUT + "ui.png")
		if index == 129:
			viewport.get_texture().get_image().save_png(OUTPUT + "opening.png")
	print("PART_CAPTURE_RESULT frames=120 fps=15 duration=8")
	demo.queue_free()
	await process_frame
	viewport.queue_free()
	await process_frame
	quit()
