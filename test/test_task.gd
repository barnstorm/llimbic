extends SceneTree
## Test harness for Task 1: World, Navigation & Characters

var _frame: int = 0
var _root: Node
var _scene: Node
var _camera: Camera2D
var _player: CharacterBody2D
var _game_manager: Node
var _nav_manager: Node

func _initialize() -> void:
	_root = get_root()

	# Load main scene
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_scene = main_scene.instantiate()
	_root.add_child(_scene)

	# Find key nodes
	_camera = _scene.get_node_or_null("Camera2D")
	_player = _scene.get_node_or_null("Player")

	# Find autoloads
	for child in _root.get_children():
		if child.name == "GameManager":
			_game_manager = child
		elif child.name == "NavigationManager":
			_nav_manager = child

	# Pre-position camera at player
	if _camera and _player:
		_camera.global_position = _player.global_position
		_camera.make_current()

	# Assertions
	if _player:
		print("ASSERT PASS: Player node exists")
	else:
		print("ASSERT FAIL: Player node missing")

	if _nav_manager and _nav_manager.astar:
		var count: int = _nav_manager.astar.get_point_count()
		print("ASSERT PASS: NavigationManager has ", count, " walkable tiles")
	else:
		print("ASSERT FAIL: NavigationManager or astar not ready")

	var npc_container = _scene.get_node_or_null("NPCs")
	if npc_container:
		var npc_count: int = npc_container.get_child_count()
		if npc_count == 8:
			print("ASSERT PASS: 8 NPCs spawned")
		else:
			print("ASSERT FAIL: Expected 8 NPCs, got ", npc_count)
	else:
		print("ASSERT FAIL: NPCs container missing")

	if _game_manager:
		print("ASSERT PASS: GameManager active, hour=", _game_manager.current_hour)
	else:
		print("ASSERT FAIL: GameManager not found")

func _process(delta: float) -> bool:
	_frame += 1

	# Simulate player movement for a few seconds to show the town
	if _frame >= 5 and _frame <= 20:
		Input.action_press(&"move_right")
	elif _frame == 21:
		Input.action_release(&"move_right")

	if _frame >= 25 and _frame <= 40:
		Input.action_press(&"move_down")
	elif _frame == 41:
		Input.action_release(&"move_down")

	# Speed up time so we can see time change
	if _game_manager and _frame == 1:
		_game_manager.time_scale = 30.0  # 30x speed for testing

	# Print time at certain frames
	if _frame == 30 and _game_manager:
		print("Time at frame 30: ", _game_manager.get_time_string())

	if _frame == 50 and _game_manager:
		print("Time at frame 50: ", _game_manager.get_time_string())

	# Check NPCs are moving after some time
	if _frame == 60:
		var npc_container = _scene.get_node_or_null("NPCs")
		if npc_container:
			var moving_count: int = 0
			for npc in npc_container.get_children():
				if npc is CharacterBody2D and npc.velocity.length() > 1.0:
					moving_count += 1
			if moving_count > 0:
				print("ASSERT PASS: ", moving_count, " NPCs are moving")
			else:
				print("ASSERT FAIL: No NPCs are moving at frame 60")

	return false  # Keep running (movie writer handles exit)
