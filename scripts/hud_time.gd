extends Label
## res://scripts/hud_time.gd — Updates time display from GameManager

var _game_manager: Node = null

func _ready() -> void:
	for child in get_tree().root.get_children():
		if child.name == "GameManager":
			_game_manager = child
			break

func _process(_delta: float) -> void:
	if _game_manager and _game_manager.has_method("get_time_string"):
		text = _game_manager.get_time_string()
