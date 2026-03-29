extends RefCounted
## res://scripts/npc_brain.gd — Orchestrates all three AI layers for one NPC

var npc_name: String = ""
var role: String = ""

# Sub-systems
var layer1: RefCounted = null  # Layer1Substrate
var layer2: RefCounted = null  # Layer2Projection
var layer3: RefCounted = null  # Layer3Executive
var memory: RefCounted = null  # MemorySystem
var perception: RefCounted = null  # Perception (FOV + hearing)

# References
var _inference_client: Node = null
var _game_manager: Node = null

# Timers
var _social_pulse_timer: float = 0.0
var _social_pulse_interval: float = 5.0  # game minutes → real seconds depend on time_scale

func setup(p_name: String, p_role: String) -> void:
	npc_name = p_name
	role = p_role

	# Create subsystems
	var L1Script: GDScript = load("res://scripts/layer1_substrate.gd")
	layer1 = L1Script.new()
	layer1.setup(role)

	var L2Script: GDScript = load("res://scripts/layer2_projection.gd")
	layer2 = L2Script.new()
	layer2.setup(npc_name, role)

	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	layer3 = L3Script.new()
	layer3.setup(npc_name, role)

	var MemScript: GDScript = load("res://scripts/memory_system.gd")
	memory = MemScript.new()

	var PercScript: GDScript = load("res://scripts/perception.gd")
	perception = PercScript.new()

func set_autoloads(inference_client: Node, game_manager: Node) -> void:
	_inference_client = inference_client
	_game_manager = game_manager

func update_layer1(delta: float, world_pos: Vector2, nearby_npcs: int) -> void:
	if layer1 == null:
		return

	# Apply Layer 2 modulation to Layer 1
	if layer2 != null:
		var mod: Dictionary = layer2.modulation
		layer1.learning_rate_mod = mod.get("learning_rate_mod", 1.0)
		layer1.exploration_bias = mod.get("exploration_bias", 0.0)
		layer1.attention_weight = mod.get("attention_weight", 1.0)
		layer1.interruption_sensitivity = mod.get("interruption_sensitivity", 0.5)
		layer1.persistence_scale = mod.get("persistence_scale", 1.0)

	# Determine context
	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour

	var current_location: String = ""
	if layer3:
		current_location = layer3.location_name_from_position(world_pos)

	var home_loc: String = ""
	if layer3:
		home_loc = layer3.get_home_location()
	var work_loc: String = ""
	if layer3:
		work_loc = layer3.get_work_location()

	var at_home: bool = (current_location == home_loc)
	var at_work: bool = (current_location == work_loc)

	layer1.set_context(hour, at_home, at_work, current_location, nearby_npcs)
	layer1.update(delta)

	# Update familiarity
	if current_location != "" and current_location != "unknown":
		memory.visit_location(current_location)
		layer1.place_familiarity[current_location] = memory.get_location_comfort(current_location)

func update_layer2(delta: float) -> void:
	if layer2 == null or layer1 == null:
		return
	var recent: Array = memory.get_recent_events_text(5)
	layer2.update(delta, layer1.get_state_dict(), recent, _inference_client)

func update_layer3(hour: float) -> void:
	if layer3 == null:
		return
	var mem_summary: String = memory.get_memory_summary()
	var emo_summary: String = ""
	if layer2:
		emo_summary = layer2.get_emotion_summary()
	layer3.update_plan(hour, mem_summary, emo_summary, _inference_client)

func get_target_position() -> Vector2:
	if layer3 == null:
		return Vector2(2096, 800)

	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour

	# Night behavior
	if layer3.should_go_home(hour):
		var night: Dictionary = layer3.get_night_behavior()
		var loc: String = night.get("location", "town_square")
		var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
		if L3Cls.LOCATIONS.has(loc):
			return L3Cls.LOCATIONS[loc]
		return Vector2(2096, 800)

	return layer3.get_target_position()

func get_current_action() -> String:
	if layer3 == null:
		return "idle"
	var chunk: Dictionary = layer3.get_current_chunk()
	if chunk.is_empty():
		return "idle"
	return chunk.get("purpose", "idle")

func on_arrived_at_destination() -> void:
	if layer3:
		var chunk: Dictionary = layer3.get_current_chunk()
		if not chunk.is_empty():
			layer1.start_task()
			memory.add_observation(npc_name, chunk.get("location", ""), "arrived for " + chunk.get("purpose", "task"))

func on_chunk_completed() -> void:
	if layer3:
		layer3.advance_chunk()
		layer1.task_momentum = 0.0

func on_player_interaction(callback: Callable) -> void:
	if layer3 == null:
		callback.call(false, {"utterance": "..."})
		return

	var emo_summary: String = ""
	if layer2:
		emo_summary = layer2.get_emotion_summary()

	var trust_val: float = memory.get_trust("Player")
	var rel_context: String = "Trust: %.2f" % trust_val
	var recent: Array = memory.get_recent_events_text(3)

	layer3.request_dialogue(emo_summary, rel_context, recent, _inference_client, callback)

	# Record the interaction
	memory.add_tagged_event("Player spoke to me", 0.6, ["interaction", "player"])
	# Modify trust slightly (positive for friendly interaction)
	memory.update_relationship("Player", 0.02, "Player initiated conversation")

	# Interruption if doing a task
	if layer1.task_momentum > 0.3:
		layer1.apply_interruption()
		memory.add_tagged_event("Player interrupted my task", 0.5, ["interruption"])
		memory.update_relationship("Player", -0.03, "Interrupted my work")

func on_path_blocked() -> void:
	layer1.apply_interruption()
	layer1.frustration = clampf(layer1.frustration + 0.05, 0.0, 1.0)
	memory.add_failed_strategy("Path blocked to destination")

func on_npc_nearby(other_name: String) -> void:
	memory.add_observation(npc_name, "", "Near " + other_name)

# --- Perception ---

func update_perception(facing: String, my_pos: Vector2, all_npcs: Array) -> void:
	"""Update FOV vision. Called every tick from npc_controller."""
	if perception == null:
		return
	perception.set_facing(facing)

	# Build entity list for vision check
	var entities: Array = []
	for npc in all_npcs:
		if npc.npc_name == npc_name:
			continue
		entities.append({
			"name": npc.npc_name,
			"position": npc.global_position,
			"doing": npc.brain.get_current_action() if npc.brain else "",
			"facing": npc._facing if "_facing" in npc else "",
		})

	perception.update_vision(my_pos, entities)

	# Record observations for newly seen NPCs
	for seen in perception.visible_entities:
		var doing: String = seen.get("doing", "")
		memory.add_observation(seen["name"], "", doing if doing != "" else "walking")

	# Process anything heard this tick
	var heard: Array = perception.consume_heard()
	for evt in heard:
		memory.add_tagged_event(
			"Heard %s say: %s" % [evt["source"], evt["text"]],
			0.4,
			["heard", "overheard"],
			evt["source"]
		)

func hear_speech(source_name: String, text: String, source_pos: Vector2, my_pos: Vector2) -> void:
	"""Called when someone speaks nearby. Omnidirectional hearing check."""
	if perception == null:
		return
	perception.hear(source_name, text, source_pos, my_pos)

func get_visible_npc_count() -> int:
	if perception:
		return perception.visible_entities.size()
	return 0
