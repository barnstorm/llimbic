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
var _world_object_registry: Node = null

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

# EXAMINE action state
var _examine_timer: float = 0.0
var _examining_object_id: String = ""
var _last_examine_times: Dictionary = {}  # object_id -> ticks_msec

# Logging
var _last_logged_action: String = ""
var _last_logged_stall: bool = false

# Timers
var _social_pulse_timer: float = 0.0
var _social_pulse_interval: float = 5.0  # game minutes → real seconds depend on time_scale

var _log_file: FileAccess = null

var _persona: Dictionary = {}

func setup(p_name: String, p_role: String) -> void:
	npc_name = p_name
	role = p_role
	# Per-NPC log file
	var dir := DirAccess.open("res://")
	if dir and not dir.dir_exists("logs"):
		dir.make_dir("logs")
	_log_file = FileAccess.open("res://logs/%s.log" % p_name.to_lower(), FileAccess.WRITE)
	if _log_file:
		_log_file.store_line("=== %s (%s) ===" % [p_name, p_role])

	# Load persona data
	var LoaderScript: GDScript = load("res://scripts/persona_loader.gd")
	_persona = LoaderScript.load_persona(p_name)
	if _persona.is_empty():
		_persona = {"name": p_name, "role": p_role}

	# Create subsystems with persona data
	var L1Script: GDScript = load("res://scripts/layer1_substrate.gd")
	layer1 = L1Script.new()
	layer1.setup(_persona)

	var L2Script: GDScript = load("res://scripts/layer2_projection.gd")
	layer2 = L2Script.new()
	layer2.setup(npc_name, role, _persona)

	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	layer3 = L3Script.new()
	layer3.setup(npc_name, role, _persona)

	var MemScript: GDScript = load("res://scripts/memory_system.gd")
	memory = MemScript.new()
	memory.npc_name = npc_name
	memory.npc_role = role
	memory.on_tagged_event = func(desc: String, salience: float) -> void:
		npc_log("MEM [%.1f]: %s" % [salience, desc])

	# Set initial trust from persona relationships
	var relationships: Dictionary = _persona.get("relationships", {})
	for entity_name in relationships:
		memory.update_relationship(str(entity_name), 0.0, "initial")
		layer1.trust[str(entity_name)] = float(relationships[entity_name])

	var PercScript: GDScript = load("res://scripts/perception.gd")
	perception = PercScript.new()

func npc_log(msg: String) -> void:
	if _log_file:
		var t: float = _game_manager.current_hour if _game_manager else 0.0
		var line: String = "[%02d:%02d] %s" % [int(t), int(fmod(t, 1.0) * 60), msg]
		_log_file.store_line(line)
		_log_file.flush()

var _sensor_system: Node = null
var _sensor_profile: Dictionary = {}

func set_autoloads(inference_client: Node, game_manager: Node, world_object_registry: Node = null) -> void:
	_inference_client = inference_client
	_game_manager = game_manager
	_world_object_registry = world_object_registry

func set_sensor_autoloads(sensor_system: Node) -> void:
	_sensor_system = sensor_system
	# Build sensor profile from persona
	var SPScript: GDScript = load("res://scripts/sensor_profile.gd")
	_sensor_profile = SPScript.from_persona(_persona)

# Urgency replan state
var _urgency_replan_cooldown: float = 0.0
const URGENCY_REPLAN_MIN_INTERVAL: float = 30.0

# Chunk outcome tracking
var _chunk_outcomes: Array[Dictionary] = []

func update_layer1(delta: float, world_pos: Vector2, nearby_npcs: int) -> void:
	if layer1 == null:
		return
	_last_world_pos = world_pos

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

	# --- Closed loop: L2 emotions computed synchronously, every tick ---
	if layer2 != null:
		var chunk_priority: float = 0.5
		if layer3:
			var chunk: Dictionary = layer3.get_current_chunk()
			chunk_priority = chunk.get("priority", 0.5)
		var recent: Array = memory.get_recent_events_text(5)
		layer2.update_deterministic(layer1.get_state_dict(), recent, chunk_priority)

		# Apply modulation from emotions (continuous, not chunk-gated)
		var mod: Dictionary = layer2.modulation
		layer1.learning_rate_mod = mod.get("learning_rate_mod", 1.0)
		layer1.exploration_bias = mod.get("exploration_bias", 0.0)
		layer1.attention_weight = mod.get("attention_weight", 1.0)
		layer1.interruption_sensitivity = mod.get("interruption_sensitivity", 0.5)
		layer1.persistence_scale = mod.get("persistence_scale", 1.0)

		# Emotion → L1 feedback (closes the bidirectional loop)
		layer1.apply_emotion_feedback(layer2.emotion_vector)

	layer1.update(delta)

	# Update familiarity
	if current_location != "" and current_location != "unknown":
		memory.visit_location(current_location)
		layer1.place_familiarity[current_location] = memory.get_location_comfort(current_location)

	# Check urgency → L3 reactive replan
	_check_urgency_replan(delta, hour)

func update_layer2(_delta: float) -> void:
	# L2 now runs inside update_layer1() every tick via update_deterministic().
	# This method is kept for backward compat but does nothing.
	pass

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
	# Include chunk outcomes for L3 feedback
	if _chunk_outcomes.size() > 0:
		mem_summary += "\nRecent task outcomes:"
		for co in _chunk_outcomes:
			mem_summary += "\n- %s at %s: %s" % [co.get("purpose", "?"), co.get("location", "?"), co.get("outcome", "?")]
	var emo_summary: String = ""
	if layer2:
		emo_summary = layer2.get_emotion_summary()
	var obj_summary: String = memory.get_object_summary()
	layer3.update_plan(hour, mem_summary, emo_summary, _inference_client, obj_summary)

	# Track chunk changes for logging
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
	_inference_client.layer3_reflect(events_text, _on_reflection_result, npc_name, role)

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

func _find_best_food_target() -> Vector2:
	## Check known food-related objects first, fallback to generic food locations.
	if memory:
		var food_objs: Array = memory.get_food_objects()
		if food_objs.size() > 0:
			# Pick the nearest food location with known stocked objects
			var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
			var best_pos: Vector2 = Vector2.ZERO
			var best_dist: float = 999999.0
			for fobj in food_objs:
				var loc_name: String = fobj["location"]
				if L3Cls.LOCATIONS.has(loc_name):
					var pos: Vector2 = L3Cls.LOCATIONS[loc_name]
					var dist: float = _last_world_pos.distance_to(pos)
					if dist < best_dist:
						best_dist = dist
						best_pos = pos
			if best_pos != Vector2.ZERO:
				return best_pos
	return _nearest_location(FOOD_LOCATIONS)

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
		var food_target: Vector2 = _find_best_food_target()
		return {"target": food_target, "reason": "Need to eat", "drive": "hunger"}
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
			memory.add_tagged_event("Recovered from: " + _drive_override.get("reason", ""), 0.3, ["drive_recovery"], "direct", "drive_recovery")
			# Signal reward to neural network — drive recovery is a positive outcome
			if layer1 and layer1._network:
				layer1._network.signal_reward()
			_drive_override = {}
			# Try to resume the suspended plan chunk
			if layer3.resume_suspended():
				memory.add_tagged_event("Resuming interrupted task", 0.3, ["plan_resume"], "direct", "plan_change")
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
		memory.add_tagged_event("Skipped task: %s because %s" % [purpose, override["reason"]], 0.6, ["drive_override", override["drive"]], "direct", "drive_override")
		_drive_override = override
		return override["target"]

	# Check if the current chunk targets a specific object
	if _world_object_registry:
		var obj_pos: Vector2 = layer3.get_object_target_position(_world_object_registry)
		if obj_pos != Vector2.ZERO:
			return obj_pos
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
	var result: Dictionary = _select_action_inner(delta)
	# Log on action change or stall state change
	var action_key: String = result.get("type", "") + "|" + result.get("reason", "")
	if action_key != _last_logged_action:
		var frust: String = "frust=%.2f" % layer1.frustration
		var mom: String = "mom=%.2f" % layer1.task_momentum
		var obs: String = "obs=%.2f" % layer1.observe
		npc_log("%s: %s [%s %s %s]" % [result.get("type", "?"), result.get("reason", ""), frust, mom, obs])
		_last_logged_action = action_key
	if layer1.is_stalled != _last_logged_stall:
		if layer1.is_stalled:
			npc_log("STALL onset — frust=%.2f mom=%.2f observe=%.2f" % [layer1.frustration, layer1.task_momentum, layer1.observe])
		else:
			npc_log("STALL cleared — frust=%.2f" % layer1.frustration)
		_last_logged_stall = layer1.is_stalled
	return result

func _select_action_inner(delta: float) -> Dictionary:

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
			memory.add_tagged_event("Fled from " + threat["name"], 0.5, ["flee", "danger"], "direct", "threat_response")
			return current_action

	# 3. Observe interesting entity
	# Cooldown prevents constant stopping during normal movement,
	# but stalled NPCs bypass it — they need to see what's in front of them
	_observe_cooldown = maxf(_observe_cooldown - delta, 0.0)
	var can_observe: bool = (_observe_cooldown <= 0.0) or layer1.is_stalled
	if layer1.observe > 0.6 and can_observe and perception:
		var interesting: Dictionary = _find_interesting_entity()
		if not interesting.is_empty():
			_observe_cooldown = 8.0 if not layer1.is_stalled else 2.0
			memory.add_observation(npc_name, "", "Stopped to observe " + interesting["name"])
			# Stalled NPCs remember the frustration, not just the observation
			if layer1.is_stalled:
				var purpose: String = get_current_action()
				memory.add_tagged_event(
					"%s is in my way while I'm trying to %s" % [interesting["name"], purpose],
					0.4 + layer1.task_momentum * 0.4,
					["blocked", "frustration"], "direct", "path_blocked"
				)
				memory.update_relationship(interesting["name"], -0.02, "Blocked my path")
			current_action = {"type": "observe", "target": interesting["position"], "entity": interesting["name"], "duration": randf_range(0.8, 1.5), "reason": "Observing " + interesting["name"], "speed_mul": 0.0}
			return current_action

	# 4. EXAMINE action: if currently examining an object, continue until done
	if _examining_object_id != "" and _examine_timer > 0.0:
		_examine_timer -= delta
		if _examine_timer <= 0.0:
			_finish_examine()
		current_action = {"type": "examine", "reason": "Examining object", "speed_mul": 0.0, "object_id": _examining_object_id}
		return current_action

	# 4b. Check if we should examine a role-relevant object nearby (>5 min since last examine)
	var examine_target: Dictionary = _find_examinable_object()
	if not examine_target.is_empty():
		_start_examine(examine_target)
		current_action = {"type": "examine", "target": examine_target["position"], "reason": "Examining " + examine_target.get("name", "object"), "speed_mul": 0.0, "object_id": examine_target.get("id", "")}
		return current_action

	# 5. Get plan target (includes drive overrides + object targeting)
	var plan_target: Vector2 = get_target_position()
	var dist_to_target: float = _last_world_pos.distance_to(plan_target)

	# 6. At destination → check for object-targeted examine, then wander + tick chunk timer
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
			# If chunk has an object_id, start examining it on arrival
			var chunk_obj_id: String = chunk.get("object_id", "")
			if chunk_obj_id != "" and _should_examine(chunk_obj_id):
				var obj_data: Dictionary = {}
				if _world_object_registry:
					obj_data = _world_object_registry.get_object(chunk_obj_id)
				if not obj_data.is_empty():
					_start_examine({"id": chunk_obj_id, "name": obj_data.get("name", ""), "position": obj_data.get("position", _last_world_pos), "state": obj_data.get("state", ""), "type": obj_data.get("type", "")})
					current_action = {"type": "examine", "target": obj_data.get("position", _last_world_pos), "reason": "Examining " + obj_data.get("name", "object"), "speed_mul": 0.0, "object_id": chunk_obj_id}
					return current_action

		# While at destination, check if the chunk's object needs examining
		if layer3 and _examining_object_id == "" and _examine_timer <= 0.0:
			var chunk_for_examine: Dictionary = layer3.get_current_chunk()
			var chunk_obj: String = chunk_for_examine.get("object_id", "")
			if chunk_obj != "" and _should_examine(chunk_obj) and _world_object_registry != null:
				var obj_data_at_dest: Dictionary = _world_object_registry.get_object(chunk_obj)
				if not obj_data_at_dest.is_empty():
					_start_examine({"id": chunk_obj, "name": obj_data_at_dest.get("name", ""), "position": obj_data_at_dest.get("position", _last_world_pos), "state": obj_data_at_dest.get("state", ""), "type": obj_data_at_dest.get("type", "")})
					current_action = {"type": "examine", "target": obj_data_at_dest.get("position", _last_world_pos), "reason": "Examining " + obj_data_at_dest.get("name", "object"), "speed_mul": 0.0, "object_id": chunk_obj}
					return current_action

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
	## Find a visible entity worth observing.
	## When stalled, the closest entity IS interesting — it's what's blocking us.
	if layer1.is_stalled and perception.visible_entities.size() > 0:
		var closest: Dictionary = {}
		var closest_dist: float = 999999.0
		for entity in perception.visible_entities:
			if entity["distance"] < closest_dist:
				closest_dist = entity["distance"]
				closest = entity
		return closest
	# Normal: find someone we haven't looked at recently
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
	# Modulation is now continuous (every tick in update_layer1).
	# This method tracks chunk changes for logging only.
	if layer3 == null:
		return
	if layer3.current_chunk_index != _last_chunk_index:
		_last_chunk_index = layer3.current_chunk_index

func _check_urgency_replan(delta: float, hour: float) -> void:
	## When L1 drives cross critical thresholds, fire immediate L3 replan.
	_urgency_replan_cooldown = maxf(_urgency_replan_cooldown - delta, 0.0)
	if _urgency_replan_cooldown > 0.0:
		return
	if layer1 == null or layer3 == null:
		return

	var reason: String = ""
	if layer1.frustration > 0.7:
		reason = "frustration_spike"
	elif layer1.safety < 20.0:
		reason = "safety_critical"
	elif layer1.energy < 15.0:
		reason = "energy_critical"
	elif layer1.hunger > 90.0:
		reason = "hunger_critical"

	if reason != "":
		_urgency_replan_cooldown = URGENCY_REPLAN_MIN_INTERVAL
		npc_log("URGENCY REPLAN: " + reason)
		_force_replan(reason, hour)

func _force_replan(reason: String, hour: float) -> void:
	if layer3 == null:
		return
	var mem_summary: String = memory.get_memory_summary()
	mem_summary += "\nURGENT: " + reason
	if memory.concerns.size() > 0:
		mem_summary += "\nConcerns: " + ", ".join(memory.concerns)
	# Add chunk outcomes to context
	if _chunk_outcomes.size() > 0:
		mem_summary += "\nRecent task outcomes:"
		for co in _chunk_outcomes:
			mem_summary += "\n- %s at %s: %s" % [co.get("purpose", "?"), co.get("location", "?"), co.get("outcome", "?")]
	var emo_summary: String = layer2.get_emotion_summary() if layer2 else ""
	var obj_summary: String = memory.get_object_summary()
	layer3._last_plan_hour = -1.0  # reset timer gate
	layer3.update_plan(hour, mem_summary, emo_summary, _inference_client, obj_summary)

func on_chunk_completed() -> void:
	if layer3:
		var old_chunk: Dictionary = layer3.get_current_chunk()
		npc_log("CHUNK done: %s" % old_chunk.get("purpose", "?"))
		# Track outcome
		var outcome: String = "completed"
		if layer1 and layer1.frustration > 0.5:
			outcome = "completed_with_difficulty"
		_chunk_outcomes.append({
			"purpose": old_chunk.get("purpose", "unknown"),
			"location": old_chunk.get("location", "unknown"),
			"outcome": outcome
		})
		if _chunk_outcomes.size() > 5:
			_chunk_outcomes.pop_front()
		layer3.advance_chunk()
		var new_chunk: Dictionary = layer3.get_current_chunk()
		npc_log("CHUNK next: %s @ %s" % [new_chunk.get("purpose", "?"), new_chunk.get("location", "?")])
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
		memory.add_tagged_event("Refused player — too busy", 0.3, ["interaction", "player"], "direct", "player_interaction")
		memory.update_relationship("Player", -0.01, "Tried to talk but I was busy")
		return

	var emo_summary: String = ""
	if layer2:
		emo_summary = layer2.get_emotion_summary()

	var trust_val: float = memory.get_trust("Player")
	var rel_context: String = "Trust: %.2f" % trust_val
	var obj_ctx: String = memory.get_object_dialogue_context(role)
	if obj_ctx != "":
		rel_context += ". " + obj_ctx
	var recent: Array = memory.get_recent_events_text(3)

	layer3.request_dialogue(emo_summary, rel_context, recent, _inference_client, callback)

	# Record the interaction
	memory.add_tagged_event("Player spoke to me", 0.6, ["interaction", "player"], "direct", "player_interaction")
	memory.update_relationship("Player", 0.02, "Player initiated conversation")

	# Interruption if doing a task
	if layer1.task_momentum > 0.3:
		layer1.apply_interruption()
		memory.add_tagged_event("Player interrupted my task", 0.5, ["interruption"], "direct", "interruption")
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

func update_perception(facing: String, my_pos: Vector2, all_npcs: Array, player: Node = null) -> void:
	"""Update perception via SensorSystem queries. Called every tick from npc_controller.
	Brain NEVER computes visibility directly — all perception goes through SensorSystem.
	Results are graded (exposure/confidence), not binary."""
	if perception == null:
		return
	perception.set_facing(facing)
	perception.clear_vision_queries()

	# Build entity list — everything with a position that isn't us
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
	if player and is_instance_valid(player):
		entities.append({
			"name": "Player",
			"position": player.global_position,
			"doing": "exploring",
			"facing": player._facing if "_facing" in player else "",
		})

	# --- Vision via SensorSystem ---
	perception.visible_entities.clear()
	if _sensor_system != null and not _sensor_profile.is_empty():
		var SRTScript: GDScript = load("res://scripts/sensory_result_types.gd")
		var actor_offsets: Array = SRTScript.actor_sample_offsets()

		for entity in entities:
			var target_pos: Vector2 = entity["position"]
			var vr: Dictionary = _sensor_system.query_vision(
				my_pos, perception.facing_vector, _sensor_profile,
				target_pos, actor_offsets
			)
			# Cache the result
			perception.cache_vision_result(entity["name"], vr)
			# Record for debug visualization
			perception.record_vision_query(my_pos, target_pos, entity["name"], vr)

			if vr.get("visible", false):
				perception.visible_entities.append({
					"name": entity["name"],
					"position": target_pos,
					"distance": vr.get("distance", 0.0),
					"doing": entity.get("doing", ""),
					"facing": entity.get("facing", ""),
					"exposure": vr.get("exposure", 0.0),
					"confidence": vr.get("confidence", 0.0),
					"vision_result": vr,
				})

	# Record observations for visible entities — include confidence level
	for seen in perception.visible_entities:
		var doing: String = seen.get("doing", "")
		var confidence: float = seen.get("confidence", 0.0)
		var obs_text: String = doing if doing != "" else "walking"
		if confidence < 0.5:
			obs_text += " (barely visible)"
		memory.add_observation(seen["name"], "", obs_text)

	# --- Object perception via SensorSystem ---
	perception.visible_objects.clear()
	if _world_object_registry != null:
		if _sensor_system != null and not _sensor_profile.is_empty():
			var SRTScript2: GDScript = load("res://scripts/sensory_result_types.gd")
			var obj_offsets: Array = SRTScript2.object_sample_offsets()
			var all_objects: Array = _world_object_registry.get_all_objects()
			for obj in all_objects:
				var obj_pos: Vector2 = obj.get("position", Vector2.ZERO)
				var vr: Dictionary = _sensor_system.query_vision(
					my_pos, perception.facing_vector, _sensor_profile,
					obj_pos, obj_offsets
				)
				if vr.get("visible", false):
					perception.visible_objects.append({
						"id": obj.get("id", ""),
						"name": obj.get("name", ""),
						"type": obj.get("type", ""),
						"position": obj_pos,
						"distance": vr.get("distance", 0.0),
						"state": obj.get("state", ""),
						"owner": obj.get("owner", ""),
						"exposure": vr.get("exposure", 0.0),
						"confidence": vr.get("confidence", 0.0),
					})
		_process_visible_objects()

	# --- Hearing via StimulusRegistry + SensorSystem ---
	if _sensor_system != null and not _sensor_profile.is_empty():
		var hearing_results: Array = _sensor_system.query_hearing_all(my_pos, _sensor_profile)
		for hr in hearing_results:
			var stim_type: String = hr.get("stimulus_type", "")
			var emitter: String = hr.get("emitter_id", "")
			var tags: Array = hr.get("tags", [])
			var vol: float = hr.get("perceived_volume", 0.0)
			var clarity: float = hr.get("clarity", 0.0)
			var est_pos: Vector2 = hr.get("estimated_source_pos", Vector2.ZERO)
			var direction: Vector2 = hr.get("direction", Vector2.ZERO)

			if emitter == npc_name:
				continue  # don't hear ourselves

			# Record for debug visualization
			perception.record_hearing_result(hr)

			if stim_type == "speech":
				# Extract speech text from tags (last tag if it's dialogue content)
				var speech_text: String = ""
				for tag in tags:
					if tag != "speech" and tag != "dialogue" and tag != "player":
						speech_text = tag
						break
				if clarity > 0.6:
					memory.add_tagged_event(
						"Heard %s say: %s" % [emitter, speech_text],
						0.4 * vol,
						["heard", "overheard"],
						emitter, "speech", clarity
					)
				else:
					# Low clarity: uncertain hearing — "heard something"
					var dir_name: String = _direction_to_name(direction)
					memory.add_tagged_event(
						"Heard someone speaking %s of me" % dir_name,
						0.2 * vol,
						["heard", "uncertain"],
						"", "speech_uncertain", clarity
					)
			elif stim_type == "footstep":
				# Footsteps only noticed at moderate volume (not always logged)
				if vol > 0.3:
					var dir_name: String = _direction_to_name(direction)
					memory.add_tagged_event(
						"Heard footsteps %s of me" % dir_name,
						0.15 * vol,
						["heard", "footstep", "uncertain"],
						"", "footstep", clarity
					)
			elif stim_type == "impact":
				var dir_name: String = _direction_to_name(direction)
				var salience: float = 0.5 * vol
				if clarity > 0.5:
					memory.add_tagged_event(
						"Heard a loud noise from %s's direction" % emitter if emitter != "" else "Heard a loud noise %s of me" % dir_name,
						salience,
						["heard", "impact"],
						emitter, "impact", clarity
					)
				else:
					memory.add_tagged_event(
						"Heard something %s of me" % dir_name,
						salience * 0.5,
						["heard", "uncertain"],
						"", "impact_uncertain", clarity
					)
	else:
		# Fallback: process anything heard via direct perception.hear() calls
		var heard: Array = perception.consume_heard()
		for evt in heard:
			memory.add_tagged_event(
				"Heard %s say: %s" % [evt["source"], evt["text"]],
				0.4,
				["heard", "overheard"],
				evt["source"], "speech"
			)

func _process_visible_objects() -> void:
	"""Process newly visible objects: add to memory, create events for discoveries and state changes."""
	if perception == null or memory == null:
		return
	for obj in perception.visible_objects:
		var obj_id: String = obj.get("id", "")
		if obj_id == "":
			continue
		var obj_name: String = obj.get("name", "")
		var obj_type: String = obj.get("type", "")
		var obj_state: String = obj.get("state", "")
		var obj_pos: Vector2 = obj.get("position", Vector2.ZERO)
		var obj_owner: String = obj.get("owner", "")

		# Determine location from registry
		var obj_location: String = ""
		if _world_object_registry:
			var full_obj: Dictionary = _world_object_registry.get_object(obj_id)
			obj_location = full_obj.get("location", "")

		var known: Dictionary = memory.get_known_object(obj_id)
		var is_new: bool = known.is_empty()
		var state_changed: bool = (not is_new) and known.get("last_seen_state", "") != obj_state

		# Upsert object knowledge
		memory.add_object_knowledge(obj_id, obj_name, obj_type, obj_pos, obj_state, obj_location, "direct")

		# Determine salience based on role affinity
		var base_salience: float = 0.4
		var full_obj_data: Dictionary = {}
		if _world_object_registry:
			full_obj_data = _world_object_registry.get_object(obj_id)
		var affinities: Array = full_obj_data.get("role_affinity", [])
		if affinities.size() == 0 or role in affinities:
			base_salience = 0.8  # Role-relevant
		else:
			base_salience = 0.4  # Not role-relevant

		# Create tagged events for discoveries
		if is_new:
			var event_text: String = "Discovered %s at %s (state: %s)" % [obj_name, obj_location, obj_state]
			var obj_kind: String = "object_problem" if obj_state in ["broken", "empty", "locked"] else "object_discovery"
			memory.add_tagged_event(event_text, base_salience, ["object_discovery", obj_type], "direct", obj_kind)

		# State change event
		if state_changed:
			var old_state: String = known.get("last_seen_state", "unknown")
			var event_text: String = "Noticed %s at %s changed from %s to %s" % [obj_name, obj_location, old_state, obj_state]
			var change_kind: String = "object_problem" if obj_state in ["broken", "empty", "locked"] else "object_state_change"
			memory.add_tagged_event(event_text, base_salience, ["object_state_change", obj_type], "direct", change_kind)

# --- EXAMINE action helpers ---

func _should_examine(object_id: String) -> bool:
	## Returns true if the object hasn't been examined recently (>5 minutes = 300000ms).
	if not _last_examine_times.has(object_id):
		return true  # Never examined
	var last_time: int = _last_examine_times[object_id]
	return (Time.get_ticks_msec() - last_time) > 300000

func _start_examine(obj: Dictionary) -> void:
	## Begin examining an object. NPC stops and faces it for 1-2 seconds.
	_examining_object_id = obj.get("id", "")
	_examine_timer = randf_range(1.0, 2.0)
	_last_examine_times[_examining_object_id] = Time.get_ticks_msec()
	memory.add_observation(npc_name, "", "Examining " + obj.get("name", "object"))

func _finish_examine() -> void:
	## Called when examine timer expires. Updates object memory and creates events.
	if _examining_object_id == "" or _world_object_registry == null:
		_examining_object_id = ""
		return
	var obj: Dictionary = _world_object_registry.get_object(_examining_object_id)
	if obj.is_empty():
		_examining_object_id = ""
		return

	var obj_name: String = obj.get("name", "")
	var obj_state: String = obj.get("state", "")
	var obj_type: String = obj.get("type", "")
	var obj_loc: String = obj.get("location", "")
	var obj_pos: Vector2 = obj.get("position", Vector2.ZERO)

	# Update memory with fresh state from registry
	memory.add_object_knowledge(_examining_object_id, obj_name, obj_type, obj_pos, obj_state, obj_loc, "direct")

	# Check if object state is problematic
	if obj_state in ["broken", "empty", "locked"]:
		var affinities: Array = obj.get("role_affinity", [])
		var is_my_domain: bool = affinities.size() == 0 or role in affinities
		var salience: float = 0.8 if is_my_domain else 0.4
		var event_text: String = "Examined %s at %s — it's %s" % [obj_name, obj_loc, obj_state]
		memory.add_tagged_event(event_text, salience, ["object_examine", "problematic", obj_type], "direct", "object_problem")

		if is_my_domain:
			# Add concern and inject a fix chunk into the plan
			var concern: String = "%s at %s is %s" % [obj_name, obj_loc, obj_state]
			memory.add_concern(concern)
			if layer3:
				var fix_purpose: String = ""
				match obj_state:
					"broken":
						fix_purpose = "Fix the %s" % obj_name
					"empty":
						fix_purpose = "Restock the %s" % obj_name
					"locked":
						fix_purpose = "Unlock the %s" % obj_name
				layer3.inject_object_concern_chunk(fix_purpose, obj_loc, _examining_object_id, "fix")
				print("[Brain] %s: Discovered problematic %s (%s) — replanning" % [npc_name, obj_name, obj_state])
	else:
		memory.add_tagged_event("Examined %s at %s — %s" % [obj_name, obj_loc, obj_state], 0.3, ["object_examine"], "direct", "object_examine")

	_examining_object_id = ""

func _find_examinable_object() -> Dictionary:
	## Find a role-relevant visible object that hasn't been examined recently.
	if perception == null or _world_object_registry == null:
		return {}
	for obj in perception.visible_objects:
		var obj_id: String = obj.get("id", "")
		if obj_id == "" or not _should_examine(obj_id):
			continue
		# Check role affinity
		var full_obj: Dictionary = _world_object_registry.get_object(obj_id)
		var affinities: Array = full_obj.get("role_affinity", [])
		if affinities.size() > 0 and role not in affinities:
			continue
		# Only auto-examine if role-relevant
		return {"id": obj_id, "name": obj.get("name", ""), "position": obj.get("position", Vector2.ZERO), "state": obj.get("state", ""), "type": obj.get("type", "")}
	return {}

func hear_speech(source_name: String, text: String, source_pos: Vector2, my_pos: Vector2) -> void:
	"""Called when someone speaks nearby. Omnidirectional hearing check.
	Note: With StimulusRegistry active, this is only used as a fallback."""
	if perception == null:
		return
	perception.hear(source_name, text, source_pos, my_pos)

static func _direction_to_name(dir: Vector2) -> String:
	"""Convert a direction vector to a compass name."""
	if dir.length_squared() < 0.01:
		return "nearby"
	var angle: float = rad_to_deg(dir.angle())
	# angle: 0=right, 90=down, -90=up, 180/-180=left (Godot 2D coords)
	if angle >= -22.5 and angle < 22.5:
		return "to the east"
	elif angle >= 22.5 and angle < 67.5:
		return "to the southeast"
	elif angle >= 67.5 and angle < 112.5:
		return "to the south"
	elif angle >= 112.5 and angle < 157.5:
		return "to the southwest"
	elif angle >= 157.5 or angle < -157.5:
		return "to the west"
	elif angle >= -157.5 and angle < -112.5:
		return "to the northwest"
	elif angle >= -112.5 and angle < -67.5:
		return "to the north"
	else:
		return "to the northeast"

func get_visible_npc_count() -> int:
	if perception:
		return perception.visible_entities.size()
	return 0
