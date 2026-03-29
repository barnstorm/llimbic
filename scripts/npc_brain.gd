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

# Drive override state
var _drive_override: Dictionary = {}  # {target: Vector2, reason: String, drive: String}
var _last_world_pos: Vector2 = Vector2.ZERO

# Food and public locations for drive overrides
const FOOD_LOCATIONS: Array = ["bakery", "inn", "market", "farm"]
const PUBLIC_LOCATIONS: Array = ["town_square", "market", "inn", "well"]

# Chunk tracking for modulation triggers
var _last_chunk_index: int = -1

# Reflection state
var _last_reflection_hour: float = -1.0
var _reflection_interval_hours: float = 2.0
var _pending_reflection: bool = false
var _tagged_event_count_at_last_reflection: int = 0

# Action selection state
var current_action: Dictionary = {}
var _observe_cooldown: float = 0.0
var _at_destination: bool = false
var _destination_timer: float = 0.0
var _destination_duration: float = 0.0

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
	_last_world_pos = world_pos

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
	# Enrich summary with state info for adaptive planning triggers
	if memory.concerns.size() > 0:
		mem_summary += "\nConcerns: " + ", ".join(memory.concerns)
	if layer1.frustration > 0.5:
		mem_summary += "\nFrustration is high (%.2f)." % layer1.frustration
	if memory.failed_strategies.size() > 2:
		mem_summary += "\nMultiple recent failures (%d)." % memory.failed_strategies.size()
	var emo_summary: String = ""
	if layer2:
		emo_summary = layer2.get_emotion_summary()
	layer3.update_plan(hour, mem_summary, emo_summary, _inference_client)

	# Trigger southbound modulation when chunk changes
	_check_modulation_trigger()

	# Check if reflection is due
	_check_reflection(hour)

	# Decay old memories at Layer 3 cadence (~every 30 game-minutes = 0.5 hours)
	memory.decay_events(0.5)

func _check_reflection(hour: float) -> void:
	if _pending_reflection:
		return
	if _inference_client == null or not _inference_client.is_server_available():
		return
	# Trigger every 2 game-hours OR when 5+ new tagged events accumulate
	var hour_diff: float = hour - _last_reflection_hour
	if hour_diff < 0:
		hour_diff += 24.0
	var new_events: int = memory.tagged_events.size() - _tagged_event_count_at_last_reflection
	if _last_reflection_hour >= 0.0 and hour_diff < _reflection_interval_hours and new_events < 5:
		return
	_pending_reflection = true
	_last_reflection_hour = hour
	_tagged_event_count_at_last_reflection = memory.tagged_events.size()
	var events_text: Array = memory.get_recent_events_text(10)
	_inference_client.layer3_reflect(events_text, _on_reflection_result)

func _on_reflection_result(success: bool, data: Dictionary) -> void:
	_pending_reflection = false
	if not success:
		return
	if data.has("reflections"):
		for r in data["reflections"]:
			memory.add_reflection(str(r))
	if data.has("concerns"):
		for c in data["concerns"]:
			memory.add_concern(str(c))

func _nearest_location(candidates: Array) -> Vector2:
	## Find the nearest location from a list of location names.
	var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
	var best_pos: Vector2 = Vector2(2096, 800)
	var best_dist: float = 999999.0
	for loc_name in candidates:
		if L3Cls.LOCATIONS.has(loc_name):
			var pos: Vector2 = L3Cls.LOCATIONS[loc_name]
			var dist: float = _last_world_pos.distance_to(pos)
			if dist < best_dist:
				best_dist = dist
				best_pos = pos
	return best_pos

func _safest_familiar_location() -> Vector2:
	## Find the location with highest familiarity, or home.
	var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
	var best_loc: String = layer3.get_home_location() if layer3 else "town_square"
	var best_comfort: float = -1.0
	for loc_name in memory.place_familiarity:
		var comfort: float = memory.get_location_comfort(loc_name)
		if comfort > best_comfort and L3Cls.LOCATIONS.has(loc_name):
			best_comfort = comfort
			best_loc = loc_name
	if L3Cls.LOCATIONS.has(best_loc):
		return L3Cls.LOCATIONS[best_loc]
	return Vector2(2096, 800)

func check_drive_override() -> Dictionary:
	## Check if any Layer 1 drive has crossed an urgent threshold.
	## Returns override dict or empty if no override needed.
	if layer1 == null:
		return {}
	# Priority order: safety, energy, hunger, social
	if layer1.safety < 30.0:
		return {"target": _safest_familiar_location(), "reason": "Seeking safety", "drive": "safety"}
	if layer1.energy < 20.0:
		var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
		var home: String = layer3.get_home_location() if layer3 else "town_square"
		var pos: Vector2 = L3Cls.LOCATIONS.get(home, Vector2(2096, 800))
		return {"target": pos, "reason": "Exhausted, going home", "drive": "energy"}
	if layer1.hunger > 80.0:
		return {"target": _nearest_location(FOOD_LOCATIONS), "reason": "Need to eat", "drive": "hunger"}
	if layer1.social_need > 85.0:
		return {"target": _nearest_location(PUBLIC_LOCATIONS), "reason": "Lonely, seeking company", "drive": "social_need"}
	return {}

func _drive_has_recovered(drive: String) -> bool:
	## Check if the drive that caused the override has recovered enough to resume.
	match drive:
		"safety":
			return layer1.safety > 50.0
		"energy":
			return layer1.energy > 40.0
		"hunger":
			return layer1.hunger < 50.0
		"social_need":
			return layer1.social_need < 60.0
	return true

func get_target_position() -> Vector2:
	if layer3 == null:
		return Vector2(2096, 800)

	var hour: float = 6.0
	if _game_manager:
		hour = _game_manager.current_hour

	# Night behavior overrides everything
	if layer3.should_go_home(hour):
		_drive_override = {}
		var night: Dictionary = layer3.get_night_behavior()
		var loc: String = night.get("location", "town_square")
		var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
		if L3Cls.LOCATIONS.has(loc):
			return L3Cls.LOCATIONS[loc]
		return Vector2(2096, 800)

	# Check if current override has resolved
	if not _drive_override.is_empty():
		if _drive_has_recovered(_drive_override.get("drive", "")):
			memory.add_tagged_event("Recovered from: " + _drive_override.get("reason", ""), 0.3, ["drive_recovery"])
			_drive_override = {}
			# Try to resume the suspended plan chunk
			if layer3.resume_suspended():
				memory.add_tagged_event("Resuming interrupted task", 0.3, ["plan_resume"])
		else:
			return _drive_override["target"]

	# Check for new drive override
	var override: Dictionary = check_drive_override()
	if not override.is_empty():
		# Suspend the current chunk before overriding
		layer3.suspend_current_chunk()
		# Log the deviation
		var chunk: Dictionary = layer3.get_current_chunk()
		var purpose: String = chunk.get("purpose", "task")
		memory.add_tagged_event("Skipped task: %s because %s" % [purpose, override["reason"]], 0.6, ["drive_override", override["drive"]])
		_drive_override = override
		return override["target"]

	return layer3.get_target_position()

func get_current_action() -> String:
	if layer3 == null:
		return "idle"
	var chunk: Dictionary = layer3.get_current_chunk()
	if chunk.is_empty():
		return "idle"
	return chunk.get("purpose", "idle")

# --- Action Selection ("Tool Call" System) ---

func select_action(delta: float) -> Dictionary:
	## Called every tick by the controller. Returns an action dictionary.
	## Priority: reorientation > flee > observe > wander-at-dest > move-toward

	# 1. Reorientation pause after interruption
	if layer1.reorientation_timer > 0.0:
		current_action = {"type": "pause", "reason": "Reorienting", "speed_mul": 0.0}
		return current_action

	# 2. Flee from threat (high flee tendency + distrusted entity visible)
	if layer1.flee > 0.5 and perception and perception.visible_entities.size() > 0:
		var threat: Dictionary = _find_threat()
		if not threat.is_empty():
			var away_dir: Vector2 = (_last_world_pos - threat["position"]).normalized()
			var flee_target: Vector2 = _last_world_pos + away_dir * 128.0
			current_action = {"type": "flee_from", "target": flee_target, "entity": threat["name"], "reason": "Fleeing from " + threat["name"], "speed_mul": 1.4}
			memory.add_tagged_event("Fled from " + threat["name"], 0.5, ["flee", "danger"])
			return current_action

	# 3. Observe interesting entity (cooldown prevents constant stops)
	_observe_cooldown = maxf(_observe_cooldown - delta, 0.0)
	if layer1.observe > 0.6 and _observe_cooldown <= 0.0 and perception:
		var interesting: Dictionary = _find_interesting_entity()
		if not interesting.is_empty():
			_observe_cooldown = 8.0
			memory.add_observation(npc_name, "", "Stopped to observe " + interesting["name"])
			current_action = {"type": "observe", "target": interesting["position"], "entity": interesting["name"], "duration": randf_range(0.8, 1.5), "reason": "Observing " + interesting["name"], "speed_mul": 0.0}
			return current_action

	# 4. Get plan target (includes drive overrides)
	var plan_target: Vector2 = get_target_position()
	var dist_to_target: float = _last_world_pos.distance_to(plan_target)

	# 5. At destination → wander + tick chunk timer
	if dist_to_target < 48.0:
		if not _at_destination:
			# Just arrived
			_at_destination = true
			_path_retry_count = 0
			layer1.start_task()
			var chunk: Dictionary = layer3.get_current_chunk() if layer3 else {}
			var duration_hours: float = chunk.get("duration", 2.0)
			_destination_duration = clampf(duration_hours * 5.0, 8.0, 30.0)
			_destination_timer = _destination_duration
			memory.add_observation(npc_name, chunk.get("location", ""), "arrived for " + chunk.get("purpose", "task"))

		# Tick destination timer
		_destination_timer -= delta
		if _destination_timer <= 0.0:
			# Chunk complete, move on
			_at_destination = false
			on_chunk_completed()
			# Recalculate target for next chunk
			plan_target = get_target_position()
			current_action = {"type": "move_toward", "target": plan_target, "reason": get_current_action(), "speed_mul": _compute_speed_mul()}
			return current_action

		current_action = {"type": "wander", "target": plan_target, "reason": get_current_action(), "speed_mul": 0.4}
		return current_action

	# 6. Moving toward destination
	_at_destination = false
	current_action = {"type": "move_toward", "target": plan_target, "reason": get_current_action(), "speed_mul": _compute_speed_mul()}
	return current_action

func _find_threat() -> Dictionary:
	## Find a visible entity we distrust enough to flee from.
	for entity in perception.visible_entities:
		var trust_val: float = memory.get_trust(entity["name"])
		if trust_val < 0.2:
			return entity
	return {}

func _find_interesting_entity() -> Dictionary:
	## Find a visible entity we haven't observed recently.
	var recent_names: Array = []
	var recent_slice: Array = memory.observations.slice(-5) if memory.observations.size() > 0 else []
	for obs in recent_slice:
		recent_names.append(obs.get("who", ""))
	for entity in perception.visible_entities:
		if entity["name"] not in recent_names:
			return entity
	return {}

func _compute_speed_mul() -> float:
	var mul: float = 1.0
	mul += layer1.flee * 0.4
	if perception and perception.visible_entities.size() > 0:
		mul -= layer1.avoid * 0.3
	return clampf(mul, 0.5, 1.5)

func on_arrived_at_destination() -> void:
	if layer3:
		var chunk: Dictionary = layer3.get_current_chunk()
		if not chunk.is_empty():
			layer1.start_task()
			memory.add_observation(npc_name, chunk.get("location", ""), "arrived for " + chunk.get("purpose", "task"))

func _check_modulation_trigger() -> void:
	## When the plan chunk changes, issue a directive to Layer 2 for southbound modulation.
	if layer3 == null:
		return
	if layer3.current_chunk_index != _last_chunk_index:
		_last_chunk_index = layer3.current_chunk_index
		var directive: String = layer3.get_chunk_directive()
		if directive != "" and layer2 != null and _inference_client != null:
			layer2.request_modulation(directive, _inference_client)

func on_chunk_completed() -> void:
	if layer3:
		layer3.advance_chunk()
		layer1.task_momentum = 0.0
		_check_modulation_trigger()

func on_player_interaction(callback: Callable) -> void:
	if layer3 == null:
		callback.call(false, {"utterance": "..."})
		return

	# Check interruption threshold — busy NPCs may refuse
	if not layer1.should_interrupt_for("medium"):
		var busy_lines: Dictionary = {
			"Baker": "Can't stop now, bread's in the oven!",
			"Guard": "I'm on duty. Come back later.",
			"Herbalist": "These remedies won't prepare themselves.",
			"Courier": "Sorry, deliveries won't wait!",
			"Blacksmith": "The iron's hot — not now!",
			"Gossip": "Hold that thought... actually, no, I'm busy.",
			"Farmer": "Crops won't tend themselves.",
			"Innkeeper": "Can't chat now, got guests to serve.",
		}
		var line: String = busy_lines.get(role, "I'm busy right now.")
		callback.call(true, {"utterance": line, "intent": "dismiss"})
		memory.add_tagged_event("Refused player — too busy", 0.3, ["interaction", "player"])
		memory.update_relationship("Player", -0.01, "Tried to talk but I was busy")
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
	memory.update_relationship("Player", 0.02, "Player initiated conversation")

	# Interruption if doing a task
	if layer1.task_momentum > 0.3:
		layer1.apply_interruption()
		memory.add_tagged_event("Player interrupted my task", 0.5, ["interruption"])
		memory.update_relationship("Player", -0.03, "Interrupted my work")

var _path_retry_count: int = 0

func on_path_blocked() -> bool:
	## Returns true if the NPC should give up, false if it should retry.
	_path_retry_count += 1
	layer1.frustration = clampf(layer1.frustration + 0.05, 0.0, 1.0)
	# High-momentum NPCs resist giving up
	if _path_retry_count < 2 and not layer1.should_interrupt_for("low"):
		return false  # Try again
	# Give up
	layer1.apply_interruption()
	memory.add_failed_strategy("Path blocked to destination")
	_path_retry_count = 0
	return true

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
