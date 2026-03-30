extends Node
## res://scripts/occluder_system.gd — Autoload: extracts wall boundary segments from collision_map.png
## Uses edge detection to build line segments along wall boundaries.
## Provides spatial-grid queries for fast broad-phase lookups.

const TILE_SIZE: int = 32
const MAP_W: int = 140
const MAP_H: int = 100
const GRID_CELL: int = 10  # spatial grid cell size in tiles

var _segments: Array = []  # [{start: Vector2, end: Vector2, blocks_vision: bool, sound_damping: float, tags: Array}]
var _grid: Dictionary = {}  # Vector2i -> Array of segment indices
var _grid_cols: int = 0
var _grid_rows: int = 0
var _blocked: PackedByteArray  # 1=blocked, 0=walkable  (MAP_W * MAP_H)

func _ready() -> void:
	_grid_cols = ceili(float(MAP_W) / GRID_CELL)
	_grid_rows = ceili(float(MAP_H) / GRID_CELL)
	_extract_segments()
	print("OccluderSystem: loaded %d wall segments" % _segments.size())

func _extract_segments() -> void:
	# Load collision image
	var tex: Texture2D = load("res://assets/img/collision_map.png")
	if tex == null:
		push_error("OccluderSystem: cannot load collision_map.png")
		return
	var img: Image = tex.get_image()
	if img == null:
		push_error("OccluderSystem: cannot get image from collision_map.png")
		return

	# Build blocked array
	_blocked = PackedByteArray()
	_blocked.resize(MAP_W * MAP_H)
	for y in range(MAP_H):
		for x in range(MAP_W):
			var pixel: Color = img.get_pixel(x, y)
			_blocked[y * MAP_W + x] = 1 if pixel.r > 0.5 else 0

	# Edge detection: find horizontal and vertical wall boundary edges
	# A boundary exists between a blocked tile and an adjacent walkable tile (or map edge).
	# We merge collinear segments to reduce count.

	# --- Horizontal edges (between rows y and y+1) ---
	# Walk each row boundary and merge runs of identical edge direction.
	for y in range(MAP_H + 1):
		var run_start: int = -1
		for x in range(MAP_W):
			var above_blocked: bool = _is_blocked(x, y - 1)
			var below_blocked: bool = _is_blocked(x, y)
			var is_edge: bool = (above_blocked != below_blocked)
			if is_edge:
				if run_start < 0:
					run_start = x
			else:
				if run_start >= 0:
					_add_segment_tiles(Vector2(run_start, y), Vector2(x, y))
					run_start = -1
		if run_start >= 0:
			_add_segment_tiles(Vector2(run_start, y), Vector2(MAP_W, y))

	# --- Vertical edges (between columns x and x+1) ---
	for x in range(MAP_W + 1):
		var run_start: int = -1
		for y in range(MAP_H):
			var left_blocked: bool = _is_blocked(x - 1, y)
			var right_blocked: bool = _is_blocked(x, y)
			var is_edge: bool = (left_blocked != right_blocked)
			if is_edge:
				if run_start < 0:
					run_start = y
			else:
				if run_start >= 0:
					_add_segment_tiles(Vector2(x, run_start), Vector2(x, y))
					run_start = -1
		if run_start >= 0:
			_add_segment_tiles(Vector2(x, run_start), Vector2(x, MAP_H))

func _is_blocked(tx: int, ty: int) -> bool:
	if tx < 0 or tx >= MAP_W or ty < 0 or ty >= MAP_H:
		return true  # map edge acts as wall
	return _blocked[ty * MAP_W + tx] == 1

func _add_segment_tiles(tile_start: Vector2, tile_end: Vector2) -> void:
	## Convert tile-edge coordinates to world coordinates and register segment.
	var world_start: Vector2 = tile_start * TILE_SIZE
	var world_end: Vector2 = tile_end * TILE_SIZE
	var seg_idx: int = _segments.size()
	_segments.append({
		"start": world_start,
		"end": world_end,
		"blocks_vision": true,
		"sound_damping": 0.8,
		"tags": ["wall"],
	})
	# Insert into spatial grid cells the segment passes through
	_register_in_grid(seg_idx, world_start, world_end)

func _register_in_grid(seg_idx: int, ws: Vector2, we: Vector2) -> void:
	var cell_px: float = GRID_CELL * TILE_SIZE
	var min_x: int = clampi(int(minf(ws.x, we.x) / cell_px), 0, _grid_cols - 1)
	var max_x: int = clampi(int(maxf(ws.x, we.x) / cell_px), 0, _grid_cols - 1)
	var min_y: int = clampi(int(minf(ws.y, we.y) / cell_px), 0, _grid_rows - 1)
	var max_y: int = clampi(int(maxf(ws.y, we.y) / cell_px), 0, _grid_rows - 1)
	for cy in range(min_y, max_y + 1):
		for cx in range(min_x, max_x + 1):
			var key: Vector2i = Vector2i(cx, cy)
			if not _grid.has(key):
				_grid[key] = []
			_grid[key].append(seg_idx)

func get_occluders_in_rect(rect: Rect2) -> Array:
	## Return all unique segment dicts whose grid cells overlap `rect`.
	var cell_px: float = GRID_CELL * TILE_SIZE
	var min_cx: int = clampi(int(rect.position.x / cell_px), 0, _grid_cols - 1)
	var max_cx: int = clampi(int(rect.end.x / cell_px), 0, _grid_cols - 1)
	var min_cy: int = clampi(int(rect.position.y / cell_px), 0, _grid_rows - 1)
	var max_cy: int = clampi(int(rect.end.y / cell_px), 0, _grid_rows - 1)
	var seen: Dictionary = {}
	var result: Array = []
	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			var key: Vector2i = Vector2i(cx, cy)
			if _grid.has(key):
				for idx in _grid[key]:
					if not seen.has(idx):
						seen[idx] = true
						result.append(_segments[idx])
	return result

func get_segment_count() -> int:
	return _segments.size()

## Fast indexed access used by SensorSystem raycaster
func get_segment_indices_in_rect(rect: Rect2) -> Array:
	var cell_px: float = GRID_CELL * TILE_SIZE
	var min_cx: int = clampi(int(rect.position.x / cell_px), 0, _grid_cols - 1)
	var max_cx: int = clampi(int(rect.end.x / cell_px), 0, _grid_cols - 1)
	var min_cy: int = clampi(int(rect.position.y / cell_px), 0, _grid_rows - 1)
	var max_cy: int = clampi(int(rect.end.y / cell_px), 0, _grid_rows - 1)
	var seen: Dictionary = {}
	var result: Array = []
	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			var key: Vector2i = Vector2i(cx, cy)
			if _grid.has(key):
				for idx in _grid[key]:
					if not seen.has(idx):
						seen[idx] = true
						result.append(idx)
	return result

func get_segment(idx: int) -> Dictionary:
	if idx >= 0 and idx < _segments.size():
		return _segments[idx]
	return {}
