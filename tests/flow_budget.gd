extends SceneTree
## 1080p 离屏、无垂直同步限制的整帧预算探测；包含默认灯光、HUD 与持续拖动。
## 可传 -- --flow-only 关闭体积雾，以区分流体与体积渲染开销。

const OUTPUT := "res://artifacts/flow-transport/"
var _demo: Node3D
var _viewport: SubViewport


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1920, 1080)
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	_demo = load("res://demo/main.tscn").instantiate() as Node3D
	_viewport.add_child(_demo)
	_demo.set_process(false)
	_demo.get_node("Player").set_physics_process(false)
	var field := _demo.get_node("FogField") as InteractiveFogField
	var brush := _demo.get_node("MouseBrush") as Node3D
	var interactor := brush.get_node("FogInteractor") as FogInteractor3D
	interactor.enabled = true
	var flow_only := "--flow-only" in OS.get_cmdline_user_args()
	var close := "--close" in OS.get_cmdline_user_args()
	var expansion := "--burst" in OS.get_cmdline_user_args()
	var next_wave := 0.25
	if close:
		var rig := _demo.get_node("CameraRig") as FogDemoOrbitCamera
		rig.distance = 15.0
		rig.pitch_degrees = 28.0
		rig.target_offset = Vector3(-0.8, 0.2, 0.0)
	(_demo.get_node("WorldEnvironment") as WorldEnvironment).environment.volumetric_fog_enabled = not flow_only
	RenderingServer.viewport_set_measure_render_time(_viewport.get_viewport_rid(), true)
	var timings: Array[float] = []
	var gpu: Array[float] = []
	var last := Time.get_ticks_usec()
	var sample_start := 0
	var index := 0
	while sample_start == 0 or Time.get_ticks_usec() - sample_start < 5000000:
		var t := field.get_simulation_time()
		if expansion and t >= next_wave:
			field.burst(Vector3(0.0, 0.0, 1.0), 3.0)
			next_wave += 1.5
		brush.position = Vector3(sin(t * 0.9) * 3.5, 0.05, 1.0 + cos(t * 1.1) * 2.0)
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		if field.get_simulation_time() >= 2.0:
			if sample_start == 0:
				sample_start = now
			timings.append(float(now - last) * 0.001)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_viewport.get_viewport_rid()))
		last = now
		index += 1
	timings.sort()
	gpu.sort()
	var report := {
		"resolution": [1920, 1080], "flow_only": flow_only,
		"camera": "close" if close else "wide",
		"expansion": expansion,
		"godot": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(),
		"volume_size": ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_size"),
		"volume_depth": ProjectSettings.get_setting("rendering/environment/volumetric_fog/volume_depth"),
		"samples": timings.size(), "velocity_resolution": field.settings.resolution,
		"density_resolution": field.settings.get_density_resolution(),
		"median_frame_ms": timings[timings.size() / 2],
		"p95_frame_ms": timings[int(timings.size() * 0.95)],
		"p99_frame_ms": timings[int(timings.size() * 0.99)],
		"max_frame_ms": timings.back(),
		"median_viewport_gpu_ms": gpu[gpu.size() / 2],
		"simulation_time": field.get_simulation_time(),
		"elapsed_process_frames": index,
		"sample_elapsed_seconds": float(Time.get_ticks_usec() - sample_start) * 0.000001,
	}
	var label := "flow-only" if flow_only else "full"
	if close:
		label += "-close"
	if expansion:
		label += "-burst"
	var file := FileAccess.open(OUTPUT + "budget-" + label + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	_viewport.get_texture().get_image().save_png(OUTPUT + "budget-" + label + ".png")
	print("FLOW_BUDGET ", JSON.stringify(report))
	_demo.queue_free()
	await process_frame
	_viewport.queue_free()
	await process_frame
	quit()
