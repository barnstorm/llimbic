extends Sprite2D
## res://scripts/world_map.gd — World container.
##
## Formerly loaded the flat prerendered town_map.png as a single Sprite2D — the
## reason locations read as "static blobs" and objects were invisible. The town
## is now REAL tiles: scenes/world.tscn is baked from assets/the_ville.tmx by
## tools/build_world_tilemap.gd (one TileMapLayer per visual layer, native 32px).
##
## This node is kept as a Sprite2D only because scenes/main.tscn already types
## WorldMap that way; NO texture is set, so it is an invisible container that
## parents the tilemap instance plus the label/object overlays. See the plan at
## C:\Users\bill\.claude\plans\fancy-moseying-hellman.md.

const WORLD_SCENE: String = "res://scenes/world.tscn"
const LABELS_SCRIPT: String = "res://scripts/world_labels.gd"
const MARKERS_SCRIPT: String = "res://scripts/world_object_markers.gd"


func _ready() -> void:
	# Real tilemap (baked from the TMX; crisp at any zoom, real cells).
	var packed: PackedScene = load(WORLD_SCENE) as PackedScene
	if packed == null:
		push_error("WorldMap: cannot load %s — run tools/build_world_tilemap.gd first" % WORLD_SCENE)
	else:
		var inst: Node2D = packed.instantiate() as Node2D
		inst.name = "WorldTiles"
		add_child(inst)

	# Location name labels (toggle with L).
	var labels: Node2D = (load(LABELS_SCRIPT) as GDScript).new() as Node2D
	labels.name = "WorldLabels"
	add_child(labels)

	# Object markers (ovens, anvils, forge, baskets, ...).
	var markers: Node2D = (load(MARKERS_SCRIPT) as GDScript).new() as Node2D
	markers.name = "WorldObjectMarkers"
	add_child(markers)
