extends RefCounted
## res://scripts/npc_brain.gd — Orchestrates all three AI layers for one NPC

const BUILDING_SIGHT_RANGE: float = 400.0  # pixels — how far buildings are visible

var npc_name: String = ""
var role: String = ""

# Sub-systems
var layer1: RefCounted = null  # Layer1Substrate
var layer2: RefCounted = null  # Layer2Projection
var layer3: RefCounted = null  # Layer3Executive
var memory: RefCounted = null  # MemorySystem
var perception: RefCounted = null  # Perception (FOV + hearing)
var inventory: RefCounted = null  # Inventory (on-person items)

# References
var _inference_client: Node = null
var _game_manager: Node = null
var _world_object_registry: Node = null

var _last_world_pos: Vector2 = Vector2.ZERO

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
var _arrival_hour: float = -1.0       # game-hour when NPC arrived at destination
var _chunk_end_hour: float = -1.0     # game-hour when current chunk should complete

# EXAMINE action state
var _examine_timer: float = 0.0
var _examining_object_id: String = ""
var _last_examine_times: Dictionary = {}  # object_id -> ticks_msec

# Hearing dedup — skip stimuli already processed
var _heard_stimulus_ids: Dictionary = {}  # stimulus_id -> tick when heard

# --- Thought loop state (server-pushed) ---
var active_intentions: Array[Dictionary] = []  # [{goal, location, priority, reason, timestamp}]
var current_thought: String = ""
var _server_action_biases: Dictionary = {}  # {action_name: bias_value} from server
var _server_action_override: Dictionary = {}  # timed action from server command
var _override_timer: float = 0.0  # seconds remaining on current override
var _last_server_push_tick: int = 0  # ticks_msec of last server push — used to detect thought loop active

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
	# Memory created before L1 so somatic stream can read place conditioning
	var MemScript: GDScript = load("res://scripts/memory_system.gd")
	memory = MemScript.new()
	memory.npc_name = npc_name
	memory.npc_role = role
	memory.on_tagged_event = func(desc: String, salience: float) -> void:
		npc_log("MEM [%.1f]: %s" % [salience, desc])

	# Seed location discovery: NPC knows home, work, and schedule locations from birth
	var known_locs: Array = []
	var home_loc: String = str(_persona.get("home_location", ""))
	var work_loc: String = str(_persona.get("work_location", ""))
	if home_loc != "":
		known_locs.append(home_loc)
	if work_loc != "" and work_loc != home_loc:
		known_locs.append(work_loc)
	var schedule: Array = _persona.get("schedule", [])
	for chunk in schedule:
		if chunk is Dictionary:
			var loc: String = str(chunk.get("location", ""))
			if loc != "" and loc not in known_locs:
				known_locs.append(loc)
	memory.seed_known_locations(known_locs)

	layer1.setup(_persona, memory)

	var L2Script: GDScript = load("res://scripts/layer2_projection.gd")
	layer2 = L2Script.new()
	layer2.setup(npc_name, role, _persona)
	layer2.on_limbic_event = func(msg: String) -> void:
		npc_log(msg)

	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	layer3 = L3Script.new()
	layer3.setup(npc_name, role, _persona)

	# Inventory — on-person items (5 slots)
	var InvScript: GDScript = load("res://scripts/inventory.gd")
	inventory = InvScript.new(5)
	var starting_items: Array = _persona.get("starting_inventory", [])
	for item in starting_items:
		if item is Dictionary:
			inventory.add(item.get("id", ""), item.get("name", ""), item.get("category", ""), item.get("quantity", 1))
		elif item is String:
			inventory.add(item, item.capitalize(), "", 1)

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

# --- Server push command processing ---

func is_thought_loop_active() -> bool:
	## Returns true if the server thought loop has pushed commands recently.
	return (Time.get_ticks_msec() - _last_server_push_tick) < 10000  # 10 seconds

func process_server_commands(commands: Array) -> void:
	## Process commands pushed by the server thought loop.
	_last_server_push_tick = Time.get_ticks_msec()
	for cmd in commands:
		if cmd is not Dictionary:
			continue
		var cmd_type: String = cmd.get("cmd", "")
		match cmd_type:
			"update_emotion":
				var vec: Array = cmd.get("vector", [])
				if layer2 and vec.size() == 27:
					layer2.emotion_vector = vec
					layer2._update_top_dimensions()
					layer2._compute_valence()
					layer2.limbic_last_update = Time.get_ticks_msec()
			"set_intention":
				_add_intention(cmd)
			"clear_intention":
				_remove_intention(cmd.get("goal", ""))
			"store_belief":
				if memory:
					memory.add_belief(
						cmd.get("subject", ""),
						cmd.get("predicate", ""),
						cmd.get("object", ""),
						cmd.get("confidence", 0.5),
						cmd.get("source", "self"),
					)
			"bias_action":
				_server_action_biases = cmd.get("biases", {})
			"set_thought":
				current_thought = cmd.get("text", "")
				npc_log("THOUGHT: " + current_thought)
			"trigger_action":
				_set_override(cmd, cmd.get("duration", 3.0))
			"speak":
				# Adventure-command SAY: trigger speech via controller
				var speech_text: String = cmd.get("text", "")
				if speech_text:
					npc_log("SAY: " + speech_text)
					_set_override({
						"type": "speak",
						"text": speech_text,
						"target": cmd.get("target", ""),
					}, 3.0)  # 3s to deliver the line
			"examine":
				# Adventure-command EXAMINE: trigger object examination
				var obj_id: String = cmd.get("object_id", "")
				if obj_id:
					npc_log("EXAMINE: " + obj_id)
					_set_override({
						"type": "examine",
						"object_id": obj_id,
						"target": cmd.get("target"),
					}, 4.0)  # 4s to inspect
			"take_item":
				var item_name: String = cmd.get("item", "")
				if item_name and inventory and _world_object_registry:
					var loc: String = layer3.location_name_from_position(_last_world_pos) if layer3 else ""
					var world_item: Dictionary = _world_object_registry.find_item_by_name(item_name, loc)
					if not world_item.is_empty():
						var obj_id: String = world_item.get("id", "")
						var iid: String = world_item.get("item_id", item_name.to_lower())
						var cat: String = world_item.get("properties", {}).get("category", "")
						var added: int = inventory.add(iid, world_item.get("name", item_name), cat, 1)
						if added > 0:
							_world_object_registry.remove_object(obj_id)
							npc_log("TAKE: %s (world obj %s removed)" % [item_name, obj_id])
							memory.add_tagged_event("Picked up %s" % item_name, 0.3, ["inventory", "take"], "direct", "inventory")
						else:
							npc_log("TAKE FAILED (full): %s" % item_name)
					else:
						npc_log("TAKE FAILED (not here): %s at %s" % [item_name, loc])
			"consume_item":
				var item_name: String = cmd.get("item", "")
				var item_id: String = item_name.to_lower()
				if item_name and inventory and inventory.has(item_id):
					var cat: String = _get_item_category(item_id)
					inventory.remove(item_id, 1)
					npc_log("CONSUME: %s (%s)" % [item_name, cat])
					if layer1:
						_apply_consume_effects_by_category(cat)
					memory.add_tagged_event("Consumed %s" % item_name, 0.4, ["inventory", "consume"], "direct", "consumption")
			"drop_item":
				var item_name: String = cmd.get("item", "")
				var item_id: String = item_name.to_lower()
				if item_name and inventory and inventory.has(item_id):
					var cat: String = _get_item_category(item_id)
					inventory.remove(item_id, 1)
					# Spawn as world object at NPC's position
					if _world_object_registry:
						var loc: String = layer3.location_name_from_position(_last_world_pos) if layer3 else ""
						_world_object_registry.spawn_item(item_id, item_name.capitalize(), cat, _last_world_pos, loc)
					npc_log("DROP: %s" % item_name)
					memory.add_tagged_event("Dropped %s" % item_name, 0.2, ["inventory", "drop"], "direct", "inventory")
			"give_item":
				var item_id: String = cmd.get("item", "")
				var target_name: String = cmd.get("target", "")
				if item_id and target_name and inventory and inventory.has(item_id):
					# Drop item — controller handles finding the target NPC
					inventory.remove(item_id, 1)
					npc_log("GIVE: %s to %s" % [item_id, target_name])
					memory.add_tagged_event("Gave %s to %s" % [item_id, target_name], 0.5, ["inventory", "give", "social"], "direct", "social")
					_set_override({
						"type": "give",
						"item_id": item_id,
						"item_name": item_id.capitalize(),
						"target": target_name,
					}, 3.0)  # 3s to hand over
			"motor_command":
				# Adventure-command: convert to action override for entity-targeted commands
				var motor_cmd: String = cmd.get("command", "")
				var motor_target: Variant = cmd.get("target")
				if motor_cmd:
					npc_log("CMD: " + motor_cmd)
					_handle_motor_command(motor_cmd, motor_target)

func _get_item_category(item_id: String) -> String:
	## Look up item category from inventory, fall back to common names.
	if inventory:
		for item in inventory.get_items():
			if item["id"] == item_id:
				return item.get("category", "")
	if item_id in ["bread", "apple", "stew", "pie"]:
		return "food"
	if item_id in ["ale", "water", "wine", "tea"]:
		return "drink"
	if item_id in ["remedy", "potion", "salve"]:
		return "medicine"
	return ""

func _apply_consume_effects_by_category(cat: String) -> void:
	## Apply drive changes from consuming an item by category.
	match cat:
		"food":
			layer1.hunger = maxf(layer1.hunger - 30.0, 0.0)
			layer1.energy = minf(layer1.energy + 5.0, 100.0)
		"drink":
			layer1.hunger = maxf(layer1.hunger - 10.0, 0.0)
			layer1.energy = minf(layer1.energy + 15.0, 100.0)
		"medicine":
			layer1.energy = minf(layer1.energy + 25.0, 100.0)
			layer1.safety = minf(layer1.safety + 10.0, 100.0)

func _add_intention(cmd: Dictionary) -> void:
	var goal: String = cmd.get("goal", "")
	if goal == "":
		return
	# Replace existing intention with same goal if priority is higher
	for i in range(active_intentions.size()):
		if active_intentions[i].get("goal", "") == goal:
			if cmd.get("priority", 0.0) > active_intentions[i].get("priority", 0.0):
				active_intentions[i] = {
					"goal": goal,
					"location": cmd.get("location", ""),
					"priority": cmd.get("priority", 0.5),
					"reason": cmd.get("reason", ""),
					"timestamp": Time.get_ticks_msec(),
				}
			return
	active_intentions.append({
		"goal": goal,
		"location": cmd.get("location", ""),
		"priority": cmd.get("priority", 0.5),
		"reason": cmd.get("reason", ""),
		"timestamp": Time.get_ticks_msec(),
	})
	npc_log("INTENTION: %s at %s (%.1f)" % [goal, cmd.get("location", "?"), cmd.get("priority", 0.5)])

func _remove_intention(goal: String) -> void:
	if goal == "":
		return
	var new_list: Array[Dictionary] = []
	for intent in active_intentions:
		if intent.get("goal", "") != goal:
			new_list.append(intent)
	active_intentions = new_list

func _set_override(action: Dictionary, duration: float) -> void:
	## Set a timed action override. Momentary actions get short TTLs so the being
	## resumes its active intention afterward instead of being stuck.
	_server_action_override = action
	_override_timer = duration

func _handle_motor_command(cmd_str: String, target: Variant) -> void:
	## Convert a motor_command string into a timed action override or intention.
	## Momentary commands (LOOK AT, WAIT) get short TTLs — the being resumes
	## its active intention after the override expires.
	## Sustained commands (GO TO) use the intention system, not overrides.
	var target_dict: Dictionary = target if target is Dictionary else {}
	var target_type: String = target_dict.get("type", "")
	var target_name: String = target_dict.get("name", "")

	if cmd_str.begins_with("APPROACH ") and target_type == "entity":
		var pos: Vector2 = _resolve_entity_position(target_name)
		if pos != Vector2.ZERO:
			_set_override({
				"type": "move_toward",
				"target": pos,
				"reason": "CMD: APPROACH " + target_name,
				"speed_mul": 0.8,
			}, 5.0)  # 5s — enough to close distance, then resume intention
	elif cmd_str.begins_with("FLEE FROM ") and target_type == "entity":
		var pos: Vector2 = _resolve_entity_position(target_name)
		if pos != Vector2.ZERO:
			_set_override({
				"type": "flee",
				"target": pos,
				"reason": "CMD: FLEE FROM " + target_name,
			}, 8.0)  # 8s — reactive, needs more time
	elif cmd_str.begins_with("LOOK AT "):
		var pos: Vector2 = _resolve_target_position(target_dict)
		if pos != Vector2.ZERO:
			_set_override({
				"type": "observe",
				"target": pos,
				"reason": "CMD: LOOK AT " + target_name,
				"speed_mul": 0.0,
			}, 2.0)  # 2s glance — then resume walking
	elif cmd_str == "WAIT":
		_set_override({
			"type": "pause",
			"reason": "CMD: WAIT",
			"speed_mul": 0.0,
		}, 6.0)  # 6s deliberate pause
	elif cmd_str == "WANDER" or cmd_str.begins_with("WANDER AT "):
		_set_override({
			"type": "wander",
			"target": _last_world_pos,
			"reason": "CMD: " + cmd_str,
			"speed_mul": 0.4,
		}, 8.0)  # 8s wander bout
	elif cmd_str.begins_with("EXPLORE ") and target_type == "direction":
		var explore_pos: Vector2 = _resolve_explore_direction(target_name)
		if explore_pos != Vector2.ZERO:
			_set_override({
				"type": "move_toward",
				"target": explore_pos,
				"reason": "CMD: EXPLORE " + target_name,
				"speed_mul": 0.8,
			}, 10.0)  # 10s — exploration needs commitment
	# GO TO <location> is handled via set_intention push — no override needed

func _resolve_entity_position(entity_name: String) -> Vector2:
	## Look up an entity's position from current perception.
	if perception == null:
		return Vector2.ZERO
	for entity in perception.visible_entities:
		if entity.get("name", "") == entity_name:
			return entity.get("position", Vector2.ZERO)
	return Vector2.ZERO

func _resolve_target_position(target_dict: Dictionary) -> Vector2:
	## Resolve a target dict to a world position.
	var target_type: String = target_dict.get("type", "")
	var target_name: String = target_dict.get("name", "")
	if target_type == "entity":
		return _resolve_entity_position(target_name)
	if target_type == "object" and perception:
		for obj in perception.visible_objects:
			if obj.get("name", "") == target_name or obj.get("id", "") == target_name:
				return obj.get("position", Vector2.ZERO)
	if target_type == "location" and layer3:
		var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
		if L3Cls.LOCATIONS.has(target_name):
			return L3Cls.LOCATIONS[target_name]
	return Vector2.ZERO

func _resolve_explore_direction(direction_name: String) -> Vector2:
	## Find nearest glimpsed-but-unvisited location matching the compass direction.
	if memory == null:
		return Vector2.ZERO
	var glimpsed_names: Array = memory.get_glimpsed_location_names()
	if glimpsed_names.is_empty():
		return Vector2.ZERO
	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	L3Script._ensure_locations_loaded()
	var best_pos: Vector2 = Vector2.ZERO
	var best_dist: float = 999999.0
	for loc_name in glimpsed_names:
		if not L3Script.LOCATIONS.has(loc_name):
			continue
		var loc_pos: Vector2 = L3Script.LOCATIONS[loc_name]
		var dir: Vector2 = loc_pos - _last_world_pos
		var cardinal: String = _direction_to_cardinal(dir)
		if cardinal == direction_name:
			var dist: float = dir.length()
			if dist < best_dist:
				best_dist = dist
				best_pos = loc_pos
	return best_pos

static func _direction_to_cardinal(dir: Vector2) -> String:
	if dir.length() < 1.0:
		return "here"
	var angle: float = rad_to_deg(atan2(dir.y, dir.x))
	if angle < -157.5 or angle >= 157.5:
		return "west"
	elif angle < -112.5:
		return "northwest"
	elif angle < -67.5:
		return "north"
	elif angle < -22.5:
		return "northeast"
	elif angle < 22.5:
		return "east"
	elif angle < 67.5:
		return "southeast"
	elif angle < 112.5:
		return "south"
	else:
		return "southwest"

func get_top_intention() -> Dictionary:
	## Return the highest priority active intention, or empty dict.
	if active_intentions.is_empty():
		return {}
	var best: Dictionary = active_intentions[0]
	for intent in active_intentions:
		if intent.get("priority", 0.0) > best.get("priority", 0.0):
			best = intent
	return best

const INTENTION_MAX_AGE_MS: int = 600000  # 10 minutes

func _maintain_intentions(hour: float) -> void:
	## Expire stale intentions. Inject night-time go-home fallback.
	var now: int = Time.get_ticks_msec()

	# Expire old non-routine intentions
	var fresh: Array[Dictionary] = []
	for intent in active_intentions:
		var age: int = now - intent.get("timestamp", now)
		if age < INTENTION_MAX_AGE_MS:
			fresh.append(intent)
		# Routine intentions don't expire
		elif intent.get("reason", "") == "daily routine":
			fresh.append(intent)
	active_intentions = fresh

	# Night fallback: if the server hasn't pushed a go-home intention by go_home_hour,
	# inject one locally so NPCs go home even without the server.
	if layer3 and _persona:
		var night: Dictionary = _persona.get("night_behavior", {})
		var go_home_hour: float = float(night.get("go_home_hour", 21.0))
		if hour >= go_home_hour or hour < 5.0:
			# Check if we already have a go-home intention
			var has_home_intent: bool = false
			for intent in active_intentions:
				if "home" in intent.get("goal", "").to_lower() or "rest" in intent.get("goal", "").to_lower() or "sleep" in intent.get("goal", "").to_lower():
					has_home_intent = true
					break
				if intent.get("location", "") == layer3.get_home_location():
					has_home_intent = true
					break
			if not has_home_intent:
				var night_override = night.get("override")
				if night_override != null and night_override is Dictionary:
					# Special night behavior (e.g., guard patrol)
					_add_intention({
						"goal": night_override.get("purpose", "Night activity"),
						"location": night_override.get("location", layer3.get_home_location()),
						"priority": 0.85,
						"reason": "night fallback",
					})
				else:
					_add_intention({
						"goal": "Rest at home",
						"location": layer3.get_home_location(),
						"priority": 0.85,
						"reason": "night fallback",
					})

func get_intention_target() -> Vector2:
	## Get position for the top active intention, or Vector2.ZERO if none.
	var intent: Dictionary = get_top_intention()
	if intent.is_empty():
		return Vector2.ZERO
	var loc_name: String = intent.get("location", "")
	if loc_name == "" or layer3 == null:
		return Vector2.ZERO
	var L3Cls: GDScript = load("res://scripts/layer3_executive.gd")
	if L3Cls.LOCATIONS.has(loc_name):
		return L3Cls.LOCATIONS[loc_name]
	return Vector2.ZERO

# Urgency replan state
var _urgency_replan_cooldown: float = 0.0
const URGENCY_REPLAN_MIN_INTERVAL: float = 30.0

# Chunk outcome tracking
var _chunk_outcomes: Array[Dictionary] = []

func _update_location_discovery(world_pos: Vector2, current_location: String) -> void:
	## Scan for buildings within sight range and update discovery state.
	## Beings discover locations by seeing them (glimpsed) or visiting them (visited).
	if memory == null or layer3 == null:
		return
	var L3Script: GDScript = load("res://scripts/layer3_executive.gd")
	L3Script._ensure_locations_loaded()
	for loc_name in L3Script.LOCATIONS:
		var loc_pos: Vector2 = L3Script.LOCATIONS[loc_name]
		var dist: float = world_pos.distance_to(loc_pos)
		if dist < BUILDING_SIGHT_RANGE:
			memory.discover_location(str(loc_name), "glimpsed")

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

	# Update location discovery — scan for visible buildings
	_update_location_discovery(world_pos, current_location)

	# Maintain intentions — expire old ones, inject night fallback
	_maintain_intentions(hour)

	# Legacy urgency replan — only when thought loop is NOT active
	if not is_thought_loop_active():
		_check_urgency_replan(delta, hour)

func update_layer2(_delta: float) -> void:
	## Async limbic server call — corrects emotion vector with trained model output.
	## Called every ~2 real seconds from npc_controller.gd.
	if layer2 == null or _inference_client == null:
		return
	var recent: Array = memory.get_recent_events_text(5)
	layer2.request_limbic_update(layer1.get_state_dict(), recent, _inference_client)

func get_limbic_attention() -> Array:
	## Returns limbic model's attention focus targets (if fresh).
	if layer2 != null and layer2.is_limbic_fresh(5000):
		return layer2.limbic_attention
	return []

func get_limbic_drives() -> Dictionary:
	## Returns limbic model's motivational drives (if fresh).
	if layer2 != null and layer2.is_limbic_fresh(5000):
		return layer2.limbic_drives
	return {}

func update_layer3(hour: float) -> void:
	if layer3 == null:
		return

	# When the thought loop is active, it drives planning via intentions.
	# Skip the legacy poll-based replan path entirely.
	if is_thought_loop_active():
		# Still track chunk changes for logging
		_check_modulation_trigger()
		# Still run reflection (thought loop doesn't replace this yet)
		_check_reflection(hour)
		memory.decay_events(0.5)
		return

	# Legacy fallback: poll-based replanning when server is down
	var replan_reason: String = _get_replan_reason()
	var ctx: Dictionary = {
		"npc_name": npc_name,
		"role": role,
		"hour": hour,
		"current_location": layer3.location_name_from_position(_last_world_pos),
		"current_chunk": layer3.get_current_chunk(),
		"replan_reason": replan_reason,
		"somatic_tags": layer1.get_somatic_tags() if layer1 else [],
		"chunk_outcomes": _chunk_outcomes,
	}
	var packet: Dictionary = memory.build_plan_packet(ctx)
	layer3.update_plan_from_packet(packet, _inference_client)

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
	var ctx: Dictionary = {"npc_name": npc_name, "role": role, "active_intention": get_current_action()}
	var packet: Dictionary = memory.build_reflection_packet(ctx)
	_inference_client.layer3_reflect_packet(packet, _on_reflection_result)

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


func get_target_position() -> Vector2:
	## Returns the best movement target, using intentions first, then schedule fallback.
	## Drive-based behavior is now emergent from the thought loop, not hardcoded thresholds.

	# 1. Server-pushed intentions (primary)
	var intent_target: Vector2 = get_intention_target()
	if intent_target != Vector2.ZERO:
		return intent_target

	# 2. Current chunk object target
	if layer3 and _world_object_registry:
		var obj_pos: Vector2 = layer3.get_object_target_position(_world_object_registry)
		if obj_pos != Vector2.ZERO:
			return obj_pos

	# 3. Fallback: layer3 schedule target (for when server is down)
	if layer3:
		return layer3.get_target_position()

	return Vector2(2096, 800)

func get_current_action() -> String:
	## What the NPC is currently doing — from intention if available, else schedule.
	var intent: Dictionary = get_top_intention()
	if not intent.is_empty():
		return intent.get("goal", "idle")
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
	## Softmax competition over action neurons — replaces the old priority queue.
	## The Hebbian network's action neuron activations now directly determine behavior.

	# Server action override takes priority while timer is active
	if not _server_action_override.is_empty() and _override_timer > 0.0:
		_override_timer -= delta
		if _override_timer <= 0.0:
			_server_action_override = {}
		else:
			return _build_action_from_override(_server_action_override)

	# Reorientation pause (mechanical, not AI)
	if layer1.reorientation_timer > 0.0:
		current_action = {"type": "pause", "reason": "Reorienting", "speed_mul": 0.0}
		return current_action

	# Continue in-progress examine
	if _examining_object_id != "" and _examine_timer > 0.0:
		_examine_timer -= delta
		if _examine_timer <= 0.0:
			_finish_examine()
		current_action = {"type": "examine", "reason": "Examining object", "speed_mul": 0.0, "object_id": _examining_object_id}
		return current_action

	# --- Softmax action selection ---
	# Read raw action neuron activations from Hebbian network
	var activations: Dictionary = {
		"flee": layer1.flee,
		"avoid": layer1.avoid,
		"observe": layer1.observe,
		"approach": layer1.approach,
		"help": layer1.help,
	}

	# Apply server-pushed biases from thought loop
	for action_name in _server_action_biases:
		if activations.has(action_name):
			activations[action_name] = clampf(
				activations[action_name] + _server_action_biases[action_name],
				0.0, 1.0
			)

	# Apply intention-derived biases
	_apply_intention_biases(activations)

	# Temperature-scaled softmax
	var temperature: float = 0.3
	var actions: Array = activations.keys()
	var exps: Array = []
	var exp_sum: float = 0.0
	for action_name in actions:
		var val: float = exp(activations[action_name] / temperature)
		exps.append(val)
		exp_sum += val

	# Stochastic selection
	var selected: String = "approach"
	if exp_sum > 0.0:
		var roll: float = randf() * exp_sum
		var cumulative: float = 0.0
		for i in range(actions.size()):
			cumulative += exps[i]
			if roll <= cumulative:
				selected = actions[i]
				break

	# Observe cooldown — prevent constant stop-start
	_observe_cooldown = maxf(_observe_cooldown - delta, 0.0)
	if selected == "observe" and _observe_cooldown > 0.0 and not layer1.is_stalled:
		selected = "approach"  # fall through to movement

	# Map selected action to concrete behavior
	current_action = _action_to_behavior(selected, delta)
	return current_action

func _apply_intention_biases(activations: Dictionary) -> void:
	## Intentions bias action neurons toward relevant behavior.
	var intent: Dictionary = get_top_intention()
	if intent.is_empty():
		return
	var intent_loc: String = intent.get("location", "")
	var intent_priority: float = intent.get("priority", 0.5)

	# If intention targets a different location, boost approach
	if intent_loc != "" and layer3:
		var current_loc: String = layer3.location_name_from_position(_last_world_pos)
		if current_loc != intent_loc:
			activations["approach"] = clampf(activations["approach"] + intent_priority * 0.3, 0.0, 1.0)

	# Goal text analysis for action hints
	var goal: String = intent.get("goal", "").to_lower()
	if "watch" in goal or "investigate" in goal or "look" in goal or "check" in goal:
		activations["observe"] = clampf(activations["observe"] + 0.15, 0.0, 1.0)
	if "help" in goal or "assist" in goal or "aid" in goal:
		activations["help"] = clampf(activations["help"] + 0.2, 0.0, 1.0)
	if "avoid" in goal or "stay away" in goal:
		activations["avoid"] = clampf(activations["avoid"] + 0.2, 0.0, 1.0)
	if "flee" in goal or "run" in goal or "escape" in goal:
		activations["flee"] = clampf(activations["flee"] + 0.3, 0.0, 1.0)

func _action_to_behavior(selected: String, delta: float) -> Dictionary:
	## Map abstract action selection to concrete movement/observation behavior.
	match selected:
		"flee":
			var threat: Dictionary = _find_threat()
			if not threat.is_empty():
				var away: Vector2 = (_last_world_pos - threat["position"]).normalized()
				memory.add_tagged_event("Fled from " + threat["name"], 0.5, ["flee", "danger"], "direct", "threat_response")
				return {"type": "flee_from", "target": _last_world_pos + away * 128.0, "entity": threat["name"], "reason": "Fleeing from " + threat["name"], "speed_mul": 1.4}
			# No visible threat but flee won — seek safety
			return {"type": "move_toward", "target": _safest_familiar_location(), "speed_mul": 1.2, "reason": "Seeking safety"}

		"avoid":
			if perception and perception.visible_entities.size() > 0:
				var nearest: Dictionary = perception.visible_entities[0]
				for e in perception.visible_entities:
					if e.get("distance", 999.0) < nearest.get("distance", 999.0):
						nearest = e
				var away: Vector2 = (_last_world_pos - nearest["position"]).normalized()
				return {"type": "move_toward", "target": _last_world_pos + away * 64.0, "speed_mul": 0.8, "reason": "Avoiding " + nearest.get("name", "entity")}
			return {"type": "wander", "target": _last_world_pos, "speed_mul": 0.4, "reason": "Drifting"}

		"observe":
			var interesting: Dictionary = _find_interesting_entity()
			if not interesting.is_empty():
				_observe_cooldown = 6.0 if not layer1.is_stalled else 2.0
				memory.add_observation(npc_name, "", "Stopped to observe " + interesting["name"])
				if layer1.is_stalled:
					var purpose: String = get_current_action()
					memory.add_tagged_event(
						"%s is in my way while I'm trying to %s" % [interesting["name"], purpose],
						0.4 + layer1.task_momentum * 0.4,
						["blocked", "frustration"], "direct", "path_blocked"
					)
				return {"type": "observe", "target": interesting["position"], "entity": interesting["name"], "duration": randf_range(0.8, 1.5), "reason": "Observing " + interesting["name"], "speed_mul": 0.0}
			# Nothing to observe — try examining nearby objects
			var examine_target: Dictionary = _find_examinable_object()
			if not examine_target.is_empty():
				_start_examine(examine_target)
				return {"type": "examine", "target": examine_target["position"], "reason": "Examining " + examine_target.get("name", "object"), "speed_mul": 0.0, "object_id": examine_target.get("id", "")}
			return {"type": "wander", "target": _last_world_pos, "speed_mul": 0.3, "reason": "Looking around"}

		"help":
			if perception:
				for entity in perception.visible_entities:
					if memory.compute_trust(entity["name"]) > 0.4:
						return {"type": "move_toward", "target": entity["position"], "speed_mul": 0.8, "reason": "Helping " + entity["name"]}
			return {"type": "wander", "target": _last_world_pos, "speed_mul": 0.4, "reason": "Looking to help"}

		"approach", _:
			# Where to go: intention target first, then schedule fallback
			var intent: Dictionary = get_top_intention()
			var target: Vector2 = get_intention_target()
			var reason: String = intent.get("goal", "") if not intent.is_empty() else ""
			if target == Vector2.ZERO:
				target = get_target_position()
			if reason == "":
				reason = get_current_action()
			var dist: float = _last_world_pos.distance_to(target)

			if dist < 48.0:
				# At destination — wander here while the thought loop decides next move
				if not _at_destination:
					_at_destination = true
					_path_retry_count = 0
					layer1.start_task()
					var location: String = layer3.location_name_from_position(_last_world_pos) if layer3 else "here"
					memory.add_observation(npc_name, location, "arrived for " + reason)
					npc_log("ARRIVED for '%s'" % reason)
				return {"type": "wander", "target": target, "reason": reason, "speed_mul": 0.4}

			_at_destination = false
			return {"type": "move_toward", "target": target, "reason": reason, "speed_mul": _compute_speed_mul()}

	return {"type": "idle", "reason": "default", "speed_mul": 0.0}

func _build_action_from_override(override: Dictionary) -> Dictionary:
	## Convert a server trigger_action or adventure-command to a concrete action dict.
	## Motor command overrides already have concrete action types — pass them through.
	var action_type: String = override.get("type", override.get("action", "observe"))
	if action_type in ["move_toward", "wander", "pause", "idle"]:
		return override
	match action_type:
		"observe":
			# Motor command path: target is a Vector2 position
			var direct_target: Variant = override.get("target")
			if direct_target is Vector2 and direct_target != Vector2.ZERO:
				return {"type": "observe", "target": direct_target, "reason": override.get("reason", "Server: observe"), "speed_mul": 0.0}
			# Legacy path: target_entity name lookup
			var target_name: String = override.get("target_entity", "")
			if target_name != "" and perception:
				for entity in perception.visible_entities:
					if entity["name"] == target_name:
						return {"type": "observe", "target": entity["position"], "entity": target_name, "reason": "Server: observe " + target_name, "speed_mul": 0.0}
			return {"type": "pause", "reason": "Server: observe (no target)", "speed_mul": 0.0}
		"flee":
			var flee_target: Vector2 = override.get("target", Vector2.ZERO)
			if flee_target is Vector2 and flee_target != Vector2.ZERO:
				# Flee away from entity position
				var away: Vector2 = (_last_world_pos - flee_target).normalized()
				return {"type": "flee_from", "target": _last_world_pos + away * 128.0, "reason": override.get("reason", "Server: flee"), "speed_mul": 1.4}
			return {"type": "flee_from", "target": _safest_familiar_location(), "reason": "Server: flee", "speed_mul": 1.4}
		"speak":
			# Adventure-command SAY: return speak action for controller to execute
			return {"type": "speak", "text": override.get("text", ""), "target": override.get("target", ""), "reason": "Server: speak", "speed_mul": 0.0}
		"examine":
			# Adventure-command EXAMINE: find object position and examine it
			var obj_id: String = override.get("object_id", "")
			if obj_id and perception:
				for obj in perception.visible_objects:
					if obj.get("id", "") == obj_id or obj.get("name", "") == obj_id:
						return {"type": "examine", "target": obj["position"], "object_id": obj_id, "reason": "Server: examine " + obj_id, "speed_mul": 0.0}
			return {"type": "pause", "reason": "Server: examine (no target)", "speed_mul": 0.0}
		_:
			return {"type": "pause", "reason": "Server: " + action_type, "speed_mul": 0.0}

func _find_threat() -> Dictionary:
	## Find a visible entity we distrust enough to flee from.
	for entity in perception.visible_entities:
		var trust_val: float = memory.compute_trust(entity["name"])
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

func _get_replan_reason() -> String:
	## Determine explicit replan reason from current state. No substring heuristics.
	if memory.concerns.size() > 0:
		return "new_high_priority_concern"
	var problems: Array = memory.get_problematic_objects()
	if problems.size() > 0:
		# Check role relevance
		for p in problems:
			if _world_object_registry:
				var full_obj: Dictionary = _world_object_registry.get_object(p.get("id", ""))
				var affinities: Array = full_obj.get("role_affinity", [])
				if affinities.size() == 0 or role in affinities:
					return "object_problem_detected"
	var recent_failures: int = 0
	for co in _chunk_outcomes:
		if co.get("outcome", "") in ["failed", "completed_with_difficulty"]:
			recent_failures += 1
	if recent_failures >= 2:
		return "repeated_failure"
	if layer1 and layer1.frustration > 0.7:
		return "frustration_spike"
	return "none"

func _force_replan(reason: String, hour: float) -> void:
	if layer3 == null:
		return
	var ctx: Dictionary = {
		"npc_name": npc_name,
		"role": role,
		"hour": hour,
		"current_location": layer3.location_name_from_position(_last_world_pos),
		"current_chunk": layer3.get_current_chunk(),
		"replan_reason": reason,
		"somatic_tags": layer1.get_somatic_tags() if layer1 else [],
		"chunk_outcomes": _chunk_outcomes,
	}
	var packet: Dictionary = memory.build_plan_packet(ctx)
	layer3._last_plan_hour = -1.0  # reset timer gate
	layer3.update_plan_from_packet(packet, _inference_client)

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
		memory.add_belief("Player", "approached while", "I was busy", 0.5, "self")
		return

	var trust_val: float = memory.compute_trust("Player")
	var ctx: Dictionary = {
		"npc_name": npc_name,
		"role": role,
		"target_name": "Player",
		"target_type": "player",
		"trust": trust_val,
		"somatic_tags": layer1.get_somatic_tags() if layer1 else [],
		"current_activity": get_current_action(),
		"current_chunk": layer3.get_current_chunk() if layer3 else {},
	}
	var packet: Dictionary = memory.build_dialogue_packet(ctx)
	layer3.request_dialogue_from_packet(packet, _inference_client, callback)

	# Record the interaction — beliefs instead of fixed trust deltas
	memory.add_tagged_event("Player spoke to me", 0.6, ["interaction", "player"], "direct", "player_interaction")
	memory.add_belief("Player", "initiated", "conversation", 0.5, "self")

	# Interruption if doing a task
	if layer1.task_momentum > 0.3:
		layer1.apply_interruption()
		memory.add_tagged_event("Player interrupted my task", 0.5, ["interruption"], "direct", "interruption")
		memory.add_belief("Player", "interrupted", "my work", 0.7, "self")

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
		# Prune expired stimulus IDs every ~60 ticks (avoid unbounded growth)
		var now_tick: int = Time.get_ticks_msec()
		if now_tick % 60 == 0:
			var expired: Array = []
			for sid in _heard_stimulus_ids:
				if now_tick - _heard_stimulus_ids[sid] > 10000:  # 10s expiry
					expired.append(sid)
			for sid in expired:
				_heard_stimulus_ids.erase(sid)

		for hr in hearing_results:
			var stim_id: String = hr.get("stimulus_id", "")
			var stim_type: String = hr.get("stimulus_type", "")
			var emitter: String = hr.get("emitter_id", "")
			var tags: Array = hr.get("tags", [])
			var vol: float = hr.get("perceived_volume", 0.0)
			var clarity: float = hr.get("clarity", 0.0)
			var est_pos: Vector2 = hr.get("estimated_source_pos", Vector2.ZERO)
			var direction: Vector2 = hr.get("direction", Vector2.ZERO)

			if emitter == npc_name:
				continue  # don't hear ourselves

			# Dedup: skip stimuli we already processed
			if stim_id != "" and _heard_stimulus_ids.has(stim_id):
				continue
			if stim_id != "":
				_heard_stimulus_ids[stim_id] = now_tick

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
