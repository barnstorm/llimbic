extends RefCounted
## res://scripts/memory_system.gd — Per-NPC memory storage and retrieval

const MAX_OBSERVATIONS: int = 20
const MAX_TAGGED_EVENTS: int = 10
const MAX_REFLECTIONS: int = 5
const MAX_CONCERNS: int = 5
const MAX_FAILED_STRATEGIES: int = 5

# NPC identity — set by brain at setup for role-relevance checks
var npc_name: String = ""
var npc_role: String = ""

# Optional log callback — set by brain to pipe events to per-NPC log
var on_tagged_event: Callable

# Raw observations: structured dicts with kind, subtype, text, source_type, confidence
var observations: Array[Dictionary] = []

# Tagged events with salience scoring, kind classification, and confidence
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

# Structured beliefs — {subject, predicate, object, confidence, source, timestamp}
var beliefs: Array[Dictionary] = []
const MAX_BELIEFS: int = 30

func add_observation_structured(obs: Dictionary) -> void:
	## Add a structured observation. Shape:
	## {kind: "vision"|"hearing", subtype: "actor_presence"|"speech"|"object_state"|"impact",
	##  text: String, source_type: "direct", confidence: float, position: Vector2,
	##  direction: Vector2, tags: Array, time: int}
	obs["time"] = obs.get("time", Time.get_ticks_msec())
	obs["source_type"] = obs.get("source_type", "direct")
	obs["confidence"] = obs.get("confidence", 1.0)
	obs["tags"] = obs.get("tags", [])
	observations.append(obs)
	if observations.size() > MAX_OBSERVATIONS:
		observations.pop_front()

func add_observation(who: String, where: String, doing: String) -> void:
	## Backward-compat wrapper — builds structured observation from simple args.
	var obs: Dictionary = {
		"kind": "vision",
		"subtype": "actor_presence",
		"text": doing if doing != "" else "Near %s" % who,
		"source_type": "direct",
		"confidence": 1.0,
		"position": Vector2.ZERO,
		"direction": Vector2.ZERO,
		"tags": [],
		"time": Time.get_ticks_msec(),
		# Legacy fields kept for any code reading observations directly
		"who": who,
		"where": where,
		"doing": doing,
	}
	observations.append(obs)
	if observations.size() > MAX_OBSERVATIONS:
		observations.pop_front()

func add_tagged_event(description: String, salience: float, tags: Array = [],
		source: String = "direct", kind: String = "generic",
		confidence: float = 1.0) -> void:
	if on_tagged_event.is_valid():
		on_tagged_event.call(description, salience)
	var evt: Dictionary = {
		"text": description,
		"description": description,  # kept for backward compat reads
		"salience": salience,
		"tags": tags,
		"source": source,
		"source_type": "direct" if source == "direct" else "second_hand",
		"kind": kind,
		"confidence": confidence,
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

func get_place_threat_level() -> float:
	## Returns threat level (0-1) for the most recently visited location.
	## Based on negative tagged events at this location.
	# Count recent threat-tagged events (flee, danger, blocked, threat)
	var threat_count: int = 0
	for event in tagged_events:
		if event is not Dictionary:
			continue
		var tags: Array = event.get("tags", [])
		for tag in tags:
			if tag in ["flee", "danger", "threat", "blocked"]:
				threat_count += 1
				break
	return clampf(float(threat_count) * 0.15, 0.0, 1.0)

func get_place_comfort_level() -> float:
	## Returns comfort level for the current location from familiarity.
	## Used by somatic stream for positive place conditioning.
	var best_comfort: float = 0.3
	for loc in place_familiarity:
		var comfort: float = place_familiarity[loc]["comfort"]
		if comfort > best_comfort:
			best_comfort = comfort
	return best_comfort

func get_entity_threat_levels() -> Dictionary:
	## Returns {entity_name: threat_level} for entities with low trust or threat history.
	## Used by somatic stream for entity-specific fear conditioning (short circuit).
	var threats: Dictionary = {}
	for entity_name in relationships:
		var trust: float = relationships[entity_name].get("trust", 0.5)
		if trust < 0.4:
			# Low trust = potential threat. Invert: trust 0.0 → threat 0.6, trust 0.3 → threat 0.15
			threats[entity_name] = clampf((0.4 - trust) * 1.5, 0.0, 1.0)
	# Also check tagged events for entity-specific threat
	for event in tagged_events:
		if event is not Dictionary:
			continue
		var source: String = event.get("source", "")
		if source == "" or source == "self" or source == "direct":
			continue
		var tags: Array = event.get("tags", [])
		for tag in tags:
			if tag in ["flee", "danger", "threat"]:
				if not threats.has(source):
					threats[source] = 0.0
				threats[source] = clampf(threats[source] + 0.2, 0.0, 1.0)
				break
	return threats

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

func add_object_knowledge(id: String, obj_name: String, type: String, position: Vector2, state: String, location: String, source: String, reliable: bool = false) -> void:
	## Upsert object knowledge. source = "direct" for seen, or NPC name for second-hand.
	## reliable = true when source is a trusted NPC (trust > 0.6).
	var existing: Dictionary = known_objects.get(id, {})
	# Direct observation always overwrites. Second-hand only overwrites if no direct observation exists
	# or if the second-hand info is newer.
	var dominated: bool = (source != "direct" and existing.get("learned_from", "") == "direct"
		and Time.get_ticks_msec() - existing.get("last_seen_time", 0) < 300000)  # 5 minutes
	if dominated:
		return  # Don't overwrite fresh direct observation with second-hand info
	known_objects[id] = {
		"name": obj_name,
		"type": type,
		"last_seen_position": position,
		"last_seen_state": state,
		"last_seen_time": Time.get_ticks_msec(),
		"learned_from": source,
		"location": location,
		"reliable": source == "direct" or reliable,
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
		var rel: String = " [reliable]" if obj.get("reliable", false) and obj["learned_from"] != "direct" else ""
		parts.append("- %s at %s: %s%s%s" % [obj["name"], obj["location"], obj["last_seen_state"], src, rel])
	if parts.size() > 8:
		parts.resize(8)
		parts.append("- ...and %d more" % (known_objects.size() - 8))
	return "Known objects:\n" + "\n".join(parts)

func get_problematic_objects() -> Array:
	## Returns objects in problematic states (broken, empty, locked).
	var result: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		var state: String = obj.get("last_seen_state", "")
		if state in ["broken", "empty", "locked"]:
			result.append({"id": id, "name": obj["name"], "type": obj["type"], "state": state, "location": obj["location"], "learned_from": obj["learned_from"]})
	return result

func get_food_objects() -> Array:
	## Returns known food-related objects (containers/supplies at food locations).
	var food_locations: Array = ["bakery", "inn", "market", "farm"]
	var result: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		var loc: String = obj.get("location", "")
		var obj_type: String = obj.get("type", "")
		var state: String = obj.get("last_seen_state", "")
		if loc in food_locations and obj_type in ["container", "supply"] and state != "empty":
			result.append({"id": id, "name": obj["name"], "location": loc, "state": state})
	return result

func get_objects_for_sharing(sharer_role: String) -> Array:
	## Returns objects suitable for sharing during social propagation.
	## Filters by role affinity: NPCs prefer sharing objects relevant to their role.
	var result: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		# Prefer objects with interesting states or from role-relevant locations
		var state: String = obj.get("last_seen_state", "")
		var is_interesting: bool = state in ["broken", "empty", "locked"] or obj.get("learned_from", "") == "direct"
		if is_interesting:
			result.append({"id": id, "name": obj["name"], "type": obj["type"], "state": state, "location": obj["location"], "position": obj.get("last_seen_position", Vector2.ZERO)})
	return result

func get_object_dialogue_context(role: String) -> String:
	## Returns a short string describing notable objects for dialogue context.
	var notable: Array = []
	for id in known_objects:
		var obj: Dictionary = known_objects[id]
		var state: String = obj.get("last_seen_state", "")
		if state in ["broken", "empty", "locked"]:
			var src: String = ""
			if obj.get("learned_from", "direct") != "direct":
				src = " (%s told me)" % obj["learned_from"]
			notable.append("%s at %s is %s%s" % [obj["name"], obj["location"], state, src])
	if notable.is_empty():
		return ""
	if notable.size() > 3:
		notable.resize(3)
	return "Notable objects: " + "; ".join(notable)

# --- Structured Beliefs ---

func add_belief(subject: String, predicate: String, obj: String, confidence: float, source: String) -> void:
	## Add or update a structured belief. Contradictions resolved by confidence.
	for i in range(beliefs.size()):
		var b: Dictionary = beliefs[i]
		if b["subject"] == subject and b["predicate"] == predicate:
			if b["object"] != obj:
				# Contradicting belief — update if higher confidence
				if confidence > b["confidence"]:
					beliefs[i] = {"subject": subject, "predicate": predicate, "object": obj,
						"confidence": confidence, "source": source, "timestamp": Time.get_ticks_msec()}
				return
			else:
				# Reinforcing belief — boost confidence
				beliefs[i]["confidence"] = minf(b["confidence"] + confidence * 0.2, 1.0)
				return
	# New belief
	beliefs.append({"subject": subject, "predicate": predicate, "object": obj,
		"confidence": confidence, "source": source, "timestamp": Time.get_ticks_msec()})
	# Evict lowest confidence if over cap
	if beliefs.size() > MAX_BELIEFS:
		var min_conf: float = 2.0
		var min_idx: int = 0
		for i in range(beliefs.size()):
			if beliefs[i]["confidence"] < min_conf:
				min_conf = beliefs[i]["confidence"]
				min_idx = i
		beliefs.remove_at(min_idx)

func query_beliefs(subject: String = "", predicate: String = "") -> Array:
	## Filter beliefs by subject and/or predicate.
	var result: Array = []
	for b in beliefs:
		if subject != "" and b["subject"] != subject:
			continue
		if predicate != "" and b["predicate"] != predicate:
			continue
		result.append(b)
	return result

func beliefs_summary(max_count: int = 5) -> String:
	## Top beliefs by confidence, for thought prompt context.
	var sorted_b: Array = beliefs.duplicate()
	sorted_b.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["confidence"] > b["confidence"])
	var parts: Array = []
	for i in range(mini(sorted_b.size(), max_count)):
		var b: Dictionary = sorted_b[i]
		parts.append("%s %s %s (%d%%)" % [b["subject"], b["predicate"], b["object"], int(b["confidence"] * 100)])
	return "; ".join(parts) if parts.size() > 0 else ""

func compute_trust(entity_name: String) -> float:
	## Compute trust from relationship history + beliefs about the entity.
	var base: float = get_trust(entity_name)
	var entity_beliefs: Array = query_beliefs(entity_name)
	var modifier: float = 0.0
	for b in entity_beliefs:
		var pred: String = b.get("predicate", "").to_lower()
		if "helped" in pred or "saved" in pred or "gave" in pred or "kind" in pred:
			modifier += b["confidence"] * 0.1
		elif "stole" in pred or "attacked" in pred or "lied" in pred or "hurt" in pred:
			modifier -= b["confidence"] * 0.15
		elif "broke" in pred or "damaged" in pred or "rude" in pred:
			modifier -= b["confidence"] * 0.1
	return clampf(base + modifier, 0.0, 1.0)

# --- Role affinity for relevance scoring ---

const ROLE_TAG_AFFINITY: Dictionary = {
	"Guard": ["security", "danger", "patrol", "crime", "suspicious", "impact", "flee"],
	"Gossip": ["rumor", "conversation", "social", "heard", "overheard", "second-hand"],
	"Baker": ["trade", "supply", "food", "delivery", "object_discovery"],
	"Farmer": ["trade", "supply", "weather", "food", "resource"],
	"Innkeeper": ["trade", "social", "travelers", "food", "supply"],
	"Courier": ["delivery", "road", "news", "travel"],
	"Herbalist": ["remedy", "illness", "herbs", "supply"],
	"Blacksmith": ["trade", "supply", "forge", "tool"],
}

# --- Observation promotion ---

func promote_observation(obs: Dictionary) -> void:
	## Check whether an observation should be promoted to a tagged event.
	## Called by brain after adding structured observations.
	## Only promotes if confidence is sufficient and the observation is notable.
	var conf: float = obs.get("confidence", 1.0)
	if conf < 0.4:
		return  # too uncertain to promote

	var subtype: String = obs.get("subtype", "")
	var tags: Array = obs.get("tags", [])
	var text: String = obs.get("text", "")
	var source_type: String = obs.get("source_type", "direct")
	var kind_str: String = obs.get("kind", "vision")

	# Determine promotion salience based on observation type
	var salience: float = 0.0
	var event_kind: String = "generic"
	var event_tags: Array = tags.duplicate()

	# Object problems always promote
	if "object_problem" in tags or "problematic" in tags:
		salience = 0.7
		event_kind = "object_problem"
	# Player-relevant observations promote
	elif "player" in tags:
		salience = 0.5
		event_kind = "player_interaction"
	# Speech with good clarity promotes
	elif subtype == "speech" and conf > 0.5:
		salience = 0.4
		event_kind = "speech"
	# State changes promote
	elif "state_change" in tags:
		salience = 0.5
		event_kind = "state_change"
	# Novel entity sightings: only if not already known
	elif subtype == "actor_presence" and "novel" in tags:
		salience = 0.3
		event_kind = "novel_sighting"
	# High-confidence impact sounds
	elif subtype == "impact" and conf > 0.5:
		salience = 0.4
		event_kind = "impact"

	if salience < 0.1:
		return  # not worth promoting

	# Role relevance boost
	var role_tags: Array = ROLE_TAG_AFFINITY.get(npc_role, [])
	for tag in event_tags:
		if tag in role_tags:
			salience = minf(salience + 0.15, 1.0)
			break

	add_tagged_event(text, salience, event_tags, "direct" if source_type == "direct" else "",
		event_kind, conf)

# --- GoEmotions dimension names (27-dim) ---

const EMOTION_NAMES: Array = [
	"admiration", "amusement", "approval", "caring", "desire", "excitement",
	"gratitude", "joy", "love", "optimism", "pride", "relief",
	"anger", "annoyance", "disappointment", "disapproval", "disgust",
	"embarrassment", "fear", "grief", "nervousness", "remorse", "sadness",
	"confusion", "curiosity", "realization", "surprise"
]

# --- Retrieval / Compression Layer ---

func _top_emotions(vector: Array, n: int = 3) -> Array:
	## Extract top N emotions from 27-dim GoEmotions vector.
	## Returns [{name: String, value: float}] sorted descending.
	if vector.is_empty():
		return []
	var indexed: Array = []
	for i in range(mini(vector.size(), EMOTION_NAMES.size())):
		if float(vector[i]) > 0.05:
			indexed.append({"name": EMOTION_NAMES[i], "value": float(vector[i])})
	indexed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["value"] > b["value"])
	if indexed.size() > n:
		indexed.resize(n)
	return indexed

func _rank_events(events: Array, ctx: Dictionary) -> Array:
	## Score and sort events by weighted relevance.
	## ctx may contain: role, current_chunk, hour
	var now: int = Time.get_ticks_msec()
	var max_age_ms: float = 600000.0  # 10 minutes
	var role_str: String = ctx.get("role", npc_role)
	var role_tags: Array = ROLE_TAG_AFFINITY.get(role_str, [])
	var chunk: Dictionary = ctx.get("current_chunk", {})
	var chunk_purpose: String = chunk.get("purpose", "").to_lower()
	var chunk_location: String = chunk.get("location", "")

	var scored: Array = []
	for evt in events:
		var s: float = evt.get("salience", 0.3) * 0.30
		# Recency
		var age_ms: float = maxf(float(now - evt.get("time", now)), 0.0)
		s += (1.0 - clampf(age_ms / max_age_ms, 0.0, 1.0)) * 0.25
		# Confidence
		s += evt.get("confidence", 1.0) * 0.20
		# Role relevance
		var tags: Array = evt.get("tags", [])
		var role_hit: bool = false
		for tag in tags:
			if tag in role_tags:
				role_hit = true
				break
		if role_hit:
			s += 0.15
		# Chunk relevance
		var chunk_hit: bool = false
		if chunk_purpose != "":
			for tag in tags:
				if tag in chunk_purpose or chunk_purpose in str(evt.get("text", evt.get("description", ""))).to_lower():
					chunk_hit = true
					break
		if chunk_location != "" and chunk_location in str(evt.get("text", evt.get("description", ""))).to_lower():
			chunk_hit = true
		if chunk_hit:
			s += 0.10
		scored.append({"event": evt, "score": s})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["score"] > b["score"])

	var result: Array = []
	for item in scored:
		result.append(item["event"])
	return result

func _dedupe_events(events: Array) -> Array:
	## Collapse duplicate/similar events.
	## Same kind + similar text prefix (first 30 chars) -> keep latest, add count.
	## Same object_id in tags -> keep latest state only.
	if events.size() <= 1:
		return events

	var result: Array = []
	var seen_keys: Dictionary = {}  # dedup key -> index in result

	for evt in events:
		var kind: String = evt.get("kind", "generic")
		var text: String = str(evt.get("text", evt.get("description", "")))
		var dedup_key: String = kind + ":" + text.substr(0, 30).to_lower()

		if seen_keys.has(dedup_key):
			var existing_idx: int = seen_keys[dedup_key]
			var existing: Dictionary = result[existing_idx]
			existing["count"] = existing.get("count", 1) + 1
			# Keep the more recent one
			if evt.get("time", 0) > existing.get("time", 0):
				var count: int = existing["count"]
				evt["count"] = count
				result[existing_idx] = evt
		else:
			seen_keys[dedup_key] = result.size()
			result.append(evt)

	return result

func _event_to_packet_entry(evt: Dictionary) -> Dictionary:
	## Convert internal event dict to a clean packet entry for L3 consumption.
	var entry: Dictionary = {
		"text": str(evt.get("text", evt.get("description", ""))),
		"kind": evt.get("kind", "generic"),
		"source_type": evt.get("source_type", "direct"),
		"confidence": evt.get("confidence", 1.0),
		"salience": evt.get("salience", 0.3),
		"tags": evt.get("tags", []),
	}
	if evt.has("count") and evt["count"] > 1:
		entry["count"] = evt["count"]
	return entry

# --- Packet Builders ---

func build_plan_packet(ctx: Dictionary) -> Dictionary:
	## Build a bounded, purpose-specific packet for Layer 3 planning.
	## ctx = {npc_name, role, hour, current_location, current_chunk,
	##        replan_reason, emotion_vector, chunk_outcomes}
	var packet: Dictionary = {
		"npc_name": ctx.get("npc_name", npc_name),
		"role": ctx.get("role", npc_role),
		"hour": ctx.get("hour", 0.0),
		"current_location": ctx.get("current_location", ""),
		"current_chunk": ctx.get("current_chunk", {}),
		"replan_reason": ctx.get("replan_reason", "none"),
	}

	# Top 3 emotions
	packet["top_emotions"] = _top_emotions(ctx.get("emotion_vector", []), 3)

	# Concerns (cap 2)
	var capped_concerns: Array = []
	for i in range(mini(concerns.size(), 2)):
		capped_concerns.append(concerns[i])
	packet["concerns"] = capped_concerns

	# Problem objects (cap 2)
	var problems: Array = get_problematic_objects()
	if problems.size() > 2:
		problems.resize(2)
	packet["problem_objects"] = problems

	# Recent failures (cap 2)
	var failures: Array = []
	var chunk_outcomes: Array = ctx.get("chunk_outcomes", [])
	for co in chunk_outcomes:
		var outcome: String = co.get("outcome", "")
		if outcome in ["failed", "completed_with_difficulty"]:
			failures.append({"purpose": co.get("purpose", ""), "location": co.get("location", ""), "outcome": outcome})
	if failures.size() > 2:
		failures = failures.slice(failures.size() - 2)
	packet["recent_failures"] = failures

	# Salient events (ranked, deduped, cap 4)
	var ranked: Array = _rank_events(tagged_events.duplicate(), ctx)
	var deduped: Array = _dedupe_events(ranked)
	var events_out: Array = []
	for i in range(mini(deduped.size(), 4)):
		events_out.append(_event_to_packet_entry(deduped[i]))
	packet["salient_events"] = events_out

	return packet

func build_reflection_packet(ctx: Dictionary) -> Dictionary:
	## Build a bounded packet for Layer 3 reflection.
	## ctx = {npc_name, role, active_intention}
	var packet: Dictionary = {
		"npc_name": ctx.get("npc_name", npc_name),
		"role": ctx.get("role", npc_role),
		"active_intention": ctx.get("active_intention", ""),
	}

	# Events (ranked, cap 6) — reflection wants broader coverage
	var ranked: Array = _rank_events(tagged_events.duplicate(), ctx)
	var deduped: Array = _dedupe_events(ranked)
	var events_out: Array = []
	for i in range(mini(deduped.size(), 6)):
		events_out.append(_event_to_packet_entry(deduped[i]))
	packet["events"] = events_out

	# Current concerns (cap 2)
	var capped_concerns: Array = []
	for i in range(mini(concerns.size(), 2)):
		capped_concerns.append(concerns[i])
	packet["current_concerns"] = capped_concerns

	return packet

func build_dialogue_packet(ctx: Dictionary) -> Dictionary:
	## Build a bounded packet for Layer 3 dialogue/conversation.
	## ctx = {npc_name, role, target_name, target_type, trust, emotion_vector,
	##        current_activity, current_chunk}
	var packet: Dictionary = {
		"npc_name": ctx.get("npc_name", npc_name),
		"role": ctx.get("role", npc_role),
		"target_type": ctx.get("target_type", "player"),
		"target_name": ctx.get("target_name", ""),
		"trust": ctx.get("trust", 0.5),
		"current_activity": ctx.get("current_activity", ""),
	}

	# Top 3 emotions
	packet["top_emotions"] = _top_emotions(ctx.get("emotion_vector", []), 3)

	# Top concern (just 1)
	packet["top_concern"] = concerns[0] if concerns.size() > 0 else ""

	# Notable objects (cap 2) — prefer problematic ones
	var notable: Array = get_problematic_objects()
	if notable.size() > 2:
		notable.resize(2)
	packet["notable_objects"] = notable

	# Known people — compact relationship list (name, trust, role if available)
	var known_people: Array = []
	for entity_name in relationships:
		var rel: Dictionary = relationships[entity_name]
		known_people.append({"name": entity_name, "trust": rel.get("trust", 0.5)})
	packet["known_people"] = known_people

	# Recent relevant events (cap 3) — prefer events relevant to the conversation target
	var ranked: Array = _rank_events(tagged_events.duplicate(), ctx)
	var deduped: Array = _dedupe_events(ranked)
	var events_out: Array = []
	for i in range(mini(deduped.size(), 3)):
		events_out.append(_event_to_packet_entry(deduped[i]))
	packet["recent_relevant_events"] = events_out

	return packet
