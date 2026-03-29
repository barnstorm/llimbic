extends RefCounted
## res://scripts/memory_system.gd — Per-NPC memory storage and retrieval

const MAX_OBSERVATIONS: int = 20
const MAX_TAGGED_EVENTS: int = 10
const MAX_REFLECTIONS: int = 5
const MAX_CONCERNS: int = 5
const MAX_FAILED_STRATEGIES: int = 5

# Raw observations: who, where, doing what
var observations: Array[Dictionary] = []

# Tagged events with salience scoring
var tagged_events: Array[Dictionary] = []

# Relationship state: trust changes with reasons
var relationships: Dictionary = {}  # entity_name -> {trust: float, reasons: Array}

# Place familiarity: per-location visit count and comfort
var place_familiarity: Dictionary = {}  # location_name -> {visits: int, comfort: float}

# Unresolved concerns from Layer 3 reflection
var concerns: Array[String] = []

# Summarized reflections from Layer 3
var reflections: Array[String] = []

# Active plan chunks (survive interruption)
var active_intentions: Array[Dictionary] = []

# Failed strategies: recently blocked paths, failed plans
var failed_strategies: Array[Dictionary] = []

# Socially acquired beliefs with source identity + trust weight
var acquired_beliefs: Array[Dictionary] = []

# Known world objects: object_id -> {name, type, last_seen_position, last_seen_state, last_seen_time, learned_from, location}
var known_objects: Dictionary = {}

func add_observation(who: String, where: String, doing: String) -> void:
	var obs: Dictionary = {
		"who": who,
		"where": where,
		"doing": doing,
		"time": Time.get_ticks_msec()
	}
	observations.append(obs)
	if observations.size() > MAX_OBSERVATIONS:
		observations.pop_front()

func add_tagged_event(description: String, salience: float, tags: Array = [], source: String = "direct") -> void:
	var evt: Dictionary = {
		"description": description,
		"salience": salience,
		"tags": tags,
		"source": source,
		"time": Time.get_ticks_msec()
	}
	tagged_events.append(evt)
	# Sort by salience descending, keep top N
	tagged_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["salience"] > b["salience"])
	if tagged_events.size() > MAX_TAGGED_EVENTS:
		tagged_events.resize(MAX_TAGGED_EVENTS)

func update_relationship(entity_name: String, trust_delta: float, reason: String) -> void:
	if not relationships.has(entity_name):
		relationships[entity_name] = {"trust": 0.5, "reasons": []}
	var rel: Dictionary = relationships[entity_name]
	rel["trust"] = clampf(rel["trust"] + trust_delta, 0.0, 1.0)
	rel["reasons"].append(reason)
	if rel["reasons"].size() > 5:
		rel["reasons"].pop_front()

func get_trust(entity_name: String) -> float:
	if relationships.has(entity_name):
		return relationships[entity_name]["trust"]
	return 0.5  # neutral default

func visit_location(location_name: String) -> void:
	if not place_familiarity.has(location_name):
		place_familiarity[location_name] = {"visits": 0, "comfort": 0.3}
	var loc: Dictionary = place_familiarity[location_name]
	loc["visits"] += 1
	loc["comfort"] = clampf(loc["comfort"] + 0.05, 0.0, 1.0)

func get_location_comfort(location_name: String) -> float:
	if place_familiarity.has(location_name):
		return place_familiarity[location_name]["comfort"]
	return 0.3  # unfamiliar default

func add_concern(concern: String) -> void:
	concerns.append(concern)
	if concerns.size() > MAX_CONCERNS:
		concerns.pop_front()

func add_reflection(reflection: String) -> void:
	reflections.append(reflection)
	if reflections.size() > MAX_REFLECTIONS:
		reflections.pop_front()

func add_failed_strategy(description: String) -> void:
	failed_strategies.append({"description": description, "time": Time.get_ticks_msec()})
	if failed_strategies.size() > MAX_FAILED_STRATEGIES:
		failed_strategies.pop_front()

func add_acquired_belief(event_desc: String, source_name: String, source_trust: float) -> void:
	acquired_beliefs.append({
		"description": event_desc,
		"source": source_name,
		"trust_weight": source_trust,
		"time": Time.get_ticks_msec()
	})
	if acquired_beliefs.size() > 10:
		acquired_beliefs.pop_front()

func get_recent_events_text(count: int = 5) -> Array:
	var result: Array = []
	var end_idx: int = tagged_events.size()
	var start_idx: int = maxi(0, end_idx - count)
	for i in range(start_idx, end_idx):
		result.append(tagged_events[i]["description"])
	return result

func get_memory_summary() -> String:
	var parts: Array = []
	if tagged_events.size() > 0:
		parts.append("Recent events: ")
		for i in range(mini(3, tagged_events.size())):
			parts.append("- " + tagged_events[i]["description"])
	if concerns.size() > 0:
		parts.append("Concerns: " + ", ".join(concerns))
	if reflections.size() > 0:
		parts.append("Reflections: " + reflections[reflections.size() - 1])
	return "\n".join(parts) if parts.size() > 0 else "No notable memories."

func decay_events(hours_elapsed: float) -> void:
	## Reduce salience of old events over time. Remove events below threshold.
	var decay_rate: float = 0.02 * hours_elapsed
	var to_remove: Array = []
	for i in range(tagged_events.size()):
		tagged_events[i]["salience"] -= decay_rate
		if tagged_events[i]["salience"] < 0.1:
			to_remove.append(i)
	# Remove from end to avoid index shifting
	to_remove.reverse()
	for idx in to_remove:
		tagged_events.remove_at(idx)

func get_tagged_events_for_exchange() -> Array[Dictionary]:
	## Returns events suitable for social propagation (direct observations, above threshold)
	var result: Array[Dictionary] = []
	for evt in tagged_events:
		if evt["salience"] > 0.3:
			result.append(evt)
	return result

# --- Object Knowledge ---

func add_object_knowledge(id: String, obj_name: String, type: String, position: Vector2, state: String, location: String, source: String) -> void:
	## Upsert object knowledge. source = "direct" for seen, or NPC name for second-hand.
	known_objects[id] = {
		"name": obj_name,
		"type": type,
		"last_seen_position": position,
		"last_seen_state": state,
		"last_seen_time": Time.get_ticks_msec(),
		"learned_from": source,
		"location": location,
	}

func get_objects_at_location(location: String) -> Array:
	## Filter known objects by location name.
	var result: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		if obj.get("location", "") == location:
			result.append({"id": id, "name": obj["name"], "type": obj["type"], "state": obj["last_seen_state"], "location": obj["location"]})
	return result

func get_objects_by_type(type: String) -> Array:
	## Filter known objects by type.
	var result: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		if obj.get("type", "") == type:
			result.append({"id": id, "name": obj["name"], "type": obj["type"], "state": obj["last_seen_state"], "location": obj["location"]})
	return result

func get_known_object(id: String) -> Dictionary:
	return known_objects.get(id, {})

func get_object_summary() -> String:
	## Summary of known objects for Layer 3 planning context.
	if known_objects.is_empty():
		return ""
	var parts: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		var src: String = " (heard from %s)" % obj["learned_from"] if obj["learned_from"] != "direct" else ""
		parts.append("- %s at %s: %s%s" % [obj["name"], obj["location"], obj["last_seen_state"], src])
	if parts.size() > 8:
		parts.resize(8)
		parts.append("- ...and %d more" % (known_objects.size() - 8))
	return "Known objects:\n" + "\n".join(parts)
