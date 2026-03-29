extends SceneTree
## test/test_5.gd — Verify Task 5: World Object Registry & Object Perception

var _frame: int = 0
var _main: Node = null
var _cam: Camera2D = null
var _debug_overlay: Node = null
var _world_obj_registry: Node = null
var _selected_npc: Node = null

func _initialize() -> void:
	# Load main scene
	var scene: PackedScene = load("res://scenes/main.tscn")
	var inst = scene.instantiate()
	root.add_child(inst)
	_main = inst

	# Find autoloads
	for child in root.get_children():
		if child.name == "WorldObjectRegistry":
			_world_obj_registry = child

	# Find camera and debug overlay
	_cam = _main.get_node_or_null("Camera2D") as Camera2D
	_debug_overlay = _main.get_node_or_null("DebugOverlay")

	# Set camera to a reasonable position and zoom
	if _cam:
		_cam.position = Vector2(1712, 464)  # Bakery area
		_cam.zoom = Vector2(2.5, 2.5)

	# Fast time scale to speed up simulation
	var gm: Node = null
	for child in root.get_children():
		if child.name == "GameManager":
			gm = child
			break
	if gm and "time_scale" in gm:
		gm.time_scale = 10.0

	# Assertions about registry
	if _world_obj_registry:
		var obj_count: int = _world_obj_registry.objects.size()
		if obj_count >= 15:
			print("ASSERT PASS: WorldObjectRegistry has %d objects (>= 15)" % obj_count)
		else:
			print("ASSERT FAIL: WorldObjectRegistry has only %d objects (need 15+)" % obj_count)

		# Check specific objects
		var oven: Dictionary = _world_obj_registry.get_object("bakery_oven_01")
		if oven.get("name", "") == "Brick Oven":
			print("ASSERT PASS: bakery_oven_01 found with name 'Brick Oven'")
		else:
			print("ASSERT FAIL: bakery_oven_01 not found or wrong name")

		var forge: Dictionary = _world_obj_registry.get_object("smith_forge_01")
		if forge.get("state", "") == "broken":
			print("ASSERT PASS: smith_forge_01 has broken state (discovery event)")
		else:
			print("ASSERT FAIL: smith_forge_01 should be broken, got '%s'" % forge.get("state", ""))

func _process(delta: float) -> bool:
	_frame += 1

	# Frame 1: Camera at bakery
	if _frame == 1:
		if _cam:
			_cam.position = Vector2(1712, 464)
			_cam.zoom = Vector2(2.5, 2.5)

	# Frame 10: Select an NPC near bakery (Edith) and enable debug overlay
	if _frame == 10:
		_select_npc_by_name("Edith")
		if _debug_overlay:
			_debug_overlay._active = true
			_debug_overlay.visible = true
			if _selected_npc:
				_debug_overlay._selected_npc = _selected_npc

	# Frame 30: Check if any NPC has discovered objects
	if _frame == 30:
		_check_discoveries()

	# Frame 40: Pan to blacksmith to show different NPC
	if _frame == 40:
		if _cam:
			_cam.position = Vector2(1168, 592)
		_select_npc_by_name("Greta")
		if _debug_overlay and _selected_npc:
			_debug_overlay._selected_npc = _selected_npc

	# Frame 60: Check Greta's discoveries
	if _frame == 60:
		_check_discoveries()

	# Frame 70: Show debug overlay with object section visible
	if _frame == 70:
		# Pan camera to follow selected NPC
		if _selected_npc:
			if _cam:
				_cam.position = _selected_npc.global_position

	# Frame 80: Final assertion check on all NPCs
	if _frame == 80:
		_final_checks()

	return false

func _select_npc_by_name(target_name: String) -> void:
	for npc in root.get_tree().get_nodes_in_group("npcs"):
		if npc.npc_name == target_name:
			_selected_npc = npc
			return

func _check_discoveries() -> void:
	var any_discovered: bool = false
	for npc in root.get_tree().get_nodes_in_group("npcs"):
		if npc.brain == null or npc.brain.memory == null:
			continue
		var known: Dictionary = npc.brain.memory.known_objects
		if known.size() > 0:
			any_discovered = true
			print("ASSERT PASS: %s has discovered %d objects" % [npc.npc_name, known.size()])
			# Check for object discovery events
			for evt in npc.brain.memory.tagged_events:
				var desc: String = evt.get("description", "")
				if "Discovered" in desc or "object_discovery" in str(evt.get("tags", [])):
					print("ASSERT PASS: %s has object discovery event: %s" % [npc.npc_name, desc])
					break
	if not any_discovered:
		print("ASSERT INFO: No NPC has discovered objects yet (may need more frames)")

func _final_checks() -> void:
	var total_discoveries: int = 0
	for npc in root.get_tree().get_nodes_in_group("npcs"):
		if npc.brain and npc.brain.memory:
			total_discoveries += npc.brain.memory.known_objects.size()
	if total_discoveries > 0:
		print("ASSERT PASS: Total object discoveries across all NPCs: %d" % total_discoveries)
	else:
		print("ASSERT FAIL: No NPCs discovered any objects after 80 frames")
