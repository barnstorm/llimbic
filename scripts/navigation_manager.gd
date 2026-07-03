extends Node
## res://scripts/navigation_manager.gd — AStar2D pathfinding from collision map (autoload)

signal navigation_ready

var astar: AStar2D
var tile_size: int = 32
var map_width: int = 140
var map_height: int = 100
var _walkable: PackedByteArray  # 0=walkable, 255=blocked

func _ready() -> void:
	_build_nav_grid()
	navigation_ready.emit()
	# NOTE (2026-07-02): a physical-collider enforcement of the navgrid was
	# tried and reverted — this world's own content contradicts "blocked =
	# solid" (NPCs natively SPAWN inside blocked regions, e.g. the town-square
	# plaza, and walk out; the navgrid is a routing layer, not a physical
	# layer). The world-side bound on external control is therefore
	# entry-denial in npc_controller._apply_velocity_and_progress: an
	# externally-driven actor may never ENTER blocked ground from walkable
	# ground — the invariant native pathing already maintains — while escape
	# from blocked ground (spawns) stays possible, exactly as for natives.

func _build_nav_grid() -> void:
	astar = AStar2D.new()
	astar.reserve_space(map_width * map_height)

	# Load collision map (140x100 grayscale, white=blocked)
	var tex: Texture2D = load("res://assets/img/collision_map.png")
	var img: Image = tex.get_image()
	if img == null:
		push_error("Failed to load collision_map.png")
		return

	_walkable = PackedByteArray()
	_walkable.resize(map_width * map_height)

	# First pass: add walkable points
	for y in range(map_height):
		for x in range(map_width):
			var idx: int = y * map_width + x
			var pixel: Color = img.get_pixel(x, y)
			# White (>0.5 brightness) = blocked
			if pixel.r > 0.5:
				_walkable[idx] = 255
			else:
				_walkable[idx] = 0
				var world_pos: Vector2 = Vector2(x * tile_size + tile_size * 0.5, y * tile_size + tile_size * 0.5)
				astar.add_point(idx, world_pos)

	# Second pass: connect walkable neighbors (4-directional)
	for y in range(map_height):
		for x in range(map_width):
			var idx: int = y * map_width + x
			if _walkable[idx] != 0:
				continue
			# Right
			if x + 1 < map_width:
				var right: int = y * map_width + (x + 1)
				if _walkable[right] == 0:
					astar.connect_points(idx, right)
			# Down
			if y + 1 < map_height:
				var down: int = (y + 1) * map_width + x
				if _walkable[down] == 0:
					astar.connect_points(idx, down)

	print("NavigationManager: built grid with ", astar.get_point_count(), " walkable tiles")

func get_nav_path(from_world: Vector2, to_world: Vector2, avoid_positions: Array = []) -> PackedVector2Array:
	if astar == null:
		return PackedVector2Array()
	# Temporarily disable tiles occupied by dynamic obstacles
	var disabled_ids: Array[int] = []
	for pos in avoid_positions:
		var tile: Vector2i = world_to_tile(pos)
		var idx: int = tile.y * map_width + tile.x
		if astar.has_point(idx) and not astar.is_point_disabled(idx):
			astar.set_point_disabled(idx, true)
			disabled_ids.append(idx)
	var from_id: int = astar.get_closest_point(from_world)
	var to_id: int = astar.get_closest_point(to_world)
	var path: PackedVector2Array
	if from_id < 0 or to_id < 0:
		path = PackedVector2Array()
	else:
		path = astar.get_point_path(from_id, to_id)
	# Re-enable
	for idx in disabled_ids:
		astar.set_point_disabled(idx, false)
	return path

func world_to_tile(world_pos: Vector2) -> Vector2i:
	var tx: int = int(world_pos.x / tile_size)
	var ty: int = int(world_pos.y / tile_size)
	return Vector2i(clampi(tx, 0, map_width - 1), clampi(ty, 0, map_height - 1))

func tile_to_world(tile_pos: Vector2i) -> Vector2:
	return Vector2(tile_pos.x * tile_size + tile_size * 0.5, tile_pos.y * tile_size + tile_size * 0.5)

func is_walkable(tile: Vector2i) -> bool:
	if tile.x < 0 or tile.x >= map_width or tile.y < 0 or tile.y >= map_height:
		return false
	return _walkable[tile.y * map_width + tile.x] == 0

func get_random_walkable_tile() -> Vector2i:
	# Pick a random walkable tile
	var attempts: int = 0
	while attempts < 500:
		var x: int = randi_range(0, map_width - 1)
		var y: int = randi_range(0, map_height - 1)
		if _walkable[y * map_width + x] == 0:
			return Vector2i(x, y)
		attempts += 1
	return Vector2i(70, 50)  # fallback center
