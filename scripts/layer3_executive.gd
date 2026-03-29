extends RefCounted
## res://scripts/layer3_executive.gd — Layer 3 executive planner via HTTP
## Slow cadence: ~every 30 game-minutes

# Town location data: name -> world position (tile center)
const LOCATIONS: Dictionary = {
	"bakery": Vector2(1712, 464),
	"guard_post": Vector2(2320, 464),
	"herbalist_shop": Vector2(528, 592),
	"courier_office": Vector2(816, 592),
	"blacksmith": Vector2(1168, 592),
	"town_square": Vector2(2096, 800),
	"market": Vector2(2768, 592),
	"farm": Vector2(2992, 592),
	"inn": Vector2(2096, 624),
	"home_north": Vector2(1712, 464),
	"home_east": Vector2(2768, 592),
	"home_south": Vector2(2096, 1200),
	"home_west": Vector2(528, 592),
	"well": Vector2(1800, 800),
	"road_east": Vector2(3500, 800),
	"road_south": Vector2(2096, 1600)
}

# Role -> home, work, default schedule
const ROLE_CONFIG: Dictionary = {
	"Baker": {"home": "bakery", "work": "bakery", "schedule": [
		{"location": "bakery", "duration": 6.0, "priority": 0.9, "purpose": "Bake morning bread"},
		{"location": "market", "duration": 3.0, "priority": 0.7, "purpose": "Sell bread at market"},
		{"location": "town_square", "duration": 2.0, "priority": 0.4, "purpose": "Socialize"},
		{"location": "bakery", "duration": 4.0, "priority": 0.8, "purpose": "Afternoon baking"},
	]},
	"Guard": {"home": "guard_post", "work": "guard_post", "schedule": [
		{"location": "guard_post", "duration": 4.0, "priority": 0.9, "purpose": "Morning watch"},
		{"location": "town_square", "duration": 2.0, "priority": 0.7, "purpose": "Patrol town square"},
		{"location": "market", "duration": 2.0, "priority": 0.6, "purpose": "Patrol market"},
		{"location": "road_east", "duration": 3.0, "priority": 0.8, "purpose": "Check east road"},
		{"location": "guard_post", "duration": 4.0, "priority": 0.9, "purpose": "Evening watch"},
	]},
	"Herbalist": {"home": "herbalist_shop", "work": "herbalist_shop", "schedule": [
		{"location": "herbalist_shop", "duration": 5.0, "priority": 0.9, "purpose": "Prepare remedies"},
		{"location": "farm", "duration": 2.0, "priority": 0.6, "purpose": "Gather herbs from farm"},
		{"location": "town_square", "duration": 2.0, "priority": 0.4, "purpose": "Rest and socialize"},
		{"location": "herbalist_shop", "duration": 4.0, "priority": 0.8, "purpose": "Afternoon treatments"},
	]},
	"Courier": {"home": "courier_office", "work": "courier_office", "schedule": [
		{"location": "courier_office", "duration": 2.0, "priority": 0.8, "purpose": "Sort deliveries"},
		{"location": "bakery", "duration": 1.0, "priority": 0.7, "purpose": "Deliver to bakery"},
		{"location": "blacksmith", "duration": 1.0, "priority": 0.7, "purpose": "Deliver to blacksmith"},
		{"location": "inn", "duration": 1.0, "priority": 0.6, "purpose": "Deliver to inn"},
		{"location": "market", "duration": 2.0, "priority": 0.5, "purpose": "Check for packages"},
		{"location": "road_east", "duration": 3.0, "priority": 0.8, "purpose": "Long distance delivery"},
		{"location": "courier_office", "duration": 2.0, "priority": 0.7, "purpose": "End of day sorting"},
	]},
	"Blacksmith": {"home": "blacksmith", "work": "blacksmith", "schedule": [
		{"location": "blacksmith", "duration": 6.0, "priority": 0.9, "purpose": "Forge tools and weapons"},
		{"location": "market", "duration": 2.0, "priority": 0.6, "purpose": "Sell wares"},
		{"location": "inn", "duration": 2.0, "priority": 0.4, "purpose": "Evening meal and rest"},
		{"location": "blacksmith", "duration": 3.0, "priority": 0.7, "purpose": "Late forging"},
	]},
	"Gossip": {"home": "home_south", "work": "town_square", "schedule": [
		{"location": "market", "duration": 3.0, "priority": 0.7, "purpose": "Gather news at market"},
		{"location": "town_square", "duration": 3.0, "priority": 0.8, "purpose": "Share stories"},
		{"location": "inn", "duration": 2.0, "priority": 0.6, "purpose": "Listen to travelers"},
		{"location": "bakery", "duration": 1.0, "priority": 0.5, "purpose": "Visit baker for gossip"},
		{"location": "well", "duration": 2.0, "priority": 0.6, "purpose": "Chat at the well"},
	]},
	"Farmer": {"home": "farm", "work": "farm", "schedule": [
		{"location": "farm", "duration": 6.0, "priority": 0.9, "purpose": "Tend crops"},
		{"location": "market", "duration": 2.0, "priority": 0.7, "purpose": "Sell produce"},
		{"location": "inn", "duration": 1.5, "priority": 0.4, "purpose": "Midday meal"},
		{"location": "farm", "duration": 4.0, "priority": 0.8, "purpose": "Afternoon farming"},
	]},
	"Innkeeper": {"home": "inn", "work": "inn", "schedule": [
		{"location": "inn", "duration": 5.0, "priority": 0.9, "purpose": "Prepare breakfast service"},
		{"location": "market", "duration": 2.0, "priority": 0.6, "purpose": "Buy supplies"},
		{"location": "inn", "duration": 8.0, "priority": 0.9, "purpose": "Run the inn"},
		{"location": "inn", "duration": 3.0, "priority": 0.8, "purpose": "Evening service until close"},
	]},
}

# Current plan
var agenda: Array[Dictionary] = []
var current_chunk_index: int = 0
var _role: String = ""
var _npc_name: String = ""
var _plan_timer: float = 0.0
var _plan_interval_minutes: float = 30.0  # game minutes
var _last_plan_hour: float = -1.0
var _pending_plan: bool = false
var _pending_dialogue: bool = false
var _dialogue_callback: Callable

func setup(npc_name: String, role: String) -> void:
	_npc_name = npc_name
	_role = role
	# Start with default schedule
	_load_default_schedule()

func _load_default_schedule() -> void:
	agenda.clear()
	current_chunk_index = 0
	if ROLE_CONFIG.has(_role):
		var config: Dictionary = ROLE_CONFIG[_role]
		for chunk in config["schedule"]:
			agenda.append(chunk.duplicate())

func get_home_location() -> String:
	if ROLE_CONFIG.has(_role):
		return ROLE_CONFIG[_role]["home"]
	return "town_square"

func get_work_location() -> String:
	if ROLE_CONFIG.has(_role):
		return ROLE_CONFIG[_role]["work"]
	return "town_square"

func get_current_chunk() -> Dictionary:
	if current_chunk_index < agenda.size():
		return agenda[current_chunk_index]
	return {}

func advance_chunk() -> void:
	current_chunk_index += 1
	if current_chunk_index >= agenda.size():
		current_chunk_index = 0

func get_target_position() -> Vector2:
	var chunk: Dictionary = get_current_chunk()
	if chunk.is_empty():
		return Vector2(2096, 800)  # fallback: town square
	var loc_name: String = chunk.get("location", "town_square")
	if LOCATIONS.has(loc_name):
		return LOCATIONS[loc_name]
	return Vector2(2096, 800)

func update_plan(hour: float, memory_summary: String, emotion_summary: String, inference_client: Node) -> void:
	# Check if it's time for a new plan (every 30 game-minutes)
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
	inference_client.layer3_plan(_role, memory_summary, context, emotion_summary, _on_plan_result)

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
	if _pending_dialogue:
		return
	if inference_client == null or not inference_client.is_server_available():
		callback.call(false, {"utterance": _get_default_greeting()})
		return
	_pending_dialogue = true
	_dialogue_callback = callback
	inference_client.layer3_dialogue(_role, emotion_summary, relationship_context, recent_events, _on_dialogue_result)

func _on_dialogue_result(success: bool, data: Dictionary) -> void:
	_pending_dialogue = false
	if _dialogue_callback.is_valid():
		if success and data.has("utterance"):
			_dialogue_callback.call(true, data)
		else:
			_dialogue_callback.call(false, {"utterance": _get_default_greeting()})

func _get_default_greeting() -> String:
	match _role:
		"Baker":
			return "Fresh bread today!"
		"Guard":
			return "Stay safe, traveler."
		"Herbalist":
			return "Need a remedy?"
		"Courier":
			return "Got a delivery?"
		"Blacksmith":
			return "Fine steel, fair prices."
		"Gossip":
			return "Have you heard the latest?"
		"Farmer":
			return "Good weather for crops."
		"Innkeeper":
			return "Welcome! Take a seat."
		_:
			return "Hello there."

func should_go_home(hour: float) -> bool:
	# NPCs return home around 21:00, except special roles
	if _role == "Innkeeper" and hour < 23.0:
		return false
	if _role == "Guard":
		return false  # Guard patrols at night
	return hour >= 21.0 or hour < 5.0

func get_night_behavior() -> Dictionary:
	if _role == "Guard":
		return {"location": "town_square", "duration": 8.0, "priority": 0.9, "purpose": "Night patrol"}
	return {"location": get_home_location(), "duration": 8.0, "priority": 1.0, "purpose": "Rest at home"}

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
