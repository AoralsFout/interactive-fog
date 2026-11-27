extends SceneTree
## 记录爆开工具的左键径向扩散和随后数秒的细雾流动。

const OUTPUT := "res://artifacts/expansion/"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT + "frames/"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(960, 600)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	viewport.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	demo.get_node("HUD").hide()
	var field := demo.get_node("FogField") as InteractiveFogField
	field.simulation_enabled = false
	var rig := demo.get_node("CameraRig") as FogDemoOrbitCamera
	rig.distance = 14.0
	rig.pitch_degrees = 55.0
	rig.target_offset = Vector3(0.0, 0.2, 1.0)
	demo.set_brush_mode(2)
	var camera := demo.get_node("CameraRig/Camera3D") as Camera3D
	for index in range(24):
		await process_frame
		await RenderingServer.frame_post_draw
	field.set_process(false)
	for index in range(240):
		if index == 30:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.position = camera.unproject_position(Vector3(0.0, 0.0, 1.0))
			click.pressed = true
			demo._unhandled_input(click)
		field._advance_simulation(1.0 / 30.0)
		await process_frame
		await RenderingServer.frame_post_draw
		if index % 2 == 0:
			viewport.get_texture().get_image().save_png(OUTPUT + "frames/%03d.png" % (index / 2))
		if index == 48:
			viewport.get_texture().get_image().save_png(OUTPUT + "wave.png")
		if index == 150:
			viewport.get_texture().get_image().save_png(OUTPUT + "wake.png")
	print("EXPANSION_CAPTURE_RESULT frames=120 fps=15 duration=8")
	demo.queue_free()
	await process_frame
	viewport.queue_free()
	await process_frame
	quit()
