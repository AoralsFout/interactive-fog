@tool
class_name FogHeightMap
extends Resource
## Static world-space XZ height map. The first and last pixel centers lie on the bounds.

@export var source: Texture2D:
	set(value):
		if source != null:
			source.changed.disconnect(_invalidate_samples)
		source = value
		if source != null:
			source.changed.connect(_invalidate_samples)
		_invalidate_samples()
@export var world_bounds := Rect2(-12.0, -10.0, 24.0, 20.0):
	set(value):
		world_bounds = value
		emit_changed()
## World-space Y in meters at red channel values 0 and 1.
@export var height_range := Vector2(0.0, 1.0):
	set(value):
		height_range = value
		_invalidate_samples()

var _needs_samples := true
var _samples: Image
var _texture: ImageTexture
var _tile_texture: ImageTexture


func _invalidate_samples() -> void:
	_needs_samples = true
	_samples = null
	_texture = null
	_tile_texture = null
	emit_changed()


func get_samples() -> Image:
	if not _needs_samples:
		return _samples
	_needs_samples = false
	if source == null or not height_range.is_finite():
		return null
	var image := source.get_image()
	if image == null or image.get_width() < 2 or image.get_height() < 2:
		return null
	if image.is_compressed() and image.decompress() != OK:
		return null
	var samples := Image.create_empty(image.get_width(), image.get_height(), false, Image.FORMAT_RF)
	for z in range(image.get_height()):
		for x in range(image.get_width()):
			var height := lerpf(height_range.x, height_range.y, image.get_pixel(x, z).r)
			if not is_finite(height):
				return null
			samples.set_pixel(x, z, Color(height, 0.0, 0.0))
	_samples = samples
	return _samples


func is_valid() -> bool:
	return world_bounds.is_finite() and world_bounds.size.x > 0.0 and world_bounds.size.y > 0.0 and get_samples() != null


func get_height_texture() -> Texture2D:
	var samples := get_samples()
	if samples != null and _texture == null:
		_texture = ImageTexture.create_from_image(samples)
	return _texture


## Conservative min/max heights for a uniform XZ grid used by the thin renderer.
func get_tile_height_texture() -> Texture2D:
	var samples := get_samples()
	if samples == null:
		return null
	if _tile_texture != null:
		return _tile_texture
	var last := samples.get_size() - Vector2i.ONE
	var tiles := Vector2i((Vector2(last) / 8.0).ceil()).clamp(Vector2i.ONE, Vector2i(32, 32))
	var cells_per_tile := Vector2(last) / Vector2(tiles)
	var image := Image.create_empty(tiles.x, tiles.y, false, Image.FORMAT_RGF)
	for z in range(tiles.y):
		for x in range(tiles.x):
			var start := Vector2i((Vector2(x, z) * cells_per_tile).floor())
			var end := Vector2i((Vector2(x + 1, z + 1) * cells_per_tile).ceil()).min(last)
			var limits := _sample_limits(start, end)
			image.set_pixel(x, z, Color(limits.x, limits.y, 0.0))
	_tile_texture = ImageTexture.create_from_image(image)
	return _tile_texture


## Returns INF outside the map. CPU, terrain triangles and the shader share a diagonal.
func sample_height(world_xz: Vector2) -> float:
	if not is_valid() or not world_bounds.encloses(Rect2(world_xz, Vector2.ZERO)):
		return INF
	var last := _samples.get_size() - Vector2i.ONE
	var grid := (world_xz - world_bounds.position) / world_bounds.size * Vector2(last)
	var cell := Vector2i(grid.floor()).clamp(Vector2i.ZERO, last - Vector2i.ONE)
	var fraction := grid - Vector2(cell)
	var h00 := _samples.get_pixelv(cell).r
	var h11 := _samples.get_pixelv(cell + Vector2i.ONE).r
	if fraction.x >= fraction.y:
		var h10 := _samples.get_pixelv(cell + Vector2i(1, 0)).r
		return h00 + (h10 - h00) * fraction.x + (h11 - h10) * fraction.y
	var h01 := _samples.get_pixelv(cell + Vector2i(0, 1)).r
	return h00 + (h11 - h01) * fraction.x + (h01 - h00) * fraction.y


## Conservative bounds including corners of the cells intersected by this area.
func get_height_limits(area: Rect2) -> Vector2:
	if not is_valid() or not world_bounds.encloses(area):
		return Vector2(INF, -INF)
	var last := _samples.get_size() - Vector2i.ONE
	var start := Vector2i(((area.position - world_bounds.position) / world_bounds.size * Vector2(last)).floor()).clamp(Vector2i.ZERO, last)
	var end := Vector2i(((area.end - world_bounds.position) / world_bounds.size * Vector2(last)).ceil()).clamp(Vector2i.ZERO, last)
	return _sample_limits(start, end)


func _sample_limits(start: Vector2i, end: Vector2i) -> Vector2:
	var limits := Vector2(INF, -INF)
	for z in range(start.y, end.y + 1):
		for x in range(start.x, end.x + 1):
			var height := _samples.get_pixel(x, z).r
			limits = Vector2(minf(limits.x, height), maxf(limits.y, height))
	return limits
