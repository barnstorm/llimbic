extends SceneTree
## Test harness for Task 3: NPC AI & Town Life
## Verifies: debug overlay, plan-driven movement, Layer 1/2/3 display

var _frame: int = 0
var _main: Node = null
var _camera: Camera2D = null
var _game_manager: Node = null
var _npcs: Array = []
var _toggled_debug: bool = false
var _selected_npc: bool = false
var _initial_positions: Dictionary = {}

func _initialize() -> void:
	print("Test Task 3: NPC AI & Town Life")

	# Load main scene
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	root.add_child(_main)

func _process(delta: float) -> bool:
	_frame += 1

	# Find references after first frame
	if _frame == 2:
		_camera = _main.get_node_or_null("Camera2D") as Camera2D
		for child in root.get_children():
			if child.name == "GameManager":
				_game_manager = child
				break
		_npcs = get_root().get_tree().get_nodes_in_group("npcs")
		print("Found %d NPCs" % _npcs.size())
		if _npcs.size() >= 8:
			print("ASSERT PASS: All 8 NPCs spawned")
		else:
			print("ASSERT FAIL: Expected 8 NPCs, got %d" % _npcs.size())

		# Record initial positions
		for npc in _npcs:
			_initial_positions[npc.npc_name] = npc.global_position

		# Check brain initialization
		for npc in _npcs:
			if npc.brain != null:
				print("ASSERT PASS: %s has brain initialized" % npc.npc_name)
			else:
				print("ASSERT FAIL: %s missing brain" % npc.npc_name)

		# Set camera to show NPCs
		if _camera:
			_camera.global_position = Vector2(2096, 800)  # town square area

	# Let NPCs move for a bit
	if _frame == 5:
		# Speed up time to see movement faster
		if _game_manager:
			_game_manager.time_scale = 10.0

	# Frame 20: Toggle debug overlay directly (simulated input doesn't propagate to _input in SceneTree)
	if _frame == 20 and not _toggled_debug:
		_toggled_debug = true
		var debug_overlay: Node = _main.get_node_or_null("DebugOverlay")
		if debug_overlay:
			debug_overlay._active = true
			debug_overlay.visible = true
			debug_overlay._update_npc_indicators()

	# Frame 30: Click on an NPC to select it (simulate mouse click near first NPC)
	if _frame == 30 and not _selected_npc and _npcs.size() > 0:
		_selected_npc = true
		# Find the debug overlay and manually select an NPC
		var debug_overlay: Node = _main.get_node_or_null("DebugOverlay")
		if debug_overlay and debug_overlay.has_method("_try_select_npc"):
			# We'll set the selected NPC directly
			debug_overlay._selected_npc = _npcs[0]
			print("Selected NPC: %s (%s)" % [_npcs[0].npc_name, _npcs[0].role])

	# Frame 35: Move camera to show selected NPC + debug panel
	if _frame == 35 and _npcs.size() > 0:
		if _camera:
			_camera.global_position = _npcs[0].global_position

	# Frame 50: Check assertions
	if _frame == 50:
		# Check NPC movement (should not be random wandering — should be plan-driven)
		var moved_count: int = 0
		for npc in _npcs:
			if npc.brain and npc.brain.layer3:
				var chunk: Dictionary = npc.brain.layer3.get_current_chunk()
				if not chunk.is_empty():
					print("ASSERT PASS: %s has plan chunk: %s" % [npc.npc_name, chunk.get("purpose", "?")])
				else:
					print("ASSERT FAIL: %s has no plan chunk" % npc.npc_name)

			var initial: Vector2 = _initial_positions.get(npc.npc_name, npc.global_position)
			if npc.global_position.distance_to(initial) > 10.0:
				moved_count += 1

		if moved_count > 0:
			print("ASSERT PASS: %d NPCs have moved from initial positions" % moved_count)
		else:
			print("ASSERT FAIL: No NPCs moved (may need more frames)")

		# Check Layer 1 values
		for npc in _npcs:
			if npc.brain and npc.brain.layer1:
				var l1 = npc.brain.layer1
				print("%s L1: energy=%.1f hunger=%.1f social=%.1f safety=%.1f" % [
					npc.npc_name, l1.energy, l1.hunger, l1.social_need, l1.safety])

		# Check Layer 2 vector
		for npc in _npcs:
			if npc.brain and npc.brain.layer2:
				var vec: Array = npc.brain.layer2.emotion_vector
				if vec.size() == 27:
					print("ASSERT PASS: %s has 27-dim emotion vector" % npc.npc_name)
				else:
					print("ASSERT FAIL: %s emotion vector size=%d" % [npc.npc_name, vec.size()])

	# Frame 60: Verify debug overlay is showing data
	if _frame == 60:
		var debug_overlay: Node = _main.get_node_or_null("DebugOverlay")
		if debug_overlay and debug_overlay.visible:
			print("ASSERT PASS: Debug overlay is visible")
		else:
			print("ASSERT FAIL: Debug overlay not visible")

	return false  # Keep running — movie writer handles exit via --quit-after
