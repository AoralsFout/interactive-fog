extends SceneTree
## Export exact GPU stencils, RHS, pressure and MAC velocities, outside timed runs.
## Companion analysis: python tests/pressure_comparison.py (NumPy, SciPy, Pillow).
const STEP := 1.0/30.0
var field: InteractiveFogField
var wall: FogObstacle3D
var mode := FogSettings.PressureSolver.JACOBI
var n := 256
var output: String


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg == "--multigrid": mode = FogSettings.PressureSolver.MULTIGRID
		if arg.begins_with("--size="): n = arg.trim_prefix("--size=").to_int()
	var name := "multigrid" if mode == FogSettings.PressureSolver.MULTIGRID else "jacobi"
	var cycles := 2
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cycles="):
			cycles = arg.trim_prefix("--cycles=").to_int()
			name += "-%d" % cycles
	output = "res://.godot/pressure-comparison/%d/%s/" % [n,name]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var pillar := _obstacle(Vector2(-2,0), Vector2.ONE)
	pillar.shape = FogObstacle3D.Shape.CIRCLE
	pillar.radius = 0.85
	wall = _obstacle(Vector2(2,-1.4),Vector2(0.30,2.2))
	var second := _obstacle(Vector2(2,1.4),Vector2(0.30,2.2))
	field = load("res://fog/scenes/fog_field.tscn").instantiate()
	field.settings = FogSettings.new()
	field.settings.resolution = n
	field.settings.pressure_iterations = 64
	field.settings.multigrid_cycles = cycles
	field.settings.wind_velocity = Vector2(1.2,0.08)
	field.settings.turbulence_strength = 0
	field.simulation_enabled = false
	root.add_child(field)
	for i in 8: await _frame()
	field.set_process(false)
	field.settings.pressure_solver = mode
	field.reset_simulation()
	if "--soak" in OS.get_cmdline_user_args():
		output += "soak-" + RenderingServer.get_current_rendering_driver_name() + "/"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
		for i in 900:
			if i == 300: wall.position.z -= 0.7
			if i == 600: wall.position.z += 0.7
			await _step(i)
			if i % 90 == 89:
				var label := "step-%d" % i
				await _snapshot(label,true)
				var pressure := FileAccess.get_file_as_bytes(output+label+"-p.bin").to_float32_array()
				if pressure.size() != n*n:
					quit(1)
					return
				for value in pressure:
					if not is_finite(value):
						push_error("Nonfinite pressure at step %d" % i)
						quit(1)
						return
		print("PRESSURE_SOAK ", output)
		field.queue_free()
		await _frame()
		quit()
		return
	for i in 101:
		if i == 91: wall.position.z -= 0.7
		await _step(i)
		if i in [0,90,100]:
			await _snapshot({0:"cold",90:"wake",100:"moved"}[i])
	# A single warm solve on identical pressure, pre-projection velocity and geometry.
	wall.position.z = -1.4
	field.settings.pressure_solver = FogSettings.PressureSolver.JACOBI
	field.reset_simulation()
	for i in 60: await _step(i)
	await _snapshot("warm_start",true)
	field.settings.pressure_solver = mode
	await _step(60)
	await _snapshot("matched")
	# Seal the whole domain, force only the left side, check coarse-grid coupling.
	pillar.enabled = false
	second.enabled = false
	wall.position = Vector3.ZERO
	wall.box_size = Vector2(maxf(0.32,1.5*24.0/n),22)
	field.settings.wind_velocity = Vector2.ZERO
	field.reset_simulation()
	field.disturb(Vector3(-2,0,0),1.0,Vector2(2,0),1)
	field._advance_simulation(STEP)
	await _frame()
	await _snapshot("sealed")
	print("PRESSURE_CAPTURE ", output)
	field.queue_free()
	await _frame()
	quit()


func _obstacle(at: Vector2, size: Vector2) -> FogObstacle3D:
	var node := FogObstacle3D.new()
	node.sync_prefab_geometry = false
	node.shape = FogObstacle3D.Shape.BOX
	node.padding = 0
	node.box_size = size
	node.position = Vector3(at.x,0,at.y)
	root.add_child(node)
	return node


func _step(i: int) -> void:
	if i % 12 == 0:
		field.disturb(Vector3(-3.4,0,0.45*sin(i*0.08)),1.3,Vector2(1.4,0.35),0.7)
	field._advance_simulation(STEP)
	await _frame()


func _frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw


func _snapshot(label: String, pressure_only := false) -> void:
	RenderingServer.call_on_render_thread(_readback.bind(field._simulation,output+label,pressure_only))
	await _frame()


func _readback(sim: FogSimulationGPU, prefix: String, pressure_only: bool) -> void:
	var textures := {"p":sim._pressures[sim._pressure_read]}
	if not pressure_only:
		textures.merge({"geom":sim._topology, "before":sim._before_projection,
			"after":sim._after_projection, "predict":sim._working_velocity, "mac":sim._velocity,
			"mask":sim._mask})
	for key in textures:
		var file := FileAccess.open(prefix+"-"+key+".bin",FileAccess.WRITE)
		file.store_buffer(sim._rd.texture_get_data(textures[key],0))
