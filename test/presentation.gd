extends SceneTree
## Presentation video — ~30s cinematic showcasing the shared perception system
## Vision raycasting with green/red rays, occlusion, hearing attenuation,
## occluder segments, exposure/confidence debug panel, smooth camera transitions

var _frame: int = 0
var _main: Node = null
var _camera: Camera2D = null
var _game_manager: Node = null
var _debug_overlay: Node = null
var _stimulus_registry: Node = null
var _sensor_system: Node = null
var _npcs: Array = []

# Camera control
var _cam_target: Vector2 = Vector2(2096, 800)
var _cam_pos: Vector2 = Vector2(2096, 800)
var _cam_zoom_target: float = 2.0
var _cam_zoom: float = 2.0
var _cam_speed: float = 3.0

# Keyframe system
var _keyframes: Array = []

# Phase tracking
var _observer_npc: Node = null

func _initialize() -> void:
	print("Presentation: Starting perception system cinematic")
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	_main = main_scene.instantiate()
	root.add_child(_main)

	# Keyframe sequence (30 FPS, ~900 frames = 30 seconds)
	# Phase 1 (0-150):   Wide shot with occluder segments visible on buildings
	# Phase 2 (150-330):  Zoom to NPC cluster — green vision rays to visible targets
	# Phase 3 (330-500):  NPC behind wall — red blocked rays + exposure drops to 0
	# Phase 4 (500-660):  Hearing: speech stimulus, arcs, volume meters
	# Phase 5 (660-810):  Close-up debug panel with changing exposure/confidence
	# Phase 6 (810-900):  Wide pullback, clean ending
	_keyframes = [
		{"frame": 0,   "pos": Vector2(2096, 800), "zoom": 1.5, "speed": 2.0},
		{"frame": 100, "pos": Vector2(2096, 720), "zoom": 2.0, "speed": 2.0},
		# Phase 2: zoom to NPC cluster near town square
		{"frame": 150, "pos": Vector2(2096, 720), "zoom": 3.4, "speed": 2.5},
		{"frame": 280, "pos": Vector2(2096, 720), "zoom": 3.6, "speed": 1.5},
		# Phase 3: pan to building edge — occlusion demo
		{"frame": 330, "pos": Vector2(1800, 520), "zoom": 3.4, "speed": 2.5},
		{"frame": 460, "pos": Vector2(1800, 520), "zoom": 3.6, "speed": 1.5},
		# Phase 4: hearing demo
		{"frame": 500, "pos": Vector2(2096, 720), "zoom": 3.2, "speed": 2.5},
		{"frame": 630, "pos": Vector2(2096, 720), "zoom": 3.5, "speed": 1.5},
		# Phase 5: close on exposure values
		{"frame": 660, "pos": Vector2(2096, 720), "zoom": 3.8, "speed": 2.5},
		{"frame": 780, "pos": Vector2(2096, 720), "zoom": 3.6, "speed": 1.5},
		# Phase 6: pull back
		{"frame": 810, "pos": Vector2(2096, 800), "zoom": 1.8, "speed": 2.0},
		{"frame": 870, "pos": Vector2(2096, 800), "zoom": 1.5, "speed": 1.5},
	]

	_cam_pos = _keyframes[0]["pos"]
	_cam_zoom = _keyframes[0]["zoom"]

func _process(delta: float) -> bool:
	_frame += 1

	# Frame 2: grab references
	if _frame == 2:
		_camera = _main.get_node_or_null("Camera2D") as Camera2D
		_debug_overlay = _main.get_node_or_null("DebugOverlay")
		for child in root.get_children():
			if child.name == "GameManager":
				_game_manager = child
			elif child.name == "StimulusRegistry":
				_stimulus_registry = child
			elif child.name == "SensorSystem":
				_sensor_system = child
		_npcs = root.get_tree().get_nodes_in_group("npcs")
		print("Presentation: Found %d NPCs" % _npcs.size())

		if _game_manager:
			_game_manager.time_scale = 5.0

		if _camera:
			_camera.position = _cam_pos
			_camera.zoom = Vector2(_cam_zoom, _cam_zoom)

		# Position NPCs for perception demo
		_setup_npc_positions()

	if _camera == null:
		return false

	if not _camera.is_current():
		_camera.make_current()

	_update_keyframe_target()

	# Smooth camera interpolation
	_cam_pos = _cam_pos.lerp(_cam_target, _cam_speed * delta)
	_cam_zoom = lerpf(_cam_zoom, _cam_zoom_target, 2.0 * delta)
	_camera.position = _cam_pos
	_camera.zoom = Vector2(_cam_zoom, _cam_zoom)

	# === PHASE 1 (0-150): Occluder segments visible, wide establishing shot ===
	if _frame == 5:
		if _debug_overlay:
			_debug_overlay._active = true
			_debug_overlay.visible = true
			_debug_overlay._update_npc_indicators()
			print("Presentation: Debug overlay ON — occluder segments visible")

	# === PHASE 2 (150-330): Vision rays demo — green rays to visible targets ===
	if _frame == 150:
		# Select Guard (Roland) who has nearby NPCs in his FOV
		_observer_npc = _find_npc_by_role("Guard")
		if _observer_npc == null and _npcs.size() > 0:
			_observer_npc = _npcs[0]
		if _observer_npc and _debug_overlay:
			_debug_overlay._selected_npc = _observer_npc
			print("Presentation: Selected %s for green vision rays" % _observer_npc.npc_name)

	# Keep NPCs in cluster during phase 2 for reliable vision rays
	if _frame >= 150 and _frame < 330:
		_maintain_cluster(Vector2(2096, 720))
		if _observer_npc:
			_cam_target = _observer_npc.global_position

	# === PHASE 3 (330-500): Occlusion demo — red rays through walls ===
	if _frame == 330:
		# Set up occlusion scenario: observer on one side of building, target on other
		var baker: Node = _find_npc_by_role("Baker")
		var courier: Node = _find_npc_by_role("Courier")
		if baker:
			# Place baker at a position where she faces a wall with someone behind it
			# Building walls run along x~1776 in the bakery area
			baker.global_position = Vector2(1760, 500)
			_observer_npc = baker
			if _debug_overlay:
				_debug_overlay._selected_npc = baker
				print("Presentation: Selected %s for occlusion demo" % baker.npc_name)
		if courier:
			# Place courier behind the wall from baker's perspective
			courier.global_position = Vector2(1850, 500)  # Behind building wall
		if _game_manager:
			_game_manager.time_scale = 3.0  # Slow so NPC stays put

	if _frame >= 330 and _frame < 500:
		if _observer_npc:
			_cam_target = _observer_npc.global_position
		# Gradually move the "blocked" NPC to emerge from cover (frame 400+)
		if _frame >= 400:
			var courier: Node = _find_npc_by_role("Courier")
			if courier:
				# Move courier from behind wall into view gradually
				var t: float = float(_frame - 400) / 100.0  # 0 to 1
				t = clampf(t, 0.0, 1.0)
				# Start behind wall (1850,500), end in open (1760,560)
				courier.global_position = Vector2(1850, 500).lerp(Vector2(1760, 560), t)

	# === PHASE 4 (500-660): Hearing demonstration ===
	if _frame == 500:
		# Move NPCs back to cluster for hearing demo
		var guard: Node = _find_npc_by_role("Guard")
		var gossip: Node = _find_npc_by_role("Gossip")
		var innkeeper: Node = _find_npc_by_role("Innkeeper")
		# Listener (selected NPC) at center
		if guard:
			guard.global_position = Vector2(2096, 720)
			_observer_npc = guard
			if _debug_overlay:
				_debug_overlay._selected_npc = guard
				print("Presentation: Selected %s for hearing demo" % guard.npc_name)
		# Near speaker (clear hearing)
		if gossip:
			gossip.global_position = Vector2(2150, 740)  # ~60px away
		# Far speaker (uncertain hearing)
		if innkeeper:
			innkeeper.global_position = Vector2(2250, 720)  # ~154px away
		if _game_manager:
			_game_manager.time_scale = 2.0  # Very slow for hearing clarity

	if _frame >= 500 and _frame < 660:
		if _observer_npc:
			_cam_target = _observer_npc.global_position
		# Emit speech stimuli repeatedly so hearing arcs stay visible
		if _frame % 30 == 0:  # Every second
			_emit_speech_stimuli()

	# === PHASE 5 (660-810): Exposure/confidence close-up ===
	if _frame == 660:
		# Place two NPCs at varying distances to show exposure gradient
		var guard: Node = _find_npc_by_role("Guard")
		var courier: Node = _find_npc_by_role("Courier")
		var gossip: Node = _find_npc_by_role("Gossip")
		if guard:
			guard.global_position = Vector2(2096, 720)
			_observer_npc = guard
			if _debug_overlay:
				_debug_overlay._selected_npc = guard
				print("Presentation: Selected %s for exposure gradient" % guard.npc_name)
		# One NPC close (high exposure), one at edge (lower exposure)
		if courier:
			courier.global_position = Vector2(2140, 740)  # ~50px, high exposure
		if gossip:
			gossip.global_position = Vector2(2180, 720)   # ~84px, lower exposure
		if _game_manager:
			_game_manager.time_scale = 5.0

	if _frame >= 660 and _frame < 810:
		if _observer_npc:
			_cam_target = _observer_npc.global_position
		# Slowly move one NPC to show exposure changing
		if _frame >= 700:
			var courier: Node = _find_npc_by_role("Courier")
			if courier:
				var t: float = float(_frame - 700) / 110.0
				t = clampf(t, 0.0, 1.0)
				# Move from close to far
				courier.global_position = Vector2(2140, 740).lerp(Vector2(2200, 720), t)

	# === PHASE 6 (810-900): Wide pullback ===
	if _frame == 810:
		if _game_manager:
			_game_manager.time_scale = 5.0
		print("Presentation: Wide pullback — full debug overview")

	if _frame == 870:
		if _debug_overlay:
			_debug_overlay._active = false
			_debug_overlay.visible = false
			_debug_overlay._selected_npc = null
			print("Presentation: Debug overlay OFF")

	return false

func _setup_npc_positions() -> void:
	"""Initial NPC positioning for perception demo."""
	var guard: Node = _find_npc_by_role("Guard")
	var courier: Node = _find_npc_by_role("Courier")
	var gossip: Node = _find_npc_by_role("Gossip")
	var innkeeper: Node = _find_npc_by_role("Innkeeper")

	# Cluster near town square (2096, 720) — open area
	if guard:
		guard.global_position = Vector2(2096, 720)
	if courier:
		courier.global_position = Vector2(2150, 740)
	if gossip:
		gossip.global_position = Vector2(2040, 700)
	if innkeeper:
		innkeeper.global_position = Vector2(2180, 700)
	print("Presentation: Positioned NPCs for perception demo")

func _maintain_cluster(center: Vector2) -> void:
	"""Keep NPCs from wandering too far from the cluster center during vision demo."""
	var guard: Node = _find_npc_by_role("Guard")
	var courier: Node = _find_npc_by_role("Courier")
	var gossip: Node = _find_npc_by_role("Gossip")
	# Gently pull back NPCs that stray too far
	for npc in [guard, courier, gossip]:
		if npc == null:
			continue
		var dist: float = npc.global_position.distance_to(center)
		if dist > 120.0:
			npc.global_position = npc.global_position.lerp(center, 0.02)

func _emit_speech_stimuli() -> void:
	"""Emit speech stimuli from NPCs near the observer for hearing visualization."""
	if _stimulus_registry == null or _observer_npc == null:
		return
	# Emit from nearby NPCs
	for npc in _npcs:
		if npc == _observer_npc:
			continue
		var d: float = npc.global_position.distance_to(_observer_npc.global_position)
		if d > 20.0 and d < 200.0:
			var name_str: String = npc.npc_name if "npc_name" in npc else "npc"
			_stimulus_registry.emit("speech", npc.global_position, 160.0, 0.8, 2.0, ["perception demo"], name_str)

func _update_keyframe_target() -> void:
	var active_kf: int = 0
	for i in range(_keyframes.size()):
		if _frame >= _keyframes[i]["frame"]:
			active_kf = i
	var kf: Dictionary = _keyframes[active_kf]
	var tracking: bool = (_frame >= 150 and _frame < 330) or \
		(_frame >= 330 and _frame < 500) or \
		(_frame >= 500 and _frame < 660) or \
		(_frame >= 660 and _frame < 810)
	if not tracking:
		_cam_target = kf["pos"]
	_cam_zoom_target = kf["zoom"]
	_cam_speed = kf["speed"]

func _find_npc_by_role(target_role: String) -> Node:
	for npc in _npcs:
		if npc.role == target_role:
			return npc
	return null
