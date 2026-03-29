extends Node
## res://scripts/navigation_manager.gd

signal navigation_ready

var astar: AStar2D
var tile_size: int = 32
var map_width: int = 140
var map_height: int = 100

func _ready() -> void:
	pass

func get_path_to_tile(from_tile: Vector2i, to_tile: Vector2i) -> PackedVector2Array:
	return PackedVector2Array()

func world_to_tile(world_pos: Vector2) -> Vector2i:
	return Vector2i()

func tile_to_world(tile_pos: Vector2i) -> Vector2:
	return Vector2()

func is_walkable(tile: Vector2i) -> bool:
	return false
