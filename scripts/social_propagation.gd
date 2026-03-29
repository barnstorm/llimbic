extends Node
## res://scripts/social_propagation.gd — NPC-to-NPC conversation system
## When NPCs are close enough and willing, they stop, face each other, and talk.
## Nearby NPCs can overhear via the hearing system.

var _pulse_timer: float = 0.0
var _pulse_interval: float = 5.0  # every 5 real seconds
var _cooldowns: Dictionary = {}   # "npcA:npcB" -> time remaining
var _active_conversations: Array[Dictionary] = []  # ongoing conversations
var _inference_client: Node = null

const CONVERSE_RANGE: float = 64.0  # 2 tiles
const COOLDOWN_DURATION: float = 60.0  # 1 game-minute between conversations for same pair

func _ready() -> void:
	call_deferred("_find_inference_client")

func _find_inference_client() -> void:
	for child in get_tree().root.get_children():
		if child.name == "InferenceClient":
			_inference_client = child
			break

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
	if npc_a._state == npc_a.State.TALKING or npc_a._state == npc_a.State.CONVERSING:
		return
	if npc_b._state == npc_b.State.TALKING or npc_b._state == npc_b.State.CONVERSING:
		return

	# Both must have social_need > 30
	if npc_a.brain.layer1.social_need < 30.0 or npc_b.brain.layer1.social_need < 30.0:
		return

	# Cooldown check
	var key: String = _pair_key(npc_a.npc_name, npc_b.npc_name)
	if _cooldowns.has(key):
		return

	# Check if they can see each other (at least one must see the other)
	var a_sees_b: bool = npc_a.brain.perception != null and npc_a.brain.perception.can_see(npc_a.global_position, npc_b.global_position)
	var b_sees_a: bool = npc_b.brain.perception != null and npc_b.brain.perception.can_see(npc_b.global_position, npc_a.global_position)
	if not a_sees_b and not b_sees_a:
		return

	# Base 50% chance, 2x in public zones
	var chance: float = 0.5
	var location: String = ""
	if npc_a.brain.layer3:
		location = npc_a.brain.layer3.location_name_from_position(npc_a.global_position)
	if location in ["town_square", "market", "inn", "well"]:
		chance = 1.0
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

	var speaker_emo: String = ""
	if speaker.brain.layer2:
		speaker_emo = speaker.brain.layer2.get_emotion_summary()
	var listener_emo: String = ""
	if listener.brain.layer2:
		listener_emo = listener.brain.layer2.get_emotion_summary()

	var location: String = ""
	if speaker.brain.layer3:
		location = speaker.brain.layer3.location_name_from_position(speaker.global_position)
	var context: String = "At %s, %s" % [location, speaker.brain.get_current_action()]
	var recent: Array = speaker.brain.memory.get_recent_events_text(3)

	_inference_client.layer3_converse(
		speaker.role, speaker_emo,
		listener.role, listener_emo,
		context, recent,
		func(success: bool, data: Dictionary) -> void:
			_on_speech_received(convo, speaker, success, data)
	)

func _on_speech_received(convo: Dictionary, speaker: Node, success: bool, data: Dictionary) -> void:
	if not is_instance_valid(speaker):
		_cleanup_conversation(convo)
		return

	var utterance: String = data.get("utterance", "...")
	var topic: String = data.get("topic", "small talk")

	# Speaker says it out loud (shows bubble + broadcasts to hearing range)
	speaker.speak(utterance)

	# Exchange memory events between the pair
	_exchange_events(convo["speaker"], convo["listener"])

	# Record the conversation in both NPCs' memory
	var listener: Node = convo["listener"] if speaker == convo["speaker"] else convo["speaker"]
	speaker.brain.memory.add_tagged_event(
		"Talked to %s about %s" % [listener.npc_name, topic], 0.5, ["conversation"]
	)

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
	"""Transfer a tagged event from one NPC's memory to another."""
	var events: Array = from_npc.brain.memory.get_tagged_events_for_exchange()
	if events.is_empty():
		return
	var evt: Dictionary = events[randi() % events.size()]
	var new_salience: float = evt["salience"] * 0.7
	to_npc.brain.memory.add_tagged_event(
		str(evt["description"]), new_salience, ["second-hand"], from_npc.npc_name
	)
	to_npc.brain.memory.add_acquired_belief(
		str(evt["description"]), from_npc.npc_name,
		to_npc.brain.memory.get_trust(from_npc.npc_name)
	)

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

func _pair_key(name_a: String, name_b: String) -> String:
	if name_a < name_b:
		return name_a + ":" + name_b
	return name_b + ":" + name_a
