@tool
extends EditorNode3DGizmoPlugin
## 这些线不参与运行时渲染，也不创建会被保存进场景的辅助节点。


func _init() -> void:
	create_material("field", Color(0.25, 0.85, 0.8))
	create_material("obstacle", Color(1.0, 0.63, 0.28))
	create_material("interactor", Color(0.5, 0.7, 1.0))


func _get_gizmo_name() -> String:
	return "Interactive Fog"


func _has_gizmo(node: Node3D) -> bool:
	return node is InteractiveFogField or node is FogObstacle3D or node is FogInteractor3D


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	var lines := PackedVector3Array()
	var material_name := "field"
	if node is InteractiveFogField and node.settings != null:
		var half: Vector2 = node.settings.area_size * 0.5
		lines = _box_lines(half, node.settings.thickness)
	elif node is FogObstacle3D:
		material_name = "obstacle"
		if node.shape == FogObstacle3D.Shape.CIRCLE:
			lines = _circle_lines(node.radius + node.padding)
		else:
			lines = _box_lines(node.box_size * 0.5 + Vector2.ONE * node.padding, 0.02)
	elif node is FogInteractor3D:
		material_name = "interactor"
		lines = _circle_lines(node.radius)
	if not lines.is_empty():
		gizmo.add_lines(lines, get_material(material_name, gizmo), false)
		gizmo.add_collision_segments(lines)


func _circle_lines(radius: float) -> PackedVector3Array:
	var lines := PackedVector3Array()
	for index in range(48):
		var a := TAU * index / 48.0
		var b := TAU * (index + 1) / 48.0
		lines.append(Vector3(cos(a), 0.04, sin(a)) * radius)
		lines.append(Vector3(cos(b), 0.04, sin(b)) * radius)
	return lines


func _box_lines(half: Vector2, height: float) -> PackedVector3Array:
	var lines := PackedVector3Array()
	var corners: Array[Vector3] = [
		Vector3(-half.x, 0, -half.y), Vector3(half.x, 0, -half.y),
		Vector3(half.x, 0, half.y), Vector3(-half.x, 0, half.y),
	]
	for index in range(4):
		var next := (index + 1) % 4
		lines.append_array(PackedVector3Array([
			corners[index], corners[next],
			corners[index] + Vector3.UP * height, corners[next] + Vector3.UP * height,
			corners[index], corners[index] + Vector3.UP * height,
		]))
	return lines
