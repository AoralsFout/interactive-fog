extends SceneTree
## Verifies shared height sampling, terrain interaction, and all four render modes.

const HILL := Vector2(-5.4, -3.2)
const HOLLOW := Vector2(1.2, 6.3)
const RAMP := Vector2(8.1, -1.1)
const DemoController = preload("res://demo/demo_controller.gd")
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("terrain_fog requires a graphics device.")
		quit(1)
		return
	var demo := load("res://demo/terrain.tscn").instantiate() as DemoController
	root.add_child(demo)
	var field := demo.get_node("FogField") as InteractiveFogField
	var player := demo.get_node("Player") as FogDemoPlayer
	var camera := demo.get_node("CameraRig/Camera3D") as Camera3D
	var hud := demo.get_node("HUD") as FogDemoHUD
	var volume := field.get_node("FogVolume") as FogVolume
	field.simulation_enabled = false
	await _frames(16)
	_check(demo.get_node("Terrain").height_map == field.height_map, "mesh, collision and fog share the height map")
	_check(field.height_map.world_bounds.size.x > field.settings.area_size.x, "a larger terrain map covers a smaller fog field")
	_check(is_finite(field.height_map.sample_height(field.height_map.world_bounds.end)), "last texel is on the inclusive map boundary")
	_check(is_inf(field.height_map.sample_height(field.height_map.world_bounds.end + Vector2.ONE)), "outside the map has no ground sample")
	var hill := Vector3(HILL.x, field.height_map.sample_height(HILL), HILL.y)
	var hollow := Vector3(HOLLOW.x, field.height_map.sample_height(HOLLOW), HOLLOW.y)
	_check(hill.y > field.settings.thickness and hollow.y < 0.0, "fixture exercises both sides of the old fog plane")
	_check(volume.position.y - volume.size.y * 0.5 <= hollow.y
		and volume.position.y + volume.size.y * 0.5 >= hill.y + field.settings.thickness,
		"volume includes the hollow and fog above the hill")
	await physics_frame
	for xz in [HILL, HOLLOW, RAMP]:
		var query := PhysicsRayQueryParameters3D.create(Vector3(xz.x, 6.0, xz.y), Vector3(xz.x, -5.0, xz.y), 2)
		var hit := demo.get_world_3d().direct_space_state.intersect_ray(query)
		var point: Vector3 = hit.get("position", Vector3.INF)
		var error := absf(point.y - field.height_map.sample_height(xz))
		_check(hit.get("collider") == demo.get_node("Terrain")
			and error < 0.005, "terrain and height map agree at %s (%.5f m error)" % [xz, error])
	_check(player.is_on_floor() and absf(player.position.y - field.get_ground_height(player.position)) < 0.12,
		"player stands on the lowered terrain")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = camera.unproject_position(hill)
	demo.set_brush_mode(DemoController.BrushMode.BURST)
	demo._unhandled_input(click)
	await _frames(4)
	var bursts: Array[FogBurst] = field.get("_active_bursts")
	_check(bursts.size() == 1 and bursts[0].world_position.distance_to(hill + Vector3.UP * 0.045) < 0.06,
		"click creates a burst at the terrain hit, above the old fog plane")
	field.reset_simulation()
	await _frames(4)
	Input.action_press("jump")
	await physics_frame
	await physics_frame
	Input.action_release("jump")
	for index in range(45):
		await physics_frame
	bursts = field.get("_active_bursts")
	_check(player.is_on_floor() and bursts.size() == 2 and bursts[0].strength < 0.0 and bursts[1].strength > 0.0,
		"takeoff and landing produce ground-level fog disturbances")
	_check(field._interactor_reaches_fog(hill + Vector3.UP * 0.07, 0.1)
		and not field._interactor_reaches_fog(hill + Vector3.UP * 2.0, 0.1), "interactor reach is relative to local ground")
	field.simulation_enabled = true
	var start := player.position
	Input.action_press("move_left")
	for index in range(20):
		await physics_frame
	Input.action_release("move_left")
	_check(player.position.distance_to(start) > 0.4 and not field.get("_active_cuts").is_empty(),
		"walking on the terrain creates fog cuts")
	field.simulation_enabled = false

	var quality := hud.get_node("%FogQuality") as OptionButton
	var slices: MultiMeshInstance3D = field.get_node("HorizontalSlices")
	var environment := (demo.get_node("WorldEnvironment") as WorldEnvironment).environment
	_check(not quality.is_item_disabled(FogDemoHUD.FogQuality.THIN_LAYER)
		and not quality.is_item_disabled(FogDemoHUD.FogQuality.HORIZONTAL_SLICES), "terrain exposes both custom render modes")
	hud.hide()
	demo.set_physics_process(false)
	demo.get_node("MouseBrush").hide()
	field.settings.density_variation = 0.0
	field.reset_simulation()
	await _frames(4)
	(demo.get_node("Obstacles/MovingWall/AnimationPlayer") as AnimationPlayer).pause()
	var density := field.settings.density
	var material_history := field.get_coordinate_texture().get_image().get_data()
	for mode in [FogDemoHUD.FogQuality.HIGH, FogDemoHUD.FogQuality.PERFORMANCE,
			FogDemoHUD.FogQuality.THIN_LAYER, FogDemoHUD.FogQuality.HORIZONTAL_SLICES]:
		hud.set_fog_quality(mode)
		var thin: bool = mode == FogDemoHUD.FogQuality.THIN_LAYER
		var tiled: bool = mode == FogDemoHUD.FogQuality.HORIZONTAL_SLICES
		_check((camera.compositor != null) == thin and slices.visible == tiled
			and environment.volumetric_fog_enabled == (not thin and not tiled), "mode %d only activates its own renderer" % mode)
		field.settings.density = 0.0
		await _frames(16)
		var clear := root.get_texture().get_image()
		field.settings.density = density
		await _frames(16)
		var fog := root.get_texture().get_image()
		var scale := Vector2(fog.get_size()) / root.get_visible_rect().size
		var hill_delta := _patch_difference(fog, clear, camera.unproject_position(hill) * scale)
		var hollow_delta := _patch_difference(fog, clear, camera.unproject_position(hollow) * scale)
		_check(quality.selected == mode and hill_delta > 0.025 and hollow_delta > 0.025,
			"mode %d renders fog on both the hill (%.3f) and hollow (%.3f)" % [mode, hill_delta, hollow_delta])
		_check(_patch_difference(fog, clear, Vector2(12.0, 12.0)) < 0.005, "mode %d keeps fog inside the field" % mode)
		if "--capture" in OS.get_cmdline_user_args():
			fog.save_png("res://.godot/terrain-fog-%d.png" % mode)
	_check(slices.multimesh == null and slices.get_child_count() > 1, "terrain slices use subdivided tiles")
	_check(field.get_coordinate_texture().get_image().get_data() == material_history,
		"switching all render modes preserves the paused fog history")

	# This opaque surface is close to the wide camera, well before the fog.
	var occluder := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.25, 0.25)
	var opaque := StandardMaterial3D.new()
	opaque.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	opaque.albedo_color = Color(0.35, 0.35, 0.35)
	occluder.mesh = quad
	occluder.material_override = opaque
	occluder.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	camera.add_child(occluder)
	occluder.position.z = -0.5
	for mode in [FogDemoHUD.FogQuality.THIN_LAYER, FogDemoHUD.FogQuality.HORIZONTAL_SLICES]:
		hud.set_fog_quality(mode)
		field.settings.density = 0.0
		await _frames(8)
		var clear := root.get_texture().get_image()
		field.settings.density = density
		await _frames(8)
		var fog := root.get_texture().get_image()
		var center := Vector2(fog.get_size()) * 0.5
		_check(_patch_difference(fog, clear, center) < 0.004, "mode %d keeps fog behind foreground geometry" % mode)
	occluder.queue_free()

	var rig := demo.get_node("CameraRig") as FogDemoOrbitCamera
	rig.set_process(false)
	var eye := Vector3(1.2, 0.0, 8.2)
	eye.y = field.get_ground_height(eye) + 0.26
	camera.global_position = eye
	var target := Vector3(1.75, 0.0, 5.1)
	target.y = field.get_ground_height(target) + 0.12
	camera.look_at(target)
	for mode in [FogDemoHUD.FogQuality.THIN_LAYER, FogDemoHUD.FogQuality.HORIZONTAL_SLICES]:
		hud.set_fog_quality(mode)
		field.settings.density = 0.0
		await _frames(8)
		var clear := root.get_texture().get_image()
		field.settings.density = density
		await _frames(8)
		var fog := root.get_texture().get_image()
		var scale := Vector2(fog.get_size()) / root.get_visible_rect().size
		var delta := _patch_difference(fog, clear, camera.unproject_position(target) * scale)
		_check(delta > 0.025, "mode %d resolves fog with the camera inside the shallow layer (%.3f)" % [mode, delta])
		if "--capture" in OS.get_cmdline_user_args():
			fog.save_png("res://.godot/terrain-low-%d.png" % mode)
	hud.set_fog_quality(FogDemoHUD.FogQuality.HIGH)
	_check(environment.volumetric_fog_enabled and camera.compositor == null and not slices.visible,
		"returning to native fog restores the terrain renderer")
	demo.queue_free()
	await _frames(4)
	print("TERRAIN_FOG_RESULT failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _patch_difference(a: Image, b: Image, center: Vector2) -> float:
	var sum := 0.0
	for y in range(-5, 6):
		for x in range(-5, 6):
			var pixel := (Vector2i(center) + Vector2i(x, y)).clamp(Vector2i.ZERO, a.get_size() - Vector2i.ONE)
			var color := a.get_pixelv(pixel) - b.get_pixelv(pixel)
			sum += (absf(color.r) + absf(color.g) + absf(color.b)) / 3.0
	return sum / 121.0


func _frames(count: int) -> void:
	for index in range(count):
		await process_frame
		await RenderingServer.frame_post_draw


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)
