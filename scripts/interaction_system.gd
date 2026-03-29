extends Node
## res://scripts/interaction_system.gd — Player interaction with nearby NPCs

const INTERACT_RANGE: float = 48.0  # pixels

var _player: Node = null

func _ready() -> void:
	# Find player after a frame (ensure scene is loaded)
	call_deferred("_find_player")

func _find_player() -> void:
	var main: Node = get_parent()
	if main:
		_player = main.get_node_or_null("Player")

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		_try_interact()

func _try_interact() -> void:
	if _player == null:
		return

	var closest_npc: Node = null
	var closest_dist: float = INTERACT_RANGE

	for npc in get_tree().get_nodes_in_group("npcs"):
		var dist: float = _player.global_position.distance_to(npc.global_position)
		if dist < closest_dist:
			closest_dist = dist
			closest_npc = npc

	if closest_npc and closest_npc.has_method("interact_with_player"):
		closest_npc.interact_with_player()
