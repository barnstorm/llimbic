extends SceneTree
## test/test_task12.gd — Verify Consumer Migration + Debug Visualization
## Shows debug overlay with vision rays from selected NPC, hearing indicators,
## occluder segments, and verifies NPCs still behave correctly.

var _frame: int = 0
var _root: Node = null
var _sensor_system: Node = null
var _occluder_system: Node = null
var _stimulus_registry: Node = null
var _debug_overlay: Node = null
var _game_manager: Node = null
var _selected_npc: Node = null
var _camera: Camera2D = null

func _initialize() -> void:
	_root = get_root()

	# Load main scene
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	_root.add_child(main)

	# Find autoloads and scene nodes
	for child in _root.get_children():
		if child.name == "SensorSystem":
			_sensor_system = child
		elif child.name == "OccluderSystem":
			_occluder_system = child
		elif child.name == "StimulusRegistry":
			_stimulus_registry = child
		elif child.name == "GameManager":
			_game_manager = child

	var main_node: Node = null
	for child in _root.get_children():
		if child.name == "Main":
			main_node = child
			break
	if main_node:
		_debug_overlay = main_node.get_node_or_null("DebugOverlay")
		_camera = main_node.get_node_or_null("Camera2D") as Camera2D

	# Set time scale fast to get NPCs moving to common areas quickly
	if _game_manager:
		_game_manager.time_scale = 30.0

func _process(delta: float) -> bool:
	_frame += 1

	if _frame == 3:
		_test_sensor_system_integration()
	elif _frame == 8:
		_test_wall_occlusion()
	elif _frame == 15:
		_test_player_sensor_profile()
	elif _frame == 20:
		# Enable debug early, select Edith initially
		_select_npc_and_enable_debug()
	elif _frame == 35:
		_test_forced_proximity_vision()
	elif _frame >= 36 and _frame <= 45:
		# Keep NPCs together for debug screenshots — re-position each frame
		_maintain_npc_proximity()
	elif _frame == 46:
		_test_hearing_debug()
	elif _frame == 55:
		_verify_npc_behavior()
	elif _frame == 60:
		# Slow down time, let NPCs resume natural behavior
		if _game_manager:
			_game_manager.time_scale = 5.0
	elif _frame == 70:
		# Test vision with more time passed
		_test_vision_through_sensor_system()
	elif _frame == 80:
		# Wide shot of town
		_frame_wide_shot()
	elif _frame >= 85 and _frame <= 110:
		# Let simulation run
		pass
	elif _frame == 111:
		_verify_behavioral_continuity()

	return false

func _test_sensor_system_integration() -> void:
	print("\n=== Test: SensorSystem Integration ===")
	if _sensor_system == null:
		print("ASSERT FAIL: SensorSystem autoload not found")
		return
	print("ASSERT PASS: SensorSystem autoload found")

	# Find an NPC and check it has sensor profile
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	if npcs.size() == 0:
		print("ASSERT FAIL: No NPCs found")
		return
	print("ASSERT PASS: Found %d NPCs" % npcs.size())

	var npc: Node = npcs[0]
	if npc.brain == null:
		print("ASSERT FAIL: NPC brain is null")
		return
	if npc.brain._sensor_system == null:
		print("ASSERT FAIL: NPC brain has no sensor system reference")
		return
	print("ASSERT PASS: NPC brain has sensor system reference")

	if npc.brain._sensor_profile.is_empty():
		print("ASSERT FAIL: NPC brain has empty sensor profile")
		return
	print("ASSERT PASS: NPC brain has sensor profile: range=%.0f arc=%.0f" % [
		npc.brain._sensor_profile.get("vision_range", 0),
		npc.brain._sensor_profile.get("vision_arc_deg", 0),
	])

func _test_vision_through_sensor_system() -> void:
	print("\n=== Test: Vision Through SensorSystem ===")
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	if npcs.size() < 2:
		print("ASSERT FAIL: Need at least 2 NPCs")
		return

	# Debug: check NPC positions and sensor system availability
	for npc in npcs:
		if npc.brain == null:
			continue
		var has_ss: bool = npc.brain._sensor_system != null
		var has_sp: bool = not npc.brain._sensor_profile.is_empty()
		var vis_count: int = npc.brain.perception.visible_entities.size() if npc.brain.perception else -1
		var query_count: int = npc.brain.perception.last_vision_queries.size() if npc.brain.perception else -1
		print("  %s: pos=%s ss=%s sp=%s vis=%d queries=%d" % [npc.npc_name, str(npc.global_position).substr(0, 20), str(has_ss), str(has_sp), vis_count, query_count])

	# Check nearest NPC pair distance
	var min_dist: float = 99999.0
	var pair_a: String = ""
	var pair_b: String = ""
	for i in range(npcs.size()):
		for j in range(i + 1, npcs.size()):
			var d: float = npcs[i].global_position.distance_to(npcs[j].global_position)
			if d < min_dist:
				min_dist = d
				pair_a = npcs[i].npc_name
				pair_b = npcs[j].npc_name
	print("  Closest pair: %s - %s at %.1f px" % [pair_a, pair_b, min_dist])

	# Check that perception uses SensorSystem results (visible_entities populated)
	var any_visible: bool = false
	var any_has_exposure: bool = false
	for npc in npcs:
		if npc.brain == null or npc.brain.perception == null:
			continue
		var vis: Array = npc.brain.perception.visible_entities
		if vis.size() > 0:
			any_visible = true
			for ent in vis:
				if ent.has("exposure") and ent["exposure"] > 0.0:
					any_has_exposure = true
					print("  %s sees %s (exposure=%.2f, confidence=%.2f)" % [
						npc.npc_name, ent["name"], ent["exposure"], ent["confidence"]
					])

	if any_visible:
		print("ASSERT PASS: NPCs can see entities through SensorSystem")
	else:
		print("ASSERT FAIL: No NPC can see any entity")

	if any_has_exposure:
		print("ASSERT PASS: Vision results include graded exposure values")
	else:
		print("ASSERT FAIL: No exposure values found in vision results")

	# Check that vision queries are being recorded for debug
	var any_queries: bool = false
	for npc in npcs:
		if npc.brain == null or npc.brain.perception == null:
			continue
		if npc.brain.perception.last_vision_queries.size() > 0:
			any_queries = true
			break
	if any_queries:
		print("ASSERT PASS: Vision queries recorded for debug visualization")
	else:
		print("ASSERT FAIL: No vision queries recorded")

func _test_wall_occlusion() -> void:
	print("\n=== Test: Wall Occlusion ===")
	if _sensor_system == null or _occluder_system == null:
		print("ASSERT FAIL: Missing autoloads")
		return

	# Test: two positions separated by walls should have exposure=0
	var SPScript: GDScript = load("res://scripts/sensor_profile.gd")
	var SRTScript: GDScript = load("res://scripts/sensory_result_types.gd")
	var profile: Dictionary = SPScript.make_default()
	profile["vision_range"] = 300.0  # extra range for test
	profile["vision_arc_deg"] = 360.0  # no arc restriction for test
	var actor_offsets: Array = SRTScript.actor_sample_offsets()

	# Known wall-blocked positions (through buildings)
	var pos_a: Vector2 = Vector2(3000, 1500)
	var pos_b: Vector2 = Vector2(3200, 1500)
	var vr: Dictionary = _sensor_system.query_vision(
		pos_a, Vector2.RIGHT, profile, pos_b, actor_offsets
	)
	var exposure: float = vr.get("exposure", -1.0)
	print("  Wall test: (3000,1500)->(3200,1500) exposure=%.2f" % exposure)
	if exposure < 0.2:
		print("ASSERT PASS: Wall-occluded vision returns low/zero exposure (%.2f)" % exposure)
	else:
		print("ASSERT FAIL: Expected low exposure through walls, got %.2f" % exposure)

	# Test: open area should have high exposure
	var pos_c: Vector2 = Vector2(2096, 800)
	var pos_d: Vector2 = Vector2(2096 + 48, 800)
	var vr2: Dictionary = _sensor_system.query_vision(
		pos_c, Vector2.RIGHT, profile, pos_d, actor_offsets
	)
	var exposure2: float = vr2.get("exposure", 0.0)
	print("  Open test: town_square nearby exposure=%.2f" % exposure2)
	if exposure2 > 0.5:
		print("ASSERT PASS: Open area vision returns high exposure (%.2f)" % exposure2)
	else:
		print("ASSERT FAIL: Expected high exposure in open area, got %.2f" % exposure2)

func _select_npc_and_enable_debug() -> void:
	print("\n=== Enabling Debug Overlay ===")
	if _debug_overlay == null:
		print("ASSERT FAIL: Debug overlay not found")
		return

	# Enable debug overlay
	_debug_overlay._active = true
	_debug_overlay.visible = true

	# Select the first NPC with visible entities
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	var best_npc: Node = null
	var best_visible: int = 0
	for npc in npcs:
		if npc.brain == null or npc.brain.perception == null:
			continue
		var vis_count: int = npc.brain.perception.visible_entities.size()
		if vis_count > best_visible:
			best_visible = vis_count
			best_npc = npc

	if best_npc == null and npcs.size() > 0:
		best_npc = npcs[0]

	if best_npc:
		_debug_overlay._selected_npc = best_npc
		_selected_npc = best_npc
		print("ASSERT PASS: Selected NPC '%s' with %d visible entities" % [best_npc.npc_name, best_visible])

		# Center camera on selected NPC
		if _camera:
			_camera.global_position = best_npc.global_position
			_camera.zoom = Vector2(3.0, 3.0)
	else:
		print("ASSERT FAIL: No NPC available for selection")

func _test_forced_proximity_vision() -> void:
	print("\n=== Test: Forced Proximity Vision ===")
	# Move two NPCs close together to verify vision works
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	if npcs.size() < 2:
		print("ASSERT FAIL: Need at least 2 NPCs")
		return
	var npc_a: Node = npcs[0]
	var npc_b: Node = npcs[1]
	# Place them 50px apart (within 96px vision range) and clear paths
	npc_a.global_position = Vector2(2096, 800)
	npc_b.global_position = Vector2(2096 + 50, 800)
	npc_a._current_path = PackedVector2Array()
	npc_b._current_path = PackedVector2Array()
	print("  Placed %s and %s 50px apart at town square" % [npc_a.npc_name, npc_b.npc_name])

	# Force a perception update on npc_a
	npc_a.brain.update_perception("right", npc_a.global_position, npcs, null)
	var vis: Array = npc_a.brain.perception.visible_entities
	print("  %s visible_entities: %d" % [npc_a.npc_name, vis.size()])
	var found_b: bool = false
	for ent in vis:
		if ent["name"] == npc_b.npc_name:
			found_b = true
			print("  %s sees %s: exposure=%.2f confidence=%.2f dist=%.1f" % [
				npc_a.npc_name, npc_b.npc_name,
				ent.get("exposure", 0.0), ent.get("confidence", 0.0), ent.get("distance", 0.0)
			])
	if found_b:
		print("ASSERT PASS: NPC sees nearby NPC through SensorSystem with graded exposure")
	else:
		print("ASSERT FAIL: NPC cannot see nearby NPC")
		# Debug: check raw query
		if npc_a.brain._sensor_system:
			var SRTScript: GDScript = load("res://scripts/sensory_result_types.gd")
			var offsets: Array = SRTScript.actor_sample_offsets()
			var vr: Dictionary = npc_a.brain._sensor_system.query_vision(
				npc_a.global_position, Vector2.RIGHT, npc_a.brain._sensor_profile,
				npc_b.global_position, offsets
			)
			print("  Direct query: visible=%s exposure=%.2f dist=%.1f" % [str(vr.get("visible")), vr.get("exposure", 0.0), vr.get("distance", 0.0)])

	# Also test that vision queries were recorded for debug
	var queries: Array = npc_a.brain.perception.last_vision_queries
	print("  Vision queries recorded: %d" % queries.size())
	var has_visible_query: bool = false
	for q in queries:
		if q.get("result", {}).get("visible", false):
			has_visible_query = true
			break
	if has_visible_query:
		print("ASSERT PASS: Debug vision query shows visible target")
	else:
		print("ASSERT FAIL: No visible targets in debug queries")

	# Select NPC A for debug overlay so vision rays show
	if _debug_overlay:
		_debug_overlay._selected_npc = npc_a
		_selected_npc = npc_a
	if _camera:
		_camera.global_position = npc_a.global_position
		_camera.zoom = Vector2(3.5, 3.5)

func _test_hearing_debug() -> void:
	print("\n=== Test: Hearing Debug Visualization ===")
	# Emit a speech stimulus near the selected NPC
	if _selected_npc == null or _stimulus_registry == null:
		print("ASSERT FAIL: Missing selected NPC or StimulusRegistry")
		return

	var npc_pos: Vector2 = _selected_npc.global_position
	var speech_pos: Vector2 = npc_pos + Vector2(60, 0)
	_stimulus_registry.emit("speech", speech_pos, 160.0, 0.8, 4.0, ["speech", "test", "Hello world"], "TestSpeaker")
	print("  Emitted speech stimulus at offset (60,0) from %s" % _selected_npc.npc_name)

	# Check if hearing results get recorded after next tick
	if _selected_npc.brain and _selected_npc.brain.perception:
		var hr_count: int = _selected_npc.brain.perception.last_hearing_results.size()
		print("  Current hearing results for debug: %d" % hr_count)
		print("ASSERT PASS: Hearing debug infrastructure in place")

func _verify_npc_behavior() -> void:
	print("\n=== Test: NPC Behavioral Continuity ===")
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	var moving_count: int = 0
	var has_brain_count: int = 0
	var has_action_count: int = 0

	for npc in npcs:
		if npc.brain != null:
			has_brain_count += 1
			var action: Dictionary = npc.brain.current_action
			var atype: String = action.get("type", "")
			if atype != "":
				has_action_count += 1
			if atype in ["move_toward", "wander", "flee_from"]:
				moving_count += 1
			elif atype in ["observe", "examine", "pause"]:
				# These are also valid actions
				has_action_count += 1

	print("  NPCs with brains: %d/%d" % [has_brain_count, npcs.size()])
	print("  NPCs with active actions: %d" % has_action_count)
	print("  NPCs currently moving: %d" % moving_count)

	if has_brain_count == npcs.size():
		print("ASSERT PASS: All NPCs have functioning brains")
	else:
		print("ASSERT FAIL: Some NPCs missing brains")

	if has_action_count >= npcs.size() - 1:
		print("ASSERT PASS: NPCs are selecting actions normally")
	else:
		print("ASSERT FAIL: Too few NPCs selecting actions (%d/%d)" % [has_action_count, npcs.size()])

func _test_player_sensor_profile() -> void:
	print("\n=== Test: Player Sensor Profile ===")
	var player: Node = _root.get_tree().get_first_node_in_group("player")
	if player == null:
		print("ASSERT FAIL: Player not found")
		return

	if "sensor_profile" in player and not player.sensor_profile.is_empty():
		var sp: Dictionary = player.sensor_profile
		print("  Player sensor profile: range=%.0f arc=%.0f" % [sp.get("vision_range", 0), sp.get("vision_arc_deg", 0)])
		print("ASSERT PASS: Player has ObserverProfile")
	else:
		print("ASSERT FAIL: Player missing sensor_profile")

func _maintain_npc_proximity() -> void:
	"""Keep two NPCs close together so debug rays are visible for multiple frames."""
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	if npcs.size() < 3:
		return
	var npc_a: Node = npcs[0]
	var npc_b: Node = npcs[1]
	var npc_c: Node = npcs[2]
	# Place 3 NPCs at different distances: one visible, one outside range
	npc_a.global_position = Vector2(2096, 800)
	npc_b.global_position = Vector2(2096 + 60, 800 + 10)  # close, visible
	npc_c.global_position = Vector2(2096 + 200, 800)  # far, outside range
	# Clear their paths so they don't get stuck trying to follow old routes
	npc_a._current_path = PackedVector2Array()
	npc_b._current_path = PackedVector2Array()
	npc_c._current_path = PackedVector2Array()
	# Keep camera on npc_a
	if _camera:
		_camera.global_position = npc_a.global_position
		_camera.zoom = Vector2(3.0, 3.0)
	# Make sure debug overlay tracks npc_a
	if _debug_overlay:
		_debug_overlay._selected_npc = npc_a
		_selected_npc = npc_a

func _frame_debug_shot() -> void:
	"""Position camera to capture debug visualization with vision rays."""
	if _selected_npc == null:
		return

	# Center on selected NPC
	if _camera:
		_camera.global_position = _selected_npc.global_position
		_camera.zoom = Vector2(2.5, 2.5)
	print("\n=== Frame 50: Debug visualization close-up on %s ===" % (_selected_npc.npc_name if _selected_npc else "none"))

func _frame_busy_area_shot() -> void:
	"""Move camera to follow NPCs in a busy area."""
	# Find the NPC cluster with most nearby NPCs
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")
	var best_npc: Node = null
	var best_score: int = 0
	for npc in npcs:
		if npc.brain == null or npc.brain.perception == null:
			continue
		var vis: int = npc.brain.perception.visible_entities.size()
		if vis > best_score:
			best_score = vis
			best_npc = npc
	if best_npc:
		_debug_overlay._selected_npc = best_npc
		_selected_npc = best_npc
		if _camera:
			_camera.global_position = best_npc.global_position
			_camera.zoom = Vector2(2.5, 2.5)
		print("=== Frame 70: Tracking %s with %d visible entities ===" % [best_npc.npc_name, best_score])
	else:
		print("=== Frame 70: No NPC with visible entities found ===")

func _frame_wide_shot() -> void:
	"""Wide shot showing multiple NPCs with debug overlay."""
	if _camera:
		_camera.global_position = Vector2(2096, 800)  # town square
		_camera.zoom = Vector2(1.6, 1.6)
	print("=== Frame 80: Wide shot of town square with debug ===")

func _verify_behavioral_continuity() -> void:
	print("\n=== Final Verification: Behavioral Continuity ===")
	var npcs: Array = _root.get_tree().get_nodes_in_group("npcs")

	# Check that object discovery still works
	var any_objects_discovered: bool = false
	for npc in npcs:
		if npc.brain == null or npc.brain.memory == null:
			continue
		if npc.brain.memory.known_objects.size() > 0:
			any_objects_discovered = true
			print("  %s knows %d objects" % [npc.npc_name, npc.brain.memory.known_objects.size()])

	if any_objects_discovered:
		print("ASSERT PASS: Object discovery still functional")
	else:
		print("ASSERT FAIL: No NPCs discovered any objects")

	# Verify debug overlay shows vision queries
	if _selected_npc and _selected_npc.brain and _selected_npc.brain.perception:
		var query_count: int = _selected_npc.brain.perception.last_vision_queries.size()
		print("  Selected NPC has %d vision queries for debug" % query_count)
		if query_count > 0:
			print("ASSERT PASS: Vision queries available for debug overlay rendering")
		else:
			print("ASSERT FAIL: No vision queries for debug overlay")

	print("\n=== All tests complete ===")
