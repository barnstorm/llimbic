extends Sprite2D
## res://scripts/world_map.gd — Loads the town map texture

func _ready() -> void:
	texture = load("res://assets/img/town_map.png")
	centered = false
