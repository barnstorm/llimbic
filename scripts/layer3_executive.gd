extends RefCounted
## res://scripts/layer3_executive.gd — Layer 3 executive planner via HTTP
## Slow cadence: ~every 30 game-minutes

# Town location data: name -> world position — loaded from data/locations.json
static var LOCATIONS: Dictionary = {}
static var _locations_loaded: bool = false

static func _ensure_locations_loaded() -> void:
	if _locations_loaded:
		return
	_locations_loaded = true
	var LoaderScript: GDScript = load("res://scripts/persona_loader.gd")
	var raw: Dictionary = LoaderScript.load_locations()
	for loc_name in raw:
		var loc_data: Dictionary = raw[loc_name]
		var pos: Array = loc_data.get("position", [2096, 800])
		LOCATIONS[loc_name] = Vector2(float(pos[0]), float(pos[1]))

# Persona data — loaded from data/npcs/{name}.json at setup
var _persona: Dictionary = {}

# Current plan
var agenda: Array[Dictionary] = []
var current_chunk_index: int = 0
var suspended_chunk: Dictionary = {}
var suspended_chunk_index: int = -1
var _role: String = ""
var _npc_name: String = ""
var _plan_timer: float = 0.0
var _plan_interval_minutes: float = 30.0  # game minutes
var _last_plan_hour: float = -1.0
var _pending_plan: bool = false
var _pending_dialogue: bool = false
var _dialogue_callback: Callable

func setup(npc_name: String, role: String, persona: Dictionary = {}) -> void:
	_npc_name = npc_name
	_role = role
	_persona = persona
	_ensure_locations_loaded()
	_load_default_schedule()

func _load_default_schedule() -> void:
	agenda.clear()
	current_chunk_index = 0
	var schedule: Array = _persona.get("schedule", [])
	for chunk in schedule:
		if chunk is Dictionary:
			agenda.append(chunk.duplicate())
	if agenda.is_empty():
		agenda.append({"location": "town_square", "duration": 4.0, "priority": 0.5, "purpose": "Idle"})

func get_home_location() -> String:
	return _persona.get("home_location", "town_square")

func get_work_location() -> String:
	return _persona.get("work_location", "town_square")

func get_current_chunk() -> Dictionary:
	if current_chunk_index < agenda.size():
		return agenda[current_chunk_index]
	return {}

func advance_chunk() -> void:
	current_chunk_index += 1
	if current_chunk_index >= agenda.size():
		current_chunk_index = 0
	clear_suspended()

func suspend_current_chunk() -> void:
	## Save the current chunk so it can be resumed after a drive override.
	if suspended_chunk_index >= 0:
		return  # Already have a suspended chunk
	suspended_chunk = get_current_chunk().duplicate()
	suspended_chunk_index = current_chunk_index

func resume_suspended() -> bool:
	## Resume the suspended chunk. Returns true if resumed, false if nothing to resume.
	if suspended_chunk_index < 0 or suspended_chunk.is_empty():
		return false
	if suspended_chunk_index < agenda.size():
		current_chunk_index = suspended_chunk_index
	suspended_chunk = {}
	suspended_chunk_index = -1
	return true

func clear_suspended() -> void:
	## Discard any suspended chunk (e.g., on normal chunk completion).
	suspended_chunk = {}
	suspended_chunk_index = -1

func get_target_position() -> Vector2:
	var chunk: Dictionary = get_current_chunk()
	if chunk.is_empty():
		return Vector2(2096, 800)  # fallback: town square
	var loc_name: String = chunk.get("location", "town_square")
	if LOCATIONS.has(loc_name):
		return LOCATIONS[loc_name]
	return Vector2(2096, 800)

func update_plan(hour: float, memory_summary: String, emotion_summary: String, inference_client: Node, object_summary: String = "") -> void:
	## Legacy prose-based planning — kept for backward compatibility.
	if _last_plan_hour < 0.0:
		_last_plan_hour = hour
	var diff: float = hour - _last_plan_hour
	if diff < 0:
		diff += 24.0
	if diff < _plan_interval_minutes / 60.0:
		return
	if _pending_plan:
		return
	_last_plan_hour = hour
	if inference_client == null or not inference_client.is_server_available():
		return
	_pending_plan = true
	var context: String = "Hour: %.1f, Location: %s" % [hour, get_current_chunk().get("location", "unknown")]
	if object_summary != "":
		context += "\n" + object_summary
	inference_client.layer3_plan(_role, memory_summary, context, emotion_summary, _on_plan_result, _npc_name)

func update_plan_from_packet(packet: Dictionary, inference_client: Node) -> void:
	## Structured packet-based planning. Replaces prose assembly.
	var hour: float = packet.get("hour", 0.0)
	if _last_plan_hour < 0.0:
		_last_plan_hour = hour
	var diff: float = hour - _last_plan_hour
	if diff < 0:
		diff += 24.0
	if diff < _plan_interval_minutes / 60.0:
		return
	if _pending_plan:
		return
	_last_plan_hour = hour

	# If no replan needed, use default schedule (no LLM call)
	var reason: String = packet.get("replan_reason", "none")
	if reason == "none":
		return

	if inference_client == null or not inference_client.is_server_available():
		return

	_pending_plan = true
	inference_client.layer3_plan_packet(packet, _on_plan_result)

func _on_plan_result(success: bool, data: Dictionary) -> void:
	_pending_plan = false
	if not success:
		return
	if data.has("agenda") and data["agenda"] is Array:
		var new_agenda: Array = data["agenda"]
		if new_agenda.size() > 0:
			agenda.clear()
			for chunk in new_agenda:
				if chunk is Dictionary:
					agenda.append(chunk)
			current_chunk_index = 0

func request_dialogue(emotion_summary: String, relationship_context: String, recent_events: Array, inference_client: Node, callback: Callable) -> void:
	## Legacy prose-based dialogue request.
	if _pending_dialogue:
		return
	if inference_client == null or not inference_client.is_server_available():
		callback.call(false, {"utterance": _get_default_greeting()})
		return
	_pending_dialogue = true
	_dialogue_callback = callback
	inference_client.layer3_dialogue(_role, emotion_summary, relationship_context, recent_events, _on_dialogue_result, _npc_name)

func request_dialogue_from_packet(packet: Dictionary, inference_client: Node, callback: Callable) -> void:
	## Structured packet-based dialogue request.
	if _pending_dialogue:
		return
	if inference_client == null or not inference_client.is_server_available():
		callback.call(false, {"utterance": _get_default_greeting()})
		return
	_pending_dialogue = true
	_dialogue_callback = callback
	inference_client.layer3_dialogue_packet(packet, _on_dialogue_result)

func _on_dialogue_result(success: bool, data: Dictionary) -> void:
	_pending_dialogue = false
	if _dialogue_callback.is_valid():
		if success and data.has("utterance"):
			_dialogue_callback.call(true, data)
		else:
			_dialogue_callback.call(false, {"utterance": _get_default_greeting()})

func _get_default_greeting() -> String:
	var dialogue: Dictionary = _persona.get("fallback_dialogue", {})
	return dialogue.get("greeting", "Hello there.")

func get_chunk_directive() -> String:
	## Generate a natural-language directive from the current plan chunk for Layer 2 modulation.
	var chunk: Dictionary = get_current_chunk()
	if chunk.is_empty():
		return "stay calm and alert"
	var priority: float = chunk.get("priority", 0.5)
	var purpose: String = chunk.get("purpose", "").to_lower()
	var parts: Array = []
	if priority > 0.8:
		parts.append("focus intensely, resist distractions")
	elif priority > 0.6:
		parts.append("stay focused")
	else:
		parts.append("be relaxed and open to interaction")
	if "patrol" in purpose or "watch" in purpose or "guard" in purpose:
		parts.append("stay alert and vigilant")
	if "sell" in purpose or "socialize" in purpose or "chat" in purpose or "gossip" in purpose:
		parts.append("be sociable and approachable")
	if "rest" in purpose or "sleep" in purpose:
		parts.append("wind down and recover")
	if "deliver" in purpose or "sort" in purpose:
		parts.append("move with purpose, minimize delays")
	return ", ".join(parts)

func should_go_home(hour: float) -> bool:
	var night: Dictionary = _persona.get("night_behavior", {})
	var go_home_hour: float = float(night.get("go_home_hour", 21.0))
	var override = night.get("override")
	# If override exists and hour is before go_home_hour, stay out
	if override != null and override is Dictionary:
		return false  # NPC has a night activity instead of going home
	return hour >= go_home_hour or hour < 5.0

func get_night_behavior() -> Dictionary:
	var night: Dictionary = _persona.get("night_behavior", {})
	var override = night.get("override")
	if override != null and override is Dictionary:
		return override
	return {"location": get_home_location(), "duration": 8.0, "priority": 1.0, "purpose": "Rest at home"}

func inject_object_concern_chunk(concern_text: String, location: String, object_id: String, object_action: String) -> void:
	## Insert a high-priority chunk right after the current one to address a problematic object.
	## This is triggered when an NPC discovers a broken/empty object in their domain.
	var fix_chunk: Dictionary = {
		"location": location,
		"duration": 2.0,
		"priority": 0.95,
		"purpose": concern_text,
		"object_id": object_id,
		"object_action": object_action,
	}
	var insert_idx: int = current_chunk_index + 1
	if insert_idx > agenda.size():
		insert_idx = agenda.size()
	agenda.insert(insert_idx, fix_chunk)
	print("[Layer3] %s: Injected concern chunk — %s (object: %s)" % [_npc_name, concern_text, object_id])

func get_object_target_position(world_object_registry: Node) -> Vector2:
	## If the current chunk has an object_id, return that object's position.
	## Otherwise return Vector2.ZERO (caller should use normal location target).
	var chunk: Dictionary = get_current_chunk()
	var obj_id: String = chunk.get("object_id", "")
	if obj_id == "" or world_object_registry == null:
		return Vector2.ZERO
	var obj: Dictionary = world_object_registry.get_object(obj_id)
	if obj.is_empty():
		return Vector2.ZERO
	return obj.get("position", Vector2.ZERO)

func location_name_from_position(world_pos: Vector2) -> String:
	var best_name: String = "unknown"
	var best_dist: float = 999999.0
	for loc_name in LOCATIONS:
		var loc_pos: Vector2 = LOCATIONS[loc_name]
		var dist: float = world_pos.distance_to(loc_pos)
		if dist < best_dist:
			best_dist = dist
			best_name = loc_name
	if best_dist > 200.0:
		return "unknown"
	return best_name
