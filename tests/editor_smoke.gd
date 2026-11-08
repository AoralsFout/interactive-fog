@tool
extends RefCounted
## 在真实 Godot 编辑器进程中检查 @tool 行为与场景保存边界。
## 启动方式见 README。测试只写 artifacts/ 下的临时场景，不保存用户的主场景。

var _failures := 0
var _plugin: EditorPlugin


func run(plugin: EditorPlugin) -> void:
	_plugin = plugin
	await _frames(30)
	EditorInterface.open_scene_from_path("res://demo/main.tscn")
	await _frames(40)
	var scene := EditorInterface.get_edited_scene_root()
	_check(scene != null and scene.scene_file_path == "res://demo/main.tscn", "main scene opened in editor")
	if scene == null:
		_plugin.get_tree().quit(1)
		return
	var field := scene.get_node("FogField") as InteractiveFogField
	_check(Engine.is_editor_hint(), "actual editor tool execution")
	var time_before := field.get_simulation_time()
	await _frames(20)
	_check(field.get_simulation_time() > time_before, "editor simulation preview advances")
	field.preview_in_editor = false
	await _frames(3)
	var paused_time := field.get_simulation_time()
	await _frames(6)
	_check(is_equal_approx(field.get_simulation_time(), paused_time), "editor preview can pause")
	var old_height := field.settings.thickness
	var old_density := field.settings.density
	field.settings.thickness = 2.1
	field.settings.density = 1.7
	await _frames(4)
	var volume := field.get_node("FogVolume") as FogVolume
	var material: ShaderMaterial = field.get("_render_material")
	var expected_height := 2.1 * (1.0 + field.settings.compression_height_boost)
	_check(is_equal_approx(volume.size.y, expected_height), "Inspector-style height changes apply while paused")
	_check(is_equal_approx(material.get_shader_parameter("density"), 1.7), "Inspector-style density updates render material")
	var wall := scene.get_node("Obstacles/WallWest") as FogObstacle3D
	var old_size := wall.box_size
	wall.box_size = Vector2(5.0, 1.1)
	await _frames(4)
	var mesh := (wall.get_node("Mesh") as MeshInstance3D).mesh as BoxMesh
	var collision := (wall.get_node("Body/CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_check(is_equal_approx(mesh.size.x, 5.0) and is_equal_approx(collision.size.z, 1.1), "editor prefab mesh and collision follow footprint")
	field.reset_button.call()
	await _frames(4)
	_check(field.get_simulation_time() < 0.1, "Inspector reset callable works")
	var packed := PackedScene.new()
	var pack_error := packed.pack(scene)
	var save_error := ResourceSaver.save(packed, "res://artifacts/editor-save-check.tscn") if pack_error == OK else pack_error
	_check(save_error == OK, "tool scene can be packed and saved")
	var text := FileAccess.get_file_as_string("res://artifacts/editor-save-check.tscn")
	_check(not text.contains("Texture2DRD"), "saved scene contains no transient GPU texture resources")
	# 恢复内存中的参数；主场景与预设文件始终没有调用保存。
	wall.box_size = old_size
	field.settings.thickness = old_height
	field.settings.density = old_density
	field.preview_in_editor = true
	await _frames(3)
	# 先由编辑器关闭场景，确保 @tool / gizmo 在编辑器单例销毁前完成清理。
	EditorInterface.close_scene()
	await _frames(6)
	print("EDITOR_SMOKE_RESULT failures=%d" % _failures)
	_plugin.get_tree().quit(0 if _failures == 0 else 1)


func _frames(count: int) -> void:
	for index in range(count):
		await _plugin.get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		push_error("FAIL: " + message)
