extends SceneTree
## tools/build_world_tilemap.gd — One-shot TMX → Godot TileMap baker.
##
## Replaces the flat prerendered world (assets/img/town_map.png, a single
## Sprite2D) with a REAL constructed tilemap so locations stop being "static
## blobs" and objects can be placed/labeled on a crisp native-resolution board.
##
## Parses assets/the_ville.tmx (orthogonal, 140×100 @ 32px, CSV layers) and
## bakes:
##   - res://tilesets/world_tileset.tres  — one shared TileSet (18 atlas sources)
##   - res://scenes/world.tscn            — one TileMapLayer per visual layer
## Reproduces town_map.png pixel-for-pixel but crisp at any zoom, and the tiles
## are real cells objects/labels can sit on.
##
## Run:  godot --headless --script res://tools/build_world_tilemap.gd
## Re-runnable (overwrites both outputs). No gameplay-coordinate data changes.
##
## Coordinate alignment: 32px tiles, origin top-left, map (0,0) at world (0,0) —
## identical to navigation_manager / world_label_system / camera limits, so the
## baked TileMapLayer drops in with zero offset. See MEMORY.md.
##
## System layers (Collisions, *Blocks, Spawning, Registry) are NOT rendered:
## collision already comes from collision_map.png (NavigationManager /
## OccluderSystem), and labels/blocks from WorldLabelSystem. No duplication.

const TMX_PATH: String = "res://assets/the_ville.tmx"
const TILESET_OUT: String = "res://tilesets/world_tileset.tres"
const SCENE_OUT: String = "res://scenes/world.tscn"
const TILE_PX: int = 32

# TMX flip flag bits encoded in the high part of each raw GID.
const FLIPPED_HORIZONTALLY: int = 0x80000000
const FLIPPED_VERTICALLY: int = 0x40000000
const FLIPPED_DIAGONALLY: int = 0x20000000
const GID_MASK: int = 0x1FFFFFFF

# All tile layers BELOW actors (z=0) so NPCs/player are never hidden behind
# ground or furniture. Visual stacking preserved within the tile group.
const Z_BASE: int = -20

# System layers we skip (collision/labels come from existing systems).
const SYSTEM_LAYERS: Dictionary = {
	"Collisions": true,
	"Object Interaction Blocks": true,
	"Arena Blocks": true,
	"Sector Blocks": true,
	"World Blocks": true,
	"Spawning Blocks": true,
	"Special Blocks Registry": true,
}

# --- Parsed TMX state ---
var _tilesets: Array = []  # [{firstgid, name, columns, tilecount, path}]
var _layers: Array = []    # [{name, w, h, data:PackedInt32Array}] in doc order
var _pending_tileset_idx: int = -1


func _initialize() -> void:
	print("[build_world] parsing TMX: %s" % TMX_PATH)
	_parse_tmx()
	if _tilesets.is_empty() or _layers.is_empty():
		push_error("[build_world] TMX parse yielded no tilesets/layers; aborting")
		quit(1)
		return
	_build()
	quit(0)


# --- TMX parsing ----------------------------------------------------------

func _parse_tmx() -> void:
	var parser: XMLParser = XMLParser.new()
	var err: int = parser.open(ProjectSettings.globalize_path(TMX_PATH))
	if err != OK:
		push_error("[build_world] cannot open TMX (err=%d)" % err)
		return

	var current_layer: Dictionary = {}
	var reading_data: bool = false
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n: String = parser.get_node_name()
				match n:
					"tileset":
						_pending_tileset_idx = _parse_tileset(parser)
					"image":
						_apply_image(parser)
					"layer":
						current_layer = _start_layer(parser)
					"data":
						reading_data = true
			XMLParser.NODE_TEXT:
				if reading_data:
					current_layer["_csv"] = String(current_layer.get("_csv", "")) + parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				var en: String = parser.get_node_name()
				if en == "data" and reading_data:
					reading_data = false
					_finalize_layer(current_layer)
					_layers.append(current_layer)
					current_layer = {}
				elif en == "tileset":
					_pending_tileset_idx = -1


func _attr(parser: XMLParser, name: String, fallback: String) -> String:
	for i in parser.get_attribute_count():
		if parser.get_attribute_name(i) == name:
			return parser.get_attribute_value(i)
	return fallback


func _parse_tileset(parser: XMLParser) -> int:
	var t: Dictionary = {
		"firstgid": int(_attr(parser, "firstgid", "0")),
		"name": _attr(parser, "name", ""),
		"columns": int(_attr(parser, "columns", "0")),
		"tilecount": int(_attr(parser, "tilecount", "0")),
		"path": "",
	}
	_tilesets.append(t)
	return _tilesets.size() - 1


func _apply_image(parser: XMLParser) -> void:
	# TMX image paths are obsolete map_assets/... subtrees; flatten to basename
	# under res://assets/tilesets/ (all 18 tilesets live there, verified).
	if _pending_tileset_idx < 0:
		return
	var src: String = _attr(parser, "source", "")
	if src == "":
		return
	var basename: String = src.get_file()
	var resolved: String = "res://assets/tilesets/" + basename
	if not ResourceLoader.exists(resolved) and not FileAccess.file_exists(resolved):
		push_warning("[build_world] tileset image missing: %s -> %s" % [src, resolved])
	_tilesets[_pending_tileset_idx]["path"] = resolved


func _start_layer(parser: XMLParser) -> Dictionary:
	return {
		"name": _attr(parser, "name", ""),
		"w": int(_attr(parser, "width", "0")),
		"h": int(_attr(parser, "height", "0")),
		"_csv": "",
	}


func _finalize_layer(layer: Dictionary) -> void:
	var data: PackedInt32Array = PackedInt32Array()
	for tok in String(layer["_csv"]).split(",", false):
		data.append(int(tok.strip_edges()))
	layer["data"] = data
	layer.erase("_csv")


# --- Build ----------------------------------------------------------------

func _build() -> void:
	var ts: TileSet = TileSet.new()
	ts.tile_size = Vector2i(TILE_PX, TILE_PX)

	# Build the firstgid → source map (sorted ascending for range resolution).
	var ts_map: Dictionary = {}  # firstgid -> {sid, columns, tilecount, name}
	var sorted_ts: Array = _tilesets.duplicate()
	sorted_ts.sort_custom(func(a, b): return int(a["firstgid"]) < int(b["firstgid"]))
	for t in sorted_ts:
		var tex_path: String = t["path"]
		if tex_path == "":
			push_warning("[build_world] skipping tileset with no image: %s" % t["name"])
			continue
		var tex: Texture2D = load(tex_path) as Texture2D
		if tex == null:
			push_error("[build_world] cannot load texture %s" % tex_path)
			continue
		var src: TileSetAtlasSource = TileSetAtlasSource.new()
		src.texture = tex
		src.texture_region_size = Vector2i(TILE_PX, TILE_PX)
		var sid: int = ts.add_source(src)
		ts_map[int(t["firstgid"])] = {
			"sid": sid,
			"columns": int(t["columns"]),
			"tilecount": int(t["tilecount"]),
			"name": t["name"],
		}

	var sorted_firstgids: Array = ts_map.keys()
	sorted_firstgids.sort()

	# Build a live node tree so TileMapLayer batching/internals flush before pack.
	var world_root: Node2D = Node2D.new()
	world_root.name = "WorldTiles"
	self.root.add_child(world_root)

	var created_tiles: Dictionary = {}  # sid -> {Vector2i: true}
	var alt_cache: Dictionary = {}      # "sid|ax,ay|mask" -> alt_id

	var visual_index: int = -1
	for layer in _layers:
		var lname: String = layer["name"]
		if SYSTEM_LAYERS.has(lname):
			continue
		visual_index += 1
		var tml: TileMapLayer = TileMapLayer.new()
		tml.name = _sanitized(lname)
		tml.tile_set = ts
		tml.z_index = Z_BASE + visual_index
		world_root.add_child(tml)
		tml.owner = world_root

		var count: int = 0
		var data: PackedInt32Array = layer["data"]
		var w: int = int(layer["w"])
		for i in data.size():
			var raw: int = int(data[i])
			if raw == 0:
				continue
			var flags: int = raw & ~GID_MASK
			var gid: int = raw & GID_MASK
			var found: Dictionary = _resolve_source(gid, sorted_firstgids, ts_map)
			if found.is_empty():
				continue
			var sid: int = int(found["sid"])
			var local: int = gid - int(found["firstgid"])
			var cols: int = int(found["columns"])
			if cols <= 0:
				continue
			var atlas: Vector2i = Vector2i(local % cols, local / cols)

			if not created_tiles.has(sid):
				created_tiles[sid] = {}
			if not created_tiles[sid].has(atlas):
				(ts.get_source(sid) as TileSetAtlasSource).create_tile(atlas)
				created_tiles[sid][atlas] = true

			var alt: int = 0
			var fh: bool = bool(flags & FLIPPED_HORIZONTALLY)
			var fv: bool = bool(flags & FLIPPED_VERTICALLY)
			var fd: bool = bool(flags & FLIPPED_DIAGONALLY)
			if fh or fv or fd:
				var mask: int = (1 if fh else 0) | (2 if fv else 0) | (4 if fd else 0)
				var key: String = "%d|%d,%d|%d" % [sid, atlas.x, atlas.y, mask]
				if alt_cache.has(key):
					alt = int(alt_cache[key])
				else:
					var asrc: TileSetAtlasSource = ts.get_source(sid) as TileSetAtlasSource
					alt = asrc.create_alternative_tile(atlas)
					var td: TileData = asrc.get_tile_data(atlas, alt)
					# TMX diagonal flip == Godot transpose; when transposed, the
					# h/v meaning swaps (standard libtiled mapping).
					if fd:
						td.transpose = true
						td.flip_h = fv
						td.flip_v = fh
					else:
						td.flip_h = fh
						td.flip_v = fv
					alt_cache[key] = alt

			var tx: int = i % w
			var ty: int = i / w
			tml.set_cell(Vector2i(tx, ty), sid, atlas, alt)
			count += 1

		tml.update_internals()
		print("[build_world] layer '%s' z=%d cells=%d" % [lname, Z_BASE + visual_index, count])

	# Persist TileSet (references tileset PNGs by path — no inline image data).
	var err1: int = ResourceSaver.save(ts, TILESET_OUT)
	if err1 != OK:
		push_error("[build_world] TileSet save failed (err=%d)" % err1)
	print("[build_world] saved TileSet -> %s (sources=%d)" % [TILESET_OUT, ts.get_source_count()])

	# Pack + save the scene (TileMapLayer.tile_map_data serializes as bytes).
	var packed: PackedScene = PackedScene.new()
	var pack_err: int = packed.pack(world_root)
	if pack_err != OK:
		push_error("[build_world] pack failed (err=%d)" % pack_err)
	var err2: int = ResourceSaver.save(packed, SCENE_OUT)
	if err2 != OK:
		push_error("[build_world] scene save failed (err=%d)" % err2)
	print("[build_world] saved scene -> %s (visual_layers=%d)" % [SCENE_OUT, visual_index + 1])

	# Self-verify: reload the saved scene and confirm cells survived serialization.
	var reloaded: PackedScene = load(SCENE_OUT) as PackedScene
	if reloaded != null:
		var inst: Node = reloaded.instantiate()
		var total: int = 0
		for child in inst.get_children():
			if child is TileMapLayer:
				total += (child as TileMapLayer).get_used_cells().size()
		print("[build_world] verify: reloaded scene has %d total placed cells across layers" % total)
		inst.queue_free()

	world_root.queue_free()


func _resolve_source(gid: int, sorted_firstgids: Array, ts_map: Dictionary) -> Dictionary:
	# Largest firstgid <= gid; then range-check against tilecount.
	var pick: int = -1
	for fg in sorted_firstgids:
		if int(fg) <= gid:
			pick = int(fg)
		else:
			break
	if pick < 0:
		return {}
	var entry: Dictionary = ts_map[pick]
	if gid >= pick + int(entry["tilecount"]):
		return {}
	entry["firstgid"] = pick
	return entry


func _sanitized(s: String) -> String:
	# Node names can't contain spaces / dots.
	return s.replace(" ", "_").replace(".", "_").trim_suffix("_")
