extends Node
## res://scripts/game_manager.gd

signal time_changed(hour: float)
signal day_changed(day: int)

@export var time_scale: float = 1.0
@export var start_hour: float = 6.0

var current_hour: float = 6.0
var current_day: int = 1

func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass
