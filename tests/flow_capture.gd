extends SceneTree
## 固定时间步记录真实三维拖雾；同目录 PNG 可用 ffmpeg 编成动态预览。

const OUTPUT := "res://artifacts/flow-transport/frames/"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
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
	rig.distance = 12.0
	rig.pitch_degrees = 42.0
	rig.target_offset = Vector3(0.0, 0.2, 1.5)
	var brush := demo.get_node("MouseBrush") as Node3D
	var interactor := brush.get_node("FogInteractor") as FogInteractor3D
	interactor.enabled = false
	for index in range(24):
		await process_frame
		await RenderingServer.frame_post_draw
	# 之后由此脚本独占固定步；暂停节点的自动 _process 会清掉交互器的上一位置。
	field.set_process(false)
	for index in range(210):
		var t := float(index) / 30.0
		# 中间 3 秒沿弧线拖动，后 3 秒松手，观察同一尾流的演化。
		interactor.enabled = index >= 30 and index < 120
		var angle := clampf((t - 1.0) * 1.15, 0.0, 3.45)
		brush.position = Vector3(-2.8 + angle * 1.5, 0.05, 1.5 + sin(angle) * 1.3)
		field._advance_simulation(1.0 / 30.0)
		await process_frame
		await RenderingServer.frame_post_draw
		if index % 2 == 0:
			viewport.get_texture().get_image().save_png(OUTPUT + "%03d.png" % (index / 2))
		if index == 119:
			viewport.get_texture().get_image().save_png("res://artifacts/flow-transport/interaction-close.png")
	print("FLOW_CAPTURE_RESULT frames=105 fps=15 duration=7")
	demo.queue_free()
	await process_frame
	viewport.queue_free()
	await process_frame
	quit()
