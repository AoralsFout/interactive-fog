@tool
extends StaticBody3D
## Draws and collides against the same triangles sampled by the fog.

@export var height_map: FogHeightMap:
	set(value):
		if height_map != null:
			height_map.changed.disconnect(_rebuild)
		height_map = value
		if height_map != null:
			height_map.changed.connect(_rebuild)
		_rebuild()
@export var ground_material: Material

var _surface: MeshInstance3D
var _collision: CollisionShape3D


func _ready() -> void:
	_surface = MeshInstance3D.new()
	_surface.material_override = ground_material
	add_child(_surface)
	_collision = CollisionShape3D.new()
	add_child(_collision)
	_rebuild()


func _rebuild() -> void:
	if not is_instance_valid(_surface):
		return
	if height_map == null or not height_map.is_valid():
		_surface.mesh = null
		_collision.shape = null
		return
	var image := height_map.get_samples()
	var size := image.get_size()
	var bounds := height_map.world_bounds
	var step := bounds.size / Vector2(size - Vector2i.ONE)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for z in range(size.y):
		for x in range(size.x):
			var xz := bounds.position + step * Vector2(x, z)
			vertices.append(Vector3(xz.x, image.get_pixel(x, z).r, xz.y))
			var left := maxi(0, x - 1)
			var right := mini(size.x - 1, x + 1)
			var back := maxi(0, z - 1)
			var front := mini(size.y - 1, z + 1)
			var dx := (image.get_pixel(right, z).r - image.get_pixel(left, z).r) / ((right - left) * step.x)
			var dz := (image.get_pixel(x, front).r - image.get_pixel(x, back).r) / ((front - back) * step.y)
			normals.append(Vector3(-dx, 1.0, -dz).normalized())
	for z in range(size.y - 1):
		for x in range(size.x - 1):
			var top_left := z * size.x + x
			var bottom_left := top_left + size.x
			indices.append_array([top_left, top_left + 1, bottom_left + 1,
				top_left, bottom_left + 1, bottom_left])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_surface.mesh = mesh
	_collision.shape = mesh.create_trimesh_shape()
