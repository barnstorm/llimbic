extends SceneTree
## test/test_6.gd — Test harness for Task 6: Object-Aware Planning & Social Object Knowledge

var _frame: int = 0
var _main_scene: Node = null
var _cam: Camera2D = null
var _npcs: Array = []
var _game_manager: Node = null
var _debug_overlay: Node = null
var _checked_plan_chunks: bool = false
var _checked_examine: bool = false
var _checked_social_prop: bool = false
var _checked_replanning: bool = false

func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/main.tscn")
	_main_scene = scene.instantiate()
	root.add_child(_main_scene)
	_cam = _main_scene.get_node_or_null("Camera2D")
	if _cam:
		_cam.position = Vector2(1712, 464)  # Start at bakery
		_cam.zoom = Vector2(3.0, 3.0)

	# Find autoloads
	for child in root.get_children():
		if child.name == "GameManager":
			_game_manager = child

func _process(delta: float) -> bool:
	_frame += 1

	# Let the simulation warm up for a few frames before checking
	if _frame == 5:
		_npcs = root.get_tree().get_nodes_in_group("npcs")
		print("[Test6] Found %d NPCs" % _npcs.size())

		# Speed up game time so things happen faster
		if _game_manager:
			_game_manager.time_scale = 15.0

		# Activate debug overlay
		_debug_overlay = _main_scene.get_node_or_null("DebugOverlay")
		if _debug_overlay:
			_debug_overlay._active = true
			_debug_overlay.visible = true

	# Frame 10: Check that plan chunks have object_id fields
	if _frame == 10 and not _checked_plan_chunks:
		_checked_plan_chunks = true
		var found_object_chunk: bool = false
		for npc in _npcs:
			if npc.brain == null or npc.brain.layer3 == null:
				continue
			for chunk in npc.brain.layer3.agenda:
				if chunk.get("object_id", "") != "":
					found_object_chunk = true
					print("[Test6] ASSERT PASS: Found object-targeting chunk in %s's plan: %s -> %s" % [npc.npc_name, chunk.get("purpose", "?"), chunk.get("object_id", "")])
					break
			if found_object_chunk:
				break
		if not found_object_chunk:
			print("[Test6] ASSERT FAIL: No NPC has an object-targeting plan chunk")

	# Frame 15: Select the Baker (Edith) for debug overlay and zoom camera to bakery
	if _frame == 15:
		if _cam:
			_cam.position = Vector2(1712, 464)
			_cam.zoom = Vector2(3.5, 3.5)
		for npc in _npcs:
			if npc.npc_name == "Edith":
				if _debug_overlay:
					_debug_overlay._selected_npc = npc
				break

	# Frame 30: Check object knowledge and discovery events
	if _frame == 30:
		var any_discovered: bool = false
		for npc in _npcs:
			if npc.brain == null or npc.brain.memory == null:
				continue
			var known: Dictionary = npc.brain.memory.known_objects
			if known.size() > 0:
				any_discovered = true
				print("[Test6] ASSERT PASS: %s knows %d objects" % [npc.npc_name, known.size()])
				# Check for problematic objects
				var problems: Array = npc.brain.memory.get_problematic_objects()
				if problems.size() > 0:
					print("[Test6] ASSERT PASS: %s knows about %d problematic objects" % [npc.npc_name, problems.size()])
					for p in problems:
						print("[Test6]   - %s at %s is %s" % [p["name"], p["location"], p["state"]])
		if not any_discovered:
			print("[Test6] ASSERT FAIL: No NPC has discovered any objects yet")

	# Frame 40-80: Check EXAMINE action has fired (keep trying)
	if _frame >= 40 and _frame <= 80 and _frame % 10 == 0 and not _checked_examine:
		for npc in _npcs:
			if npc.brain == null:
				continue
			if npc.brain._last_examine_times.size() > 0:
				_checked_examine = true
				print("[Test6] ASSERT PASS: %s has examined %d objects" % [npc.npc_name, npc.brain._last_examine_times.size()])
				break
		if _frame == 80 and not _checked_examine:
			print("[Test6] ASSERT FAIL: No NPC has examined objects after 80 frames")

	# Frame 50-90: Check for replanning due to problematic objects (keep trying)
	if _frame >= 50 and _frame <= 90 and _frame % 10 == 0 and not _checked_replanning:
		for npc in _npcs:
			if npc.brain == null or npc.brain.layer3 == null:
				continue
			for chunk in npc.brain.layer3.agenda:
				var purpose: String = chunk.get("purpose", "")
				if purpose.begins_with("Fix") or purpose.begins_with("Restock") or purpose.begins_with("Unlock"):
					_checked_replanning = true
					print("[Test6] ASSERT PASS: %s has replanned — injected chunk: '%s'" % [npc.npc_name, purpose])
					break
			if _checked_replanning:
				break
		if _frame == 90 and not _checked_replanning:
			print("[Test6] ASSERT FAIL: No NPC replanned due to object concerns")

	# Frame 55: Move camera to show two NPCs near each other (town square area)
	if _frame == 55:
		if _cam:
			_cam.position = Vector2(2096, 800)
			_cam.zoom = Vector2(3.0, 3.0)

	# Frame 70: Check social propagation of object knowledge
	if _frame == 70 and not _checked_social_prop:
		_checked_social_prop = true
		var any_secondhand: bool = false
		for npc in _npcs:
			if npc.brain == null or npc.brain.memory == null:
				continue
			for obj_id in npc.brain.memory.known_objects:
				var obj: Dictionary = npc.brain.memory.known_objects[obj_id]
				if obj.get("learned_from", "direct") != "direct":
					any_secondhand = true
					print("[Test6] ASSERT PASS: %s learned about %s from %s" % [npc.npc_name, obj["name"], obj["learned_from"]])
		if not any_secondhand:
			print("[Test6] INFO: No object knowledge shared via social propagation yet")

	# Frame 75: Check food object awareness in drive overrides
	if _frame == 75:
		var any_food_knowledge: bool = false
		for npc in _npcs:
			if npc.brain == null or npc.brain.memory == null:
				continue
			var food_objs: Array = npc.brain.memory.get_food_objects()
			if food_objs.size() > 0:
				any_food_knowledge = true
				print("[Test6] ASSERT PASS: %s knows %d food objects" % [npc.npc_name, food_objs.size()])
				break
		if not any_food_knowledge:
			print("[Test6] INFO: No NPC has food object knowledge yet")

	# Frame 80: Check object dialogue context
	if _frame == 80:
		for npc in _npcs:
			if npc.brain == null or npc.brain.memory == null:
				continue
			var ctx: String = npc.brain.memory.get_object_dialogue_context(npc.role)
			if ctx != "":
				print("[Test6] ASSERT PASS: %s has object dialogue context: %s" % [npc.npc_name, ctx])
				break

	# Frame 85: Zoom into Greta (Blacksmith) — she should discover the broken forge
	if _frame == 85:
		if _cam:
			_cam.position = Vector2(1168, 592)
			_cam.zoom = Vector2(3.5, 3.5)
		for npc in _npcs:
			if npc.npc_name == "Greta":
				if _debug_overlay:
					_debug_overlay._selected_npc = npc
				break

	# Final summary at frame 95
	if _frame == 95:
		print("[Test6] === Final Summary ===")
		for npc in _npcs:
			if npc.brain == null:
				continue
			var known_count: int = npc.brain.memory.known_objects.size() if npc.brain.memory else 0
			var examined_count: int = npc.brain._last_examine_times.size()
			var concern_count: int = npc.brain.memory.concerns.size() if npc.brain.memory else 0
			print("[Test6] %s (%s): %d known objects, %d examined, %d concerns" % [npc.npc_name, npc.role, known_count, examined_count, concern_count])

	return false
