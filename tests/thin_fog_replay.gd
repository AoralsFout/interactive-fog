extends SceneTree
## GPU benchmark and paired captures. Run each mode in a fresh process.
## -- --mode=high|performance|thin [--run=1] [--capture] [--clip]
const OUTPUT := "res://artifacts/thin-fog/"
const MODES := ["high", "performance", "thin"]
const KEYFRAMES := {96: "part", 164: "wave", 268: "wake"}
const STEP := 1.0 / 30.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var mode := "high"
	var run_id := 1
	var capture := false
	var clip := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="): mode = arg.trim_prefix("--mode=")
		if arg.begins_with("--run="): run_id = arg.trim_prefix("--run=").to_int()
		if arg == "--capture": capture = true
		if arg == "--clip":
			clip = true
			capture = true
	if mode not in MODES or DisplayServer.get_name() == "headless":
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var clip_path := "res://.godot/thin-clips/" + mode + "/"
	if clip:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(clip_path))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var vp := SubViewport.new()
	vp.size = Vector2i(1920,1080)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var demo: Node3D = load("res://demo/main.tscn").instantiate()
	vp.add_child(demo)
	demo.set_process(false)
	var player: Node3D = demo.get_node("Player")
	player.set_physics_process(false)
	var field: InteractiveFogField = demo.get_node("FogField")
	var hud: FogDemoHUD = demo.get_node("HUD")
	var rig: FogDemoOrbitCamera = demo.get_node("CameraRig")
	var brush: Node3D = demo.get_node("MouseBrush")
	var interactor: FogInteractor3D = brush.get_node("FogInteractor")
	var env: Environment = demo.get_node("WorldEnvironment").environment
	hud.hide()
	brush.hide()
	field.simulation_enabled = false
	hud.set_fog_quality(MODES.find(mode))
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	# Wait for the asynchronous 3D noise bake before starting the fixed replay.
	var volume: FogVolume = field.get_node(field.volume_path)
	var noise: NoiseTexture3D = volume.material.get_shader_parameter("detail_texture")
	if noise.get_data().is_empty():
		await noise.changed
	for warmup in range(60):
		await process_frame
		await RenderingServer.frame_post_draw
	field.set_process(false)
	field.reset_simulation()
	var wall := PackedFloat64Array()
	var gpu := PackedFloat64Array()
	var hashes := {}
	var previous := Time.get_ticks_usec()
	for frame in range(360):
		var orbit := smoothstep(42.0,190.0,frame)
		rig.distance = lerpf(22,13,orbit)
		rig.pitch_degrees = lerpf(57,19,orbit) + 13*smoothstep(210.0,300.0,frame)
		rig.yaw_degrees = 12 + 24*smoothstep(48.0,258.0,frame)
		rig.target_offset = Vector3(-0.8,0.22,1.0)
		player.position = Vector3(lerpf(-1,2,smoothstep(20.0,195.0,frame)),0,3)
		if frame == 36: demo.set_brush_mode(1)
		var stroke := clampf((frame-36.0)/78,0,1)
		brush.position = Vector3(lerpf(-3,2.5,stroke),0.05,1.0+sin(PI*stroke))
		interactor.enabled = frame >= 36 and frame < 114
		if frame == 144: field.burst(Vector3(0.5,0,1.0),3.0)
		if frame % 2 == 0: field._advance_simulation(STEP)
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		if frame >= 48 and not capture:
			wall.append((now-previous)*0.001)
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid()))
		previous = now
		if clip and frame % 3 == 0:
			var still := vp.get_texture().get_image()
			still.resize(640,360,Image.INTERPOLATE_LANCZOS)
			if still.save_jpg(clip_path + "%03d.jpg" % (frame/3), 0.96) != OK:
				quit(1)
				return
		if capture and KEYFRAMES.has(frame):
			var tag := str(KEYFRAMES[frame])
			if vp.get_texture().get_image().save_png(OUTPUT+mode+"-"+tag+".png") != OK:
				quit(1)
				return
			hashes[tag] = _state_hash(field)
	var report := {
		"mode": mode, "run": run_id, "capture": capture, "keyframe_state_sha256": hashes,
		"end_state_sha256": _state_hash(field), "simulation_seconds": field.get_simulation_time(),
		"gpu": RenderingServer.get_video_adapter_name(), "driver": RenderingServer.get_current_rendering_driver_name(),
		"godot": Engine.get_version_info().string, "viewport": [vp.size.x,vp.size.y],
		"native_fog_enabled": env.volumetric_fog_enabled, "samples": wall.size(),
	}
	if not capture:
		report["wall_ms"] = _stats(wall)
		report["viewport_gpu_ms"] = _stats(gpu)
	var key := "%s-%s" % [mode,"capture" if capture else str(run_id)]
	var file := FileAccess.open(OUTPUT+key+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")+"\n")
	file.close()
	# Exercise live switching on a frozen field, including restoration.
	var end_hash := str(report.end_state_sha256)
	for index in [2,1,0]:
		hud.set_fog_quality(index)
		await process_frame
		await RenderingServer.frame_post_draw
		if env.volumetric_fog_enabled != (index != 2) or _state_hash(field) != end_hash:
			push_error("Switch changed the frozen field or left the wrong renderer active")
			quit(1)
			return
	print("THIN_REPLAY ", JSON.stringify(report))
	demo.queue_free()
	await process_frame
	vp.queue_free()
	await process_frame
	quit()


func _state_hash(field: InteractiveFogField) -> String:
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	for texture in [field.get_state_texture(), field.get_coordinate_texture()]:
		hash_context.update(texture.get_image().get_data())
	return hash_context.finish().hex_encode()


func _stats(values: PackedFloat64Array) -> Dictionary:
	values.sort()
	return {"median":values[values.size()/2], "p95":values[ceili(values.size()*0.95)-1],
		"p99":values[ceili(values.size()*0.99)-1]}
