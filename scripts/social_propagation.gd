extends Node
## res://scripts/social_propagation.gd — NPC-to-NPC conversation system
## When NPCs are close enough and willing, they stop, face each other, and talk.
## Nearby NPCs can overhear via the hearing system.

var _pulse_timer: float = 0.0
var _pulse_interval: float = 5.0  # every 5 real seconds
var _cooldowns: Dictionary = {}   # "npcA:npcB" -> time remaining
var _active_conversations: Array[Dictionary] = []  # ongoing conversations
var _inference_client: Node = null
var _game_manager: Node = null
var _sensor_system: Node = null

const CONVERSE_RANGE: float = 64.0  # 2 tiles
const COOLDOWN_DURATION: float = 60.0  # 1 game-minute between conversations for same pair

# Role-tag affinity for preferential information sharing
const ROLE_TAG_AFFINITY: Dictionary = {
	"Guard": ["security", "danger", "patrol", "crime", "suspicious"],
	"Gossip": ["rumor", "conversation", "social", "heard", "overheard"],
	"Baker": ["trade", "supply", "food", "delivery"],
	"Farmer": ["trade", "supply", "weather", "food"],
	"Innkeeper": ["trade", "social", "travelers", "food"],
	"Courier": ["delivery", "road", "news"],
	"Herbalist": ["remedy", "illness", "herbs"],
	"Blacksmith": ["trade", "supply", "forge"],
}

func _ready() -> void:
	call_deferred("_find_inference_client")

func _find_inference_client() -> void:
	for child in get_tree().root.get_children():
		if child.name == "InferenceClient":
			_inference_client = child
		elif child.name == "SensorSystem":
			_sensor_system = child
		elif child.name == "GameManager":
			_game_manager = child

func _process(delta: float) -> void:
	# Tick cooldowns
	var expired: Array = []
	for key in _cooldowns:
		_cooldowns[key] -= delta
		if _cooldowns[key] <= 0.0:
			expired.append(key)
	for key in expired:
		_cooldowns.erase(key)

	# Update active conversations
	_update_conversations(delta)

	# Pulse for new conversations
	_pulse_timer += delta
	if _pulse_timer < _pulse_interval:
		return
	_pulse_timer = 0.0
	_do_propagation_pulse()

func _do_propagation_pulse() -> void:
	var npcs: Array = get_tree().get_nodes_in_group("npcs")
	if npcs.size() < 2:
		return

	for i in range(npcs.size()):
		for j in range(i + 1, npcs.size()):
			_try_start_conversation(npcs[i], npcs[j])

func _try_start_conversation(npc_a: Node, npc_b: Node) -> void:
	# Must be within range
	var dist: float = npc_a.global_position.distance_to(npc_b.global_position)
	if dist > CONVERSE_RANGE:
		return

	# Both must have brains
	if npc_a.brain == null or npc_b.brain == null:
		return

	# Both must not already be in conversation or talking
	if not npc_a.has_method("start_conversation") or not npc_b.has_method("start_conversation"):
		return
	if npc_a._externally_locked:
		return
	if npc_b._externally_locked:
		return

	# Check willingness: either social need is high enough, or a thought-loop intention
	# explicitly drives social behavior (e.g., "talk to X", "socialize")
	var a_social_intent: bool = _has_social_intention(npc_a, npc_b.npc_name)
	var b_social_intent: bool = _has_social_intention(npc_b, npc_a.npc_name)
	var a_willing: bool = a_social_intent or npc_a.brain.layer1.social_need > 30.0
	var b_willing: bool = b_social_intent or npc_b.brain.layer1.social_need > 30.0
	if not a_willing or not b_willing:
		return

	# Both must be willing to interrupt — but social intentions bypass the check
	if not a_social_intent and not npc_a.brain.layer1.should_interrupt_for("medium"):
		return
	if not b_social_intent and not npc_b.brain.layer1.should_interrupt_for("medium"):
		return

	# Cooldown check
	var key: String = _pair_key(npc_a.npc_name, npc_b.npc_name)
	if _cooldowns.has(key):
		return

	# Check if they can see each other via SensorSystem (at least one must see the other)
	var a_sees_b: bool = false
	var b_sees_a: bool = false
	if _sensor_system != null:
		var SPScript: GDScript = load("res://scripts/sensor_profile.gd")
		var SRTScript: GDScript = load("res://scripts/sensory_result_types.gd")
		var actor_offsets: Array = SRTScript.actor_sample_offsets()
		# Check A sees B
		if npc_a.brain and npc_a.brain.perception:
			var profile_a: Dictionary = npc_a.brain._sensor_profile if not npc_a.brain._sensor_profile.is_empty() else SPScript.make_default()
			var vr_a: Dictionary = _sensor_system.query_vision(
				npc_a.global_position, npc_a.brain.perception.facing_vector, profile_a,
				npc_b.global_position, actor_offsets
			)
			a_sees_b = vr_a.get("visible", false)
		# Check B sees A
		if npc_b.brain and npc_b.brain.perception:
			var profile_b: Dictionary = npc_b.brain._sensor_profile if not npc_b.brain._sensor_profile.is_empty() else SPScript.make_default()
			var vr_b: Dictionary = _sensor_system.query_vision(
				npc_b.global_position, npc_b.brain.perception.facing_vector, profile_b,
				npc_a.global_position, actor_offsets
			)
			b_sees_a = vr_b.get("visible", false)
	else:
		# Fallback: check cached visible entities
		if npc_a.brain and npc_a.brain.perception:
			for ent in npc_a.brain.perception.visible_entities:
				if ent.get("name", "") == npc_b.npc_name:
					a_sees_b = true
					break
		if npc_b.brain and npc_b.brain.perception:
			for ent in npc_b.brain.perception.visible_entities:
				if ent.get("name", "") == npc_a.npc_name:
					b_sees_a = true
					break
	if not a_sees_b and not b_sees_a:
		return

	# Conversation probability — driven by intentions + social need, not fixed rules
	var chance: float = 0.3  # base chance
	# Social intentions guarantee conversation
	if a_social_intent or b_social_intent:
		chance = 1.0
	else:
		# Higher social need increases chance
		var avg_social: float = (npc_a.brain.layer1.social_need + npc_b.brain.layer1.social_need) / 200.0
		chance += avg_social * 0.5  # up to +0.5 from social need
	if randf() > chance:
		return

	# Start the conversation
	_begin_conversation(npc_a, npc_b, key)

func _begin_conversation(npc_a: Node, npc_b: Node, pair_key: String) -> void:
	# Both NPCs stop and face each other
	npc_a.start_conversation(npc_b)
	npc_b.start_conversation(npc_a)

	# Set cooldown
	_cooldowns[pair_key] = COOLDOWN_DURATION

	# Determine who speaks first (the one with higher social need)
	var first: Node = npc_a
	var second: Node = npc_b
	if npc_b.brain.layer1.social_need > npc_a.brain.layer1.social_need:
		first = npc_b
		second = npc_a

	# Create conversation state
	var convo: Dictionary = {
		"speaker": first,
		"listener": second,
		"phase": "requesting_speech",  # requesting_speech -> showing_speech -> requesting_reply -> showing_reply -> done
		"timer": 0.0,
		"pair_key": pair_key,
	}
	_active_conversations.append(convo)

	# Request speech from the first speaker via Layer 3
	_request_speech(convo, first, second)

func _request_speech(convo: Dictionary, speaker: Node, listener: Node) -> void:
	if _inference_client == null or not _inference_client.is_server_available():
		# Fallback: use a generic line
		_on_speech_received(convo, speaker, true, {
			"utterance": _fallback_line(speaker.role, listener.role),
			"intent": "greet",
			"topic": "small talk"
		})
		return

	# Build dialogue packets for both participants
	var speaker_trust: float = speaker.brain.memory.compute_trust(listener.npc_name) if speaker.brain.memory else 0.5
	var speaker_ctx: Dictionary = {
		"npc_name": speaker.npc_name,
		"role": speaker.role,
		"target_name": listener.npc_name,
		"target_type": "npc",
		"trust": speaker_trust,
		"emotion_vector": speaker.brain.layer2.emotion_vector if speaker.brain.layer2 else [],
		"current_activity": speaker.brain.get_current_action(),
		"current_chunk": speaker.brain.layer3.get_current_chunk() if speaker.brain.layer3 else {},
	}
	var speaker_packet: Dictionary = speaker.brain.memory.build_dialogue_packet(speaker_ctx)

	var listener_trust: float = listener.brain.memory.compute_trust(speaker.npc_name) if listener.brain.memory else 0.5
	var listener_ctx: Dictionary = {
		"npc_name": listener.npc_name,
		"role": listener.role,
		"target_name": speaker.npc_name,
		"target_type": "npc",
		"trust": listener_trust,
		"emotion_vector": listener.brain.layer2.emotion_vector if listener.brain.layer2 else [],
		"current_activity": listener.brain.get_current_action(),
		"current_chunk": listener.brain.layer3.get_current_chunk() if listener.brain.layer3 else {},
	}
	var listener_packet: Dictionary = listener.brain.memory.build_dialogue_packet(listener_ctx)

	_inference_client.layer3_converse_packet(
		speaker_packet, listener_packet,
		func(success: bool, data: Dictionary) -> void:
			_on_speech_received(convo, speaker, success, data),
	)

func _on_speech_received(convo: Dictionary, speaker: Node, success: bool, data: Dictionary) -> void:
	if not is_instance_valid(speaker):
		_cleanup_conversation(convo)
		return

	var utterance: String = data.get("utterance", "...")
	var topic: String = data.get("topic", "small talk")

	# Speaker says it out loud (shows bubble + broadcasts to hearing range)
	speaker.speak(utterance)

	# Exchange memory events and object knowledge between the pair
	_exchange_events(convo["speaker"], convo["listener"])
	_exchange_object_knowledge(convo["speaker"], convo["listener"])

	# Record the conversation in both NPCs' memory
	var listener: Node = convo["listener"] if speaker == convo["speaker"] else convo["speaker"]
	speaker.brain.memory.add_tagged_event(
		"Talked to %s about %s" % [listener.npc_name, topic], 0.5, ["conversation"], "direct", "social"
	)

	# Notify server for belief extraction — listener extracts beliefs from what speaker said
	if _inference_client and is_instance_valid(listener):
		_inference_client.notify_speech(listener.npc_name, listener.role, utterance, speaker.npc_name)

	# Log to shared conversation log
	if _game_manager:
		var intent: String = data.get("intent", "?")
		_game_manager.log_conversation(speaker.npc_name, listener.npc_name, utterance, "npc-npc, intent=%s, topic=%s" % [intent, topic])

	# Satisfy social need
	speaker.brain.layer1.social_need = clampf(speaker.brain.layer1.social_need - 8.0, 0.0, 100.0)

	if convo["phase"] == "requesting_speech":
		convo["phase"] = "showing_speech"
		convo["timer"] = 3.0  # show first speaker's bubble for 3 seconds
	elif convo["phase"] == "requesting_reply":
		convo["phase"] = "showing_reply"
		convo["timer"] = 3.0  # show reply for 3 seconds

func _update_conversations(delta: float) -> void:
	var finished: Array = []
	for convo in _active_conversations:
		if convo["phase"] == "showing_speech":
			convo["timer"] -= delta
			if convo["timer"] <= 0.0:
				# Now the listener replies
				convo["phase"] = "requesting_reply"
				var listener: Node = convo["listener"]
				var speaker: Node = convo["speaker"]
				if is_instance_valid(listener) and is_instance_valid(speaker):
					_request_speech(convo, listener, speaker)
				else:
					finished.append(convo)
		elif convo["phase"] == "showing_reply":
			convo["timer"] -= delta
			if convo["timer"] <= 0.0:
				convo["phase"] = "done"
				finished.append(convo)
		elif convo["phase"] == "done":
			finished.append(convo)

	for convo in finished:
		_cleanup_conversation(convo)
		_active_conversations.erase(convo)

func _cleanup_conversation(convo: Dictionary) -> void:
	# Release both NPCs from conversation state
	if is_instance_valid(convo.get("speaker")) and convo["speaker"].has_method("end_conversation"):
		convo["speaker"].end_conversation()
	if is_instance_valid(convo.get("listener")) and convo["listener"].has_method("end_conversation"):
		convo["listener"].end_conversation()

func _exchange_events(from_npc: Node, to_npc: Node) -> void:
	"""Transfer a tagged event from one NPC's memory to another with role filtering and trust weighting."""
	var events: Array = from_npc.brain.memory.get_tagged_events_for_exchange()
	if events.is_empty():
		return

	# Role-filtered selection: prefer events matching speaker's role affinity
	var speaker_role: String = from_npc.role if "role" in from_npc else ""
	var affinity_tags: Array = ROLE_TAG_AFFINITY.get(speaker_role, [])
	var preferred: Array = []
	for evt in events:
		var tags: Array = evt.get("tags", [])
		for tag in tags:
			if tag in affinity_tags:
				preferred.append(evt)
				break
	var chosen: Dictionary
	if preferred.size() > 0:
		chosen = preferred[randi() % preferred.size()]
	else:
		chosen = events[randi() % events.size()]

	# Trust-weighted salience: low trust = much lower salience
	var trust: float = to_npc.brain.memory.compute_trust(from_npc.npc_name)
	var trust_factor: float = clampf(trust + 0.3, 0.3, 1.0)
	var new_salience: float = chosen["salience"] * 0.7 * trust_factor

	to_npc.brain.memory.add_tagged_event(
		str(chosen["description"]), new_salience, ["second-hand"], from_npc.npc_name,
		chosen.get("kind", "generic"), chosen.get("confidence", 0.7) * trust_factor
	)
	to_npc.brain.memory.add_acquired_belief(
		str(chosen["description"]), from_npc.npc_name, trust
	)

func _exchange_object_knowledge(from_npc: Node, to_npc: Node) -> void:
	"""Share object knowledge between NPCs during conversation.
	Role-filtered: NPCs prefer sharing objects relevant to their role.
	Trust-weighted: objects from trusted sources get 'reliable' flag."""
	if from_npc.brain == null or to_npc.brain == null:
		return
	if from_npc.brain.memory == null or to_npc.brain.memory == null:
		return

	var speaker_role: String = from_npc.role if "role" in from_npc else ""
	var shareable: Array = from_npc.brain.memory.get_objects_for_sharing(speaker_role)
	if shareable.is_empty():
		return

	# Role-filtered: prefer objects matching speaker's role
	var affinity_tags: Array = ROLE_TAG_AFFINITY.get(speaker_role, [])
	var preferred: Array = []
	for obj in shareable:
		# Objects at the speaker's work location are more likely to be shared
		var obj_loc: String = obj.get("location", "")
		if speaker_role == "Baker" and obj_loc == "bakery":
			preferred.append(obj)
		elif speaker_role == "Guard" and obj_loc == "guard_post":
			preferred.append(obj)
		elif speaker_role == "Innkeeper" and obj_loc == "inn":
			preferred.append(obj)
		elif speaker_role == "Blacksmith" and obj_loc == "blacksmith":
			preferred.append(obj)
		elif speaker_role == "Herbalist" and obj_loc == "herbalist_shop":
			preferred.append(obj)
		elif speaker_role == "Farmer" and obj_loc == "farm":
			preferred.append(obj)
		elif obj.get("state", "") in ["broken", "empty", "locked"]:
			preferred.append(obj)  # Problematic objects are always interesting

	var to_share: Array = preferred if preferred.size() > 0 else shareable
	# Share 1-2 objects per conversation
	var share_count: int = mini(to_share.size(), randi_range(1, 2))
	to_share.shuffle()

	var trust: float = to_npc.brain.memory.compute_trust(from_npc.npc_name)
	var is_reliable: bool = trust > 0.6

	for i in range(share_count):
		var obj: Dictionary = to_share[i]
		var obj_id: String = obj.get("id", "")
		if obj_id == "":
			continue
		# Don't share if listener already knows it from direct observation
		var existing: Dictionary = to_npc.brain.memory.get_known_object(obj_id)
		if not existing.is_empty() and existing.get("learned_from", "") == "direct":
			continue

		to_npc.brain.memory.add_object_knowledge(
			obj_id, obj.get("name", ""), obj.get("type", ""),
			obj.get("position", Vector2.ZERO), obj.get("state", ""),
			obj.get("location", ""), from_npc.npc_name, is_reliable
		)

		# Create a tagged event about the shared knowledge
		var state: String = obj.get("state", "")
		if state in ["broken", "empty", "locked"]:
			to_npc.brain.memory.add_tagged_event(
				"%s told me the %s at %s is %s" % [from_npc.npc_name, obj.get("name", ""), obj.get("location", ""), state],
				0.5 * clampf(trust + 0.3, 0.3, 1.0),
				["object_knowledge", "second-hand"],
				from_npc.npc_name, "object_problem", 0.7 * clampf(trust + 0.3, 0.3, 1.0)
			)
			print("[SocialProp] %s shared object knowledge with %s: %s at %s is %s" % [from_npc.npc_name, to_npc.npc_name, obj.get("name", ""), obj.get("location", ""), state])

func _fallback_line(speaker_role: String, listener_role: String) -> String:
	var lines: Dictionary = {
		"Gossip": "Did you hear what happened near the square?",
		"Guard": "Stay safe out there, %s." % listener_role,
		"Baker": "Fresh batch just came out of the oven!",
		"Farmer": "Rain's coming, I can feel it.",
		"Innkeeper": "You should stop by the inn later.",
		"Courier": "I've got news from the road.",
		"Herbalist": "I've been preparing new remedies.",
		"Blacksmith": "The forge has been keeping me busy.",
	}
	return lines.get(speaker_role, "Good day, %s." % listener_role)

func _has_social_intention(npc: Node, target_name: String) -> bool:
	## Check if an NPC has a thought-loop intention to socialize or talk to a specific person.
	if npc.brain == null:
		return false
	for intent in npc.brain.active_intentions:
		var goal: String = intent.get("goal", "").to_lower()
		if "talk" in goal or "socialize" in goal or "chat" in goal or "gossip" in goal:
			return true
		if target_name.to_lower() in goal:
			return true
	return false

func _pair_key(name_a: String, name_b: String) -> String:
	if name_a < name_b:
		return name_a + ":" + name_b
	return name_b + ":" + name_a
