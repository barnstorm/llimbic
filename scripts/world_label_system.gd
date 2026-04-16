extends Node
## res://scripts/world_label_system.gd — Autoload: spatial label lookup from TMX block layers
## Parses the Smallville TMX special_blocks CSVs and block layers to provide
## hierarchical location awareness: world → sector → arena → game objects.
## Any world position can be resolved to "what is here" and "what objects are nearby."

const TILE_SIZE: int = 32
const MAP_WIDTH: int = 140
const MAP_HEIGHT: int = 100

# Spatial grids: tile coord (Vector2i) -> label string
var _sector_grid: Dictionary = {}   # Vector2i -> sector name
var _arena_grid: Dictionary = {}    # Vector2i -> arena name
var _object_grid: Dictionary = {}   # Vector2i -> object name
var _world_name: String = "the Ville"

# GID -> label mappings from CSVs
var _sector_labels: Dictionary = {}   # gid -> {world, sector}
var _arena_labels: Dictionary = {}    # gid -> {world, sector, arena}
var _object_labels: Dictionary = {}   # gid -> {world, sector_filter, object}

# Reverse lookups
var _sector_tiles: Dictionary = {}    # sector_name -> Array[Vector2i]
var _arena_tiles: Dictionary = {}     # "sector:arena" -> Array[Vector2i]
var _object_positions: Array = []     # [{name, position, sector, arena}]

# Stats
var _total_sectors: int = 0
var _total_arenas: int = 0
var _total_objects: int = 0

func _ready() -> void:
	_load_label_csvs()
	_apply_labels_from_tmx()
	print("[WorldLabels] %d sectors, %d arenas, %d objects loaded" % [_total_sectors, _total_arenas, _total_objects])

# --- Public API ---

func get_location_at(world_pos: Vector2) -> Dictionary:
	## Returns {world, sector, arena} for a world position.
	var tile: Vector2i = Vector2i(int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))
	return {
		"world": _world_name,
		"sector": _sector_grid.get(tile, ""),
		"arena": _arena_grid.get(tile, ""),
	}

func get_sector_at(world_pos: Vector2) -> String:
	var tile: Vector2i = Vector2i(int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))
	return _sector_grid.get(tile, "")

func get_arena_at(world_pos: Vector2) -> String:
	var tile: Vector2i = Vector2i(int(world_pos.x / TILE_SIZE), int(world_pos.y / TILE_SIZE))
	return _arena_grid.get(tile, "")

func get_objects_near(world_pos: Vector2, radius_px: float = 96.0) -> Array:
	## Returns all labeled game objects within radius of world_pos.
	## Each entry: {name, position, sector, arena, distance}
	var result: Array = []
	var r2: float = radius_px * radius_px
	for obj in _object_positions:
		var dist2: float = world_pos.distance_squared_to(obj["position"])
		if dist2 <= r2:
			var entry: Dictionary = obj.duplicate()
			entry["distance"] = sqrt(dist2)
			result.append(entry)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])
	return result

func get_objects_in_sector(sector_name: String) -> Array:
	## Returns all game objects within a named sector.
	var result: Array = []
	for obj in _object_positions:
		if obj["sector"] == sector_name:
			result.append(obj)
	return result

func get_visible_labels(world_pos: Vector2, facing: Vector2, range_px: float = 96.0, arc_deg: float = 90.0) -> Dictionary:
	## Returns what an NPC can "see" label-wise from their position and facing.
	## {sector, arena, objects: [{name, distance}]}
	var loc: Dictionary = get_location_at(world_pos)
	var half_arc: float = deg_to_rad(arc_deg * 0.5)

	var visible_objects: Array = []
	var r2: float = range_px * range_px
	for obj in _object_positions:
		var to_obj: Vector2 = obj["position"] - world_pos
		var dist2: float = to_obj.length_squared()
		if dist2 > r2 or dist2 < 1.0:
			continue
		# Arc check
		if facing.length_squared() > 0.01:
			var angle: float = acos(clampf(facing.dot(to_obj.normalized()), -1.0, 1.0))
			if angle > half_arc:
				continue
		visible_objects.append({
			"name": obj["name"],
			"distance": sqrt(dist2),
			"sector": obj["sector"],
			"arena": obj["arena"],
		})

	visible_objects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["distance"] < b["distance"])

	return {
		"world": loc["world"],
		"sector": loc["sector"],
		"arena": loc["arena"],
		"objects": visible_objects,
	}

func describe_location(world_pos: Vector2) -> String:
	## Human-readable description of what's at a position.
	var loc: Dictionary = get_location_at(world_pos)
	var parts: Array = []
	if loc["sector"] != "":
		parts.append(loc["sector"])
	if loc["arena"] != "":
		parts.append(loc["arena"])
	if parts.is_empty():
		return "outdoors"
	return ", ".join(parts)

func describe_visible(world_pos: Vector2, facing: Vector2, range_px: float = 96.0) -> String:
	## Human-readable description of what an NPC can see from their position.
	var vis: Dictionary = get_visible_labels(world_pos, facing, range_px)
	var parts: Array = []
	if vis["sector"] != "":
		parts.append("In %s" % vis["sector"])
	if vis["arena"] != "":
		parts.append("(%s)" % vis["arena"])
	var objs: Array = vis["objects"]
	if objs.size() > 0:
		var obj_names: Array = []
		for o in objs.slice(0, 5):
			obj_names.append(o["name"])
		parts.append("— can see: %s" % ", ".join(obj_names))
	if parts.is_empty():
		return "Outdoors, nothing notable nearby."
	return " ".join(parts)

func get_all_sectors() -> Array:
	## Returns list of all sector names.
	return _sector_tiles.keys()

func get_sector_center(sector_name: String) -> Vector2:
	## Returns the center world position of a sector.
	if not _sector_tiles.has(sector_name):
		return Vector2.ZERO
	var tiles: Array = _sector_tiles[sector_name]
	var sum_x: float = 0.0
	var sum_y: float = 0.0
	for t in tiles:
		sum_x += t.x
		sum_y += t.y
	var n: float = float(tiles.size())
	return Vector2((sum_x / n + 0.5) * TILE_SIZE, (sum_y / n + 0.5) * TILE_SIZE)

# --- Loading ---

func _load_label_csvs() -> void:
	var base_path: String = "res://assets/the_ville/special_blocks/"

	# World
	var world_csv: String = _read_csv(base_path + "world_blocks.csv")
	for line in world_csv.split("\n"):
		var parts: Array = _parse_csv_line(line)
		if parts.size() >= 2:
			_world_name = parts[1]

	# Sectors: gid, world, sector_name
	var sector_csv: String = _read_csv(base_path + "sector_blocks.csv")
	for line in sector_csv.split("\n"):
		var parts: Array = _parse_csv_line(line)
		if parts.size() >= 3:
			var gid: int = int(parts[0])
			_sector_labels[gid] = {"world": parts[1], "sector": parts[2]}

	# Arenas: gid, world, sector, arena_name
	var arena_csv: String = _read_csv(base_path + "arena_blocks.csv")
	for line in arena_csv.split("\n"):
		var parts: Array = _parse_csv_line(line)
		if parts.size() >= 4:
			var gid: int = int(parts[0])
			_arena_labels[gid] = {"world": parts[1], "sector": parts[2], "arena": parts[3]}

	# Game objects: gid, world, sector_filter (<all> = any sector), object_name
	var obj_csv: String = _read_csv(base_path + "game_object_blocks.csv")
	for line in obj_csv.split("\n"):
		var parts: Array = _parse_csv_line(line)
		if parts.size() >= 4:
			var gid: int = int(parts[0])
			_object_labels[gid] = {"world": parts[1], "sector_filter": parts[2], "object": parts[3]}

func _apply_labels_from_tmx() -> void:
	## Parse the TMX file and apply GID -> label mappings to tile positions.
	var tmx_path: String = "res://assets/the_ville.tmx"
	var file := FileAccess.open(tmx_path, FileAccess.READ)
	if file == null:
		push_error("WorldLabelSystem: Cannot open " + tmx_path)
		return
	var xml_text: String = file.get_as_text()
	file.close()

	var parser := XMLParser.new()
	if parser.open(tmx_path) != OK:
		push_error("WorldLabelSystem: Cannot parse " + tmx_path)
		return

	# We need to extract CSV data from specific layers by name
	var target_layers: Dictionary = {
		"Sector Blocks": _sector_labels,
		"Arena Blocks": _arena_labels,
		"Object Interaction Blocks": _object_labels,
	}

	var current_layer: String = ""
	var reading_data: bool = false
	var data_text: String = ""

	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node_name: String = parser.get_node_name()
				if node_name == "layer":
					current_layer = ""
					for i in range(parser.get_attribute_count()):
						if parser.get_attribute_name(i) == "name":
							current_layer = parser.get_attribute_value(i)
				elif node_name == "data" and current_layer in target_layers:
					reading_data = true
					data_text = ""
			XMLParser.NODE_TEXT:
				if reading_data:
					data_text += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				if parser.get_node_name() == "data" and reading_data:
					reading_data = false
					_process_layer_data(current_layer, data_text.strip_edges(), target_layers[current_layer])
					current_layer = ""

func _process_layer_data(layer_name: String, csv_data: String, labels: Dictionary) -> void:
	var tiles: PackedInt32Array = PackedInt32Array()
	for val in csv_data.split(","):
		tiles.append(int(val.strip_edges()))

	for i in range(tiles.size()):
		var gid: int = tiles[i]
		if gid == 0 or not labels.has(gid):
			continue
		var tx: int = i % MAP_WIDTH
		var ty: int = i / MAP_WIDTH
		var tile_pos: Vector2i = Vector2i(tx, ty)
		var label_data: Dictionary = labels[gid]

		if layer_name == "Sector Blocks":
			var sector_name: String = label_data["sector"]
			_sector_grid[tile_pos] = sector_name
			if not _sector_tiles.has(sector_name):
				_sector_tiles[sector_name] = []
				_total_sectors += 1
			_sector_tiles[sector_name].append(tile_pos)

		elif layer_name == "Arena Blocks":
			var arena_name: String = label_data["arena"]
			_arena_grid[tile_pos] = arena_name
			var arena_key: String = label_data["sector"] + ":" + arena_name
			if not _arena_tiles.has(arena_key):
				_arena_tiles[arena_key] = []
				_total_arenas += 1
			_arena_tiles[arena_key].append(tile_pos)

		elif layer_name == "Object Interaction Blocks":
			var obj_name: String = label_data["object"]
			_object_grid[tile_pos] = obj_name
			# Resolve sector/arena from position
			var sector: String = _sector_grid.get(tile_pos, "")
			var arena: String = _arena_grid.get(tile_pos, "")
			var world_pos: Vector2 = Vector2((tx + 0.5) * TILE_SIZE, (ty + 0.5) * TILE_SIZE)
			_object_positions.append({
				"name": obj_name,
				"position": world_pos,
				"sector": sector,
				"arena": arena,
				"tile": tile_pos,
			})
			_total_objects += 1

func _read_csv(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("WorldLabelSystem: Cannot read " + path)
		return ""
	return file.get_as_text()

func _parse_csv_line(line: String) -> Array:
	## Parse a CSV line, trimming whitespace from each field.
	var raw: Array = line.split(",")
	var result: Array = []
	for part in raw:
		var trimmed: String = part.strip_edges()
		if trimmed != "":
			result.append(trimmed)
	return result
