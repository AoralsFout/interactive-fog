extends SceneTree
## 1080p 离屏、无垂直同步限制的整帧预算探测；包含默认灯光、HUD 与持续拖动。
## 可传 -- --flow-only 关闭体积雾，以区分流体与体积渲染开销。

const OUTPUT := "res://artifacts/flow-transport/"
var _demo: Node3D
var _viewport: SubViewport
var _pre_draw_usec := 0


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
	var parting := "--part" in OS.get_cmdline_user_args()
	var no_obstacles := "--no-obstacles" in OS.get_cmdline_user_args()
	if no_obstacles:
		for obstacle in _demo.get_node("Obstacles").get_children():
			if obstacle is FogObstacle3D:
				obstacle.enabled = false
	if parting:
		_demo.set_brush_mode(1)
		interactor.enabled = true
	var separated := "--four-bursts" in OS.get_cmdline_user_args()
	var trace := "--trace" in OS.get_cmdline_user_args()
	var performance_grid := "--performance" in OS.get_cmdline_user_args()
	var hud := _demo.get_node("HUD") as FogDemoHUD
	if performance_grid:
		hud.set_fog_quality(1)
	var rows: Array[Array] = []
	if trace:
		RenderingServer.frame_pre_draw.connect(func(): _pre_draw_usec = Time.get_ticks_usec())
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
	var sample_sim_start := 0.0
	var index := 0
	var max_cut_segments := 0
	while sample_start == 0 or Time.get_ticks_usec() - sample_start < 5000000:
		var t := field.get_simulation_time()
		if (expansion or separated) and t >= next_wave:
			if separated:
				for x in [-7.0, 7.0]:
					for z in [-5.0, 5.0]:
						field.burst(Vector3(x, 0.0, z), 3.0)
			else:
				field.burst(Vector3(0.0, 0.0, 1.0), 3.0)
			next_wave += 1.5
		brush.position = Vector3(sin(t * 0.9) * 3.5, 0.05, 1.0 + cos(t * 1.1) * 2.0)
		await process_frame
		var process_start := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		max_cut_segments = maxi(max_cut_segments, field.get("_active_cuts").size())
		if field.get_simulation_time() >= 2.0:
			if sample_start == 0:
				sample_start = now
				sample_sim_start = field.get_simulation_time()
			timings.append(float(now - last) * 0.001)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_viewport.get_viewport_rid()))
			if trace:
				rows.append([Engine.get_process_frames(), now, timings.back(),
					(process_start - last) * 0.001, (now - process_start) * 0.001,
					(_pre_draw_usec - process_start) * 0.001, (now - _pre_draw_usec) * 0.001,
					field.get_simulation_time() > t, RenderingServer.get_frame_setup_time_cpu(),
					RenderingServer.viewport_get_measured_render_time_cpu(_viewport.get_viewport_rid()), gpu.back()])
		last = now
		index += 1
	timings.sort()
	gpu.sort()
	var report := {
		"resolution": [1920, 1080], "flow_only": flow_only,
		"camera": "close" if close else "wide",
		"expansion": expansion or separated, "four_bursts": separated,
		"parting": parting,
		"obstacles_disabled": no_obstacles,
		"max_cut_segments": max_cut_segments,
		"godot": Engine.get_version_info().string,
		"adapter": RenderingServer.get_video_adapter_name(),
		"volume_size": hud.fog_grid.x,
		"volume_depth": hud.fog_grid.y,
		"samples": timings.size(), "velocity_resolution": field.settings.resolution,
		"density_resolution": field.settings.get_density_resolution(),
		"median_frame_ms": timings[timings.size() / 2],
		"p95_frame_ms": timings[int(timings.size() * 0.95)],
		"p99_frame_ms": timings[int(timings.size() * 0.99)],
		"max_frame_ms": timings.back(),
		"p95_viewport_gpu_ms": gpu[int(gpu.size() * 0.95)],
		"median_viewport_gpu_ms": gpu[gpu.size() / 2],
		"simulation_time": field.get_simulation_time(),
		"elapsed_process_frames": index,
		"sample_elapsed_seconds": float(last - sample_start) * 0.000001,
		"sample_sim_seconds": field.get_simulation_time() - sample_sim_start,
	}
	var label := "flow-only" if flow_only else "full"
	if close:
		label += "-close"
	if expansion:
		label += "-burst"
	if parting:
		label += "-part"
	if no_obstacles:
		label += "-no-obstacles"
	if separated:
		label += "-four-bursts"
	if performance_grid:
		label += "-performance"
	if trace:
		var trace_file := FileAccess.open(OUTPUT + "frames-" + label + ".csv", FileAccess.WRITE)
		trace_file.store_csv_line(["process_frame","wall_end_us","wall_ms","post_draw_to_process_ms",
			"process_to_post_draw_ms","process_to_pre_draw_ms","pre_to_post_draw_ms","simulation_step","render_setup_cpu_ms","viewport_cpu_ms","viewport_gpu_ms"])
		for row in rows:
			trace_file.store_csv_line(PackedStringArray(row.map(func(value): return str(value))))
	var file := FileAccess.open(OUTPUT + "budget-" + label + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	_viewport.get_texture().get_image().save_png(OUTPUT + "budget-" + label + ".png")
	print("FLOW_BUDGET ", JSON.stringify(report))
	if parting and max_cut_segments == 0:
		push_error("Parting benchmark did not submit any cut segments.")
		quit(1)
		return
	_demo.queue_free()
	await process_frame
	_viewport.queue_free()
	await process_frame
	quit()
