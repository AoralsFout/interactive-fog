@tool
class_name FogObstacle3D
extends Node3D
## 雾的二维碰撞足迹，独立于物理碰撞体。子节点 Mesh/CollisionShape 仍在 .tscn 中编辑。
## 足迹、变换及成员变化时通知雾场重新收集，再按数据变化更新 GPU 距离场。
## 模拟足迹支持世界 Y 轴旋转和 XZ 缩放，不使用高度。

enum Shape { BOX, CIRCLE }

static var footprint_revision := 0

@export var enabled := true:
	set(value):
		if enabled == value:
			return
		enabled = value
		footprint_revision += 1
@export var shape: Shape = Shape.BOX:
	set(value):
		if shape == value:
			return
		shape = value
		footprint_revision += 1
		set_process(sync_prefab_geometry)
## 盒形完整宽、深，沿此节点的局部 X、Z 轴。
@export var box_size := Vector2(2.0, 2.0):
	set(value):
		if box_size == value:
			return
		box_size = value
		footprint_revision += 1
		set_process(sync_prefab_geometry)
## 圆柱足迹半径；非等比缩放时取 XZ 中较大的缩放值。
@export_range(0.05, 20.0, 0.05, "suffix:m") var radius := 0.8:
	set(value):
		if radius == value:
			return
		radius = value
		footprint_revision += 1
		set_process(sync_prefab_geometry)
## 在可见网格外额外留出的空隙。可用于避免雾穿入柱脚。
@export_range(0.0, 2.0, 0.01, "suffix:m") var padding := 0.08:
	set(value):
		if padding == value:
			return
		padding = value
		footprint_revision += 1
## 标准预制体可让可见网格、物理碰撞与雾足迹共用尺寸。自定义模型请关闭并单独编辑子节点。
@export var sync_prefab_geometry := true:
	set(value):
		if sync_prefab_geometry == value:
			return
		sync_prefab_geometry = value
		set_process(sync_prefab_geometry)
@export_range(0.1, 10.0, 0.05, "suffix:m") var height := 2.6:
	set(value):
		if height == value:
			return
		height = value
		set_process(sync_prefab_geometry)

var _geometry_key: Array = []


func _enter_tree() -> void:
	set_notify_transform(true)
	set_notify_local_transform(true)
	footprint_revision += 1
	set_process(sync_prefab_geometry)
	add_to_group(&"interactive_fog_obstacles")


func _exit_tree() -> void:
	footprint_revision += 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED or what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
		footprint_revision += 1


func _process(_delta: float) -> void:
	set_process(false)
	if not sync_prefab_geometry:
		return
	var key: Array = [shape, box_size, radius, height]
	if key == _geometry_key:
		return
	var mesh_node := get_node_or_null("Mesh") as MeshInstance3D
	var collision_node := get_node_or_null("Body/CollisionShape3D") as CollisionShape3D
	if mesh_node == null or collision_node == null:
		set_process(true)
		return
	_geometry_key = key
	# 只创建资源，不创建场景节点；所有节点均在对应 .tscn 中明确声明。
	if shape == Shape.BOX:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(maxf(box_size.x, 0.05), height, maxf(box_size.y, 0.05))
		var collision := BoxShape3D.new()
		collision.size = mesh.size
		mesh_node.mesh = mesh
		collision_node.shape = collision
	else:
		var mesh := CylinderMesh.new()
		mesh.top_radius = radius
		mesh.bottom_radius = radius
		mesh.height = height
		var collision := CylinderShape3D.new()
		collision.radius = radius
		collision.height = height
		mesh_node.mesh = mesh
		collision_node.shape = collision
	mesh_node.position.y = height * 0.5
	collision_node.position.y = height * 0.5


## 与 shaders/build_obstacles.glsl 的 Obstacle 结构严格对应，共两个 vec4。
func pack_gpu_data() -> PackedFloat32Array:
	var world_scale := global_basis.get_scale().abs()
	var axis := Vector2(global_basis.x.x, global_basis.x.z).normalized()
	var extent := box_size.max(Vector2(0.05, 0.05)) * Vector2(world_scale.x, world_scale.z) * 0.5
	if shape == Shape.CIRCLE:
		extent = Vector2.ONE * radius * maxf(world_scale.x, world_scale.z)
	return PackedFloat32Array([
		global_position.x, global_position.z, extent.x, extent.y,
		axis.x, axis.y, float(shape), padding,
	])


## 薄层阴影使用网格的局部尺寸和世界变换。自定义模型可以用自身的雾障碍形状近似遮挡。
func pack_shadow_caster() -> PackedVector4Array:
	var mesh_node := get_node_or_null("Mesh") as MeshInstance3D
	if not is_visible_in_tree():
		return PackedVector4Array()
	if mesh_node != null and (not mesh_node.is_visible_in_tree()
			or mesh_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF):
		return PackedVector4Array()

	var half_height := height * 0.5
	var extents := Vector3(box_size.x * 0.5, half_height, box_size.y * 0.5)
	var caster_transform := global_transform.translated_local(Vector3(0.0, half_height, 0.0))
	var caster_shape := shape
	if caster_shape == Shape.CIRCLE:
		extents = Vector3(radius, half_height, radius)
	if mesh_node != null and mesh_node.mesh is BoxMesh:
		extents = (mesh_node.mesh as BoxMesh).size * 0.5
		caster_transform = mesh_node.global_transform
		caster_shape = Shape.BOX
	elif mesh_node != null and mesh_node.mesh is CylinderMesh:
		var cylinder := mesh_node.mesh as CylinderMesh
		if is_equal_approx(cylinder.top_radius, cylinder.bottom_radius):
			extents = Vector3(cylinder.top_radius, cylinder.height * 0.5, cylinder.top_radius)
			caster_transform = mesh_node.global_transform
			caster_shape = Shape.CIRCLE
	if minf(extents.x, minf(extents.y, extents.z)) <= 0.0 or is_zero_approx(caster_transform.basis.determinant()):
		return PackedVector4Array()

	var world_to_caster := caster_transform.affine_inverse()
	var x := world_to_caster.basis.x
	var y := world_to_caster.basis.y
	var z := world_to_caster.basis.z
	var offset := world_to_caster.origin
	return PackedVector4Array([
		Vector4(x.x, y.x, z.x, offset.x),
		Vector4(x.y, y.y, z.y, offset.y),
		Vector4(x.z, y.z, z.z, offset.z),
		Vector4(extents.x, extents.y, extents.z, float(caster_shape)),
	])
