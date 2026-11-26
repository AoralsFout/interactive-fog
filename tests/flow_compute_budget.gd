extends SceneTree
## Per-step GPU timestamps around the same render-thread submission used by FogField.
## Keep readout and deferred results outside the production simulation.
const STEP := 1.0 / 30.0
const WARMUP := 15
const SAMPLES := 90
var _last_gpu_frame := -1
var _samples := {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var demo := load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(demo)
	demo.set_process(false)
	demo.get_node("Player").set_physics_process(false)
	(demo.get_node("WorldEnvironment") as WorldEnvironment).environment.volumetric_fog_enabled = false
	var field := demo.get_node("FogField") as InteractiveFogField
	field.simulation_enabled = false
	await process_frame
	await RenderingServer.frame_post_draw
	field.set_process(false)
	for mode: String in ["flow", "part", "four_bursts"]:
		field.reset_simulation()
		for i in range(WARMUP + SAMPLES):
			var point := Vector3(sin(i * 0.09) * 3.5, 0.0, cos(i * 0.11) * 2.0)
			if mode == "part":
				field.part(point, point + Vector3(0.3, 0.0, 0.15))
			elif mode == "four_bursts" and i % 21 == 0:
				for x in [-7.0, 7.0]:
					for z in [-5.0, 5.0]:
						field.burst(Vector3(x, 0.0, z), 3.0)
			field.disturb(point, 1.4, Vector2(0.1, -0.03))
			RenderingServer.call_on_render_thread(_begin.bind(mode if i >= WARMUP else "warmup"))
			field._advance_simulation(STEP)
			RenderingServer.call_on_render_thread(_end)
			await process_frame
			await RenderingServer.frame_post_draw
	for i in range(12):
		RenderingServer.call_on_render_thread(_collect)
		await process_frame
		await RenderingServer.frame_post_draw
	var valid := true
	var report := {}
	for mode: String in ["flow", "part", "four_bursts"]:
		var values: Array = _samples.get(mode, [])
		values.sort()
		if values.size() != SAMPLES:
			valid = false
		if not values.is_empty():
			report[mode] = {"samples": values.size(), "median_ms": values[values.size()/2],
				"p95_ms": values[int(values.size()*0.95)]}
	print("COMPUTE_BUDGET ", JSON.stringify(report))
	demo.queue_free()
	await process_frame
	quit(0 if valid else 1)


func _begin(mode: String) -> void:
	_collect()
	RenderingServer.get_rendering_device().capture_timestamp("fog_begin/" + mode)


func _end() -> void:
	RenderingServer.get_rendering_device().capture_timestamp("fog_end")


func _collect() -> void:
	var rd := RenderingServer.get_rendering_device()
	var frame := rd.get_captured_timestamps_frame()
	if frame == _last_gpu_frame:
		return
	_last_gpu_frame = frame
	var start := -1
	var mode := ""
	for i in range(rd.get_captured_timestamps_count()):
		var label := rd.get_captured_timestamp_name(i)
		if label.begins_with("fog_begin/"):
			mode = label.trim_prefix("fog_begin/")
			start = rd.get_captured_timestamp_gpu_time(i)
		elif label == "fog_end" and start >= 0:
			var elapsed := rd.get_captured_timestamp_gpu_time(i) - start
			if elapsed > 0 and mode != "warmup":
				# RenderingServerDefault converts GPU nanoseconds to milliseconds.
				_record.call_deferred(mode, elapsed / 1_000_000.0)
			start = -1


func _record(mode: String, elapsed_ms: float) -> void:
	if not _samples.has(mode):
		_samples[mode] = []
	_samples[mode].append(elapsed_ms)
