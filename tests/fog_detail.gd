extends SceneTree
## 固定步、固定镜头的真实体积雾外观验收；PNG 用于人工比较，不把像素差当成美术结论。
## -- --fog-detail-baseline 仅保存改动前截图；普通运行检查细节参数热更新及交互。

const STEP := 1.0 / 30.0
const OUTPUT := "res://artifacts/fog-detail/"
var _failures := 0
var _demo: Node3D
var _field: InteractiveFogField


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Fog detail capture needs a real GPU; omit --headless.")
		quit(1)
		return
	var baseline := "--fog-detail-baseline" in OS.get_cmdline_user_args()
	var prefix := "baseline" if baseline else "candidate"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	_demo = load("res://demo/main.tscn").instantiate() as Node3D
	root.add_child(_demo)
	_demo.set_process(false)
	_demo.get_node("Player").set_physics_process(false)
	_demo.get_node("Player/FogInteractor").set("enabled", false)
	_demo.get_node("MouseBrush").hide()
	_demo.get_node("HUD").hide()
	_field = _demo.get_node("FogField") as InteractiveFogField
	_field.simulation_enabled = false
	await _frames(30)
	for index in range(90):
		_field._advance_simulation(STEP)
		await _frames(1)
	await _capture(prefix + "-wide")
	var rig := _demo.get_node("CameraRig") as FogDemoOrbitCamera
	rig.distance = 15.0
	rig.pitch_degrees = 28.0
	rig.target_offset = Vector3(-0.8, 0.2, 0.0)
	await _capture(prefix + "-close")
	if not baseline:
		var detailed := root.get_texture().get_image()
		var amount := _field.settings.detail_amount
		_field.settings.detail_amount = 0.0
		await _frames(5)
		var smooth := root.get_texture().get_image()
		_check(_difference(detailed, smooth) > 0.001, "detail can be disabled live")
		_field.settings.detail_amount = amount
		_field.settings.detail_sharpness = 0.0
		await _frames(5)
		var soft := root.get_texture().get_image()
		_field.settings.detail_sharpness = 0.75
		await _frames(5)
		_check(_difference(soft, root.get_texture().get_image()) > 0.0002, "edge sharpness changes rendered fog live")
		_field.settings.detail_warp = 0.0
		await _frames(5)
		var unwarped := root.get_texture().get_image()
		_field.settings.detail_warp = 0.65
		await _frames(5)
		_check(_difference(unwarped, root.get_texture().get_image()) > 0.00001, "filament warping changes rendered fog live")
		_field.burst(Vector3(0.0, 0.0, 1.0), 2.8)
		for index in range(12):
			_field._advance_simulation(STEP)
			await _frames(1)
		await _capture(prefix + "-interaction")
		# P 暂停时着色细节和局部卷曲也应冻结，不使用独立的 Shader TIME。
		var frozen_time := _field.get_simulation_time()
		await _frames(12)
		_check(is_equal_approx(frozen_time, _field.get_simulation_time()), "paused field freezes detail animation time")
	_demo.queue_free()
	await _frames(5)
	print("FOG_DETAIL_RESULT failures=%d baseline=%s" % [_failures, baseline])
	quit(0 if _failures == 0 else 1)


func _capture(name: String) -> void:
	await _frames(8)
	var error := root.get_texture().get_image().save_png(OUTPUT + name + ".png")
	_check(error == OK, "capture " + name)


func _frames(count: int) -> void:
	for index in range(count):
		await process_frame
		await RenderingServer.frame_post_draw


func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var count := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			count += 1
	return total / count


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
