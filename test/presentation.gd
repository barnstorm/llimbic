extends SceneTree
## Presentation video — ~30s cinematic showcasing NPC town simulation
## Camera pans, zoom transitions, debug overlay, time progression

var _frame: int = 0
var _main: Node = null
var _camera: Camera2D = null
var _game_manager: Node = null
var _debug_overlay: Node = null
var _npcs: Array = []

# Camera control
var _cam_target: Vector2 = Vector2(2096, 800)
var _cam_pos: Vector2 = Vector2(2096, 800)
var _cam_zoom_target: float = 2.5
var _cam_zoom: float = 2.5
var _cam_speed: float = 3.0
var _initialized_cam: bool = false

# Keyframe system: [frame, target_pos, zoom, speed, description]
var _keyframes: Array = []
var _current_kf: int = 0

func _initialize() -> void:
	print("Presentation: Starting cinematic capture")

	# Load main scene
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	root.add_child(_main)

	# Build keyframe sequence (30 FPS, ~900 frames = 30 seconds)
	# Frame ranges and camera targets
	_keyframes = [
		# Opening: wide establishing shot of the town
		{"frame": 0, "pos": Vector2(2096, 800), "zoom": 1.8, "speed": 2.0},
		# Pan left to show western buildings (herbalist, courier)
		{"frame": 90, "pos": Vector2(800, 600), "zoom": 2.0, "speed": 2.5},
		# Pan to town square area
		{"frame": 180, "pos": Vector2(2096, 800), "zoom": 2.5, "speed": 2.5},
		# Zoom into an NPC (will be set dynamically)
		{"frame": 270, "pos": Vector2(2096, 800), "zoom": 4.0, "speed": 3.0},
		# Toggle debug overlay here (frame ~300)
		# Show debug overlay on selected NPC
		{"frame": 360, "pos": Vector2(2096, 800), "zoom": 3.5, "speed": 2.0},
		# Pan to eastern side (market, farm)
		{"frame": 480, "pos": Vector2(2800, 600), "zoom": 2.5, "speed": 2.5},
		# Speed up time, show NPCs adjusting
		{"frame": 570, "pos": Vector2(2096, 800), "zoom": 2.0, "speed": 2.0},
		# Close-up on NPC interaction area
		{"frame": 660, "pos": Vector2(1712, 464), "zoom": 3.5, "speed": 3.0},
		# Final wide shot
		{"frame": 780, "pos": Vector2(2096, 800), "zoom": 1.6, "speed": 2.0},
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

		# Start with moderate time speed for visible NPC activity
		if _game_manager:
			_game_manager.time_scale = 5.0

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

	# === Scripted events ===

	# Frame 270: Follow a specific NPC closely
	if _frame == 270 and _npcs.size() > 0:
		# Find an NPC that's walking (prefer courier or guard - they move a lot)
		var follow_npc: Node = _find_npc_by_role("Courier")
		if follow_npc == null and _npcs.size() > 0:
			follow_npc = _npcs[0]
		if follow_npc:
			_cam_target = follow_npc.global_position
			# Update the keyframe pos to track this NPC
			for kf in _keyframes:
				if kf["frame"] == 270:
					kf["pos"] = follow_npc.global_position

	# Frame 280-360: Track the NPC we're following
	if _frame >= 280 and _frame <= 360:
		var follow_npc: Node = _find_npc_by_role("Courier")
		if follow_npc == null and _npcs.size() > 0:
			follow_npc = _npcs[0]
		if follow_npc:
			_cam_target = follow_npc.global_position

	# Frame 300: Toggle debug overlay ON
	if _frame == 300:
		if _debug_overlay:
			_debug_overlay._active = true
			_debug_overlay.visible = true
			_debug_overlay._update_npc_indicators()
			print("Presentation: Debug overlay ON")

	# Frame 310: Select an NPC for the debug panel
	if _frame == 310:
		if _debug_overlay and _npcs.size() > 0:
			var target_npc: Node = _find_npc_by_role("Baker")
			if target_npc == null:
				target_npc = _npcs[0]
			_debug_overlay._selected_npc = target_npc
			print("Presentation: Selected NPC for debug: %s" % target_npc.npc_name)

	# Frame 450: Turn off debug overlay
	if _frame == 450:
		if _debug_overlay:
			_debug_overlay._active = false
			_debug_overlay.visible = false
			_debug_overlay._selected_npc = null
			print("Presentation: Debug overlay OFF")

	# Frame 570: Speed up time to show day progression
	if _frame == 570:
		if _game_manager:
			_game_manager.time_scale = 30.0
			print("Presentation: Fast-forward time (time_scale=30)")

	# Frame 660: Back to normal-ish speed for close-up
	if _frame == 660:
		if _game_manager:
			_game_manager.time_scale = 5.0

	# Frame 660-780: Track an NPC pair that might be close together
	if _frame >= 660 and _frame <= 750:
		var closest_pair = _find_closest_npc_pair()
		if closest_pair.size() == 2:
			var midpoint: Vector2 = (closest_pair[0].global_position + closest_pair[1].global_position) * 0.5
			_cam_target = midpoint

	# Frame 780: Turn on debug overlay briefly for final shot
	if _frame == 780:
		if _debug_overlay and _npcs.size() > 0:
			_debug_overlay._active = true
			_debug_overlay.visible = true
			_debug_overlay._update_npc_indicators()
			# Select a different NPC
			var npc: Node = _find_npc_by_role("Guard")
			if npc == null and _npcs.size() > 1:
				npc = _npcs[1]
			elif npc == null and _npcs.size() > 0:
				npc = _npcs[0]
			if npc:
				_debug_overlay._selected_npc = npc

	# Frame 860: Turn off debug for clean ending
	if _frame == 860:
		if _debug_overlay:
			_debug_overlay._active = false
			_debug_overlay.visible = false
			_debug_overlay._selected_npc = null

	return false  # Keep running — --quit-after handles exit

func _update_keyframe_target() -> void:
	# Find the active keyframe based on current frame
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
			if d < best_dist and d > 10.0:  # Not overlapping but close
				best_dist = d
				best_pair = [_npcs[i], _npcs[j]]
	return best_pair
