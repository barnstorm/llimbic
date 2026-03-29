extends SceneTree
## Presentation video — ~30s cinematic showcasing the object knowledge system
## Camera pans, zoom transitions, debug overlay with object knowledge,
## object discovery, social propagation of object knowledge, replanning

var _frame: int = 0
var _main: Node = null
var _camera: Camera2D = null
var _game_manager: Node = null
var _debug_overlay: Node = null
var _npcs: Array = []

# Camera control
var _cam_target: Vector2 = Vector2(1168, 592)
var _cam_pos: Vector2 = Vector2(1168, 592)
var _cam_zoom_target: float = 2.5
var _cam_zoom: float = 2.5
var _cam_speed: float = 3.0
var _initialized_cam: bool = false

# Keyframe system
var _keyframes: Array = []
var _current_kf: int = 0

func _initialize() -> void:
	print("Presentation: Starting object knowledge cinematic")

	# Load main scene
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	root.add_child(_main)

	# Keyframe sequence (30 FPS, ~900 frames = 30 seconds)
	# Phase 1 (0-180): Establishing shot, pan to blacksmith (Greta has broken forge)
	# Phase 2 (180-360): Zoom into Greta arriving at blacksmith, debug overlay ON showing object discovery
	# Phase 3 (360-480): Show debug overlay with Known Objects section populated + EXAMINE action
	# Phase 4 (480-600): Pan to two NPCs near each other, show social propagation of object knowledge
	# Phase 5 (600-750): Fast-forward to show replanning triggered by object discovery
	# Phase 6 (750-900): Final wide shot with debug overlay showing plan with object-targeting chunks
	_keyframes = [
		# Opening: wide establishing shot centered on town
		{"frame": 0, "pos": Vector2(2096, 800), "zoom": 1.6, "speed": 2.0},
		# Pan toward blacksmith area (Greta discovers broken forge)
		{"frame": 90, "pos": Vector2(1168, 592), "zoom": 2.2, "speed": 2.5},
		# Zoom into blacksmith closely
		{"frame": 180, "pos": Vector2(1168, 592), "zoom": 3.8, "speed": 3.0},
		# Hold on blacksmith with debug overlay showing objects
		{"frame": 270, "pos": Vector2(1168, 592), "zoom": 3.5, "speed": 2.0},
		# Pan to bakery area (Edith discovers empty bread basket)
		{"frame": 360, "pos": Vector2(1712, 464), "zoom": 3.5, "speed": 2.5},
		# Pan toward town center to catch NPC pair for social propagation
		{"frame": 480, "pos": Vector2(2096, 800), "zoom": 3.0, "speed": 2.5},
		# Fast-forward: show replanning in action
		{"frame": 600, "pos": Vector2(2096, 800), "zoom": 2.0, "speed": 2.0},
		# Zoom in on another NPC with object-aware plan
		{"frame": 700, "pos": Vector2(2096, 624), "zoom": 3.5, "speed": 3.0},
		# Final wide establishing shot
		{"frame": 800, "pos": Vector2(2096, 800), "zoom": 1.6, "speed": 2.0},
	]

	# Pre-position camera (quirk: frame 0 renders before _process)
	_cam_pos = _keyframes[0]["pos"]
	_cam_zoom = _keyframes[0]["zoom"]

func _process(delta: float) -> bool:
	_frame += 1

	# Frame 2: grab references (autoloads ready after first frame)
	if _frame == 2:
		_camera = _main.get_node_or_null("Camera2D") as Camera2D
		_debug_overlay = _main.get_node_or_null("DebugOverlay")
		for child in root.get_children():
			if child.name == "GameManager":
				_game_manager = child
				break
		_npcs = root.get_tree().get_nodes_in_group("npcs")
		print("Presentation: Found %d NPCs, camera=%s" % [_npcs.size(), str(_camera != null)])

		# Moderate time speed so NPCs move and discover objects
		if _game_manager:
			_game_manager.time_scale = 8.0

		# Boost social need on all NPCs so conversations trigger more reliably
		for npc in _npcs:
			if npc.brain and npc.brain.layer1:
				npc.brain.layer1.social_need = 60.0

		# Snap camera on first real frame
		if _camera:
			_camera.position = _cam_pos
			_camera.zoom = Vector2(_cam_zoom, _cam_zoom)
			_initialized_cam = true

	if _camera == null:
		return false

	# Ensure our camera stays current
	if not _camera.is_current():
		_camera.make_current()

	# Update keyframe target
	_update_keyframe_target()

	# Smooth camera interpolation
	_cam_pos = _cam_pos.lerp(_cam_target, _cam_speed * delta)
	_cam_zoom = lerpf(_cam_zoom, _cam_zoom_target, 2.0 * delta)
	_camera.position = _cam_pos
	_camera.zoom = Vector2(_cam_zoom, _cam_zoom)

	# === Scripted Events ===

	# Phase 2 (frame 180): Turn on debug overlay and select Greta (Blacksmith - broken forge)
	if _frame == 180:
		if _debug_overlay:
			_debug_overlay._active = true
			_debug_overlay.visible = true
			_debug_overlay._update_npc_indicators()
			print("Presentation: Debug overlay ON — object discovery phase")

	# Frame 195: Select Greta (Blacksmith) to show broken forge discovery
	if _frame == 195:
		if _debug_overlay and _npcs.size() > 0:
			var greta: Node = _find_npc_by_role("Blacksmith")
			if greta:
				_debug_overlay._selected_npc = greta
				print("Presentation: Selected Greta (Blacksmith) — shows broken Forge in objects")

	# Frame 180-340: Track Greta closely to show her at the blacksmith
	if _frame >= 180 and _frame <= 340:
		var greta: Node = _find_npc_by_role("Blacksmith")
		if greta:
			_cam_target = greta.global_position

	# Phase 3 (frame 360): Switch to Baker (Edith) to show empty bread basket
	if _frame == 360:
		if _debug_overlay and _npcs.size() > 0:
			var edith: Node = _find_npc_by_role("Baker")
			if edith:
				_debug_overlay._selected_npc = edith
				print("Presentation: Selected Edith (Baker) — shows empty Bread Basket")

	# Frame 360-470: Track Edith at the bakery
	if _frame >= 360 and _frame <= 470:
		var edith: Node = _find_npc_by_role("Baker")
		if edith:
			_cam_target = edith.global_position

	# Phase 4 (frame 480): Look for two NPCs near each other for social propagation
	# Use slower time scale so conversation pulses have more real time to fire
	if _frame == 480:
		if _game_manager:
			_game_manager.time_scale = 3.0  # Slow down so social propagation has time

	# Frame 480-590: Track the closest NPC pair or any conversing pair
	if _frame >= 480 and _frame <= 590:
		# Prefer NPCs currently in conversation (speech bubble visible)
		var convo_pair = _find_conversing_pair()
		if convo_pair.size() == 2:
			var midpoint: Vector2 = (convo_pair[0].global_position + convo_pair[1].global_position) * 0.5
			_cam_target = midpoint
		else:
			var closest_pair = _find_closest_npc_pair()
			if closest_pair.size() == 2:
				var midpoint: Vector2 = (closest_pair[0].global_position + closest_pair[1].global_position) * 0.5
				_cam_target = midpoint

	# Frame 500: Select one of the pair NPCs to show object knowledge propagation
	if _frame == 500:
		var convo_pair = _find_conversing_pair()
		if convo_pair.size() == 0:
			convo_pair = _find_closest_npc_pair()
		if convo_pair.size() == 2 and _debug_overlay:
			# Select the NPC with more known objects (likely received second-hand knowledge)
			var npc_a = convo_pair[0]
			var npc_b = convo_pair[1]
			var count_a: int = 0
			var count_b: int = 0
			if npc_a.brain and npc_a.brain.memory:
				count_a = npc_a.brain.memory.known_objects.size()
			if npc_b.brain and npc_b.brain.memory:
				count_b = npc_b.brain.memory.known_objects.size()
			var selected: Node = npc_b if count_b >= count_a else npc_a
			_debug_overlay._selected_npc = selected
			print("Presentation: Selected %s for social propagation view (knows %d objects)" % [selected.npc_name, maxi(count_a, count_b)])

	# Phase 5 (frame 600): Fast-forward time to show replanning from object discovery
	if _frame == 600:
		if _game_manager:
			_game_manager.time_scale = 30.0
			print("Presentation: Fast-forward (time_scale=30) — replanning from object discovery")

	# Frame 620: Select an NPC with object-targeting plan chunk
	if _frame == 620:
		if _debug_overlay:
			# Prefer Greta (broken forge should trigger replan) or Edith (empty basket)
			var target: Node = _find_npc_with_object_plan()
			if target == null:
				target = _find_npc_by_role("Blacksmith")
			if target == null:
				target = _find_npc_by_role("Baker")
			if target == null and _npcs.size() > 0:
				target = _npcs[0]
			if target:
				_debug_overlay._selected_npc = target
				print("Presentation: Selected %s — showing object-aware plan chunks" % target.npc_name)

	# Phase 5 continued (frame 700): Back to normal speed, zoom on inn area
	if _frame == 700:
		if _game_manager:
			_game_manager.time_scale = 8.0

	# Frame 700-790: Track the selected NPC or Hugo (Innkeeper with empty ale barrel)
	if _frame >= 700 and _frame <= 790:
		var hugo: Node = _find_npc_by_role("Innkeeper")
		if hugo:
			_cam_target = hugo.global_position
			if _frame == 710 and _debug_overlay:
				_debug_overlay._selected_npc = hugo
				print("Presentation: Selected Hugo (Innkeeper) — empty Ale Barrel")

	# Phase 6 (frame 800): Final wide shot
	if _frame == 800:
		if _debug_overlay:
			# Keep overlay on for the ending — shows the full system
			var best: Node = _find_npc_with_most_objects()
			if best and _debug_overlay:
				_debug_overlay._selected_npc = best
				print("Presentation: Final shot — %s knows %d objects" % [best.npc_name, best.brain.memory.known_objects.size() if best.brain and best.brain.memory else 0])

	# Frame 870: Turn off debug overlay for clean ending
	if _frame == 870:
		if _debug_overlay:
			_debug_overlay._active = false
			_debug_overlay.visible = false
			_debug_overlay._selected_npc = null
			print("Presentation: Debug overlay OFF — clean ending")

	return false  # Keep running — --quit-after handles exit

func _update_keyframe_target() -> void:
	var active_kf: int = 0
	for i in range(_keyframes.size()):
		if _frame >= _keyframes[i]["frame"]:
			active_kf = i
	var kf: Dictionary = _keyframes[active_kf]
	_cam_target = kf["pos"]
	_cam_zoom_target = kf["zoom"]
	_cam_speed = kf["speed"]

func _find_npc_by_role(target_role: String) -> Node:
	for npc in _npcs:
		if npc.role == target_role:
			return npc
	return null

func _find_closest_npc_pair() -> Array:
	var best_dist: float = 99999.0
	var best_pair: Array = []
	for i in range(_npcs.size()):
		for j in range(i + 1, _npcs.size()):
			var d: float = _npcs[i].global_position.distance_to(_npcs[j].global_position)
			if d < best_dist and d > 10.0:
				best_dist = d
				best_pair = [_npcs[i], _npcs[j]]
	return best_pair

func _find_conversing_pair() -> Array:
	"""Find two NPCs that are currently in conversation (externally locked and near each other)."""
	var locked: Array = []
	for npc in _npcs:
		if npc._externally_locked:
			locked.append(npc)
	if locked.size() >= 2:
		# Return the closest locked pair
		var best_dist: float = 99999.0
		var best_pair: Array = []
		for i in range(locked.size()):
			for j in range(i + 1, locked.size()):
				var d: float = locked[i].global_position.distance_to(locked[j].global_position)
				if d < best_dist:
					best_dist = d
					best_pair = [locked[i], locked[j]]
		return best_pair
	return []

func _find_npc_with_object_plan() -> Node:
	"""Find an NPC whose current plan chunk targets a specific object."""
	for npc in _npcs:
		if npc.brain == null or npc.brain.layer3 == null:
			continue
		var l3 = npc.brain.layer3
		var agenda: Array = l3.agenda
		var idx: int = l3.current_chunk_index
		if idx >= 0 and idx < agenda.size():
			var chunk: Dictionary = agenda[idx]
			if chunk.get("object_id", "") != "":
				return npc
	# Fallback: check any chunk in any NPC's agenda
	for npc in _npcs:
		if npc.brain == null or npc.brain.layer3 == null:
			continue
		for chunk in npc.brain.layer3.agenda:
			if chunk.get("object_id", "") != "":
				return npc
	return null

func _find_npc_with_most_objects() -> Node:
	"""Find the NPC that knows about the most world objects."""
	var best: Node = null
	var best_count: int = -1
	for npc in _npcs:
		if npc.brain == null or npc.brain.memory == null:
			continue
		var count: int = npc.brain.memory.known_objects.size()
		if count > best_count:
			best_count = count
			best = npc
	return best
