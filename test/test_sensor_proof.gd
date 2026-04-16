extends SceneTree
## test/test_sensor_proof.gd — Prove SensorSystem vision + hearing pipeline works
## Loads the main scene, waits for autoloads, then runs direct queries and prints results.

var _frame: int = 0
var _root: Node = null
var _sensor_system: Node = null
var _occluder_system: Node = null
var _stimulus_registry: Node = null
var _world_object_registry: Node = null
var _done: bool = false

func _initialize() -> void:
	_root = get_root()
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main = main_scene.instantiate()
	_root.add_child(main)

	for child in _root.get_children():
		if child.name == "SensorSystem":
			_sensor_system = child
		elif child.name == "OccluderSystem":
			_occluder_system = child
		elif child.name == "StimulusRegistry":
			_stimulus_registry = child
		elif child.name == "WorldObjectRegistry":
			_world_object_registry = child

func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < 5:
		return false  # let autoloads settle

	if _done:
		return true  # quit

	_done = true
	_run_tests()
	return true

func _run_tests() -> void:
	print("\n========== SENSOR SYSTEM PROOF ==========\n")

	# --- Check autoloads ---
	print("Autoloads:")
	print("  SensorSystem: %s" % ("OK" if _sensor_system else "MISSING"))
	print("  OccluderSystem: %s (segments: %d)" % [
		"OK" if _occluder_system else "MISSING",
		_occluder_system.get_segment_count() if _occluder_system and _occluder_system.has_method("get_segment_count") else -1
	])
	print("  StimulusRegistry: %s" % ("OK" if _stimulus_registry else "MISSING"))
	print("  WorldObjectRegistry: %s" % ("OK" if _world_object_registry else "MISSING"))

	if not _sensor_system:
		print("\nFATAL: No SensorSystem — cannot test")
		return

	# --- Build a standard sensor profile ---
	var SPScript: GDScript = load("res://scripts/sensor_profile.gd")
	var profile: Dictionary = SPScript.make_default()
	print("\nSensor profile: range=%.0f arc=%.0f" % [profile["vision_range"], profile["vision_arc_deg"]])

	# --- Get sample offsets ---
	var SRTScript: GDScript = load("res://scripts/sensory_result_types.gd")
	var actor_offsets: Array = SRTScript.actor_sample_offsets()
	var object_offsets: Array = SRTScript.object_sample_offsets()
	print("Sample points: actor=%d object=%d" % [actor_offsets.size(), object_offsets.size()])

	# --- Test 1: Vision — NPC at inn sees nearby objects ---
	print("\n--- TEST 1: Vision — Hugo's position looking at inn objects ---")
	var hugo_pos: Vector2 = Vector2(2096, 624)  # Hugo's spawn
	var facing_down: Vector2 = Vector2(0, 1)
	var facing_left: Vector2 = Vector2(-1, 0)
	var facing_right: Vector2 = Vector2(1, 0)
	var facing_up: Vector2 = Vector2(0, -1)

	# Inn objects
	var test_targets: Array = [
		{"name": "Pantry", "pos": Vector2(2080, 610), "offsets": object_offsets},
		{"name": "Guest Ledger", "pos": Vector2(2110, 620), "offsets": object_offsets},
		{"name": "Ale Barrel", "pos": Vector2(2070, 640), "offsets": object_offsets},
	]

	for facing_name in ["down", "left", "right", "up"]:
		var facing: Vector2
		match facing_name:
			"down": facing = facing_down
			"left": facing = facing_left
			"right": facing = facing_right
			"up": facing = facing_up
		print("  Facing %s:" % facing_name)
		for target in test_targets:
			var vr: Dictionary = _sensor_system.query_vision(
				hugo_pos, facing, profile, target["pos"], target["offsets"]
			)
			var status: String = "VISIBLE" if vr.get("visible", false) else "hidden"
			print("    %s (dist=%.0f): %s  exposure=%.2f confidence=%.2f hits=%d/%d blocked=%s" % [
				target["name"], vr.get("distance", 0),
				status, vr.get("exposure", 0), vr.get("confidence", 0),
				vr.get("sample_hits", 0), vr.get("sample_total", 0),
				str(vr.get("blocked_by", []))
			])

	# --- Test 2: Vision — entity-to-entity ---
	print("\n--- TEST 2: Vision — entity sees another entity ---")
	var npc_a_pos: Vector2 = Vector2(2096, 624)  # Hugo
	var npc_b_pos: Vector2 = Vector2(2096, 580)  # 44px north (< 96 range)
	var npc_c_pos: Vector2 = Vector2(2096, 500)  # 124px north (> 96 range)
	var player_near: Vector2 = Vector2(2050, 624)  # 46px west

	var entity_tests: Array = [
		{"name": "NPC_B (44px north)", "pos": npc_b_pos},
		{"name": "NPC_C (124px north, out of range)", "pos": npc_c_pos},
		{"name": "Player (46px west)", "pos": player_near},
	]

	for target in entity_tests:
		var vr: Dictionary = _sensor_system.query_vision(
			npc_a_pos, facing_down, profile, target["pos"], actor_offsets
		)
		var status: String = "VISIBLE" if vr.get("visible", false) else "hidden"
		print("  %s: %s  dist=%.0f exposure=%.2f confidence=%.2f" % [
			target["name"], status, vr.get("distance", 0),
			vr.get("exposure", 0), vr.get("confidence", 0)
		])

	# Facing toward the target
	for target in entity_tests:
		var dir: Vector2 = (target["pos"] - npc_a_pos).normalized()
		var vr: Dictionary = _sensor_system.query_vision(
			npc_a_pos, dir, profile, target["pos"], actor_offsets
		)
		var status: String = "VISIBLE" if vr.get("visible", false) else "hidden"
		print("  %s (facing toward): %s  dist=%.0f exposure=%.2f confidence=%.2f" % [
			target["name"], status, vr.get("distance", 0),
			vr.get("exposure", 0), vr.get("confidence", 0)
		])

	# --- Test 3: Hearing ---
	print("\n--- TEST 3: Hearing — speech stimulus ---")
	if _stimulus_registry:
		# Emit a speech stimulus near Hugo
		_stimulus_registry.emit(
			"speech", Vector2(2050, 624), 160.0, 0.8, 4.0,
			["speech", "dialogue", "Hello Hugo!"], "TestSpeaker"
		)
		# Query hearing
		var hearing: Array = _sensor_system.query_hearing_all(hugo_pos, profile)
		print("  Stimuli heard: %d" % hearing.size())
		for hr in hearing:
			print("    type=%s emitter=%s vol=%.2f clarity=%.2f tags=%s" % [
				hr.get("stimulus_type", "?"),
				hr.get("emitter_id", "?"),
				hr.get("perceived_volume", 0),
				hr.get("clarity", 0),
				str(hr.get("tags", [])),
			])
	else:
		print("  SKIP — no StimulusRegistry")

	# --- Test 4: Occluder count ---
	print("\n--- TEST 4: Occluder system ---")
	if _occluder_system:
		var seg_count: int = _occluder_system.get_segment_count() if _occluder_system.has_method("get_segment_count") else -1
		print("  Total segments: %d" % seg_count)
		# Test a ray that should be blocked by a building wall
		# (We don't know exact segment positions, but we can report the count)
	else:
		print("  SKIP — no OccluderSystem")

	# --- Test 5: What Hugo actually sees right now ---
	print("\n--- TEST 5: Hugo's live perception ---")
	var npcs: Array = get_root().get_tree().get_nodes_in_group("npcs") if get_root().get_tree() else []
	var hugo: Node = null
	for npc in npcs:
		if npc.npc_name == "Hugo":
			hugo = npc
			break
	if hugo and hugo.brain and hugo.brain.perception:
		var perc = hugo.brain.perception
		print("  Visible entities: %d" % perc.visible_entities.size())
		for e in perc.visible_entities:
			print("    %s dist=%.0f exposure=%.2f" % [e.get("name","?"), e.get("distance",0), e.get("exposure",0)])
		print("  Visible objects: %d" % perc.visible_objects.size())
		for o in perc.visible_objects:
			print("    %s (%s) dist=%.0f state=%s" % [o.get("name","?"), o.get("id",""), o.get("distance",0), o.get("state","")])
		print("  Hugo pos: %s facing: %s" % [str(hugo.global_position), hugo._facing])
	else:
		print("  Hugo not found or no brain/perception")

	print("\n========== END ==========\n")
